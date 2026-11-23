{ parc_solid: which files go together into which solid block, and in what order (PArc's own
  design, MIT).

  Planning a set of new files is four steps:

  1. Rules. The `[File groups]` table (parc_presets.ArcGroupLines: "$group" headers followed by
     masks) is compiled once into three lookups: exact base names, "*.ext" extensions (both
     hashed) and the few remaining wildcard masks. For each file this gives the set of groups
     whose masks match it and its "home" group (the group of the first matching line); files
     that match nothing are in "$default".

  2. Order. Files are sorted by home group, lower-case extension, directory and base name.
     Then "twins" are pulled together: a file whose base name already appeared earlier in the
     same (group, extension) run is moved right behind the first file with that name, so the
     copies of a file kept in several directories (versions, other targets, backups) end up
     adjacent, where even a small window sees them. The order does not depend on the thread
     count or the platform (byte comparisons on UTF-8 names). With -s- (or -s1f), or when
     every method stores, the order does not matter and files keep the order they were found
     in (folder by folder).

  3. Kind. The kind of a file selects its method in the `-m` group list: the first group of the
     list (after the default) that is in the file's group set, otherwise the default. If the
     list has a `$text` or `$compressed` method, the content is checked: big files are sampled
     at 3 (from 128 KB) or 5 (from 8 MB) evenly spread places, 64 KB each, and the verdict of
     more than half of the samples counts; small files are judged together with their
     neighbours of the same kind and extension (runs of up to 1 MB: whole files from the
     start of the run, and from its middle file, until 64 KB each; both must agree). Text moves default
     and compressed files to `$text`; compressed data moves any file to `$compressed` (cheap
     to code and no gain from the heavier methods); binary data moves text or compressed
     files to their next group. A `$wav`/`$bmp` file that does not look like samples or pixels
     (parc_mmdet) falls back to the next group. Reading is done by a job pool (batches of
     files), and the result only depends on the bytes.

  4. Blocks. For each kind, its files (in the order of step 2) are cut into solid blocks:
     - `tta`/`mm` without an explicit sample layout: one file per block (the layout is
       detected per stream);
     - `-s` limits: a new block when the extension changes (`e`), after N files (`Nf`), or
       once the block holds at least the given size (the file that crosses it closes it);
     - the blocks of block-local stages: a solid block holds at most one `dict` or `lzp`
       block, or four `bwt` blocks (the codec restarts there anyway; more, smaller solid blocks
       are compressed in parallel).
     Blocks come out in the order of their first file.

  Updating (parc.lpr) uses SplitRun for the files of old blocks that have to be rewritten. }
unit parc_solid;

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  SysUtils, Types, parc_presets;

type
  TSolidRule = (srNone, srExt, srBytes, srCount);
  TSolidLimit = record
    Rule: TSolidRule;
    Value: Int64;
  end;
  { Empty: everything together (only the methods cut). }
  TSolidLimits = array of TSolidLimit;

  TPlanFile = record
    Name: string;       // stored name: UTF-8 with '/'
    DiskPath: string;   // where to read it for the content checks ('' = do not read)
    Size: Int64;
    Hint: string;       // <> '': method of the old block it comes from (keeps that kind if
                        // the list has a method with the same stages)
  end;

  TPlanBlock = record
    Method: string;
    Files: TIntegerDynArray;   // indices into the planned array, in block order
  end;
  TPlanBlocks = array of TPlanBlock;

{ The text after "-s": '' = everything together; '-' (or 'zip', 'arj') = one file per block;
  '7z', 'cab' = together; otherwise a list of limits, the first one reached closes the block:
  'e' = extension change, N or Nf = N files (1f = non-solid), N with b/k/m/g = at least that
  many bytes. With ';' the part after it applies (the part before is for directory blocks,
  which PArc does not split). False if not understood. }
function ParseSolidSpec(const Opt: string; out Limits: TSolidLimits): Boolean;

{ Solid blocks for new files with the methods per group GM (DecodeMethod). }
function PlanSolidBlocks(const Files: array of TPlanFile; const GM: TGroupMethods;
  const Limits: TSolidLimits): TPlanBlocks;

{ Cuts Files[Order[0..]] (already in order) for Method with Limits and the method's own
  block limits; returns the runs as lists of indices into Files. }
function SplitRun(const Method: string; const Files: array of TPlanFile;
  const Order: array of Integer; const Limits: TSolidLimits): TPlanBlocks;

{ The sort order of step 2 (indices into Files); exposed for tests and the update path. }
function SolidOrder(const Files: array of TPlanFile): TIntegerDynArray;

{ Home group of a name ('$text', ..., '$default') and lower-case extension (for tests). }
function HomeGroupOf(const Name: string): string;
function LowerExt(const Name: string): string;

implementation

uses
  Classes, Math, parc_os, parc_filetype, parc_mmdet, parc_strmap, parc_parallel,
  parc_bwt, parc_lzp, parc_dict, parc_tta, parc_mm;

