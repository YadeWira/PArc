{ Métodos de compresión (el formato base de FreeArc §7). Una cadena "a+b+c" se aplicó de izquierda a
  derecha al comprimir, así que al descomprimir se arma archivo -> c -> b -> a. }
unit parc_methods;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, parc_bytes, parc_stream;

type
  EUnsupportedMethod = class(Exception);
  EPasswordRequired = class(Exception);   // el archivo está cifrado y no hay contraseña
  EBadPassword = class(Exception);        // el check-code no coincide

  TPpmdParams = record
    Order, MRMethod: Integer;
    Mem, Chunk: QWord;
  end;

{ Parámetros de ppmd como parse_PPMD (compartido por el decodificador y el codificador). }
function ParsePpmdParams(const Params: TStringArray): TPpmdParams;

{ Contraseña para los archivos cifrados (bytes tal como los escribió el usuario, UTF-8). }
procedure SetArchivePassword(const Pwd: RawByteString);
{ La contraseña dada con SetArchivePassword ('' si no hay). }
function ArchivePassword: RawByteString;
{ Otra contraseña para probar (p. ej. -p y -hp distintas): como FreeArc, cada bloque cifrado
  se abre con la primera de la lista cuyo check-code coincide. }
procedure AddArchivePassword(const Pwd: RawByteString);

{ Arma la cadena de decodificadores sobre Source (la cadena pasa a ser dueña de Source). }
function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;

{ Descomprime un bloque de control (en memoria) a exactamente OrigSize bytes. }
function DecompressMem(const Method: string; Src: PByte; SrcLen: SizeInt; OrigSize: SizeInt): TBytes;

{ Tamaño de memoria de FreeArc ("1mb", "244kb", "64m", "512b"; sin sufijo = 2^N: "24" = 16mb). }
function ParseMem(const S: string; out Value: QWord): Boolean;

function IsStoring(const Method: string): Boolean;

implementation

uses
  parc_crypt, StrUtils, parc_os, parc_lzma, parc_filters, parc_lz4, parc_rep, parc_lzp, parc_ppmd,
  parc_dict, parc_tornado, parc_grzip, parc_parallel, parc_tta, parc_mm, parc_dispack, parc_srep, parc_cm,
  parc_bcj2;

var
  GPassword: RawByteString;
  GHavePassword: Boolean;
  GExtraPasswords: array of RawByteString;

procedure SetArchivePassword(const Pwd: RawByteString);
begin
  GPassword := Pwd;
  GHavePassword := True;
end;

function ArchivePassword: RawByteString;
begin
  if GHavePassword then Result := GPassword else Result := '';
end;

procedure AddArchivePassword(const Pwd: RawByteString);
begin
  if not GHavePassword then begin SetArchivePassword(Pwd); Exit; end;
  SetLength(GExtraPasswords, Length(GExtraPasswords) + 1);
  GExtraPasswords[High(GExtraPasswords)] := Pwd;
end;

{ ¿La etapa es de cifrado? El nombre va antes de '-' (bits) o '/' (modo): "aes-256/ctr". }
function IsCipherStage(const Stage: string): Boolean;
var
  Name: string;
  p: Integer;
begin
  Name := Stage.Split([':'])[0];
  p := Pos('-', Name); if p > 0 then Name := Copy(Name, 1, p - 1);
  p := Pos('/', Name); if p > 0 then Name := Copy(Name, 1, p - 1);
  Result := IsCipherName(Name);
end;

{ Bytes de la contraseña tal como los ve FreeArc 0.67 (Encryption.hs:85 y EncryptionLib.hs:27):
  - con :f, unicode2utf8: los bytes UTF-8;
  - sin :f (el caso de siempre), la contraseña llega como caracteres Unicode reales
    (Charsets.myGetArgs usa CommandLineToArgvW) y withCStringLen de GHC 6.x trunca cada
    carácter a su byte bajo (castCharToCChar). Para ASCII da lo mismo; para "日" (U+65E5), E5.
  Nuestra contraseña viene en UTF-8. }
function PasswordBytes(const Password: RawByteString; Fixed: Boolean): RawByteString;
var
  W: UnicodeString;
  i: Integer;
begin
  if Fixed then Exit(Password);
  W := UTF8Decode(Password);
  SetLength(Result, Length(W));
  for i := 1 to Length(W) do Result[i] := Chr(Ord(W[i]) and $FF);
end;

{ Como generateDecryption (Encryption.hs): cada etapa de cifrado sin clave (:k) se reemplaza
  por su versión con la clave derivada de la contraseña, después de comprobar el check-code. }
