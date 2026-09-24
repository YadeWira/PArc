{ Prueba del decodificador LZMA raw: tests/test_lzma <comp> <orig> <lc> <lp> <pb>; sale con 0 si coincide. }
program test_lzma;
{$mode objfpc}{$H+}
uses SysUtils, Classes, parc_lzma;

function LoadFile(const N: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(N, fmOpenRead);
  try SetLength(Result, f.Size); if f.Size > 0 then f.ReadBuffer(Result[0], f.Size); finally f.Free; end;
end;

var Comp, Orig, Outb: TBytes; W: SizeInt; r: TLzmaResult;
begin
  Comp := LoadFile(ParamStr(1)); Orig := LoadFile(ParamStr(2));
  SetLength(Outb, Length(Orig));
  r := LzmaDecodeRaw(PByte(Comp), Length(Comp), PByte(Outb), Length(Outb),
    StrToInt(ParamStr(3)), StrToInt(ParamStr(4)), StrToInt(ParamStr(5)), W);
  if (r in [lzOk, lzInputEof]) and (W = Length(Orig)) and ((W = 0) or CompareMem(@Outb[0], @Orig[0], W)) then Halt(0);
  WriteLn('FAIL r=', Ord(r), ' w=', W, '/', Length(Orig)); Halt(1);
end.