const
  KB = 1024;
  MB = 1024 * KB;
  SAMPLE = 64 * KB;          // bytes of a content sample
  RUN_BYTES = 1024 * KB;     // small files judged together, up to this many bytes
  SMALL_FILE = 64 * KB;      // below this, files are judged in runs with their neighbours
  MIN_JUDGE = 4 * KB;        // fewer bytes than this: no verdict (the name decides)
  RUN_FILES = 256;           // at most this many small files per run
  MAX_GROUPS = 64;
  BWT_SOLID_BLOCKS = 4;      // bwt blocks per solid block

type
  TGroupSet = QWord;

  TWild = record
    Mask: string;   // lower case
    Line, Group: Integer;
  end;

  { compiled [File groups] }
  TRules = record
    Loaded: Boolean;
    GroupNames: TStringArray;     // lower case, with '$'
    DefaultGroup: Integer;
    NameMap, ExtMap: TStrIntMap;     // key -> slot in NameHits/ExtHits
    NameHits, ExtHits: array of record Line, Group: Integer; Groups: TGroupSet; end;
    NoExt: record Line, Group: Integer; Groups: TGroupSet; end;   // the "*." mask
    Wild: array of TWild;
  end;

var
  R: TRules;
  RulesLock: TRTLCriticalSection;

{ ---------------------------------------------------------------------------------------- }
{ Names                                                                                    }
{ ---------------------------------------------------------------------------------------- }

