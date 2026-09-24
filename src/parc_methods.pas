{ Métodos de compresión (FORMATO-ARC.md §7). Una cadena "a+b+c" se aplicó de izquierda a
  derecha al comprimir, así que al descomprimir se arma archivo -> c -> b -> a. }
unit parc_methods;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream;

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
  StrUtils, parc_os, parc_lzma, parc_filters, parc_lz4, parc_rep, parc_lzp, parc_ppmd, parc_dict, parc_tornado, parc_grzip, parc_parallel, parc_tta, parc_mm;

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

type
  TPpmdParams = record
    Order, MRMethod: Integer;
    Mem, Chunk: QWord;
  end;

{ Parámetros como parse_PPMD (C_PPMD.cpp): o<N>, m<mem> (o "mem<mem>"), r / r<N>, c<mem>;
  sin nombre: entero = orden, memoria = mem. Defaults: orden 10, 48mb. }
function ParsePpmdParams(const Params: TStringArray): TPpmdParams;
var
  k, n: Integer;
  p: string;
  m: QWord;
begin
  Result.Order := 10;
  Result.Mem := 48 shl 20;
  Result.MRMethod := 0;
  Result.Chunk := 0;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if Copy(p, 1, 3) = 'mem' then Delete(p, 1, 2);   // "mem..." como "m..."
    if p = '' then Continue;
    if p = 'r' then begin Result.MRMethod := 1; Continue; end;
    if Length(p) > 1 then
      case p[1] of
        'm': begin if ParseMem(Copy(p, 2, MaxInt), m) then Result.Mem := m; Continue; end;
        'o': begin Result.Order := StrToIntDef(Copy(p, 2, MaxInt), -1); Continue; end;
        'r': begin Result.MRMethod := StrToIntDef(Copy(p, 2, MaxInt), 0); Continue; end;
        'c': begin if ParseMem(Copy(p, 2, MaxInt), m) then Result.Chunk := m; Continue; end;
      end;
    n := StrToIntDef(p, -1);
    if n >= 0 then Result.Order := n
    else if ParseMem(p, m) then Result.Mem := m;
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
    'tor':
      // Dentro de 4x4 FreeArc usa compress_all_at_once, que cambia cuándo se deshacen las tablas
      if not TornadoDecodeMem(Src, SrcLen, Dst, DstLen, Written) or (Written <> DstLen) then
        Corrupt('4x4: falló la descompresión tor');
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
  { Un bloque de 4x4: se descomprime entero en memoria con el método interno. }
  T4x4Job = class(TParallelJob)
  public
    Inner: string;
    InBuf: TBytes;
    Stored: Boolean;
    procedure Decode; override;
  end;

  { 4x4 (Compression/4x4/C_4x4.cpp): U32 versión (=0) y bloques [Int32 OutSize][U32 InSize][datos].
    OutSize = -1: bloque guardado. Como en FreeArc, los bloques se descomprimen en paralelo y la
    salida se entrega en orden (parc_parallel). }
  T4x4Stage = class(TParallelBlockStage)
  private
    FInner: string;
    FStarted: Boolean;
  protected
    function ReadJob: TParallelJob; override;
  public
    constructor Create(ASource: TInStage; const AInner: string);
  end;

procedure T4x4Job.Decode;
begin
  if Stored then
    OutBuf := InBuf
  else
  begin
    SetLength(OutBuf, OutSize);
    DecompressBlockMem(Inner, PByte(InBuf), Length(InBuf), PByte(OutBuf), OutSize);
  end;
  InBuf := nil;
end;

constructor T4x4Stage.Create(ASource: TInStage; const AInner: string);
begin
  // Por encima de ~16 hilos empeora (contención del heap; medido en una máquina de 64 núcleos).
  // Un bloque extra por hilo: mientras uno se entrega, los demás ya se están descomprimiendo
  inherited Create(ASource, 16, 16);
  FInner := AInner;
end;

function T4x4Stage.ReadJob: TParallelJob;
var
  Hdr: array[0..3] of Byte;
  OutSize: LongInt;
  InSize: LongWord;
  Job: T4x4Job;
begin
  Result := nil;
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
  Job := T4x4Job.Create;
  try
    Job.Inner := FInner;
    Job.Stored := OutSize = -1;
    if Job.Stored then Job.OutSize := InSize else Job.OutSize := OutSize;
    SetLength(Job.InBuf, InSize);
    if InSize > 0 then Source.ReadExact(@Job.InBuf[0], InSize);
  except
    Job.Free;
    raise;
  end;
  Result := Job;
end;

function CreateStage(const Stage: string; Source: TInStage): TInStage;
var
  Params: TStringArray;
  lz: TLzmaParams;
  pp: TPpmdParams;
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
    'lzp':
      Result := TLzpStage.Create(Source, ParseLzpParams(Params));
    'dict':
      Result := TDictStage.Create(Source, ParseDictBlockSize(Params));
    'tor':
      // El stream de Tornado describe su propio formato: los parámetros son del compresor
      Result := TTornadoStage.Create(Source);
    'grzip':
      Result := TGrzipStage.Create(Source, Params);
    'tta':
      Result := TTtaStage.Create(Source, ParseTtaParams(Params));
    'mm':
      Result := TMmStage.Create(Source, ParseMmParams(Params));
    'ppmd':
      begin
        pp := ParsePpmdParams(Params);
        Result := TPpmdStage.Create(Source, pp.Order, pp.Mem, pp.MRMethod, pp.Chunk);
      end;
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
