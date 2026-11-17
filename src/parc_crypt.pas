{ parc_crypt — cifrado autenticado de .parc (esquema propio, versión 1).

  Resumen (detalle en docs/formato/FORMATO-PARC.md §3b):

  - Etapa al final de la cadena de métodos de un bloque, SIN clave:
        xchacha20:t<T>:m<KiB>:p<P>:s<sal>:c<check>:n<nonce>[:h]
        aes256gcm:t<T>:m<KiB>:p<P>:s<sal>:c<check>:n<nonce>[:h]
    s = sal de Argon2 (16 bytes), c = valor de comprobación de la contraseña (8 bytes),
    n = prefijo de nonce del bloque (16 bytes, al azar en cada bloque), todo en hex; :h =
    bloque de control (directorio o footer, -hp).
  - Clave maestra: Argon2id(contraseña en UTF-8, sal, t, m, p) -> 32 bytes (RFC 9106; por
    defecto t = 3, m = 64 MiB, p = 4: la segunda opción recomendada por el RFC).
  - Subclaves con BLAKE2b-256 con clave (RFC 7693), clave = maestra:
        check  = BLAKE2b(maestra, "PArc/1 check")[0..7]
        K_uso  = BLAKE2b(maestra, "PArc/1 data <cifrado>" | "PArc/1 header <cifrado>")
  - El bloque cifrado es una serie de trozos de 64 KiB de claro (el último, de 0 a 64 KiB) con
    su etiqueta de 16 bytes detrás. Cada trozo i es un AEAD independiente sin datos asociados:
        XChaCha20-Poly1305: clave K_uso, nonce (24) = n ‖ LE56(i) ‖ fin
        AES-256-GCM:        clave BLAKE2b(K_uso, n), nonce (12) = LE88(i) ‖ fin
    con fin = 1 en el último trozo y 0 en los demás: cortar, reordenar, quitar o agregar
    trozos falla la autenticación. Se descifra un trozo sólo después de comprobar su etiqueta,
    así que nunca sale texto sin autenticar.
  - Nada depende de la posición del bloque en el archivo: los bloques se copian tal cual al
    actualizar. El nonce del bloque está en su cadena de método, que va en el directorio:
    con -hp (directorio autenticado) cambiar un bloque de lugar o por otro también falla.

  Las claves derivadas se guardan en un caché (protegido por un candado: los bloques se
  abren desde varios hilos) indexado por (sal, t, m, p, check), así que Argon2 corre una
  vez por sal y contraseña. Al escribir se reutiliza la sal de una clave ya derivada con la
  misma contraseña (la del archivo que se actualiza), y si no hay ninguna se genera una. }
unit parc_crypt;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream;

const
  CRYPT_CHUNK = 65536;             // claro por trozo
  CRYPT_TAG = 16;
  KDF_DEFAULT_T = 3;
  KDF_DEFAULT_M = 65536;           // KiB = 64 MiB
  KDF_DEFAULT_P = 4;
  // Lo más que acepta un lector (un archivo hostil no puede pedir más)
  KDF_MAX_T = 64;
  KDF_MAX_M = 4194304;             // 4 GiB
  KDF_MAX_P = 64;

type
  TCipherKind = (ckXChaCha20, ckAes256Gcm);

  TKdfParams = record
    T, M, P: LongWord;
    Salt: array[0..15] of Byte;
  end;

  TCryptParams = record
    Kind: TCipherKind;
    Kdf: TKdfParams;
    Check: array[0..7] of Byte;
    Nonce: array[0..15] of Byte;
    Header: Boolean;
  end;

  TMasterKey = array[0..31] of Byte;

  { -ae=<algoritmo>[:t<n>][:m<KiB>|:m<n>m|:m<n>g][:p<n>] }
  TCipherChoice = record
    Kind: TCipherKind;
    T, M, P: LongWord;
  end;

{ ¿Es una etapa de cifrado ("xchacha20:..." o "aes256gcm:...")? }
function IsCipherStage(const Stage: string): Boolean;
{ Lee una etapa de cifrado. Lanza EArcCorrupt si está mal formada o pide un costo de KDF
  fuera de los límites. }
function ParseCipherStage(const Stage: string): TCryptParams;
function CipherStageString(const Par: TCryptParams): string;
{ Lee -ae=. False si el algoritmo o un parámetro no valen. }
function ParseCipherChoice(const S: string; out C: TCipherChoice): Boolean;