function AsciiLower(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  UniqueString(Result);
  for i := 1 to Length(Result) do
    if Result[i] in ['A'..'Z'] then Result[i] := Chr(Ord(Result[i]) + 32);
end;

function BaseOf(const Name: string): string;
var
  i: Integer;
begin
  i := Length(Name);
  while (i > 0) and (Name[i] <> '/') do Dec(i);
  Result := Copy(Name, i + 1, MaxInt);
end;

function DirOf(const Name: string): string;
var
  i: Integer;
begin
  i := Length(Name);
  while (i > 0) and (Name[i] <> '/') do Dec(i);
  Result := Copy(Name, 1, i);
end;

{ After the last '.' of the base name ('' if there is none). }
function ExtOfBase(const Base: string): string;
var
  i: Integer;
begin
  i := Length(Base);
  while (i > 0) and (Base[i] <> '.') do Dec(i);
  if i = 0 then Result := '' else Result := Copy(Base, i + 1, MaxInt);
end;

function LowerExt(const Name: string): string;
begin
  Result := AsciiLower(ExtOfBase(BaseOf(Name)));
end;

{ '*' = any run, '?' = one character (a whole UTF-8 sequence). Both strings lower case. }
function WildMatch(const M, S: string): Boolean;
var
  mi, si, starM, starS: Integer;

  function NextChar(i: Integer): Integer;
  begin
    Result := i + 1;
    while (Result <= Length(S)) and ((Ord(S[Result]) and $C0) = $80) do Inc(Result);
  end;

begin
  mi := 1; si := 1; starM := 0; starS := 0;
  while si <= Length(S) do
  begin
    if (mi <= Length(M)) and (M[mi] = '*') then
    begin
      starM := mi; starS := si; Inc(mi);
    end
    else if (mi <= Length(M)) and (M[mi] = '?') then
    begin
      Inc(mi); si := NextChar(si);
    end
    else if (mi <= Length(M)) and (M[mi] = S[si]) then
    begin
      Inc(mi); Inc(si);
    end
    else if starM > 0 then
    begin
      mi := starM + 1;
      starS := NextChar(starS);
      si := starS;
    end
    else
      Exit(False);
  end;
  while (mi <= Length(M)) and (M[mi] = '*') do Inc(mi);
  Result := mi > Length(M);
end;

{ ---------------------------------------------------------------------------------------- }
{ Rules                                                                                    }
{ ---------------------------------------------------------------------------------------- }

function GroupIndex(const G: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(R.GroupNames) do
    if R.GroupNames[i] = G then Exit(i);
  Result := -1;
end;

procedure LoadRules;
var
  Lines: TStringArray;
  i, g, k: Integer;
  L, E: string;
begin
  if R.Loaded then Exit;
  EnterCriticalSection(RulesLock);
  try
    if R.Loaded then Exit;
    R.NameMap.Init;
    R.ExtMap.Init;
    R.NoExt.Line := -1;
    Lines := ArcGroupLines;
    g := -1;
    for i := 0 to High(Lines) do
    begin
      L := AsciiLower(Trim(Lines[i]));
      if L = '' then Continue;
      if L[1] = '$' then
      begin
        g := GroupIndex(L);
        if g < 0 then
        begin
          if Length(R.GroupNames) >= MAX_GROUPS then
            raise Exception.Create('too many file groups');
          SetLength(R.GroupNames, Length(R.GroupNames) + 1);
          R.GroupNames[High(R.GroupNames)] := L;
          g := High(R.GroupNames);
        end;
        Continue;
      end;
      if g < 0 then Continue;
      if L = '*.' then
      begin
        if R.NoExt.Line < 0 then begin R.NoExt.Line := i; R.NoExt.Group := g; end;
        R.NoExt.Groups := R.NoExt.Groups or (QWord(1) shl g);
      end
      else if (Copy(L, 1, 2) = '*.') and (LastDelimiter('*?/', Copy(L, 3, MaxInt)) = 0) then
      begin
        E := Copy(L, 3, MaxInt);
        k := R.ExtMap.Get(E);
        if k < 0 then
        begin
          k := Length(R.ExtHits);
          SetLength(R.ExtHits, k + 1);
          R.ExtHits[k].Line := i; R.ExtHits[k].Group := g; R.ExtHits[k].Groups := 0;
          R.ExtMap.Put(E, k);
        end;
        R.ExtHits[k].Groups := R.ExtHits[k].Groups or (QWord(1) shl g);
      end
      else if LastDelimiter('*?', L) = 0 then
      begin
        k := R.NameMap.Get(L);
        if k < 0 then
        begin
          k := Length(R.NameHits);
          SetLength(R.NameHits, k + 1);
          R.NameHits[k].Line := i; R.NameHits[k].Group := g; R.NameHits[k].Groups := 0;
          R.NameMap.Put(L, k);
        end;
        R.NameHits[k].Groups := R.NameHits[k].Groups or (QWord(1) shl g);
      end
      else
      begin
        k := Length(R.Wild);
        SetLength(R.Wild, k + 1);
        R.Wild[k].Mask := L; R.Wild[k].Line := i; R.Wild[k].Group := g;
      end;
    end;
    R.DefaultGroup := GroupIndex('$default');
    if R.DefaultGroup < 0 then
    begin
      SetLength(R.GroupNames, Length(R.GroupNames) + 1);
      R.GroupNames[High(R.GroupNames)] := '$default';
      R.DefaultGroup := High(R.GroupNames);
    end;
    WriteBarrier;
    R.Loaded := True;
  finally
    LeaveCriticalSection(RulesLock);
  end;
end;

{ Groups matching a lower-case base name with extension LExt; Home = group of the first
  matching line (the default group if none). }
function MatchGroups(const LBase, LExt: string; HasDot: Boolean; out Home: Integer): TGroupSet;
var
  k, Line: Integer;
begin
  LoadRules;
  Result := 0;
  Line := MaxInt;
  Home := R.DefaultGroup;
  k := R.NameMap.Get(LBase);
  if k >= 0 then
  begin
    Result := Result or R.NameHits[k].Groups;
    if R.NameHits[k].Line < Line then begin Line := R.NameHits[k].Line; Home := R.NameHits[k].Group; end;
  end;
  if HasDot then
  begin
    k := R.ExtMap.Get(LExt);
    if k >= 0 then
    begin
      Result := Result or R.ExtHits[k].Groups;
      if R.ExtHits[k].Line < Line then begin Line := R.ExtHits[k].Line; Home := R.ExtHits[k].Group; end;
    end;
  end
  else if R.NoExt.Line >= 0 then
  begin
    Result := Result or R.NoExt.Groups;
    if R.NoExt.Line < Line then begin Line := R.NoExt.Line; Home := R.NoExt.Group; end;
  end;
  for k := 0 to High(R.Wild) do
    if ((Result and (QWord(1) shl R.Wild[k].Group)) = 0) or (R.Wild[k].Line < Line) then
      if WildMatch(R.Wild[k].Mask, LBase) then
      begin
        Result := Result or (QWord(1) shl R.Wild[k].Group);
        if R.Wild[k].Line < Line then begin Line := R.Wild[k].Line; Home := R.Wild[k].Group; end;
      end;
end;

function HomeGroupOf(const Name: string): string;
var
  B: string;
  Home: Integer;
begin
  B := AsciiLower(BaseOf(Name));
  MatchGroups(B, ExtOfBase(B), Pos('.', B) > 0, Home);
  Result := R.GroupNames[Home];
end;

{ ---------------------------------------------------------------------------------------- }
{ Order                                                                                    }
{ ---------------------------------------------------------------------------------------- }

type
  TFileKey = record
    Home: Integer;
    Ext, Dir, Base: string;   // lower case
    Groups: TGroupSet;
  end;
  TFileKeys = array of TFileKey;
  TIntArray = array of Integer;
  TCmpFn = function(a, b: Integer): Integer of object;

  TSorter = class
    K: TFileKeys;
    Names: array of string;
    Rank: TIntArray;
    function CmpKey(a, b: Integer): Integer;
    function CmpRank(a, b: Integer): Integer;
  end;

function TSorter.CmpKey(a, b: Integer): Integer;
begin
  Result := K[a].Home - K[b].Home;
  if Result <> 0 then Exit;
  Result := CompareStr(K[a].Ext, K[b].Ext);
  if Result <> 0 then Exit;
  Result := CompareStr(K[a].Dir, K[b].Dir);
  if Result <> 0 then Exit;
  Result := CompareStr(K[a].Base, K[b].Base);
  if Result <> 0 then Exit;
  Result := CompareStr(Names[a], Names[b]);
  if Result = 0 then Result := a - b;
end;

function TSorter.CmpRank(a, b: Integer): Integer;
begin
  Result := Rank[a] - Rank[b];
end;

{ Stable merge sort of Idx. }
procedure MergeSort(var Idx: TIntArray; Cmp: TCmpFn);
var
  Tmp: TIntArray;
  w, lo, mid, hi, i, j, k, n: Integer;
  Src, Dst, Sw: TIntArray;
begin
  n := Length(Idx);
  if n < 2 then Exit;
  // runs of 16 by insertion sort
  lo := 0;
  while lo < n do
  begin
    hi := Min(lo + 16, n);
    for i := lo + 1 to hi - 1 do
    begin
      k := Idx[i];
      j := i - 1;
      while (j >= lo) and (Cmp(Idx[j], k) > 0) do
      begin
        Idx[j + 1] := Idx[j];
        Dec(j);
      end;
      Idx[j + 1] := k;
    end;
    lo := hi;
  end;
  SetLength(Tmp, n);
  Src := Idx; Dst := Tmp;
  w := 16;
  while w < n do
  begin
    lo := 0;
    while lo < n do
    begin
      mid := Min(lo + w, n);
      hi := Min(lo + 2 * w, n);
      i := lo; j := mid; k := lo;
      while (i < mid) and (j < hi) do
      begin
        if Cmp(Src[j], Src[i]) < 0 then begin Dst[k] := Src[j]; Inc(j); end
        else begin Dst[k] := Src[i]; Inc(i); end;
        Inc(k);
      end;
      while i < mid do begin Dst[k] := Src[i]; Inc(i); Inc(k); end;
      while j < hi do begin Dst[k] := Src[j]; Inc(j); Inc(k); end;
      lo := hi;
    end;
    Sw := Src; Src := Dst; Dst := Sw;
    w := w * 2;
  end;
  Idx := Src;
end;

function MakeKeys(const Files: array of TPlanFile): TFileKeys;
var
  i: Integer;
  B: string;
begin
  LoadRules;
  SetLength(Result, Length(Files));
  for i := 0 to High(Files) do
  begin
    B := BaseOf(Files[i].Name);
    Result[i].Dir := AsciiLower(DirOf(Files[i].Name));
    Result[i].Base := AsciiLower(B);
    Result[i].Ext := ExtOfBase(Result[i].Base);
    Result[i].Groups := MatchGroups(Result[i].Base, Result[i].Ext, Pos('.', B) > 0, Result[i].Home);
  end;
end;

function OrderOf(const Files: array of TPlanFile; const K: TFileKeys): TIntArray;
var
  S: TSorter;
  i, j, Start, p: Integer;
  First: TStrIntMap;
begin
  SetLength(Result, Length(Files));
  for i := 0 to High(Result) do Result[i] := i;
  S := TSorter.Create;
  try
    S.K := K;
    SetLength(S.Names, Length(Files));
    for i := 0 to High(Files) do S.Names[i] := Files[i].Name;
    MergeSort(Result, @S.CmpKey);
    // twins: rank = position of the first file with the same base name in the same
    // (home group, extension) run
    SetLength(S.Rank, Length(Files));
    Start := 0;
    while Start < Length(Result) do
    begin
      j := Start;
      while (j < Length(Result)) and (K[Result[j]].Home = K[Result[Start]].Home) and
            (K[Result[j]].Ext = K[Result[Start]].Ext) do Inc(j);
      First.Init;
      for i := Start to j - 1 do
      begin
        p := First.Get(K[Result[i]].Base);
        if p < 0 then
        begin
          First.Put(K[Result[i]].Base, i);
          p := i;
        end;
        S.Rank[Result[i]] := p;
      end;
      Start := j;
    end;
    // stable: equal ranks keep the order of the first sort
    MergeSort(Result, @S.CmpRank);
  finally
    S.Free;
  end;
end;

function SolidOrder(const Files: array of TPlanFile): TIntegerDynArray;
var
  O: TIntArray;
  i: Integer;
begin
  O := OrderOf(Files, MakeKeys(Files));
  SetLength(Result, Length(O));
  for i := 0 to High(O) do Result[i] := O[i];
end;

{ ---------------------------------------------------------------------------------------- }
{ Content                                                                                  }
{ ---------------------------------------------------------------------------------------- }

type
  TVerdict = (vNone, vText, vComp, vBin, vMixed);
  TCheckKind = (ckData, ckMedia);

  { A unit to judge: one file, or a run of small files judged together. }
  TCheckUnit = record
    Kind: TCheckKind;
    First, Count: Integer;   // positions in the order array
    Verdict: TVerdict;
    Media: Boolean;
  end;
  TCheckUnits = array of TCheckUnit;

  TCheckJob = class(TParallelJob)
    Files: ^TPlanFile;       // Files[0..]
    Order: TIntArray;
    Units: ^TCheckUnit;
    UFirst, UCount: Integer;
    procedure Process; override;
  end;

function OpenRead(const Path: string; out Fs: TFileStream): Boolean;
begin
  Fs := nil;
  if Path = '' then Exit(False);
  try
    Fs := TFileStream.Create(FsPath(Path), fmOpenRead or fmShareDenyNone);
    Result := True;
  except
    Result := False;
  end;
end;

function ReadAt(Fs: TFileStream; Pos: Int64; Buf: PByte; Count: Integer): Integer;
var
  n: Integer;
begin
  Result := 0;
  try
    Fs.Position := Pos;
    while Result < Count do
    begin
      n := Fs.Read(Buf[Result], Count - Result);
      if n <= 0 then Break;
      Inc(Result, n);
    end;
  except
    // a read error: what was read so far
  end;
end;

function VerdictOf(Buf: PByte; n: Integer): TVerdict;
var
  T: string;
begin
  if n < MIN_JUDGE then Exit(vNone);
  T := DetectDatatype(Buf, n);
  if Pos('$text', T) > 0 then Result := vText
  else if Pos('$compressed', T) > 0 then Result := vComp
  else Result := vBin;
end;

procedure TCheckJob.Process;
var
  Buf: array of Byte;
  u, i, n, k, Samples: Integer;
  Fs: TFileStream;
  Size, P: Int64;
  V, W: TVerdict;
  Votes: array[TVerdict] of Integer;
  F: ^TPlanFile;

  { Whole files of the run from position From on, until Want bytes; returns the bytes read. }
  function ReadRun(From, Want: Integer): Integer;
  var
    j: Integer;
    G: ^TPlanFile;
    Fr: TFileStream;
  begin
    Result := 0;
    j := From;
    while (j < Units[u].First + Units[u].Count) and (Result < Want) do
    begin
      G := @Files[Order[j]];
      if OpenRead(G^.DiskPath, Fr) then
      try
        Inc(Result, ReadAt(Fr, 0, @Buf[Result], Want - Result));
      finally
        Fr.Free;
      end;
      Inc(j);
    end;
  end;

begin
  SetLength(Buf, SAMPLE);
  for u := UFirst to UFirst + UCount - 1 do
    with Units[u] do
    begin
      if Kind = ckMedia then
      begin
        F := @Files[Order[First]];
        Media := True;   // if it cannot be read, the name decides
        if OpenRead(F^.DiskPath, Fs) then
        try
          n := ReadAt(Fs, 0, @Buf[0], SAMPLE);
          Media := MmLooksMultimedia(@Buf[0], n, True);
        finally
          Fs.Free;
        end;
      end
      else if Count = 1 then
      begin
        F := @Files[Order[First]];
        Size := F^.Size;
        FillChar(Votes, SizeOf(Votes), 0);
        Samples := 0;
        if OpenRead(F^.DiskPath, Fs) then
        try
          if Size <= 2 * SAMPLE then Samples := 1
          else if Size < 8 * MB then Samples := 3
          else Samples := 5;
          for k := 0 to Samples - 1 do
          begin
            if Samples = 1 then
              n := ReadAt(Fs, 0, @Buf[0], SAMPLE)
            else
            begin
              P := (Size - SAMPLE) * k div (Samples - 1);
              n := ReadAt(Fs, P, @Buf[0], SAMPLE);
            end;
            Inc(Votes[VerdictOf(@Buf[0], n)]);
          end;
        finally
          Fs.Free;
        end;
        // the verdict of more than half of the samples (none: the name decides)
        V := vNone;
        Samples := Samples - Votes[vNone];
        for W := vText to vBin do
          if 2 * Votes[W] > Samples then V := W;
        Verdict := V;
      end
      else
      begin
        // a run of small files: their bytes one after another; a long run is judged by
        // two samples, from its first file and from the file in its middle
        Size := 0;
        for i := First to First + Count - 1 do Inc(Size, Files[Order[i]].Size);
        if Size <= SAMPLE then
          Verdict := VerdictOf(@Buf[0], ReadRun(First, SAMPLE))
        else
        begin
          P := 0;
          i := First;
          while (i < First + Count - 1) and (2 * (P + Files[Order[i]].Size) <= Size) do
          begin
            Inc(P, Files[Order[i]].Size);
            Inc(i);
          end;
          V := VerdictOf(@Buf[0], ReadRun(First, SAMPLE));
          W := VerdictOf(@Buf[0], ReadRun(i, SAMPLE));
          if V = vNone then V := W
          else if (W <> vNone) and (W <> V) then V := vMixed;
          Verdict := V;
        end;
      end;
    end;
end;

{ ---------------------------------------------------------------------------------------- }
{ Blocks                                                                                   }
{ ---------------------------------------------------------------------------------------- }

function StageName(const Stage: string): string;
var
  p: Integer;
begin
  p := Pos(':', Stage);
  if p > 0 then Result := Copy(Stage, 1, p - 1) else Result := Stage;
  Result := LowerCase(Trim(Result));
end;

{ tta/mm without an explicit layout (or with a header offset): one file per block. }
function PerFileMethod(const Method: string): Boolean;
var
  Stages, Parts: TStringArray;
  i: Integer;
  W, O: Integer;
begin
  Result := False;
  Stages := Method.Split(['+']);
  for i := 0 to High(Stages) do
  begin
    Parts := Trim(Stages[i]).Split([':']);
    if Length(Parts) = 0 then Continue;
    W := 0; O := 0;
    try
      case StageName(Stages[i]) of
        'tta': with ParseTtaEncParams(Parts) do begin W := WordSize; O := Offset; end;
        'mm':  with ParseMmEncParams(Parts) do begin W := WordSize; O := Offset; end;
      else
        Continue;
      end;
    except
      Exit(True);
    end;
    if (W <= 0) or (O <> 0) then Exit(True);
  end;
end;

{ Most bytes a solid block may hold for the block-local stages of Method (0 = no limit). }
function MethodCap(const Method: string): Int64;
var
  Stages, Parts: TStringArray;
  i: Integer;
  C: Int64;
begin
  Result := 0;
  Stages := Method.Split(['+']);
  for i := 0 to High(Stages) do
  begin
    Parts := Trim(Stages[i]).Split([':']);
    C := 0;
    try
      case StageName(Stages[i]) of
        'dict': C := ParseDictBlockSize(Parts);
        'lzp':  C := ParseLzpParams(Parts).BlockSize;
        'bwt':  C := Int64(ParseBwtParams(Parts).BlockSize) * BWT_SOLID_BLOCKS;
      end;
    except
      C := 0;
    end;
    if (C > 0) and ((Result = 0) or (C < Result)) then Result := C;
  end;
end;

function SplitRun(const Method: string; const Files: array of TPlanFile;
  const Order: array of Integer; const Limits: TSolidLimits): TPlanBlocks;
var
  PerFile, Cut: Boolean;
  Cap, Bytes: Int64;
  i, j, n, Cnt: Integer;
  PrevExt, Ext: string;
  Cur: TIntegerDynArray;

  procedure Close;
  begin
    if n = 0 then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)].Method := Method;
    Result[High(Result)].Files := Copy(Cur, 0, n);
    n := 0; Bytes := 0; Cnt := 0;
  end;