var
  GKeyCacheId: string = '';   // la última clave derivada (ApplyKeys)
  GKeyCache: array of Byte;

function ApplyKeys(const Method: string): string;
var
  Stages, Params: TStringArray;
  k, j: Integer;
  HasKey: Boolean;
  Par: TCryptParams;
  Key: array of Byte;
  Pwd: RawByteString;
  p: Integer;
  Ok: Boolean;
  CacheId: string;
begin
  Result := Method;
  if Pos('/', Method) = 0 then Exit;   // atajo: toda etapa de cifrado lleva "/modo"
  Stages := Method.Split(['+']);
  for k := 0 to High(Stages) do
  begin
    if not IsCipherStage(Stages[k]) then Continue;
    Params := Stages[k].Split([':']);
    HasKey := False;
    for j := 1 to High(Params) do
      if (Params[j] <> '') and (Params[j][1] = 'k') then HasKey := True;
    if HasKey then Continue;
    if not GHavePassword then
      raise EPasswordRequired.Create('archive is encrypted: provide the password with -p<password>');
    Par := ParseCryptParams(Params);
    SetLength(Key, Par.KeySize + 2);
    // Los bloques de un .parc comparten sal: la clave derivada se recuerda (con muchas
    // iteraciones de PBKDF2, derivarla en cada bloque costaría ~0,6 s por bloque)
    CacheId := Par.Cipher + IntToStr(Par.KeySize) + ':' + IntToStr(Par.NumIterations) + ':' +
               BoolToStr(Par.Fixed, 'f', '') + ':' + Par.SaltHex + ':' + Par.CheckHex;
    Ok := (CacheId = GKeyCacheId) and (Length(GKeyCache) >= Par.KeySize);
    if Ok then Move(GKeyCache[0], Key[0], Par.KeySize)
    else
    begin
      Pwd := PasswordBytes(GPassword, Par.Fixed);
      Ok := DeriveKeyAndCheck(Par, PByte(Pwd), Length(Pwd), @Key[0]);
      p := 0;
      while not Ok and (p <= High(GExtraPasswords)) do
      begin
        Pwd := PasswordBytes(GExtraPasswords[p], Par.Fixed);
        Ok := DeriveKeyAndCheck(Par, PByte(Pwd), Length(Pwd), @Key[0]);
        Inc(p);
      end;
      if Ok then
      begin
        GKeyCacheId := CacheId;
        GKeyCache := Copy(Key, 0, Par.KeySize);
      end;
    end;
    if not Ok then
      raise EBadPassword.Create('wrong password');
    Stages[k] := KeyedMethod(Par, @Key[0]);
  end;
  Result := string.Join('+', Stages);
end;

function IsStoring(const Method: string): Boolean;
begin
  Result := Method = 'storing';
end;

function ParseMem(const S: string; out Value: QWord): Boolean;
var
  i: Integer;
  Num: QWord;
  c: Char;
begin
  // parseMem64 de FreeArc (Common.cpp:232): dígitos y un sufijo b/k/m/g; SIN sufijo es una
  // potencia de 2 ('^', el default de todos los métodos): "24" = 16mb, no 24mb. Solo cuenta
  // la primera letra del sufijo ("mb" = "m"); un '=' inicial se ignora
  Result := False;
  i := 1;
  if (i <= Length(S)) and (S[i] = '=') then Inc(i);
  if (i > Length(S)) or not (S[i] in ['0'..'9']) then Exit;
  Num := 0;
  while (i <= Length(S)) and (S[i] in ['0'..'9']) do
  begin
    if Num > (High(QWord) div 10) then Exit;
    Num := Num * 10 + Ord(S[i]) - Ord('0');
    Inc(i);
  end;
  if i <= Length(S) then c := LowerCase(S[i]) else c := '^';
  case c of
    'b': Value := Num;
    'k': Value := Num shl 10;
    'm': Value := Num shl 20;
    'g': Value := Num shl 30;
    '^': begin
           if Num > 63 then Exit;
           Value := QWord(1) shl Num;
         end;
  else
    Exit;
  end;
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
        if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then raise EUnsupportedMethod.Create('invalid lzma properties');
        if (LzmaDecodeRaw(Src, SrcLen, Dst, DstLen, lz.lc, lz.lp, lz.pb, Written) = lzDataError) or (Written <> DstLen) then
          Corrupt('4x4: lzma decompression failed');
      end;
    'lz4':
      if not Lz4DecodeMem(Src, SrcLen, Dst, DstLen) then Corrupt('4x4: lz4 decompression failed');
    'tor':
      // Dentro de 4x4 FreeArc usa compress_all_at_once, que cambia cuándo se deshacen las tablas
      if not TornadoDecodeMem(Src, SrcLen, Dst, DstLen, Written) or (Written <> DstLen) then
        Corrupt('4x4: tornado decompression failed');
  else
    begin
      Chain := CreateDecoderChain(Method, TMemStage.Create(Src, SrcLen));
      try
        if DstLen > 0 then Chain.ReadExact(Dst, DstLen);
        if Chain.Read(@Extra, 1) <> 0 then Corrupt('4x4: block decompresses to more bytes than expected');
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
    procedure Process; override;
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

