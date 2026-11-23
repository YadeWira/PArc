{ test_filters: helper of tests/delta.sh, tests/lzp.sh and tests/filters_cross.sh
  for PArc's own filters and codecs (src/parc_delta.pas, parc_lzp.pas, parc_bwt.pas).
    test_filters enc <method> <in> <out> <chunk>   encode, writing in pieces of <chunk> bytes
                                                   (0 = random sizes, fixed seed)
    test_filters dec <method> <in> <out>           decode, reading in random-sized pieces
    test_filters fuzz <method> <stream> <n> <seed> decode <n> damaged copies (flipped bytes, cuts,
                                                   inserted/deleted bytes): each must give data or
                                                   a clean EArcCorrupt, never another exception
    test_filters synth <dir>                       synthetic tables (every delta layout) in <dir>
    test_filters segs <method> <in>                the segments the delta encoder chooses
  Exit code 0 = ok. }
program test_filters;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes, parc_bytes, parc_stream, parc_outstream, parc_delta, parc_lzp, parc_bwt;

function MinCompr(const Parts: TStringArray): Integer;
var
  k: Integer;
begin
  Result := 100;
  for k := 1 to High(Parts) do
    if (Parts[k] <> '') and (Parts[k][Length(Parts[k])] = '%') then
      Result := StrToIntDef(Copy(Parts[k], 1, Length(Parts[k]) - 1), 100);
end;

function NewEncoder(const Method: string; Sink: TOutStage): TOutStage;
var
  Parts: TStringArray;
begin
  Parts := Method.Split([':']);
  case Parts[0] of
    'delta': Result := TDeltaEncStage.Create(Sink, Parts);
    'lzp': Result := TLzpEncStage.Create(Sink, ParseLzpParams(Parts), MinCompr(Parts));
    'bwt': Result := TBwtEncStage.Create(Sink, Parts);
  else
    raise Exception.Create('unknown method ' + Method);
  end;
end;

function NewDecoder(const Method: string; Src: TInStage): TInStage;
var
  Parts: TStringArray;
begin
  Parts := Method.Split([':']);
  case Parts[0] of
    'delta': Result := TDeltaStage.Create(Src);
    'lzp': Result := TLzpStage.Create(Src, ParseLzpParams(Parts));
    'bwt': Result := TBwtStage.Create(Src, Parts);
  else
    raise Exception.Create('unknown method ' + Method);
  end;
end;

function LoadFile(const FN: string): TBytes;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FN, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure SaveFile(const FN: string; const B: TBytes; Len: SizeInt = -1);
var
  fs: TFileStream;
begin
  if Len < 0 then Len := Length(B);
  fs := TFileStream.Create(FN, fmCreate);
  try
    if Len > 0 then fs.WriteBuffer(B[0], Len);
  finally
    fs.Free;
  end;
end;

function Encode(const Method: string; const Data: TBytes; Chunk: SizeInt): TBytes;
var
  Sink: TMemSink;
  St: TOutStage;
  pos, n: SizeInt;
begin
  Sink := TMemSink.Create;
  St := NewEncoder(Method, Sink);
  try
    pos := 0;
    while pos < Length(Data) do
    begin
      if Chunk > 0 then n := Chunk
      else if Random(4) = 0 then n := 1 + Random(16)
      else n := 1 + Random(3 shl 20);
      if n > Length(Data) - pos then n := Length(Data) - pos;
      St.Write(@Data[pos], n);
      Inc(pos, n);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

function Decode(const Method: string; const C: TBytes; out Len: SizeInt): TBytes;
var
  St: TInStage;
  n: SizeInt;
begin
  St := NewDecoder(Method, TMemStage.Create(PByte(C), Length(C)));
  try
    SetLength(Result, 1 shl 16);
    Len := 0;
    repeat
      if Len + (1 shl 20) > Length(Result) then SetLength(Result, 2 * Length(Result) + (1 shl 20));
      n := St.Read(@Result[Len], 1 + Random(1 shl 20));
      Inc(Len, n);
    until n = 0;
  finally
    St.Free;
  end;