begin
  Result := nil;
  PerFile := PerFileMethod(Method);
  for j := 0 to High(Limits) do
    if (Limits[j].Rule = srNone) or ((Limits[j].Rule = srCount) and (Limits[j].Value <= 1)) then
      PerFile := True;
  Cap := MethodCap(Method);
  n := 0; Bytes := 0; Cnt := 0; PrevExt := '';
  SetLength(Cur, Length(Order));
  for i := 0 to High(Order) do
  begin
    Ext := LowerExt(Files[Order[i]].Name);
    if n > 0 then
    begin
      // limits that a file cannot cross: close the block before it
      Cut := PerFile or ((Cap > 0) and (Bytes + Files[Order[i]].Size > Cap));
      for j := 0 to High(Limits) do
        if (Limits[j].Rule = srExt) and (Ext <> PrevExt) then Cut := True;
      if Cut then Close;
    end;
    Cur[n] := Order[i];
    Inc(n);
    Inc(Bytes, Files[Order[i]].Size);
    Inc(Cnt);
    PrevExt := Ext;
    // "at least" limits: the file that reaches them closes the block
    for j := 0 to High(Limits) do
      if ((Limits[j].Rule = srBytes) and (Bytes >= Limits[j].Value)) or
         ((Limits[j].Rule = srCount) and (Cnt >= Limits[j].Value)) then
      begin
        Close;
        Break;
      end;
  end;
  Close;
