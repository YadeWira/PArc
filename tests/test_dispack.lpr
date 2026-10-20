{ tests/test_dispack.lpr — filtro/desfiltro DisPack de PArc, para comparar con la referencia C.
  Uso: test_dispack f <origin> < in > out
       test_dispack u <origin> <outsize> < in > out }
program test_dispack;

{$mode objfpc}{$H+}

uses
  SysUtils, parc_dispack;

function ReadAll: TBytes;
var
  Cap, Len, N: Integer;
begin
  Result := nil;
  Cap := 1 shl 20;
  SetLength(Result, Cap);
  Len := 0;
  while True do
  begin
    if Len = Cap then
    begin
      Cap := Cap * 2;
      SetLength(Result, Cap);
    end;
    N := FileRead(StdInputHandle, Result[Len], Cap - Len);
    if N <= 0 then Break;
    Inc(Len, N);
  end;
  SetLength(Result, Len);
end;

procedure WriteAll(const B: TBytes);
var
  Done, N: Integer;
begin
  Done := 0;
  while Done < Length(B) do
  begin
    N := FileWrite(StdOutputHandle, B[Done], Length(B) - Done);
    if N <= 0 then Break;
    Inc(Done, N);
  end;
end;

var
  In_, Out_: TBytes;
  Origin, OutLen, DstLen: Integer;
begin
  if ParamCount < 2 then
  begin
    Writeln(StdErr, 'uso: test_dispack f|u origin [outsize]');
    Halt(2);
  end;
  In_ := ReadAll;
  Origin := StrToIntDef(ParamStr(2), 0);
  if ParamStr(1) = 'f' then
  begin
    Out_ := DisPackFilter(@In_[0], Length(In_), LongWord(Origin), OutLen);
    WriteAll(Out_);
  end
  else
  begin
    DstLen := StrToIntDef(ParamStr(3), 0);
    SetLength(Out_, DstLen);
    if not DisPackUnFilter(@In_[0], Length(In_), @Out_[0], DstLen, LongWord(Origin)) then
    begin
      Writeln(StdErr, 'unfilter FALLÓ');
      Halt(1);
    end;
    WriteAll(Out_);
  end;
end.