{ Argon2id y el valor de comprobación (expuestos para los tests). }
procedure DeriveMaster(const Kdf: TKdfParams; Pwd: PByte; PwdLen: SizeInt; out Master: TMasterKey);
procedure CheckValue(const Master: TMasterKey; Check: PByte);

{ Caché de claves: True y la maestra si ya se derivó la de Par. }
function CryptLookup(const Par: TCryptParams; out Master: TMasterKey): Boolean;
{ Prueba una contraseña con la sal y el check de Par (derivando si hace falta). }
function CryptTryPassword(const Par: TCryptParams; const Pwd: RawByteString; out Master: TMasterKey): Boolean;
{ ¿Abre Pwd la primera etapa de cifrado de Method? (True si no tiene ninguna) }
function CryptMethodPasswordOk(const Method: string; const Pwd: RawByteString): Boolean;
{ Etapa de cifrado para un bloque nuevo (nonce al azar), con la clave de Pwd ya en el caché
  (si no estaba, se deriva: con la sal de una clave ya derivada con esa contraseña, o con
  una sal nueva). }
function CryptStageForWrite(const C: TCipherChoice; const Pwd: RawByteString; Header: Boolean): string;

type
  { Cifra: Emit recibe trozos de CRYPT_CHUNK + 16 (el último, más corto). }
  TAeadEncryptStage = class(TOutStage)
  private
    FPar: TCryptParams;
    FKey: TMasterKey;            // K_uso (xchacha) o la clave del bloque (aes)
    FGcm: Pointer;               // TAesGcmKey (aes)
    FBuf: array of Byte;
    FLen: SizeInt;
    FIndex: QWord;
    procedure Seal(Last: Boolean);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const APar: TCryptParams; const Master: TMasterKey);
    destructor Destroy; override;
  end;

  { Descifra trozo a trozo; un trozo sólo se entrega si su etiqueta es correcta. }
  TAeadDecryptStage = class(TInStage)
  private
    FPar: TCryptParams;
    FKey: TMasterKey;
    FGcm: Pointer;
    FIn: array of Byte;          // CRYPT_CHUNK + 16 + 1 (un byte de más para saber si es el último)
    FInLen: SizeInt;
    FOut: array of Byte;
    FOutPos, FOutLen: SizeInt;
    FIndex: QWord;
    FDone, FSrcEof: Boolean;
    procedure NextChunk;
  public
    constructor Create(ASource: TInStage; const APar: TCryptParams; const Master: TMasterKey);
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Bytes al azar del RNG del sistema. Linux: /dev/urandom. Windows: RtlGenRandom
  (SystemFunction036 de advapi32, desde XP). }
function OsRandom(Buf: PByte; Len: SizeInt): Boolean;

{ Para los tests y el benchmark: sella/abre un trozo con el esquema (sin la cadena). }
function CipherName(Kind: TCipherKind): string;

implementation

uses
  parc_bytes, parc_blake2, parc_chacha, parc_aes, parc_parallel;

const
  CIPHER_NAMES: array[TCipherKind] of string = ('xchacha20', 'aes256gcm');

function CipherName(Kind: TCipherKind): string;
begin
  Result := CIPHER_NAMES[Kind];
end;

{ ---------------------------------------------------------------------------------- RNG }

function OsRandom(Buf: PByte; Len: SizeInt): Boolean;
{$IFDEF WINDOWS}
type
  TRtlGenRandom = function(RandomBuffer: Pointer; BufferLength: LongWord): ByteBool; stdcall;
var
  h: THandle;
  f: TRtlGenRandom;
  done: ByteBool;
begin
  Result := False;
  if Len <= 0 then Exit(True);
  h := LoadLibrary('advapi32.dll');
  if h = 0 then Exit;
  try
    f := TRtlGenRandom(GetProcAddress(h, 'SystemFunction036'));
    if not Assigned(f) then Exit;
    done := f(Buf, LongWord(Len));
    Result := done <> False;
  finally
    FreeLibrary(h);
  end;
end;
{$ELSE}
var
  f: THandle;
  got: SizeInt;
