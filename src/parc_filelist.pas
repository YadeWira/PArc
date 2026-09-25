{ Orden de los archivos y corte en bloques sólidos, como FreeArc 0.67 (ArhiveFileList.hs):
    sort_files         orden "gerpn": grupo de arc.groups (por LÍNEA), extensión, reorder
                       (junta archivos parecidos), directorio y nombre;
    splitFileTypes     tipo de cada tanda de archivos: por arc.groups y, si el método tiene
                       grupos $text/$compressed, por contenido (detect_datatype, detect_mm);
    splitToSolidBlocks un grupo por método (ordenados por el texto del método) y cortes por
                       -s, por el tamaño de bloque de dict/grzip/lzp y "nosolid" de tta/mm.
  Solo para archivos NUEVOS (del disco); los que vienen de un archivo existente los maneja
  CmdModify aparte. Los directorios no pasan por acá (van en su propio bloque, primero). }
unit parc_filelist;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_presets;

type
  TFaFile = record
    Name: string;       // nombre guardado: UTF-8, '/'
    DiskPath: string;   // de dónde leerlo para la detección por contenido
    Size: Int64;
  end;

  TFaCritKind = (fcNone, fcExt, fcSize, fcBlockSize, fcNumber, fcAll);
  TFaCrit = record
    Kind: TFaCritKind;
    Value: Int64;
  end;
  TFaCrits = array of TFaCrit;

  TFaBlock = record
    Method: string;
    Files: array of Integer;   // índices en el arreglo de entrada, en el orden del bloque
  end;
  TFaBlocks = array of TFaBlock;

{ -m como lo escribió el usuario ("4", "9x", "lzma", ...): da el nivel de autodetección
  (clevel de Cmdline.hs: el dígito; si no, 4). }
function FaDetectLevel(const MainMethod: string): Integer;

{ Criterio de -s: [] -> GroupAll; -s- -> GroupNone; -s<mem> -> GroupBySize; -s<N>f -> por
  cantidad; -se -> por extensión. }
function FaCrit(Kind: TFaCritKind; Value: Int64 = 0): TFaCrit;

{ Bloques sólidos para Files con los métodos por grupo GM (DecodeMethod). Sort = False
  desactiva el orden (FreeArc no ordena con -s- ni con -m0). }
function FaSolidBlocks(const Files: array of TFaFile; const GM: TGroupMethods;
  const Crits: TFaCrits; DetectLevel: Integer): TFaBlocks;

{ La clave de orden de FreeArc, expuesta para los tests: grupo de arc.groups (índice de línea)
  y extensión en minúsculas. }
function FaGroupIndex(const Name: string): Integer;
function FaLCExtension(const Name: string): string;

{ Comparación de nombres de FreeArc en Windows (strcasecmp de los bytes UTF-8). }
function FaCompareNames(const A, B: string): Integer;

implementation

uses
  Classes, Math, parc_os, parc_methods, parc_filetype, parc_mmdet, parc_torenc;

const
  KB = 1024;
  MB = 1024 * 1024;
  aGROUP_SIZE = 2 * MB;
  aCHUNKS = 5;
  aCHUNK_SIZE = 64 * KB;

type
  TIntArray = array of Integer;

var
  GLines: TStringArray;        // arc.groups en minúsculas (las máscaras)
  GLineType: TStringArray;     // nombre de tipo de cada línea ($binary, $text, ...), más el $default del final
  GDefaultGroup: Integer;      // índice de la línea "$default"

{ ---------------------------------------------------------------------------------------- }
{ Nombres                                                                                 }
{ ---------------------------------------------------------------------------------------- }

function FaCompareNames(const A, B: string): Integer;
var
  i, n: Integer;
  ca, cb: Byte;
begin
  n := Length(A);
  if Length(B) < n then n := Length(B);
  for i := 1 to n do
  begin
    ca := Ord(A[i]); cb := Ord(B[i]);
    if ca in [Ord('A')..Ord('Z')] then Inc(ca, 32);
    if cb in [Ord('A')..Ord('Z')] then Inc(cb, 32);
    if ca <> cb then Exit(Integer(ca) - Integer(cb));
  end;
  Result := Length(A) - Length(B);
end;

function BaseName(const Name: string): string;
begin
  Result := Copy(Name, LastDelimiter('/', Name) + 1, MaxInt);
end;

function DirName(const Name: string): string;
var
  p: Integer;
begin
  p := LastDelimiter('/', Name);
  if p > 0 then Result := Copy(Name, 1, p - 1) else Result := '';
end;

{ splitExtension de FilePath.hs sobre el nombre base: lo que sigue al último '.'
  (".bashrc" -> "bashrc", "foo." -> "", "readme" -> ""). }
function Suffix(const Base: string): string;
var
  p: Integer;