end;

{ Stage names of a method: "orep:96m+lzma:8m" -> "+orep+lzma". }
function Signature(const Method: string): string;
var
  St: TStringArray;
  i: Integer;
begin
  Result := '';
  St := Method.Split(['+']);
  for i := 0 to High(St) do Result := Result + '+' + StageName(St[i]);
end;

function IsStoringMethod(const Method: string): Boolean;
begin
  Result := (Signature(Method) = '+storing') or (Trim(Method) = '');
end;

function GmIndex(const GM: TGroupMethods; const G: string): Integer;
var
  i: Integer;
begin
  for i := 1 to High(GM) do
    if LowerCase(GM[i].Group) = G then Exit(i);
  Result := -1;
end;

{ First entry of GM (after the default) whose group is in S, without those in Skip. }
function KindOf(const GM: TGroupMethods; const GmBit: array of Integer; S, Skip: TGroupSet): Integer;
var
  i: Integer;
begin
  S := S and not Skip;
  for i := 1 to High(GM) do
    if (GmBit[i] >= 0) and ((S and (QWord(1) shl GmBit[i])) <> 0) then Exit(i);
  Result := 0;
end;

function PlanSolidBlocks(const Files: array of TPlanFile; const GM: TGroupMethods;
  const Limits: TSolidLimits): TPlanBlocks;