begin
  Result := False;
  if Len <= 0 then Exit(True);
  f := FileOpen('/dev/urandom', fmOpenRead or fmShareDenyNone);
  if f = THandle(-1) then Exit;
  try
    while Len > 0 do
    begin
      got := FileRead(f, Buf^, Len);
      if got <= 0 then Exit;
      Inc(Buf, got);
      Dec(Len, got);
    end;
    Result := True;
  finally
    FileClose(f);
  end;
end;
{$ENDIF}

procedure RandomBytes(Buf: PByte; Len: SizeInt);
begin
  if not OsRandom(Buf, Len) then
    raise Exception.Create('encryption: the system random number generator is not available');
end;

{ ------------------------------------------------------------------------ cadena de etapa }

function HexStr(p: PByte; n: Integer): string;
const
  D: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  SetLength(Result, 2 * n);
  for i := 0 to n - 1 do
  begin
    Result[2 * i + 1] := D[p[i] shr 4];
    Result[2 * i + 2] := D[p[i] and 15];
  end;
end;

function UnhexInto(const S: string; p: PByte; n: Integer): Boolean;
var
  i, k, v: Integer;
  c: Char;
begin
  Result := False;
  if Length(S) <> 2 * n then Exit;
  for i := 0 to n - 1 do
  begin
    v := 0;
    for k := 1 to 2 do
    begin
      c := S[2 * i + k];
      case c of
        '0'..'9': v := v * 16 + Ord(c) - Ord('0');
        'a'..'f': v := v * 16 + Ord(c) - Ord('a') + 10;
        'A'..'F': v := v * 16 + Ord(c) - Ord('A') + 10;
      else
        Exit;
      end;
    end;
    p[i] := v;
  end;
  Result := True;
end;

function StageName(const Stage: string): string;
var
  p: Integer;
begin
  p := Pos(':', Stage);
  if p > 0 then Result := Copy(Stage, 1, p - 1) else Result := Stage;
end;

function IsCipherStage(const Stage: string): Boolean;
var
  n: string;
begin
  n := StageName(Stage);
  Result := (n = CIPHER_NAMES[ckXChaCha20]) or (n = CIPHER_NAMES[ckAes256Gcm]);
end;

function ParseU32(const S: string; out V: LongWord): Boolean;
var
  q: QWord;
  i: Integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 10) then Exit;
  q := 0;
  for i := 1 to Length(S) do
  begin
    if not (S[i] in ['0'..'9']) then Exit;
    q := q * 10 + Ord(S[i]) - Ord('0');
  end;
  if q > High(LongWord) then Exit;
  V := q;
  Result := True;
end;

function KdfValid(T, M, P: LongWord): Boolean;
begin
  Result := (T >= 1) and (T <= KDF_MAX_T) and (P >= 1) and (P <= KDF_MAX_P) and
            (M >= 8 * P) and (M <= KDF_MAX_M);
end;

function ParseCipherStage(const Stage: string): TCryptParams;
var
  Parts: TStringArray;
  i: Integer;
  v, Have: string;
  Ok: Boolean;
begin
  Result := Default(TCryptParams);
  Parts := Stage.Split([':']);
  if Parts[0] = CIPHER_NAMES[ckXChaCha20] then Result.Kind := ckXChaCha20
  else if Parts[0] = CIPHER_NAMES[ckAes256Gcm] then Result.Kind := ckAes256Gcm
  else Corrupt('encryption: unknown cipher "' + Parts[0] + '"');
  Have := '';
  for i := 1 to High(Parts) do
  begin
    if Parts[i] = '' then Corrupt('encryption: invalid parameters');
    v := Copy(Parts[i], 2, MaxInt);
    case Parts[i][1] of
      't': Ok := ParseU32(v, Result.Kdf.T);
      'm': Ok := ParseU32(v, Result.Kdf.M);
      'p': Ok := ParseU32(v, Result.Kdf.P);
      's': Ok := UnhexInto(v, @Result.Kdf.Salt[0], SizeOf(Result.Kdf.Salt));
      'c': Ok := UnhexInto(v, @Result.Check[0], SizeOf(Result.Check));
      'n': Ok := UnhexInto(v, @Result.Nonce[0], SizeOf(Result.Nonce));
      'h': begin Ok := v = ''; Result.Header := True; end;
    else
      Ok := False;
    end;
    if not Ok or (Pos(Parts[i][1], Have) > 0) then
      Corrupt('encryption: invalid parameter "' + Parts[i] + '"');
    Have := Have + Parts[i][1];
  end;
  for v in ['t', 'm', 'p', 's', 'c', 'n'] do
    if Pos(v, Have) = 0 then Corrupt('encryption: missing parameter "' + v + '"');
  if not KdfValid(Result.Kdf.T, Result.Kdf.M, Result.Kdf.P) then
    Corrupt('encryption: key derivation cost out of range');