begin
  p := LastDelimiter('.', Base);
  if p > 0 then Result := Copy(Base, p + 1, MaxInt) else Result := '';
end;

function FaLCExtension(const Name: string): string;
begin
  Result := LowerCase(Suffix(BaseName(Name)));   // filenameLower = strLower en Windows
end;

{ match de FreeArc (Utils.hs, compile_RE): '*' y '?' sobre caracteres Unicode. }
function Glob(const Mask, S: UnicodeString): Boolean;
var
  m, n, StarM, StarN: Integer;
begin
  m := 1; n := 1; StarM := 0; StarN := 0;
  while n <= Length(S) do
  begin
    if (m <= Length(Mask)) and ((Mask[m] = '?') or ((Mask[m] <> '*') and (Mask[m] = S[n]))) then
    begin
      Inc(m); Inc(n);
    end
    else if (m <= Length(Mask)) and (Mask[m] = '*') then
    begin
      StarM := m; StarN := n; Inc(m);
    end
    else if StarM > 0 then
    begin
      m := StarM + 1; Inc(StarN); n := StarN;
    end
    else
      Exit(False);
  end;
  while (m <= Length(Mask)) and (Mask[m] = '*') do Inc(m);
  Result := m > Length(Mask);
end;

function GlobU(const Mask, S: string): Boolean;
begin
  Result := Glob(UTF8Decode(Mask), UTF8Decode(S));
end;

{ match_FP fpBasename (FileInfo.hs): "*.ext" compara la extensión; una máscara sin
  directorio, el nombre base; con directorio, el nombre completo. }
function MatchLine(const Line, Name, LcExt: string): Boolean;
var
  Rest, NamePart: string;
  p: Integer;
begin
  if Line = '*' then Exit(True);
  p := LastDelimiter('/', Line);
  Rest := Copy(Line, p + 1, MaxInt);
  NamePart := Rest;
  p := LastDelimiter('.', Rest);
  if p > 0 then NamePart := Copy(Rest, 1, p - 1);
  if LastDelimiter('/', Line) = 0 then
  begin
    if NamePart = '*' then
    begin
      if p > 0 then Result := GlobU(Copy(Rest, p + 1, MaxInt), LcExt)
      else Result := LcExt = '';
    end
    else
      Result := GlobU(Line, LowerCase(BaseName(Name)));
  end
  else
    Result := GlobU(Line, LowerCase(Name));
end;

function FaGroupIndex(const Name: string): Integer;
var
  i: Integer;
  Ext: string;
begin
  Ext := FaLCExtension(Name);
  for i := 0 to High(GLines) do
    if MatchLine(GLines[i], Name, Ext) then Exit(i);
  Result := GDefaultGroup;
end;

{ find_type (Cmdline.hs): el MENOR número de tipo t >= 1 tal que alguna línea de ese tipo
  coincide; si ninguna, 0. Los tipos son índices en GM (0 = el método por defecto). }
function FindType(const Name: string; const GM: TGroupMethods; out TypesCount: Integer): Integer;
var
  i, t, MaxT: Integer;
  Ext: string;
  LineT: TIntArray;

  function TypeNum(const T: string): Integer;
  var
    k: Integer;
  begin
    for k := 0 to High(GM) do
      if GM[k].Group = T then Exit(k);
    Result := 0;
  end;

begin
  SetLength(LineT, Length(GLineType));
  MaxT := 0;
  for i := 0 to High(GLineType) do
  begin
    LineT[i] := TypeNum(GLineType[i]);
    if LineT[i] > MaxT then MaxT := LineT[i];
  end;
  TypesCount := MaxT + 1;
  Ext := FaLCExtension(Name);
  for t := 1 to MaxT do
    for i := 0 to High(GLines) do   // (el $default agregado al final no tiene máscara)
      if (LineT[i] = t) and MatchLine(GLines[i], Name, Ext) then Exit(t);
  Result := 0;
end;

{ ---------------------------------------------------------------------------------------- }
{ Orden "gerpn"                                                                          }
{ ---------------------------------------------------------------------------------------- }

var
  SortFiles: array of TFaFile;   // (para las comparaciones)

{ Orden estable de Idx por una comparación (merge sort: sortBy de Haskell es estable). }
type
  TCmp = function(a, b: Integer): Integer;

