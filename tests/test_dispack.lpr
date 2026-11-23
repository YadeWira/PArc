{ tests/test_dispack.lpr — PArc's x86 filter (dispack) through its stages.
  Usage: test_dispack enc  <in> <out> [block] [seed]   encode (seed > 0: random write sizes)
         test_dispack dec  <in> <out> [block] [seed]   decode (seed > 0: random read sizes)
         test_dispack dump <in> <dir> [block]          encode, append each stream to <dir>/s<k>.bin
                                                       and list the regions on stderr
         test_dispack fuzz <in> <count> [seed]         damage the encoded <in> <count> times:
                                                       decoding must end in EArcCorrupt or give
                                                       some output, never crash or hang
  Exit code 0 = ok, 1 = damaged stream (EArcCorrupt), 2 = usage / other error. }
program test_dispack;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_outstream, parc_dispack;

function LoadFile(const Fn: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Fn, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

procedure SaveFile(const Fn: string; const B: TBytes; Len: SizeInt);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Fn, fmCreate);
  try
    if Len > 0 then F.WriteBuffer(B[0], Len);
  finally
    F.Free;
  end;
end;

var
  Seed: LongWord = 0;

function Rnd(N: LongWord): LongWord;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := (Seed shr 8) mod N;
end;

function Encode(const Src: TBytes; Block: SizeInt; RandomWrites: Boolean): TBytes;
var
  Sink: TMemSink;
  St: TDisPackEncStage;
  Pos, N: SizeInt;
begin
  Sink := TMemSink.Create;
  St := TDisPackEncStage.Create(Sink, Block);
  try
    Pos := 0;
    while Pos < Length(Src) do
    begin
      N := Length(Src) - Pos;
      if RandomWrites then
      begin
        case Rnd(4) of
          0: N := 1 + Rnd(16);
          1: N := 1 + Rnd(4096);
          2: N := 1 + Rnd(300000);
        end;
        if N > Length(Src) - Pos then N := Length(Src) - Pos;
      end;
      St.Write(@Src[Pos], N);
      Inc(Pos, N);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

function Decode(const Src: TBytes; Block: SizeInt; RandomReads: Boolean; out Len: SizeInt): TBytes;
var
  Mem: TMemStage;
  St: TDisPackStage;
  N, Got: SizeInt;
begin
  Result := nil;
  SetLength(Result, 1 shl 16);
  Len := 0;
  Mem := TMemStage.Create(@Src[0], Length(Src));
  St := TDisPackStage.Create(Mem, Block);
  try
    repeat
      if Len + 400000 > Length(Result) then SetLength(Result, 2 * Length(Result) + 400000);
      N := 400000;
      if RandomReads then N := 1 + Rnd(400000);
      if (Len > 1 shl 30) then Break;
      Got := St.Read(@Result[Len], N);
      Inc(Len, Got);
    until Got <= 0;
  finally
    St.Free;
  end;
end;

var
  Cmd: string;
  Src, Dst, Bad: TBytes;
  Block: SizeInt;
  Len: SizeInt;
  i, Count, Fails, Oks: Integer;
  m: QWord;
begin
  if ParamCount < 3 then
  begin
    WriteLn(StdErr, 'usage: test_dispack enc|dec|dump|fuzz ...');
    Halt(2);
  end;
  Cmd := ParamStr(1);
  Block := DISPACK_BLOCK;
  if (ParamCount >= 4) and (Cmd <> 'fuzz') then
    if ParseMemSize(ParamStr(4), m) then Block := m;
  if ParamCount >= 5 then Seed := StrToInt(ParamStr(5));
  try
    Src := LoadFile(ParamStr(2));
    if Cmd = 'enc' then
    begin
      Dst := Encode(Src, Block, Seed > 0);
      SaveFile(ParamStr(3), Dst, Length(Dst));
    end
    else if Cmd = 'dec' then
    begin
      Dst := Decode(Src, Block, Seed > 0, Len);
      SaveFile(ParamStr(3), Dst, Len);
    end
    else if Cmd = 'dump' then
    begin
      XfDumpDir := ParamStr(3);
      Dst := Encode(Src, Block, False);
      WriteLn(Length(Src), ' -> ', Length(Dst));
    end
    else if Cmd = 'fuzz' then
    begin
      Count := StrToInt(ParamStr(3));
      if ParamCount >= 4 then Seed := StrToInt(ParamStr(4)) else Seed := 1;
      Fails := 0;
      Oks := 0;
      for i := 1 to Count do
      begin
        Bad := Copy(Src, 0, Length(Src));
        case Rnd(3) of
          0: Bad[Rnd(Length(Bad))] := Bad[Rnd(Length(Bad))] xor (1 + Rnd(255));
          1: SetLength(Bad, Rnd(Length(Bad)));
          2: begin
               Bad[Rnd(Length(Bad))] := Rnd(256);
               Bad[Rnd(Length(Bad))] := Rnd(256);
               Bad[Rnd(Length(Bad))] := Rnd(256);
             end;
        end;
        if Length(Bad) = 0 then Continue;
        try
          Decode(Bad, DISPACK_BLOCK, False, Len);
          Inc(Oks);
        except
          on EArcCorrupt do Inc(Fails);
        end;
      end;
      WriteLn('fuzz: ', Count, ' runs, ', Fails, ' rejected, ', Oks, ' decoded');
    end
    else
      Halt(2);
  except
    on E: EArcCorrupt do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;
end.