end;

function CipherStageString(const Par: TCryptParams): string;
begin
  Result := Format('%s:t%u:m%u:p%u:s%s:c%s:n%s', [CIPHER_NAMES[Par.Kind], Par.Kdf.T, Par.Kdf.M, Par.Kdf.P,
    HexStr(@Par.Kdf.Salt[0], 16), HexStr(@Par.Check[0], 8), HexStr(@Par.Nonce[0], 16)]);
  if Par.Header then Result := Result + ':h';
end;

function ParseCipherChoice(const S: string; out C: TCipherChoice): Boolean;
var
  Parts: TStringArray;
  i: Integer;
  v: string;
  Mul: LongWord;
begin
  Result := False;
  C.T := KDF_DEFAULT_T; C.M := KDF_DEFAULT_M; C.P := KDF_DEFAULT_P;
  Parts := LowerCase(S).Split([':']);
  if Length(Parts) = 0 then Exit;
  case Parts[0] of
    'chacha', 'xchacha', 'xchacha20', 'xchacha20-poly1305', 'chacha20', 'chacha20-poly1305': C.Kind := ckXChaCha20;
    'aes', 'aes256', 'aes-256', 'aes256gcm', 'aes-gcm', 'aes-256-gcm', 'gcm': C.Kind := ckAes256Gcm;
  else
    Exit;
  end;
  for i := 1 to High(Parts) do
  begin
    if Length(Parts[i]) < 2 then Exit;
    v := Copy(Parts[i], 2, MaxInt);
    case Parts[i][1] of
      't': if not ParseU32(v, C.T) then Exit;
      'p': if not ParseU32(v, C.P) then Exit;
      'm':
        begin
          // KiB; con sufijo k/m/g, en esa unidad
          Mul := 1;
          case v[Length(v)] of
            'k': Mul := 1;
            'm': Mul := 1024;
            'g': Mul := 1024 * 1024;
          end;
          if v[Length(v)] in ['k', 'm', 'g'] then Delete(v, Length(v), 1);
          if not ParseU32(v, C.M) or (QWord(C.M) * Mul > KDF_MAX_M) then Exit;
          C.M := C.M * Mul;
        end;
    else
      Exit;
    end;
  end;
  Result := KdfValid(C.T, C.M, C.P);
end;

{ ------------------------------------------------------------------- derivación de claves }

procedure DeriveMaster(const Kdf: TKdfParams; Pwd: PByte; PwdLen: SizeInt; out Master: TMasterKey);
var
  Th: Integer;
begin
  // los carriles de Argon2 en paralelo, dentro del presupuesto de hilos (el resultado no
  // depende de cuántos)
  Th := BudgetThreads;
  if Th > Integer(Kdf.P) then Th := Kdf.P;
  if Th < 1 then Th := 1;
  Argon2(a2id, Pwd, PwdLen, @Kdf.Salt[0], SizeOf(Kdf.Salt), Kdf.T, Kdf.M, Kdf.P, @Master[0],
         SizeOf(Master), nil, 0, nil, 0, Th);
end;

procedure Subkey(const Master: TMasterKey; const Lbl: string; Out_: PByte);
var
  L: RawByteString;
begin
  L := 'PArc/1 ' + Lbl;
  Blake2b(Out_, 32, PByte(L), Length(L), @Master[0], SizeOf(Master));
end;

procedure CheckValue(const Master: TMasterKey; Check: PByte);
var
  K: TMasterKey;
begin
  Subkey(Master, 'check', @K[0]);
  Move(K[0], Check^, 8);
  FillChar(K, SizeOf(K), 0);
end;

{ La clave de los trozos de un bloque: K_uso (xchacha) o BLAKE2b(K_uso, nonce del bloque) (aes). }
procedure BlockKey(const Par: TCryptParams; const Master: TMasterKey; out Key: TMasterKey);
var
  K: TMasterKey;
  Lbl: string;
