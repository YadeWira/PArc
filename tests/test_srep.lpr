{ tests/test_srep.lpr — decodificador SREP de PArc contra streams del srep de referencia.
  Uso: test_srep <archivo.srep> <salida> }
program test_srep;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_srep;

function ReadAll(const Name: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmOpenRead);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

var
  In_, Out_: TBytes;
  Size: Int64;
  F: TFileStream;
begin
  if ParamStr(1) = 'e' then
  begin
    In_ := ReadAll(ParamStr(2));
    Out_ := SrepEncode(@In_[0], Length(In_));
    F := TFileStream.Create(ParamStr(3), fmCreate);
    try
      if Length(Out_) > 0 then F.WriteBuffer(Out_[0], Length(Out_));
    finally
      F.Free;
    end;
    Halt(0);
  end;
  In_ := ReadAll(ParamStr(1));
  Size := SrepDecodedSize(@In_[0], Length(In_));
  if Size < 0 then begin Writeln(StdErr, 'cabecera inválida'); Halt(1); end;
  SetLength(Out_, Size);
  if not SrepDecode(@In_[0], Length(In_), @Out_[0], Size) then
  begin
    Writeln(StdErr, 'decode FALLÓ');
    Halt(1);
  end;
  F := TFileStream.Create(ParamStr(2), fmCreate);
  try
    if Size > 0 then F.WriteBuffer(Out_[0], Size);
  finally
    F.Free;
  end;
end.