procedure StableSort(var Idx: TIntArray; Cmp: TCmp);
var
  Tmp: TIntArray;

  procedure Merge(Lo, Mid, Hi: Integer);
  var
    i, j, k: Integer;
  begin
    i := Lo; j := Mid; k := Lo;
    while (i < Mid) and (j < Hi) do
    begin
      if Cmp(Idx[j], Idx[i]) < 0 then begin Tmp[k] := Idx[j]; Inc(j); end
      else begin Tmp[k] := Idx[i]; Inc(i); end;
      Inc(k);
    end;
    while i < Mid do begin Tmp[k] := Idx[i]; Inc(i); Inc(k); end;
    while j < Hi do begin Tmp[k] := Idx[j]; Inc(j); Inc(k); end;
    for k := Lo to Hi - 1 do Idx[k] := Tmp[k];
  end;

  procedure Sort(Lo, Hi: Integer);
  var
    Mid: Integer;
  begin
    if Hi - Lo < 2 then Exit;
    Mid := (Lo + Hi) div 2;
    Sort(Lo, Mid);
    Sort(Mid, Hi);
    Merge(Lo, Mid, Hi);
  end;

begin
  SetLength(Tmp, Length(Idx));
  Sort(0, Length(Idx));
end;

{ comparePS de UTF8Z.hs en Windows: strcasecmp sobre los bytes UTF-8 (minúsculas ASCII, el
  resto tal cual). arc.exe es de Windows, así que lo mismo en todas las plataformas. }
function CmpStr(const a, b: string): Integer;
begin
  Result := FaCompareNames(a, b);
end;

function CmpExt(a, b: Integer): Integer;
begin
  Result := CmpStr(FaLCExtension(SortFiles[a].Name), FaLCExtension(SortFiles[b].Name));
end;

function CmpDirName(a, b: Integer): Integer;
begin
  Result := CmpStr(DirName(SortFiles[a].Name), DirName(SortFiles[b].Name));
  if Result = 0 then Result := CmpStr(BaseName(SortFiles[a].Name), BaseName(SortFiles[b].Name));
end;

var
  ReNum: TIntArray;   // número de reorder de cada archivo (índice en SortFiles)

function CmpReorder(a, b: Integer): Integer;
begin
  // ordering (num, size, basename, directory)
  Result := CompareValue(ReNum[a], ReNum[b]);
  if Result = 0 then Result := CompareValue(SortFiles[a].Size, SortFiles[b].Size);
  if Result = 0 then Result := CmpStr(BaseName(SortFiles[a].Name), BaseName(SortFiles[b].Name));
  if Result = 0 then Result := CmpStr(DirName(SortFiles[a].Name), DirName(SortFiles[b].Name));
end;

{ reorder (ArhiveFileList.hs): cada archivo > 1 KB toma el número de uno ya visto con la misma
  extensión y tamaño (si > 16 KB), o con el mismo nombre y tamaño parecido (igual si <= 16 KB,
  entre la mitad y el doble si no); si no, el suyo. Las tablas devuelven lo más reciente. }
procedure Reorder(var Idx: TIntArray);
type
  TEntry = record Key: string; Size: Int64; Num: Integer; end;
var
  H1, H2: array of TEntry;
  i, k, Num: Integer;
  F: TFaFile;
  Ext, Base: string;
  Found: Boolean;

  function NearSize(S1, S2: Int64): Boolean;
  begin
    if S1 <= 16 * KB then Result := S1 = S2
    else Result := (S1 >= S2 div 2) and (S1 <= S2 * 2);
  end;

begin
  H1 := nil; H2 := nil;
  for i := 0 to High(Idx) do
  begin
    F := SortFiles[Idx[i]];
    Num := i;
    if F.Size > 1024 then
    begin
      Ext := FaLCExtension(F.Name);
      Base := BaseName(F.Name);
      Found := False;
      if F.Size > 16 * KB then
        for k := High(H1) downto 0 do
          if (H1[k].Key = Ext) and (H1[k].Size = F.Size) then
          begin
            Num := H1[k].Num; Found := True; Break;
          end;
      if not Found then
        for k := High(H2) downto 0 do
          if (FaCompareNames(H2[k].Key, Base) = 0) and NearSize(F.Size, H2[k].Size) then
          begin
            Num := H2[k].Num; Found := True; Break;
          end;
      SetLength(H1, Length(H1) + 1);
      H1[High(H1)].Key := Ext; H1[High(H1)].Size := F.Size; H1[High(H1)].Num := Num;
      SetLength(H2, Length(H2) + 1);
      H2[High(H2)].Key := Base; H2[High(H2)].Size := F.Size; H2[High(H2)].Num := Num;
    end;
    ReNum[Idx[i]] := Num;
  end;
  StableSort(Idx, @CmpReorder);
end;

{ sort_files con "gerpn". }
function SortGerpn(const Files: array of TFaFile): TIntArray;
var
  Buckets: array of TIntArray;
  i, g, n, a, b: Integer;
  Grp, Run: TIntArray;
