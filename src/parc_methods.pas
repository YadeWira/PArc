{ Métodos de compresión (FORMATO-ARC.md §7). Por ahora solo lo necesario para bloques de
  control: `storing` y `lzma`. Las cadenas se aplican de derecha a izquierda al descomprimir. }
unit parc_methods;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_bytes;

type
  EUnsupportedMethod = class(Exception);

{ Descomprime Src (SrcLen bytes) con la cadena Method a exactamente OrigSize bytes.
  Solo para bloques de control: en cadenas de varias etapas no conocemos los tamaños
  intermedios, así que por ahora solo sirve con una etapa real (más `storing`). }
function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;

{ Parsea un tamaño de memoria de FreeArc ("1mb", "244kb", "64m", "512b"). False si no lo es. }
function ParseMem(const S: string; out Value: QWord): Boolean;

function IsStoring(const Method: string): Boolean;

implementation

uses
  StrUtils, parc_lzma;

function IsStoring(const Method: string): Boolean;
begin
  Result := Method = 'storing';
end;

function ParseMem(const S: string; out Value: QWord): Boolean;
var
  i: Integer;
  Num: QWord;
  Suffix: string;
  Shift: Integer;
begin
  Result := False;
  i := 1;
  Num := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    Num := Num * 10 + Ord(S[i]) - Ord('0');
    Inc(i);
  end;
  if i = 1 then Exit;
  Suffix := LowerCase(Copy(S, i, MaxInt));
  case Suffix of
    '', 'm', 'mb': Shift := 20;
    'b':           Shift := 0;
    'k', 'kb':     Shift := 10;
    'g', 'gb':     Shift := 30;
  else
    Exit;
  end;
  Value := Num shl Shift;
  Result := True;
end;

function DecompressLzma(const Params: array of string; const Src: TBytes; OrigSize: SizeInt): TBytes;
var
  lc, lp, pb, k: Integer;
  p: string;
  Written: SizeInt;
  r: TLzmaResult;
begin
  lc := 3; lp := 0; pb := 2;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then Continue;
    if p[1] = '*' then Delete(p, 1, 1);   // parámetro opcional
    if AnsiStartsStr('lc', p) then lc := StrToIntDef(Copy(p, 3, MaxInt), -1)
    else if AnsiStartsStr('lp', p) then lp := StrToIntDef(Copy(p, 3, MaxInt), -1)
    else if AnsiStartsStr('pb', p) then pb := StrToIntDef(Copy(p, 3, MaxInt), -1);
    // d<mem>, h<mem>, a, fb, mc, mf, bt4, normal, numFastBytes: solo afectan al compresor
  end;
  SetLength(Result, OrigSize);
  if OrigSize = 0 then Exit;
  r := LzmaDecodeRaw(PByte(Src), Length(Src), PByte(Result), OrigSize, lc, lp, pb, Written);
  if r = lzBadProps then raise EUnsupportedMethod.Create('propiedades lzma inválidas');
  if (r = lzDataError) or (Written <> OrigSize) then
    Corrupt('falló la descompresión lzma');
end;

function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;
var
  Stages, Params: TStringArray;
  Buf: TBytes;
  k: Integer;
begin
  SetLength(Buf, SrcLen);
  if SrcLen > 0 then Move(Src^, Buf[0], SrcLen);
  Stages := Method.Split(['+']);
  for k := High(Stages) downto 0 do
  begin
    Params := Stages[k].Split([':']);
    case Params[0] of
      'storing': ;
      'lzma':    Buf := DecompressLzma(Params, Buf, OrigSize);
    else
      raise EUnsupportedMethod.CreateFmt('método no soportado todavía: "%s"', [Stages[k]]);
    end;
  end;
  if Length(Buf) <> OrigSize then Corrupt('tamaño descomprimido incorrecto');
  Result := Buf;
end;

end.
