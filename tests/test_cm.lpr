{ test_cm: helper of tests/cm.sh and tests/cm_cross.sh for the cm codec (src/parc_cm.pas,
  src/cm/pcm_core.c).
    test_cm enc <level> <in> <out> <chunk>   encode, writing in pieces of <chunk> bytes
                                             (0 = random sizes, fixed seed)
    test_cm dec <in> <out>                   decode, reading in random-sized pieces
    test_cm fuzz <stream> <n> <seed>         decode <n> damaged copies (flipped bytes, cuts,
                                             inserted/deleted bytes): each must give data or a
                                             clean EArcCorrupt, never another exception
  Exit code 0 = ok. }
program test_cm;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_outstream, parc_cm;

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

function Encode(Level: Integer; const Data: TBytes; Chunk: SizeInt): TBytes;
var
  Sink: TMemSink;
  St: TOutStage;
  pos, n: SizeInt;
begin
  Sink := TMemSink.Create;
  St := TCmEncStage.Create(Sink, Level);
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

function Decode(const C: TBytes; out Len: SizeInt; Limit: SizeInt = High(SizeInt)): TBytes;
var
  St: TInStage;
  n: SizeInt;
begin
  St := TCmDecStage.Create(TMemStage.Create(PByte(C), Length(C)));
  try
    SetLength(Result, 1 shl 16);
    Len := 0;
    repeat
      if Len + (1 shl 20) > Length(Result) then SetLength(Result, 2 * Length(Result) + (1 shl 20));
      n := St.Read(@Result[Len], 1 + Random(1 shl 20));
      Inc(Len, n);
    until (n = 0) or (Len > Limit);
  finally
    St.Free;
  end;
end;

procedure DoFuzz(const FN: string; N, Seed: Integer);
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
      0, 1:
        for k := 0 to Random(4) do
          if Length(M) > 0 then
          begin
            if Random(2) = 0 then pos := Random(64) else pos := Random(Length(M));
            if pos < Length(M) then M[pos] := M[pos] xor Byte(1 + Random(255));
          end;
      2:
        if Length(M) > 0 then SetLength(M, Random(Length(M)));
      3:
        begin
          pos := Random(Length(M) + 1);
          k := 1 + Random(9);
          SetLength(M, Length(M) + k);
          if Length(M) - k - pos > 0 then Move(M[pos], M[pos + k], Length(M) - k - pos);
          for j := 0 to k - 1 do M[pos + j] := Random(256);
        end;
      4:
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
      // a damaged stream can decode to more bytes than the original: stop at 4x
      Decode(M, Len, 4 * 1024 * 1024 + 4 * Length(C));
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

var
  D, C: TBytes;
  Len: SizeInt;
begin
  RandSeed := 12345;
  try
    case ParamStr(1) of
      'enc':
        begin
          D := LoadFile(ParamStr(3));
          C := Encode(StrToInt(ParamStr(2)), D, StrToInt(ParamStr(5)));
          SaveFile(ParamStr(4), C);
        end;
      'dec':
        begin
          C := LoadFile(ParamStr(2));
          D := Decode(C, Len);
          SaveFile(ParamStr(3), D, Len);
        end;
      'fuzz': DoFuzz(ParamStr(2), StrToInt(ParamStr(3)), StrToInt(ParamStr(4)));
    else
      begin
        WriteLn('usage: test_cm enc|dec|fuzz ...');
        Halt(2);
      end;
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