begin
  if Par.Header then Lbl := 'header ' else Lbl := 'data ';
  Subkey(Master, Lbl + CIPHER_NAMES[Par.Kind], @K[0]);
  if Par.Kind = ckXChaCha20 then
    Key := K
  else
    Blake2b(@Key[0], 32, @Par.Nonce[0], SizeOf(Par.Nonce), @K[0], SizeOf(K));
  FillChar(K, SizeOf(K), 0);
end;

type
  TKeyEntry = record
    Kdf: TKdfParams;
    Check: array[0..7] of Byte;
    Master: TMasterKey;
    PwdTag: array[0..31] of Byte;   // BLAKE2b de la contraseña (para reutilizar la sal al escribir)
    Bad: Boolean;                   // contraseña probada que NO es la de esta sal y check
  end;

var
  GLock: TRTLCriticalSection;
  GKeys: array of TKeyEntry;

function SameKdf(const a, b: TKdfParams): Boolean;
begin
  Result := (a.T = b.T) and (a.M = b.M) and (a.P = b.P) and CompareMem(@a.Salt[0], @b.Salt[0], 16);
end;

procedure PwdTagOf(const Pwd: RawByteString; Tag: PByte);
begin
  Blake2b(Tag, 32, PByte(Pwd), Length(Pwd));
end;

function CryptLookup(const Par: TCryptParams; out Master: TMasterKey): Boolean;
var
  i: Integer;
begin
  Result := False;
  EnterCriticalSection(GLock);
  try
    for i := 0 to High(GKeys) do
      if not GKeys[i].Bad and SameKdf(GKeys[i].Kdf, Par.Kdf) and CompareMem(@GKeys[i].Check[0], @Par.Check[0], 8) then
      begin
        Master := GKeys[i].Master;
        Exit(True);
      end;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

procedure AddEntry(const Kdf: TKdfParams; Check: PByte; const Master: TMasterKey; Tag: PByte; Bad: Boolean);
var
  n: Integer;
begin
  n := Length(GKeys);
  SetLength(GKeys, n + 1);
  GKeys[n].Kdf := Kdf;
  Move(Check^, GKeys[n].Check[0], 8);
  GKeys[n].Master := Master;
  Move(Tag^, GKeys[n].PwdTag[0], 32);
  GKeys[n].Bad := Bad;
end;

function CryptTryPassword(const Par: TCryptParams; const Pwd: RawByteString; out Master: TMasterKey): Boolean;
var
  Tag: array[0..31] of Byte;
  Chk: array[0..7] of Byte;
  i: Integer;
begin
  PwdTagOf(Pwd, @Tag[0]);
  // (con el candado tomado durante la derivación: dos hilos que abren bloques de la misma
  // sal esperan una sola derivación)
  EnterCriticalSection(GLock);
  try
    for i := 0 to High(GKeys) do
      if SameKdf(GKeys[i].Kdf, Par.Kdf) and CompareMem(@GKeys[i].Check[0], @Par.Check[0], 8) and
         CompareMem(@GKeys[i].PwdTag[0], @Tag[0], 32) then
      begin
        Master := GKeys[i].Master;
        Exit(not GKeys[i].Bad);
      end;
    DeriveMaster(Par.Kdf, PByte(Pwd), Length(Pwd), Master);
    CheckValue(Master, @Chk[0]);
    Result := ConstEq(@Chk[0], @Par.Check[0], 8);
    if not Result then FillChar(Master, SizeOf(Master), 0);
    AddEntry(Par.Kdf, @Par.Check[0], Master, @Tag[0], not Result);
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function CryptMethodPasswordOk(const Method: string; const Pwd: RawByteString): Boolean;
var
  Stage: string;
  Master: TMasterKey;
begin
  for Stage in Method.Split(['+']) do
    if IsCipherStage(Stage) then
    begin
      Result := CryptTryPassword(ParseCipherStage(Stage), Pwd, Master);
      FillChar(Master, SizeOf(Master), 0);
      Exit;
    end;
  Result := True;
end;

function CryptStageForWrite(const C: TCipherChoice; const Pwd: RawByteString; Header: Boolean): string;
var
  Tag: array[0..31] of Byte;
  Par: TCryptParams;
  Master: TMasterKey;
  i: Integer;
  Found: Boolean;