end;

procedure DoFuzz(const Method, FN: string; N, Seed: Integer);
var
  C, M: TBytes;
  i, k, j, pos, Clean, Data: Integer;
  Len: SizeInt;
begin
  C := LoadFile(FN);
  RandSeed := Seed;
  Clean := 0; Data := 0;
  for i := 1 to N do
  begin
    M := Copy(C);
    case Random(5) of
      0, 1:   // flip bytes (more often in the header)
        for k := 0 to Random(4) do
          if Length(M) > 0 then
          begin
            if Random(2) = 0 then pos := Random(64) else pos := Random(Length(M));
            if pos < Length(M) then M[pos] := M[pos] xor Byte(1 + Random(255));
          end;
      2:      // cut
        if Length(M) > 0 then SetLength(M, Random(Length(M)));
      3:      // insert bytes
        begin
          pos := Random(Length(M) + 1);
          k := 1 + Random(9);
          SetLength(M, Length(M) + k);
          if Length(M) - k - pos > 0 then Move(M[pos], M[pos + k], Length(M) - k - pos);
          for j := 0 to k - 1 do M[pos + j] := Random(256);
        end;
      4:      // delete bytes
        if Length(M) > 0 then
        begin
          pos := Random(Length(M));
          k := 1 + Random(9);
          if pos + k > Length(M) then k := Length(M) - pos;
          if Length(M) - pos - k > 0 then Move(M[pos + k], M[pos], Length(M) - pos - k);
          SetLength(M, Length(M) - k);
        end;
    end;
    try
      Decode(Method, M, Len);
      Inc(Data);
    except
      on E: EArcCorrupt do Inc(Clean);
      on E: Exception do
      begin
        WriteLn('fuzz ', i, ': ', E.ClassName, ': ', E.Message);
        Halt(1);
      end;
    end;
  end;
  WriteLn(Format('fuzz %s: %d damaged streams, %d errors, %d decoded', [ExtractFileName(FN), N, Clean, Data]));
end;

{ ---------- synthetic data ---------- }

procedure PutField(var B: TBytes; p: SizeInt; W: Integer; BE: Boolean; v: LongWord);
var
  k: Integer;
begin
  for k := 0 to W - 1 do
    if BE then B[p + k] := Byte(v shr (8 * (W - 1 - k)))
    else B[p + k] := Byte(v shr (8 * k));
end;

{ Count records of Stride bytes: W-byte fields (BE or LE) that drift slowly, constant fields, a
  noisy field; surrounded by text so the run has edges. }
function Table(Stride, W: Integer; BE: Boolean; Count: SizeInt): TBytes;
var
  NF, f, Pre: Integer;
  k, p: SizeInt;
  v: array of LongWord;
  S: string;
begin
  NF := Stride div W;
  S := 'Some text before the table, then the table, then more text. ';
  Pre := Length(S) * 3 + Random(7);
  SetLength(Result, Pre + Stride * Count + Pre);
  for k := 0 to Pre - 1 do
  begin
    Result[k] := Ord(S[1 + k mod Length(S)]);
    Result[Length(Result) - 1 - k] := Ord(S[1 + k mod Length(S)]);
  end;
  SetLength(v, NF);
  for f := 0 to NF - 1 do v[f] := Random(1 shl 30);
  p := Pre;
  for k := 0 to Count - 1 do
  begin
    for f := 0 to NF - 1 do
    begin
      case f mod 4 of
        0: Inc(v[f], 1 + Random(20));             // slowly increasing
        1: v[f] := v[f] + LongWord(Random(9) - 4); // wandering
        2: ;                                       // constant
        3: v[f] := Random(High(LongInt));          // noise
      end;
      PutField(Result, p + f * W, W, BE, v[f]);
    end;
    Inc(p, Stride);
  end;
