{ Métodos de compresión (FORMATO-ARC.md §7). Una cadena "a+b+c" se aplicó de izquierda a
  derecha al comprimir, así que al descomprimir se arma archivo -> c -> b -> a. }
unit parc_methods;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_bytes, parc_stream;

type
  EUnsupportedMethod = class(Exception);

{ Arma la cadena de decodificadores sobre Source (la cadena pasa a ser dueña de Source). }
function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;

{ Descomprime un bloque de control (en memoria) a exactamente OrigSize bytes. }
function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;

{ Tamaño de memoria de FreeArc ("1mb", "244kb", "64m", "512b"; sin sufijo = MB). }
function ParseMem(const S: string; out Value: QWord): Boolean;

function IsStoring(const Method: string): Boolean;

implementation

uses
  StrUtils, parc_lzma, parc_filters;

function IsStoring(const Method: string): Boolean;
begin
  Result := Method = 'storing';
end;

function ParseMem(const S: string; out Value: QWord): Boolean;
var
  i: Integer;
  Num: QWord;
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
  case LowerCase(Copy(S, i, MaxInt)) of
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

type
  TLzmaParams = record
    lc, lp, pb: Integer;
    DictSize: QWord;
  end;

{ Parámetros como parse_LZMA (C_LZMA.cpp): con nombre (d, lc, lp, pb, ...) o sin nombre
  (match finder, entero = numFastBytes, memoria = diccionario). Solo guardamos lo que usa el
  decodificador. }
function ParseLzmaParams(const Params: TStringArray): TLzmaParams;
var
  k: Integer;
  p: string;
  m: QWord;
begin
  Result.lc := 3; Result.lp := 0; Result.pb := 2;
  Result.DictSize := 64 shl 20;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if (p <> '') and (p[1] = '*') then Delete(p, 1, 1);   // parámetro opcional
    if p = '' then Continue;
    if AnsiStartsStr('lc', p) then Result.lc := StrToIntDef(Copy(p, 3, MaxInt), -1)
    else if AnsiStartsStr('lp', p) then Result.lp := StrToIntDef(Copy(p, 3, MaxInt), -1)
    else if AnsiStartsStr('pb', p) then Result.pb := StrToIntDef(Copy(p, 3, MaxInt), -1)
    else if (p[1] = 'd') and ParseMem(Copy(p, 2, MaxInt), m) then Result.DictSize := m
    else if (p[1] in ['0'..'9']) and (StrToIntDef(p, -1) < 0) and ParseMem(p, m) then
      Result.DictSize := m;   // "1mb", "103mb"; un entero pelado es numFastBytes
  end;
end;

function CreateStage(const Stage: string; Source: TInStage): TInStage;
var
  Params: TStringArray;
  lz: TLzmaParams;
begin
  Params := Stage.Split([':']);
  if Length(Params) = 0 then raise EUnsupportedMethod.Create('método vacío');
  case Params[0] of
    'storing':
      Result := Source;
    'lzma':
      begin
        lz := ParseLzmaParams(Params);
        Result := TLzmaStage.Create(Source, lz.lc, lz.lp, lz.pb, lz.DictSize);
      end;
    'exe':
      Result := TBcjX86Stage.Create(Source);
    'delta':
      Result := TDeltaStage.Create(Source);
  else
    raise EUnsupportedMethod.CreateFmt('método no soportado todavía: "%s"', [Stage]);
  end;
end;

function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;
var
  Stages: TStringArray;
  k: Integer;
begin
  Result := Source;
  try
    Stages := Method.Split(['+']);
    for k := High(Stages) downto 0 do
      Result := CreateStage(Stages[k], Result);
  except
    Result.Free;   // libera lo ya armado (y con eso Source)
    raise;
  end;
end;

function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;
var
  Params: TStringArray;
  lz: TLzmaParams;
  Written: SizeInt;
  Chain: TInStage;
  Extra: Byte;
begin
  SetLength(Result, OrigSize);
  if IsStoring(Method) then
  begin
    if SrcLen <> OrigSize then Corrupt('tamaño de bloque incorrecto');
    if OrigSize > 0 then Move(Src^, Result[0], OrigSize);
    Exit;
  end;
  Params := Method.Split([':']);
  if (Pos('+', Method) = 0) and (Params[0] = 'lzma') then
  begin
    // FreeArc descomprime los bloques de control memoria-a-memoria (sin exigir marca de fin)
    lz := ParseLzmaParams(Params);
    if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then raise EUnsupportedMethod.Create('propiedades lzma inválidas');
    if LzmaDecodeRaw(Src, SrcLen, PByte(Result), OrigSize, lz.lc, lz.lp, lz.pb, Written) = lzDataError then
      Corrupt('falló la descompresión lzma');
    if Written <> OrigSize then Corrupt('falló la descompresión lzma');
    Exit;
  end;
  // Cualquier otra cadena: en streaming
  Chain := CreateDecoderChain(Method, TMemStage.Create(Src, SrcLen));
  try
    if OrigSize > 0 then Chain.ReadExact(PByte(Result), OrigSize);
    if Chain.Read(@Extra, 1) <> 0 then Corrupt('el bloque descomprime a más bytes de lo esperado');
  finally
    Chain.Free;
  end;
end;

end.