begin
  SetLength(SortFiles, Length(Files));
  for i := 0 to High(Files) do SortFiles[i] := Files[i];
  SetLength(ReNum, Length(Files));
  // g: partitionList por el índice de línea (conserva el orden)
  SetLength(Buckets, Length(GLines) + 1);
  for i := 0 to High(Files) do
  begin
    g := FaGroupIndex(Files[i].Name);
    n := Length(Buckets[g]);
    SetLength(Buckets[g], n + 1);
    Buckets[g][n] := i;
  end;
  Result := nil;
  for g := 0 to High(Buckets) do
  begin
    Grp := Copy(Buckets[g]);
    // e: orden estable por extensión y cada tanda de igual extensión, por separado
    StableSort(Grp, @CmpExt);
    a := 0;
    while a < Length(Grp) do
    begin
      b := a + 1;
      while (b < Length(Grp)) and (CmpExt(Grp[a], Grp[b]) = 0) do Inc(b);
      Run := Copy(Grp, a, b - a);
      StableSort(Run, @CmpDirName);   // "pn"
      Reorder(Run);                   // "r"
      n := Length(Result);
      SetLength(Result, n + Length(Run));
      for i := 0 to High(Run) do Result[n + i] := Run[i];
      a := b;
    end;
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ Tipos por contenido                                                                     }
{ ---------------------------------------------------------------------------------------- }

type
  TTyped = record
    Typ: Integer;
    Files: TIntArray;
  end;
  TTypedArray = array of TTyped;

var
  CurGM: TGroupMethods;
  CurLevel: Integer;
  CurFiles: array of TFaFile;
  CurType: TIntArray;   // cfType de cada archivo

function GroupName(t: Integer): string;
begin
  if (t >= 0) and (t <= High(CurGM)) then Result := CurGM[t].Group else Result := '';
end;

function IsDetectable(const T: string): Boolean;
begin
  Result := (T = '$compressed') or (T = '$text');
end;

function DefaultTypeOf(f: Integer): string;
begin
  Result := GroupName(CurType[f]);
  if (Result = '') or IsDetectable(Result) then Result := '$binary';
end;

function ReadChunk(Fs: TFileStream; Pos, Size: Int64; out Buf: TBytes): Integer;
begin
  SetLength(Buf, Size);
  if Size <= 0 then Exit(0);
  Fs.Position := Pos;
  Result := Fs.Read(Buf[0], Size);
  if Result < 0 then Result := 0;
end;

{ detectMM: solo para $wav/$bmp: cabecera en el primer KB, o entropía en la mitad. }
function DetectMM(Fs: TFileStream; FileSize: Int64; const DefaultType: string): Boolean;
var
  Buf: TBytes;
  Len, Bytes: Integer;
  IsFloat, NumChan, WordSize, Offset: Integer;
begin
  Result := False;
  if (DefaultType <> '$wav') and (DefaultType <> '$bmp') then Exit;
  if FileSize > High(LongInt) then FileSize := High(LongInt);   // clipToMaxInt
  Len := ReadChunk(Fs, 0, Min(1024, FileSize), Buf);
  if (Len > 0) and MmDetectWavHeader(@Buf[0], Len, IsFloat, NumChan, WordSize, Offset) then Exit(True);
  // detect_mm_bytes
  if CurLevel <= 2 then Bytes := 64 * KB
  else Bytes := Max(64 * KB, Min(FileSize, MB) div 2);
  if Bytes > FileSize then Bytes := FileSize;
  Len := ReadChunk(Fs, (FileSize - Bytes) div 2, Bytes, Buf);
  if Len <= 0 then Exit;
  if CurLevel <= 2 then
    Result := MmDetectByEntropy(@Buf[0], Len, [1, 3], [8, 16], 0.80, IsFloat, NumChan, WordSize, Offset)
  else
    Result := MmDetectByEntropy(@Buf[0], Len, [1, 2, 3, 4], [8, 16, 24, 32], 0.80, IsFloat, NumChan, WordSize, Offset);
end;

{ check: tipos de los trozos (o nil si el archivo no se puede abrir). }
function Check(f: Integer; const DefaultType: string; BlockSize: Int64; const Positions: array of Int64;
  out Types: TStringArray): Boolean;
var
  Fs: TFileStream;
  i, Len: Integer;
  Buf: TBytes;
  Dummy: Byte;
begin
  Types := nil;
  try
    Fs := TFileStream.Create(FsPath(CurFiles[f].DiskPath), fmOpenRead or fmShareDenyNone);
  except
    Exit(False);
  end;
  try
    if DetectMM(Fs, CurFiles[f].Size, DefaultType) then
    begin
      SetLength(Types, 1);
      Types[0] := DefaultType;
      Exit(True);
    end;
    SetLength(Types, Length(Positions));
    for i := 0 to High(Positions) do
    begin
      Len := ReadChunk(Fs, Positions[i], BlockSize, Buf);
      // (un trozo vacío va con un puntero no nulo: con nil el C devuelve la lista de tipos)
      if Len > 0 then Types[i] := DetectDatatype(@Buf[0], Len)
      else Types[i] := DetectDatatype(@Dummy, 0);
    end;
  finally
    Fs.Free;
  end;
  Result := True;