var
  K: TFileKeys;
  Order: TIntArray;
  Kind, Posn: TIntArray;
  GmBit: array of Integer;
  iText, iComp, iWav, iBmp, i, j, t, u, n, nu: Integer;
  MediaSkip: TGroupSet;
  Units: TCheckUnits;
  UnitOf: TIntArray;
  Jobs: array of TCheckJob;
  Pool: TJobPool;
  Lists: array of TIntArray;
  Counts: TIntArray;
  Part: TPlanBlocks;
  Starts: TIntArray;
  Tmp: TPlanBlock;
  Data, Solid: Boolean;

  procedure AddUnit(Kd: TCheckKind; F, C: Integer);
  var
    x: Integer;
  begin
    if nu >= Length(Units) then SetLength(Units, 2 * nu + 16);
    Units[nu].Kind := Kd; Units[nu].First := F; Units[nu].Count := C;
    Units[nu].Verdict := vNone; Units[nu].Media := True;
    for x := F to F + C - 1 do UnitOf[x] := nu;
    Inc(nu);
  end;

begin
  Result := nil;
  if Length(Files) = 0 then Exit;
  // The order only matters inside solid blocks: with -s- (or -s1f) or when everything is
  // stored, the files keep the order they were found in (folder by folder).
  Solid := False;
  for i := 0 to High(GM) do
    if not IsStoringMethod(GM[i].Method) then Solid := True;
  for i := 0 to High(Limits) do
    if (Limits[i].Rule = srNone) or ((Limits[i].Rule = srCount) and (Limits[i].Value <= 1)) then
      Solid := False;
  // (one method and no order: nothing to look at)
  if Solid or (Length(GM) > 1) then K := MakeKeys(Files)
  else SetLength(K, Length(Files));
  if Solid then
    Order := OrderOf(Files, K)
  else
  begin
    SetLength(Order, Length(Files));
    for i := 0 to High(Order) do Order[i] := i;
  end;

  // kind by name
  SetLength(GmBit, Length(GM));
  for i := 0 to High(GM) do
    if i = 0 then GmBit[i] := -1 else GmBit[i] := GroupIndex(LowerCase(Trim(GM[i].Group)));
  iText := GmIndex(GM, '$text');
  iComp := GmIndex(GM, '$compressed');
  iWav := GmIndex(GM, '$wav');
  iBmp := GmIndex(GM, '$bmp');
  MediaSkip := 0;
  if (iWav > 0) and (GmBit[iWav] >= 0) then MediaSkip := MediaSkip or (QWord(1) shl GmBit[iWav]);
  if (iBmp > 0) and (GmBit[iBmp] >= 0) then MediaSkip := MediaSkip or (QWord(1) shl GmBit[iBmp]);
  SetLength(Kind, Length(Files));
  for i := 0 to High(Files) do
  begin
    Kind[i] := KindOf(GM, GmBit, K[i].Groups, 0);
    if Files[i].Hint <> '' then
      for j := 0 to High(GM) do
        if Signature(GM[j].Method) = Signature(Files[i].Hint) then
        begin
          Kind[i] := j;
          Break;
        end;
  end;

  // content checks (positions in Order)
  SetLength(UnitOf, Length(Order));
  for i := 0 to High(UnitOf) do UnitOf[i] := -1;
  nu := 0;
  i := 0;
  while i < Length(Order) do
  begin
    t := Kind[Order[i]];
    // text can only replace default, text or compressed; compressed data replaces any kind
    Data := ((iText > 0) and ((t = 0) or (t = iText) or (t = iComp))) or (iComp > 0);
    if (Files[Order[i]].DiskPath = '') or (Files[Order[i]].Size = 0) or (Files[Order[i]].Hint <> '') then
    begin
      Inc(i);
      Continue;
    end;
    if (t > 0) and ((t = iWav) or (t = iBmp)) then
    begin
      AddUnit(ckMedia, i, 1);
      Inc(i);
    end
    else if Data and (Files[Order[i]].Size >= SMALL_FILE) then
    begin
      AddUnit(ckData, i, 1);
      Inc(i);
    end
    else if Data then
    begin
      // small files of the same kind and extension that follow, up to one sample
      j := i;
      n := 0;
      while (j < Length(Order)) and (j - i < RUN_FILES) and (Kind[Order[j]] = t) and
            (K[Order[j]].Ext = K[Order[i]].Ext) and (Files[Order[j]].DiskPath <> '') and
            (Files[Order[j]].Size > 0) and (Files[Order[j]].Size < SMALL_FILE) and (n < RUN_BYTES) do
      begin
        Inc(n, Files[Order[j]].Size);
        Inc(j);
      end;
      AddUnit(ckData, i, j - i);
      i := j;
    end
    else
      Inc(i);
  end;
  if nu > 0 then
  begin
    // batches of about 1 MB of reading or 64 units per job
    SetLength(Jobs, 0);
    u := 0;
    while u < nu do
    begin
      j := u;
      n := 0;
      while (j < nu) and (j - u < 64) and (n < 4 * MB) do
      begin
        if Units[j].Kind = ckData then Inc(n, 2 * SAMPLE)
        else Inc(n, SAMPLE);
        Inc(j);
      end;
      SetLength(Jobs, Length(Jobs) + 1);
      Jobs[High(Jobs)] := TCheckJob.Create;
      Jobs[High(Jobs)].Files := @Files[0];
      Jobs[High(Jobs)].Order := Order;
      Jobs[High(Jobs)].Units := @Units[0];
      Jobs[High(Jobs)].UFirst := u;
      Jobs[High(Jobs)].UCount := j - u;
      u := j;
    end;
    Pool := TJobPool.Create(PoolWorkers(32), Length(Jobs));
    try
      try
        for i := 0 to High(Jobs) do Pool.Submit(Jobs[i]);
        for i := 0 to High(Jobs) do Pool.WaitJob(Jobs[i]);
      finally
        Pool.Free;
      end;
    finally
      for i := 0 to High(Jobs) do Jobs[i].Free;
    end;
    for u := 0 to nu - 1 do
      for j := Units[u].First to Units[u].First + Units[u].Count - 1 do
      begin
        i := Order[j];
        t := Kind[i];
        if Units[u].Kind = ckMedia then
        begin
          if not Units[u].Media then Kind[i] := KindOf(GM, GmBit, K[i].Groups, MediaSkip);
        end
        else
          case Units[u].Verdict of
            vText: if (iText > 0) and ((t = 0) or (t = iComp)) then Kind[i] := iText;
            vComp: if iComp > 0 then Kind[i] := iComp;
            vBin:  if (t = iText) or (t = iComp) then Kind[i] := KindOf(GM, GmBit, K[i].Groups,
                     (QWord(1) shl Max(0, GmBit[t])));
          end;
      end;
  end;

  // per kind, in order; then the blocks, ordered by their first file
  SetLength(Lists, Length(GM));
  SetLength(Counts, Length(GM));
  for i := 0 to High(Order) do
  begin
    t := Kind[Order[i]];
    if Counts[t] >= Length(Lists[t]) then SetLength(Lists[t], 2 * Counts[t] + 16);
    Lists[t][Counts[t]] := Order[i];
    Inc(Counts[t]);
  end;
  SetLength(Posn, Length(Files));
  for i := 0 to High(Order) do Posn[Order[i]] := i;
  for t := 0 to High(GM) do
  begin
    if Counts[t] = 0 then Continue;
    SetLength(Lists[t], Counts[t]);
    Part := SplitRun(GM[t].Method, Files, Lists[t], Limits);
    n := Length(Result);
    SetLength(Result, n + Length(Part));
    for i := 0 to High(Part) do Result[n + i] := Part[i];
  end;
  // insertion by first-file position (merging the per-kind lists, each already in order)
  SetLength(Starts, Length(Result));
  for i := 0 to High(Result) do Starts[i] := Posn[Result[i].Files[0]];
  for i := 1 to High(Result) do
  begin
    Tmp := Result[i];
    n := Starts[i];
    j := i - 1;
    while (j >= 0) and (Starts[j] > n) do
    begin
      Result[j + 1] := Result[j];
      Starts[j + 1] := Starts[j];
      Dec(j);
    end;
    Result[j + 1] := Tmp;
    Starts[j + 1] := n;
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ -s                                                                                       }
{ ---------------------------------------------------------------------------------------- }

