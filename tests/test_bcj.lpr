{ Decodifica con TBcjX86Stage un archivo codificado por tests/bcj_ref, entregándole la entrada
  en pedazos de tamaño aleatorio (1..MaxChunk bytes) para estresar los bordes de buffer.
  Uso: test_bcj <codificado> <original> <seed> <maxchunk>; sale con 0 si coincide. }
program test_bcj;
{$mode objfpc}{$H+}
uses SysUtils, Classes, parc_stream, parc_filters;

type
  TChoppyStage = class(TInStage)
    Data: TBytes; Pos, MaxChunk: SizeInt;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

function TChoppyStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var r: SizeInt;
begin
  Result := Length(Data) - Pos;
  if Result > Count then Result := Count;
  r := 1 + Random(MaxChunk);
  if Result > r then Result := r;
  if Result <= 0 then Exit(0);
  Move(Data[Pos], Buf^, Result); Inc(Pos, Result);
end;

function LoadFile(const N: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(N, fmOpenRead);
  try SetLength(Result, f.Size); if f.Size > 0 then f.ReadBuffer(Result[0], f.Size); finally f.Free; end;
end;

var Src: TChoppyStage; Dec: TInStage; Orig, Outb: TBytes; n, got: SizeInt;
begin
  RandSeed := StrToInt(ParamStr(3));
  Src := TChoppyStage.Create(nil); Src.Data := LoadFile(ParamStr(1)); Src.MaxChunk := StrToInt(ParamStr(4));
  Orig := LoadFile(ParamStr(2));
  Dec := TBcjX86Stage.Create(Src);
  SetLength(Outb, Length(Orig) + 16); got := 0;
  repeat n := Dec.Read(@Outb[got], Length(Outb) - got); Inc(got, n); until (n = 0) or (got = Length(Outb));
  Dec.Free;
  if (got = Length(Orig)) and ((got = 0) or CompareMem(@Outb[0], @Orig[0], got)) then Halt(0);
  n := 0; while (n < got) and (n < Length(Orig)) and (Outb[n] = Orig[n]) do Inc(n);
  WriteLn('FAIL len=', got, '/', Length(Orig), ' primer byte distinto en ', n); Halt(1);
end.