var
  FourBlockWarned: Integer = 0;   // 1 cuando ya se avisó del primer bloque dañado

procedure T4x4Job.Process;
begin
  if Stored then
    OutBuf := InBuf
  else
  begin
    SetLength(OutBuf, OutSize);
    // Los bloques de 4x4 son independientes: si uno está dañado, se entregan ceros de su
    // tamaño original (su CRC fallará aparte) y los demás salen bien (como FreeArc, que
    // descomprime cada bloque con su propio DeCompressMem)
    try
      DecompressBlockMem(Inner, PByte(InBuf), Length(InBuf), PByte(OutBuf), OutSize);
    except
      on E: EArcCorrupt do
      begin
        FillChar(OutBuf[0], OutSize, 0);
        if InterlockedExchange(FourBlockWarned, 1) = 0 then
          ErrLn('Warning: damaged 4x4 block (' + E.Message + '); zeros are returned and the remaining blocks continue');
      end;
    end;
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
    if (Hdr[0] or Hdr[1] or Hdr[2] or Hdr[3]) <> 0 then Corrupt('4x4: unknown format version');
  end;
  if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit;
  OutSize := LongInt(LongWord(Hdr[0]) or (LongWord(Hdr[1]) shl 8) or (LongWord(Hdr[2]) shl 16) or (LongWord(Hdr[3]) shl 24));
  InSize := Source.ReadU32;
  if (InSize > $7FFFFFFF) or (OutSize < -1) then Corrupt('4x4: invalid block size');
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
  if Length(Params) = 0 then raise EUnsupportedMethod.Create('empty method');
  if IsCipherStage(Stage) then
    Exit(TDecryptStage.Create(Source, ParseCryptParams(Params)));
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
    'bcj2', 'exe2':
      Result := TBcj2DecStage.Create(Source);
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
    'dispack', 'dispack070':
      Result := TDisPackStage.Create(Source, DispackBlockSize(Params));
    'srep':
      Result := TSrepStage.Create(Source);
    'cm':
      Result := TCmDecStage.Create(Source);
  else
    raise EUnsupportedMethod.CreateFmt('method not supported yet: "%s"', [Stage]);
  end;
end;

function CreateDecoderChain(const Method: string; Source: TInStage): TInStage;
var
  Stages: TStringArray;
  k: Integer;
begin
  Result := Source;
  try
    Stages := ApplyKeys(Method).Split(['+']);
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
    if SrcLen <> OrigSize then Corrupt('wrong block size');
    if OrigSize > 0 then Move(Src^, Result[0], OrigSize);
    Exit;
  end;
  Params := Method.Split([':']);
  if (Pos('+', Method) = 0) and (Params[0] = 'lzma') then
  begin
    // FreeArc descomprime los bloques de control memoria-a-memoria (sin exigir marca de fin)
    lz := ParseLzmaParams(Params);
    if not ValidLzmaProps(lz.lc, lz.lp, lz.pb) then raise EUnsupportedMethod.Create('invalid lzma properties');
    if LzmaDecodeRaw(Src, SrcLen, PByte(Result), OrigSize, lz.lc, lz.lp, lz.pb, Written) = lzDataError then
      Corrupt('lzma decompression failed');
    if Written <> OrigSize then Corrupt('lzma decompression failed');
    Exit;
  end;
  // Cualquier otra cadena: en streaming
  Chain := CreateDecoderChain(Method, TMemStage.Create(Src, SrcLen));
  try
    if OrigSize > 0 then Chain.ReadExact(PByte(Result), OrigSize);
    if Chain.Read(@Extra, 1) <> 0 then Corrupt('block decompresses to more bytes than expected');
  finally
    Chain.Free;
  end;
end;

end.