end;

{ bestType: si (casi) todas las pruebas dieron lo mismo, eso; si no, "default". }
function BestType(const T: TStringArray): string;
var
  i, LenX: Integer;
  First: string;
  Same: Boolean;
begin
  Result := 'default';
  LenX := 0; First := ''; Same := True;
  for i := 0 to High(T) do
    if T[i] <> 'default' then
    begin
      if LenX = 0 then First := T[i]
      else if T[i] <> First then Same := False;
      Inc(LenX);
    end;
  if (LenX > 0) and Same and ((LenX = Length(T)) or ((Length(T) >= aCHUNKS) and (LenX = Length(T) - 1)) or
     (LenX * 12 >= Length(T) * 11)) then
    Result := First;
end;

{ chooseType: el primer tipo (de las palabras de bestType) que tenga método; si no, 0. }
function ChooseType(const T: TStringArray; const DefaultType: string): Integer;
var
  Best, W: string;
  k: Integer;
begin
  Best := BestType(T);
  if Best = 'default' then Best := DefaultType;
  for W in Best.Split([' ']) do
    if W <> '' then
      for k := 0 to High(CurGM) do
        if CurGM[k].Group = W then Exit(k);
  Result := 0;
end;

function AllEqual(const T: TStringArray): Boolean;
var
  i: Integer;
begin
  for i := 1 to High(T) do
    if T[i] <> T[0] then Exit(False);
  Result := True;
end;

procedure AddTyped(var R: TTypedArray; Typ: Integer; const Files: TIntArray);
begin
  SetLength(R, Length(R) + 1);
  R[High(R)].Typ := Typ;
  R[High(R)].Files := Copy(Files);
end;

{ groupLen (<Limit): cuántos archivos del principio suman menos que Limit. }
function PrefixUnder(const L: TIntArray; From: Integer; Limit: Int64): Integer;
var
  Sum: Int64;
begin
  Result := 0;
  Sum := 0;
  while From + Result <= High(L) do
  begin
    Inc(Sum, CurFiles[L[From + Result]].Size);
    if Sum >= Limit then Break;
    Inc(Result);
  end;
end;

function GroupType(const L: TIntArray): TTypedArray;
var
  f, i, n, a, Len, Best: Integer;
  Size, Chunks, BlockSz, Step, Total: Int64;
  Positions: array of Int64;
  T, All: TStringArray;
  DefaultType: string;
  Groups: array of TIntArray;
  Try_: TIntArray;
  Sub: TTypedArray;
begin
  Result := nil;
  if Length(L) = 1 then
  begin
    f := L[0];
    DefaultType := DefaultTypeOf(f);
    Size := CurFiles[f].Size;
    Chunks := Size div aCHUNK_SIZE + 1;
    if Chunks < aCHUNKS then n := Chunks else n := Round(Sqrt(Double(aCHUNKS * Chunks)));
    BlockSz := Min(Int64(aCHUNK_SIZE), Size div n);
    Step := (Size - n * BlockSz) div n;
    SetLength(Positions, n);
    for i := 0 to n - 1 do Positions[i] := i * (BlockSz + Step);
    // (si no se puede abrir, FreeArc lo saca de la lista; acá sigue, y la lectura avisará)
    if not Check(f, DefaultType, BlockSz, Positions, T) then
    begin
      SetLength(T, 1); T[0] := 'default';
    end;
    AddTyped(Result, ChooseType(T, DefaultType), L);
    Exit;
  end;
  DefaultType := DefaultTypeOf(L[0]);
  Groups := nil;
  if Length(L) <= aCHUNKS then
  begin
    SetLength(Groups, Length(L));
    for i := 0 to High(L) do begin SetLength(Groups[i], 1); Groups[i][0] := L[i]; end;
  end
  else
  begin
    // aCHUNKS tandas de tamaño parecido (GroupBySize: la que cruza el límite entra)
    Total := 0;
    for i := 0 to High(L) do Inc(Total, CurFiles[L[i]].Size);
    a := 0;
    while a <= High(L) do
    begin
      Len := Min(1 + PrefixUnder(L, a, Total div aCHUNKS), Length(L) - a);
      SetLength(Groups, Length(Groups) + 1);
      Groups[High(Groups)] := Copy(L, a, Len);
      Inc(a, Len);
    end;
  end;
  // El más grande de cada tanda (maxOn: el último, si empatan)
  SetLength(Try_, Length(Groups));
  for i := 0 to High(Groups) do
  begin
    Best := Groups[i][0];
    for a := 1 to High(Groups[i]) do
      if not (CurFiles[Best].Size > CurFiles[Groups[i][a]].Size) then Best := Groups[i][a];
    Try_[i] := Best;
  end;
  All := nil;
  SetLength(Positions, 1);
  Positions[0] := 0;
  for i := 0 to High(Try_) do
  begin
    if not Check(Try_[i], DefaultType, aCHUNK_SIZE, Positions, T) then
    begin
      SetLength(T, 1); T[0] := 'default';
    end;
    for a := 0 to High(T) do
    begin
      SetLength(All, Length(All) + 1);
      All[High(All)] := T[a];
    end;
  end;
  if not AllEqual(All) then
  begin
    for i := 0 to High(Groups) do
    begin
      Sub := GroupType(Groups[i]);
      for a := 0 to High(Sub) do AddTyped(Result, Sub[a].Typ, Sub[a].Files);
    end;
  end
  else
    AddTyped(Result, ChooseType(All, DefaultType), L);
