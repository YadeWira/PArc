{ test_4x4: helper of tests/4x4.sh for the 4x4 stage (src/parc_4x4.pas).
    test_4x4 enc <method> <in> <out> <chunk>   encode with the encoder chain, writing in pieces of
                                               <chunk> bytes (0 = random sizes, fixed seed)
    test_4x4 dec <method> <in> <out>           decode with the decoder chain, random-sized reads
    test_4x4 fuzz <method> <stream> <n> <seed> decode <n> damaged copies (flipped bytes, cuts,
                                               inserted/deleted bytes): each must give data or a
                                               clean EArcCorrupt, never another exception
    test_4x4 recs <stream>                     record kinds and sizes of a 4x4 stream
  Exit code 0 = ok. }
program test_4x4;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF} SysUtils, Classes, parc_bytes, parc_stream, parc_outstream,
  parc_encoders, parc_methods;

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
  St := CreateEncoderChain(Method, Sink);
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
  St := CreateDecoderChain(Method, TMemStage.Create(PByte(C), Length(C)));
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

procedure DoRecs(const FN: string);
var
  C: TBytes;
  p: SizeInt;
  K: Byte;
  Raw, Pk, NS, L, G, j: QWord;
  NSt, NPk, NMix: Integer;

  function VI: QWord;
  var
    b: Byte;
    s: Integer;
  begin
    Result := 0;
    s := 0;
    repeat
      b := C[p];
      Inc(p);
      Result := Result or (QWord(b and $7F) shl s);
      Inc(s, 7);
    until b and $80 = 0;
  end;

begin
  C := LoadFile(FN);
  p := 3;
  NSt := 0; NPk := 0; NMix := 0;
  repeat
    K := C[p];
    Inc(p);
    if K = 0 then Break;
    Raw := VI;
    case K of
      1: begin Inc(NSt); Inc(p, Raw); end;
      2: begin Inc(NPk); Pk := VI; Inc(p, Pk); end;
      3:
        begin
          Inc(NMix);
          NS := VI;
          G := 0;
          for j := 0 to NS - 1 do
          begin
            L := VI;
            if not Odd(j) then Inc(G, L);
          end;
          Pk := VI;
          Inc(p, Pk + Raw - G);
        end;
    end;
  until False;
  WriteLn(Format('stored %d packed %d mixed %d', [NSt, NPk, NMix]));
end;

var
  D, C: TBytes;
  Len: SizeInt;
begin
  RandSeed := 12345;
  try
    if (ParamCount >= 5) and (ParamStr(1) = 'enc') then
    begin
      D := LoadFile(ParamStr(3));
      C := Encode(ParamStr(2), D, StrToInt(ParamStr(5)));
      SaveFile(ParamStr(4), C);
    end
    else if (ParamCount >= 4) and (ParamStr(1) = 'dec') then
    begin
      C := LoadFile(ParamStr(3));
      D := Decode(ParamStr(2), C, Len);
      SaveFile(ParamStr(4), D, Len);
    end
    else if (ParamCount >= 5) and (ParamStr(1) = 'fuzz') then
      DoFuzz(ParamStr(2), ParamStr(3), StrToInt(ParamStr(4)), StrToInt(ParamStr(5)))
    else if (ParamCount >= 2) and (ParamStr(1) = 'recs') then
      DoRecs(ParamStr(2))
    else
    begin
      WriteLn('uso: test_4x4 enc|dec|fuzz|recs ...');
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
