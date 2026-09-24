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
  StrUtils, parc_lzma, parc_filters, parc_lz4, parc_rep;

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

{ Parámetros de lz4 (parse_LZ4): solo b<mem> (tamaño de bloque) le importa al decodificador. }
function ParseLz4BlockSize(const Params: TStringArray): SizeInt;
var
  k: Integer;
  m: QWord;
begin
  Result := 1 shl 20;
  for k := 1 to High(Params) do
    if (Params[k] <> '') and (Params[k][1] = 'b') and ParseMem(Copy(Params[k], 2, MaxInt), m) then
      Result := m;
end;

{ Método interno de 4x4 (parse_4x4): los parámetros propios de 4x4 empiezan con dígito o con
  letra+dígito (t4, b7mb, i2, r99, 8mb); el primero que no cumple eso arranca el método interno. }
function Inner4x4Method(const Params: TStringArray): string;
var
  k: Integer;
begin
  Result := '';
  for k := 1 to High(Params) do
    if not ((Params[k] <> '') and ((Params[k][1] in ['0'..'9']) or
            ((Length(Params[k]) > 1) and (Params[k][2] in ['0'..'9'])))) then
    begin
      Result := string.Join(':', Params, k, Length(Params) - k);
      Exit;
    end;
  if Result = '' then Result := 'tor:3:1mb';   // default de _4x4_METHOD
end;

{ Descomprime en memoria un bloque de 4x4 con el método interno (COMPRESSION_METHOD::DeCompressMem).
  Métodos sin variante propia en memoria: su decodificador de stream sobre el bloque. }
procedure DecompressBlockMem(const Method: string; Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt);
var
  Params: TStringArray;
  lz: TLzmaParams;
  Written: SizeInt;
  Chain: TInStage;
  Extra: Byte;
begin
  Params := Method.Split([':']);
  case Params[0] of
    'lzma':
      begin
        lz := ParseLzmaParams(Params);
        if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then raise EUnsupportedMethod.Create('propiedades lzma inválidas');
        if (LzmaDecodeRaw(Src, SrcLen, Dst, DstLen, lz.lc, lz.lp, lz.pb, Written) = lzDataError) or (Written <> DstLen) then
          Corrupt('4x4: falló la descompresión lzma');
      end;
    'lz4':
      if not Lz4DecodeMem(Src, SrcLen, Dst, DstLen) then Corrupt('4x4: falló la descompresión lz4');
  else
    begin
      Chain := CreateDecoderChain(Method, TMemStage.Create(Src, SrcLen));
      try
        if DstLen > 0 then Chain.ReadExact(Dst, DstLen);
        if Chain.Read(@Extra, 1) <> 0 then Corrupt('4x4: el bloque descomprime a más bytes de lo esperado');
      finally
        Chain.Free;
      end;
    end;
  end;
end;

type
  { 4x4 (Compression/4x4/C_4x4.cpp): U32 versión (=0) y bloques [Int32 OutSize][U32 InSize][datos].
    OutSize = -1: bloque guardado. Si no, se descomprime entero en memoria con el método interno.
    FreeArc lo hace en varios hilos; acá secuencial, el resultado es el mismo. }
  T4x4Stage = class(TInStage)
  private
    FInner: string;
    FIn, FOut: array of Byte;
    FLen, FPos: SizeInt;
    FStarted, FEof: Boolean;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; const AInner: string);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

constructor T4x4Stage.Create(ASource: TInStage; const AInner: string);
begin
  inherited Create(ASource);
  FInner := AInner;
end;

function T4x4Stage.NextBlock: Boolean;
var
  Hdr: array[0..3] of Byte;
  OutSize: LongInt;
  InSize: LongWord;
begin
  Result := False;
  if not FStarted then
  begin
    FStarted := True;
    if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit;
    if (Hdr[0] or Hdr[1] or Hdr[2] or Hdr[3]) <> 0 then Corrupt('4x4: versión de formato desconocida');
  end;
  if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit;
  OutSize := LongInt(LongWord(Hdr[0]) or (LongWord(Hdr[1]) shl 8) or (LongWord(Hdr[2]) shl 16) or (LongWord(Hdr[3]) shl 24));
  InSize := Source.ReadU32;
  if (InSize > $7FFFFFFF) or (OutSize < -1) then Corrupt('4x4: tamaño de bloque inválido');
  if InSize > LongWord(Length(FIn)) then SetLength(FIn, InSize);
  if InSize > 0 then Source.ReadExact(@FIn[0], InSize);
  if OutSize = -1 then
  begin
    // Bloque guardado sin comprimir
    if InSize > LongWord(Length(FOut)) then SetLength(FOut, InSize);
    if InSize > 0 then Move(FIn[0], FOut[0], InSize);
    FLen := InSize;
  end
  else
  begin
    if OutSize > Length(FOut) then SetLength(FOut, OutSize);
    DecompressBlockMem(FInner, @FIn[0], InSize, @FOut[0], OutSize);
    FLen := OutSize;
  end;
  FPos := 0;
  Result := True;
end;

function T4x4Stage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  while FPos >= FLen do
  begin
    if FEof then Exit(0);
    if not NextBlock then
    begin
      FEof := True;
      Exit(0);
    end;
  end;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
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
    'lz4':
      Result := TLz4Stage.Create(Source, ParseLz4BlockSize(Params));
    'rep':
      Result := TRepStage.Create(Source);
    '4x4':
      Result := T4x4Stage.Create(Source, Inner4x4Method(Params));
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