end;

function SplitFileTypes(const Order: TIntArray; TypesCount: Integer): TTypedArray;
var
  Quick: Boolean;
  i, t, a, Len, ExtRun: Integer;
  Bucket, Chunk: TIntArray;
  Sub: TTypedArray;
begin
  Result := nil;
  Quick := CurLevel <= 1;
  if not Quick then
  begin
    Quick := True;
    for i := 0 to High(CurGM) do
      if IsDetectable(CurGM[i].Group) then Quick := False;
  end;
  if Quick then
  begin
    for t := 0 to TypesCount - 1 do
    begin
      Bucket := nil;
      for i := 0 to High(Order) do
        if CurType[Order[i]] = t then
        begin
          SetLength(Bucket, Length(Bucket) + 1);
          Bucket[High(Bucket)] := Order[i];
        end;
      if Length(Bucket) > 0 then AddTyped(Result, t, Bucket);
    end;
    Exit;
  end;
  // splitBy [GroupByExt, GroupByBlockSize aGROUP_SIZE]: tandas de igual extensión y < 8 MB
  // (special: 4*2mb)
  a := 0;
  while a <= High(Order) do
  begin
    ExtRun := 1;
    while (a + ExtRun <= High(Order)) and
          (FaLCExtension(CurFiles[Order[a + ExtRun]].Name) = FaLCExtension(CurFiles[Order[a]].Name)) do
      Inc(ExtRun);
    Len := Min(ExtRun, Max(1, PrefixUnder(Order, a, 4 * aGROUP_SIZE)));
    Chunk := Copy(Order, a, Len);
    Sub := GroupType(Chunk);
    for i := 0 to High(Sub) do AddTyped(Result, Sub[i].Typ, Sub[i].Files);
    Inc(a, Len);
  end;
end;

{ ---------------------------------------------------------------------------------------- }
{ Bloques sólidos                                                                         }
{ ---------------------------------------------------------------------------------------- }

function StageName(const Stage: string): string;
begin
  Result := Stage.Split([':'])[0];
end;

{ Como las listas de Haskell: etapa por etapa; la que es prefijo va primero. }
function CmpMethod(const A, B: string): Integer;
var
  SA, SB: TStringArray;
  i: Integer;
begin
  SA := A.Split(['+']);
  SB := B.Split(['+']);
  for i := 0 to Min(High(SA), High(SB)) do
  begin
    Result := CompareStr(SA[i], SB[i]);
    if Result <> 0 then Exit;
  end;
  Result := CompareValue(Length(SA), Length(SB));
end;

function IsIntParam(const S: string): Boolean;
var
  v: Integer;
begin
  Result := FaParseInt(S, v);
end;

function MemParam(const S: string; out V: Int64): Boolean;
var
  q: QWord;
begin
  Result := ParseMem(S, q);
  V := q;
end;

{ GetBlockSize de dict, grzip y lzp (C_Dict/C_GRZip/C_LZP.cpp: el parámetro de memoria
  suelto o b<mem>); los demás, 0. }
function BlockSizeOf(const Stage: string): Int64;
var
  P: TStringArray;
  i: Integer;
  Name, S: string;
  v: Int64;
begin
  P := Stage.Split([':']);
  Name := P[0];
  if Name = 'dict' then Result := 64 * MB
  else if (Name = 'grzip') or (Name = 'lzp') then Result := 8 * MB
  else Exit(0);
  for i := 1 to High(P) do
  begin
    S := P[i];
    if S = '' then Continue;
    if (Name <> 'lzp') and (Length(S) = 1) then Continue;   // opciones de una letra
    if (S[1] = 'b') and MemParam(Copy(S, 2, MaxInt), v) then begin Result := v; Continue; end;
    if (Name = 'dict') and (S[1] in ['c', 'l', 'm', 's', 'r']) then Continue;
    if (Name = 'grzip') and (S[1] in ['m', 'l', 'h', 't', 'i']) then Continue;
    if (Name = 'lzp') and (S[1] in ['l', 'h', 'd', 's']) then Continue;
    if (S[Length(S)] = '%') and (Name <> 'grzip') and IsIntParam(Copy(S, 1, Length(S) - 1)) then Continue;
    if IsIntParam(S) then Continue;
    if MemParam(S, v) then Result := v;
  end;