begin
  if Pwd = '' then raise Exception.Create('encryption: empty password');
  PwdTagOf(Pwd, @Tag[0]);
  Par := Default(TCryptParams);
  Par.Kind := C.Kind;
  Par.Header := Header;
  EnterCriticalSection(GLock);
  try
    Found := False;
    // una clave ya derivada con esta contraseña y estos costos (la del archivo que se
    // actualiza, o la del bloque anterior): misma sal, sin volver a correr Argon2
    for i := 0 to High(GKeys) do
      if not GKeys[i].Bad and CompareMem(@GKeys[i].PwdTag[0], @Tag[0], 32) and
         (GKeys[i].Kdf.T = C.T) and (GKeys[i].Kdf.M = C.M) and (GKeys[i].Kdf.P = C.P) then
      begin
        Par.Kdf := GKeys[i].Kdf;
        Move(GKeys[i].Check[0], Par.Check[0], 8);
        Found := True;
        Break;
      end;
    if not Found then
    begin
      Par.Kdf.T := C.T; Par.Kdf.M := C.M; Par.Kdf.P := C.P;
      RandomBytes(@Par.Kdf.Salt[0], SizeOf(Par.Kdf.Salt));
      DeriveMaster(Par.Kdf, PByte(Pwd), Length(Pwd), Master);
      CheckValue(Master, @Par.Check[0]);
      AddEntry(Par.Kdf, @Par.Check[0], Master, @Tag[0], False);
      FillChar(Master, SizeOf(Master), 0);
    end;
  finally
    LeaveCriticalSection(GLock);
  end;
  RandomBytes(@Par.Nonce[0], SizeOf(Par.Nonce));
  Result := CipherStageString(Par);
end;

{ ------------------------------------------------------------------------------- trozos }

{ Nonce del trozo Index (Last = el último del bloque). }
procedure ChunkNonce(const Par: TCryptParams; Index: QWord; Last: Boolean; N: PByte);
var
  i, o: Integer;
begin
  if Par.Kind = ckXChaCha20 then
  begin
    Move(Par.Nonce[0], N^, 16);
    o := 16;
    for i := 0 to 6 do begin N[o + i] := Byte(Index); Index := Index shr 8; end;
    N[23] := Ord(Last);
  end
  else
  begin
    for i := 0 to 10 do begin N[i] := Byte(Index); Index := Index shr 8; end;
    N[11] := Ord(Last);
  end;
end;

procedure SealChunk(const Par: TCryptParams; const Key: TMasterKey; Gcm: Pointer; Index: QWord;
  Last: Boolean; Buf: PByte; Len: SizeInt);
var
  N: array[0..23] of Byte;
begin
  ChunkNonce(Par, Index, Last, @N[0]);
  if Par.Kind = ckXChaCha20 then
    XChaChaPolySeal(@Key[0], @N[0], nil, 0, Buf, Buf, Len, Buf + Len)
  else
    AesGcmSeal(TAesGcmKey(Gcm^), @N[0], nil, 0, Buf, Buf, Len, Buf + Len);
end;

function OpenChunk(const Par: TCryptParams; const Key: TMasterKey; Gcm: Pointer; Index: QWord;
  Last: Boolean; Src: PByte; Len: SizeInt; Dst: PByte): Boolean;
var
  N: array[0..23] of Byte;
begin
  ChunkNonce(Par, Index, Last, @N[0]);
  if Par.Kind = ckXChaCha20 then
    Result := XChaChaPolyOpen(@Key[0], @N[0], nil, 0, Src, Dst, Len, Src + Len)
  else
    Result := AesGcmOpen(TAesGcmKey(Gcm^), @N[0], nil, 0, Src, Dst, Len, Src + Len);
end;

procedure SetupKey(const Par: TCryptParams; const Master: TMasterKey; out Key: TMasterKey; out Gcm: Pointer);
begin
  BlockKey(Par, Master, Key);
  Gcm := nil;
  if Par.Kind = ckAes256Gcm then
  begin
    New(PAesGcmKey(Gcm));
    AesGcmInit(PAesGcmKey(Gcm)^, @Key[0]);
  end;
end;