function ParseSolidSpec(const Opt: string; out Limits: TSolidLimits): Boolean;
var
  S: string;
  i, p: Integer;
  V, Mul: Int64;

  procedure Add(Rule: TSolidRule; Value: Int64);
  begin
    SetLength(Limits, Length(Limits) + 1);
    Limits[High(Limits)].Rule := Rule;
    Limits[High(Limits)].Value := Value;
  end;

begin
  Limits := nil;
  S := LowerCase(Opt);
  p := Pos(';', S);
  if p > 0 then S := Copy(S, p + 1, MaxInt);
  if (S = '') or (S = '7z') or (S = 'cab') then Exit(True);
  if (S = '-') or (S = 'zip') or (S = 'arj') then
  begin
    Add(srNone, 0);
    Exit(True);
  end;
  i := 1;
  while i <= Length(S) do
  begin
    if S[i] = 'e' then
    begin
      Add(srExt, 0);
      Inc(i);
      Continue;
    end;
    if not (S[i] in ['0'..'9']) then Exit(False);
    V := 0;
    while (i <= Length(S)) and (S[i] in ['0'..'9']) do
    begin
      if V > High(Int64) div 16 then Exit(False);
      V := V * 10 + Ord(S[i]) - Ord('0');
      Inc(i);
    end;
    Mul := 0;
    if i <= Length(S) then
      case S[i] of
        'f': begin Mul := 0; Inc(i); end;
        'b': begin Mul := 1; Inc(i); end;
        'k': begin Mul := KB; Inc(i); end;
        'm': begin Mul := MB; Inc(i); end;
        'g': begin Mul := 1024 * MB; Inc(i); end;
      end;
    if Mul = 0 then
    begin
      if V < 1 then Exit(False);
      Add(srCount, V);
    end
    else
    begin
      if V > High(Int64) div Mul then Exit(False);
      Add(srBytes, V * Mul);
    end;
  end;
  Result := True;
end;

initialization
  InitCriticalSection(RulesLock);
finalization
  DoneCriticalSection(RulesLock);
end.