end;

{ "nosolid?" de tta/mm (C_TTA.h, C_MM.h): word_size != 8 o offset != 0 (sin parámetros,
  word_size = 0). jpg, siempre. }
function NoSolidStage(const Stage: string): Boolean;
var
  P: TStringArray;
  i, WordSize, Offset, a, b, v: Integer;
  IsFloat: Boolean;
begin
  if StageName(Stage) = 'jpg' then Exit(True);
  P := Stage.Split([':']);
  WordSize := 0; Offset := 0;
  for i := 1 to High(P) do
    if P[i] <> '' then
    begin
      if (P[i][1] = 'w') and FaParseInt(Copy(P[i], 2, MaxInt), v) then WordSize := v
      else if (P[i][1] = 'o') and FaParseInt(Copy(P[i], 2, MaxInt), v) then Offset := v
      else if FaParseChanWord(P[i], a, b, IsFloat) then WordSize := b;
    end;
  Result := (WordSize <> 8) or (Offset <> 0);
end;

function SpecialSize(Size: Int64): Int64;
begin
  if Size > 8 * MB then Result := Size else Result := 4 * Size;
end;

function CritLen(const C: TFaCrit; const L: TIntArray; From: Integer): Integer;
var
  Ext: string;
begin
  case C.Kind of
    fcNone: Result := 1;
    fcExt:
      begin
        Result := 1;
        Ext := FaLCExtension(CurFiles[L[From]].Name);
        while (From + Result <= High(L)) and (FaLCExtension(CurFiles[L[From + Result]].Name) = Ext) do
          Inc(Result);
      end;
    fcSize: Result := 1 + PrefixUnder(L, From, C.Value);
    fcBlockSize: Result := Max(1, PrefixUnder(L, From, SpecialSize(C.Value)));
    fcNumber: Result := Max(1, C.Value);
  else
    Result := MaxInt;
  end;
end;

procedure SplitOneType(const Method: string; const L: TIntArray; const Crits0: TFaCrits;
  var R: TFaBlocks);
var
  Crits: TFaCrits;
  Stages: TStringArray;
  i, a, Len: Integer;
  bs: Int64;

  procedure Emit(From, Count: Integer);
  begin
    SetLength(R, Length(R) + 1);
    R[High(R)].Method := Method;
    R[High(R)].Files := Copy(L, From, Count);
  end;

  procedure Prepend(const C: TFaCrit);
  var
    k: Integer;
  begin
    SetLength(Crits, Length(Crits) + 1);
    for k := High(Crits) downto 1 do Crits[k] := Crits[k - 1];
    Crits[0] := C;
  end;

begin
  if Length(L) = 0 then Exit;
  if Method = 'storing' then begin Emit(0, Length(L)); Exit; end;
  Crits := Copy(Crits0);
  if Length(Crits) = 0 then begin SetLength(Crits, 1); Crits[0] := FaCrit(fcAll); end;
  Stages := Method.Split(['+']);
  if (StageName(Stages[0]) = 'tta') or (StageName(Stages[0]) = 'mm') or (StageName(Stages[0]) = 'jpg') then
  begin
    if NoSolidStage(Stages[0]) then
    begin
      SetLength(Crits, 1);
      Crits[0] := FaCrit(fcNone);
    end;
  end
  else if StageName(Stages[0]) = 'dict' then
    Prepend(FaCrit(fcBlockSize, BlockSizeOf(Stages[0])))
  else if Length(Stages) = 1 then
  begin
    bs := BlockSizeOf(Stages[0]);
    if bs > 0 then Prepend(FaCrit(fcBlockSize, bs));
  end;
  a := 0;
  while a <= High(L) do
  begin
    Len := MaxInt;
    for i := 0 to High(Crits) do Len := Min(Len, CritLen(Crits[i], L, a));
    Len := Min(Len, Length(L) - a);
    Emit(a, Len);
    Inc(a, Len);
  end;
end;

{ VeryFast? de un método de una sola etapa (C_Tornado.h, C_LZP.h): FreeArc no ordena. }
function VeryFast(const Method: string): Boolean;
var
  M: TTorMethod;
  P: TStringArray;
  i, h: Integer;