procedure FreeKey(var Key: TMasterKey; var Gcm: Pointer);
begin
  FillChar(Key, SizeOf(Key), 0);
  if Gcm <> nil then
  begin
    AesGcmClear(PAesGcmKey(Gcm)^);
    Dispose(PAesGcmKey(Gcm));
    Gcm := nil;
  end;
end;

{ ------------------------------------------------------------------- etapa de cifrado }

constructor TAeadEncryptStage.Create(ATarget: TOutStage; const APar: TCryptParams; const Master: TMasterKey);
begin
  inherited Create(ATarget);
  FPar := APar;
  SetupKey(FPar, Master, FKey, FGcm);
  SetLength(FBuf, CRYPT_CHUNK + CRYPT_TAG);
end;

destructor TAeadEncryptStage.Destroy;
begin
  FreeKey(FKey, FGcm);
  if Length(FBuf) > 0 then FillChar(FBuf[0], Length(FBuf), 0);
  inherited Destroy;
end;

procedure TAeadEncryptStage.Seal(Last: Boolean);
begin
  SealChunk(FPar, FKey, FGcm, FIndex, Last, @FBuf[0], FLen);
  Emit(@FBuf[0], FLen + CRYPT_TAG);
  Inc(FIndex);
  FLen := 0;
end;

procedure TAeadEncryptStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    // un trozo lleno se sella recién cuando llega algo más: si no, era el último
    if FLen = CRYPT_CHUNK then Seal(False);
    n := CRYPT_CHUNK - FLen;
    if n > Count then n := Count;
    Move(Buf^, FBuf[FLen], n);
    Inc(FLen, n);
    Inc(Buf, n);
    Dec(Count, n);
  end;
end;

procedure TAeadEncryptStage.DoFinish;
begin
  Seal(True);
end;

{ ----------------------------------------------------------------- etapa de descifrado }

constructor TAeadDecryptStage.Create(ASource: TInStage; const APar: TCryptParams; const Master: TMasterKey);
begin
  inherited Create(ASource);
  FPar := APar;
  SetupKey(FPar, Master, FKey, FGcm);
  SetLength(FIn, CRYPT_CHUNK + CRYPT_TAG + 1);
  SetLength(FOut, CRYPT_CHUNK);
end;

destructor TAeadDecryptStage.Destroy;
begin
  FreeKey(FKey, FGcm);
  if Length(FOut) > 0 then FillChar(FOut[0], Length(FOut), 0);
  inherited Destroy;
end;

procedure TAeadDecryptStage.NextChunk;
var
  n, Len: SizeInt;
  Last: Boolean;
begin
  // hasta un trozo entero y un byte más: si el byte está, este trozo no es el último
  while not FSrcEof and (FInLen < Length(FIn)) do
  begin
    n := Source.Read(@FIn[FInLen], Length(FIn) - FInLen);
    if n <= 0 then FSrcEof := True else Inc(FInLen, n);
  end;
  Last := FInLen < Length(FIn);
  if Last then Len := FInLen else Len := CRYPT_CHUNK + CRYPT_TAG;
  if Len < CRYPT_TAG then Corrupt('encryption: authentication failed (truncated data)');
  Dec(Len, CRYPT_TAG);
  if not OpenChunk(FPar, FKey, FGcm, FIndex, Last, @FIn[0], Len, @FOut[0]) then
    Corrupt('encryption: authentication failed (modified or damaged data)');
  Inc(FIndex);
  FOutPos := 0;
  FOutLen := Len;
  if Last then
  begin
    FDone := True;
    FInLen := 0;
  end
  else
  begin
    FIn[0] := FIn[CRYPT_CHUNK + CRYPT_TAG];
    FInLen := 1;
  end;
end;

function TAeadDecryptStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  Result := 0;
  while Result = 0 do
  begin
    if FOutPos < FOutLen then
    begin
      n := FOutLen - FOutPos;
      if n > Count then n := Count;
      Move(FOut[FOutPos], Buf^, n);
      Inc(FOutPos, n);
      Exit(n);
    end;
    if FDone or (Count <= 0) then Exit;
    NextChunk;
  end;
end;

initialization
  InitCriticalSection(GLock);
finalization
  if Length(GKeys) > 0 then FillChar(GKeys[0], Length(GKeys) * SizeOf(TKeyEntry), 0);
  DoneCriticalSection(GLock);
end.