end;

{ 16-bit stereo "audio" and 8-bit samples }
function Audio(Bits, Ch: Integer; BE: Boolean; Count: SizeInt): TBytes;
var
  k: SizeInt;
  c: Integer;
  ph, x: Double;
  v: LongInt;
begin
  SetLength(Result, Count * Ch * (Bits div 8));
  ph := 0;
  for k := 0 to Count - 1 do
  begin
    ph := ph + 0.01 + 0.002 * Sin(k / 5000);
    for c := 0 to Ch - 1 do
    begin
      x := Sin(ph * (c + 1)) * 0.6 + (Random - 0.5) * 0.02;
      if Bits = 16 then
      begin
        v := Round(x * 30000);
        PutField(Result, (k * Ch + c) * 2, 2, BE, LongWord(v) and $FFFF);
      end
      else Result[k * Ch + c] := Byte(Round(x * 120) + 128);
    end;
  end;
end;

procedure Synth(const Dir: string);
var
  St, W, i: Integer;
  BE: Boolean;
  All, B: TBytes;
  n: SizeInt;
begin
  RandSeed := 12345;
  ForceDirectories(Dir);
  All := nil;
  for St := 1 to 40 do
    for W in [1, 2, 4] do
      if St mod W = 0 then
        for BE in [False, True] do
        begin
          if (W = 1) and BE then Continue;
          B := Table(St, W, BE, 300 + Random(3000));
          n := Length(All);
          SetLength(All, n + Length(B));
          Move(B[0], All[n], Length(B));
        end;
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'tables', All);
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'wide64', Table(64, 4, False, 20000));
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'audio16le', Audio(16, 2, False, 1500000));
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'audio16be', Audio(16, 1, True, 1000000));
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'audio8', Audio(8, 1, False, 3000000));
  // a big table split by block boundaries (default 8 MB blocks)
  SaveFile(IncludeTrailingPathDelimiter(Dir) + 'bigtable', Table(12, 4, False, 1500000));
  for i := 0 to 0 do ;
end;

var
  Data, C, D: TBytes;
  Len: SizeInt;
  Segs: TDeltaSegArray;
  i: Integer;
begin
  try
    if (ParamCount >= 5) and (ParamStr(1) = 'enc') then
    begin
      RandSeed := 777;
      Data := LoadFile(ParamStr(3));
      C := Encode(ParamStr(2), Data, StrToInt(ParamStr(5)));
      SaveFile(ParamStr(4), C);
    end
    else if (ParamCount >= 4) and (ParamStr(1) = 'dec') then
    begin
      RandSeed := 778;
      C := LoadFile(ParamStr(3));
      D := Decode(ParamStr(2), C, Len);
      SaveFile(ParamStr(4), D, Len);
    end
    else if (ParamCount >= 5) and (ParamStr(1) = 'fuzz') then
      DoFuzz(ParamStr(2), ParamStr(3), StrToInt(ParamStr(4)), StrToInt(ParamStr(5)))
    else if (ParamCount >= 2) and (ParamStr(1) = 'synth') then
      Synth(ParamStr(2))
    else if (ParamCount >= 3) and (ParamStr(1) = 'segs') then
    begin
      Data := LoadFile(ParamStr(3));
      Segs := DeltaAnalyze(PByte(Data), Length(Data), ParseDeltaEncParams(ParamStr(2).Split([':'])));
      for i := 0 to High(Segs) do
        with Segs[i] do
          WriteLn(Start, ' ', Count * Stride, ' N=', Stride, ' W=', Width, ' ', BoolToStr(BigEndian, 'BE', 'LE'),
            ' mask=', IntToHex(Mask, 1));
    end
    else
    begin
      WriteLn('uso: test_filters enc|dec|fuzz|synth|segs ...');
      Halt(2);
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