begin
  Result := False;
  if Pos('+', Method) > 0 then Exit;
  P := Method.Split([':']);
  if P[0] = 'tor' then
    Result := (ParseTorEncParams(P, M) = '') and (M.HashRowWidth <= 2)
  else if P[0] = 'lzp' then
  begin
    h := 18;
    for i := 1 to High(P) do
      if (P[i] <> '') and (P[i][1] = 'h') then FaParseInt(Copy(P[i], 2, MaxInt), h);
    Result := h <= 15;
  end;
end;

function FaSolidBlocks(const Files: array of TFaFile; const GM: TGroupMethods;
  const Crits: TFaCrits; DetectLevel: Integer): TFaBlocks;
var
  i, j, k, TypesCount: Integer;
  Order: TIntArray;
  Typed: TTypedArray;
  Meth: TStringArray;
  Idx: TIntArray;
  NoSort: Boolean;
  L: TIntArray;
begin
  Result := nil;
  if Length(Files) = 0 then Exit;
  CurGM := GM;
  CurLevel := DetectLevel;
  SetLength(CurFiles, Length(Files));
  SetLength(CurType, Length(Files));
  TypesCount := 1;
  for i := 0 to High(Files) do
  begin
    CurFiles[i] := Files[i];
    CurType[i] := FindType(Files[i].Name, GM, TypesCount);
  end;
  // Sin orden con -s- (solo GroupNone) o si el método principal es storing o muy rápido
  NoSort := ((Length(Crits) = 1) and (Crits[0].Kind = fcNone)) or
            (GM[0].Method = 'storing') or VeryFast(GM[0].Method);
  if NoSort then
  begin
    SetLength(Order, Length(Files));
    for i := 0 to High(Files) do Order[i] := i;
  end
  else
    Order := SortGerpn(Files);
  Typed := SplitFileTypes(Order, TypesCount);
  // sort_and_groupOn por método (estable): cada método junta sus tandas en orden
  SetLength(Meth, Length(Typed));
  SetLength(Idx, Length(Typed));
  for i := 0 to High(Typed) do
  begin
    Meth[i] := GM[Typed[i].Typ].Method;
    if Meth[i] = '' then Meth[i] := 'storing';
    Idx[i] := i;
  end;
  // (inserción estable: son pocas tandas)
  for i := 1 to High(Idx) do
  begin
    k := Idx[i];
    j := i - 1;
    while (j >= 0) and (CmpMethod(Meth[Idx[j]], Meth[k]) > 0) do
    begin
      Idx[j + 1] := Idx[j];
      Dec(j);
    end;
    Idx[j + 1] := k;
  end;
  i := 0;
  while i <= High(Idx) do
  begin
    L := nil;
    j := i;
    while (j <= High(Idx)) and (Meth[Idx[j]] = Meth[Idx[i]]) do
    begin
      for k := 0 to High(Typed[Idx[j]].Files) do
      begin
        SetLength(L, Length(L) + 1);
        L[High(L)] := Typed[Idx[j]].Files[k];
      end;
      Inc(j);
    end;
    SplitOneType(Meth[Idx[i]], L, Crits, Result);
    i := j;
  end;
end;

function FaDetectLevel(const MainMethod: string): Integer;
var
  M: string;
begin
  M := MainMethod.Split(['/'])[0];
  if (Length(M) = 1) and (M[1] in ['0'..'9']) then Result := Ord(M[1]) - Ord('0')
  else if (Length(M) = 2) and (M[1] in ['0'..'9']) and (M[2] in ['p', 'x']) then Result := Ord(M[1]) - Ord('0')
  else if (Length(M) = 2) and (M[1] = 'x') and (M[2] in ['0'..'9']) then Result := Ord(M[2]) - Ord('0')
  else if (M = 'mx') or (M = 'max') then Result := 9
  else Result := 4;
end;

function FaCrit(Kind: TFaCritKind; Value: Int64): TFaCrit;
begin
  Result.Kind := Kind;
  Result.Value := Value;
end;

procedure LoadLines;
var
  Raw: TStringArray;
  i: Integer;
  Cur, L: string;
begin
  Raw := ArcGroupLines;
  SetLength(GLines, Length(Raw));
  SetLength(GLineType, Length(Raw) + 1);
  GDefaultGroup := -1;
  Cur := '$binary';
  for i := 0 to High(Raw) do
  begin
    L := LowerCase(Raw[i]);
    GLines[i] := L;
    if (L <> '') and (L[1] = '$') and (L <> '$default') then Cur := L;
    GLineType[i] := Cur;
    if (L = '$default') and (GDefaultGroup < 0) then GDefaultGroup := i;
  end;
  GLineType[High(GLineType)] := Cur;   // el "$default" que FreeArc agrega al final
  if GDefaultGroup < 0 then GDefaultGroup := Length(Raw);
end;

initialization
  LoadLines;
end.
