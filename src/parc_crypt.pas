{ parc_crypt — descifrado de FreeArc 0.67 (Encryption.hs + C_Encryption.cpp).

  El cifrado es una ETAPA MÁS de la cadena de métodos, unida con '+'. Formato:

      <cifrado>-<bits>/<modo>[:f]:n<iter>:r<rondas>[:k<clave>][:i<iv>][:s<salt>][:c<check>]

  Derivación de clave (Encryption.hs::deriveKey):

      dk        = PBKDF2-HMAC-SHA512(password, salt, iteraciones, keySize+2)
      clave     = dk[0 .. keySize-1]
      checkCode = dk[keySize .. keySize+1]

  El descifrador comprueba el check-code para saber si la contraseña es la
  correcta (no hay otra verificación) y arma el "método con clave" sustituyendo
  salt/check-code por :k<clave>, que es lo que usan las etapas de descifrado.

  Aritmética de 32 bits con wrapping en todo lo que toca a los cifrados: el
  encoder es de 32 bits. }
unit parc_crypt;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream, parc_outstream;

type
  TCryptParams = record
    Cipher: string;            // aes | blowfish | serpent | twofish
    KeySize: Integer;          // bytes
    IVSize: Integer;           // bytes (= tamaño de bloque)
    Mode: string;              // ctr | cfb
    Fixed: Boolean;            // :f  (contraseña Unicode -> UTF-8)
    NumIterations: Integer;    // :n
    Rounds: Integer;           // :r
    KeyHex: string;            // :k   (sólo en cabeceras ya descifradas)
    IVHex: string;             // :i
    SaltHex: string;           // :s
    CheckHex: string;          // :c
  end;

  { Etapa de descifrado: lee del fuente el texto cifrado y entrega el claro.
    El estado del modo (contador/pad) persiste entre llamadas a Read, que es lo
    que hace docrypt con los bloques de LARGE_BUFFER_SIZE. }
  TDecryptStage = class(TInStage)
  private
    FPar: TCryptParams;
    FKey: array of Byte;
    FCounter: array[0..15] of Byte;   { contador CTR }
    FPad: array[0..15] of Byte;       { keystream (CTR) o feedback cifrado (CFB) }
    FIV: array[0..15] of Byte;        { keystream actual (CFB) }
    FPadLen: Integer;
    FBlockSize: Integer;
    FRk: array[0..63] of LongWord;    { AES }
    function  BlockEncrypt(const Src: array of Byte; var Dst: array of Byte): Boolean;
    procedure ModeStart;
    procedure ModeDecrypt(Buf: PByte; Len: SizeInt);
  public
    constructor Create(ASource: TInStage; const APar: TCryptParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Parámetros de la etapa de cifrado, como parse_ENCRYPTION. }
function ParseCryptParams(const Params: TStringArray): TCryptParams;

function CipherMaxKeySize(const Name: string): Integer;
function CipherBlockSize(const Name: string): Integer;
function IsCipherName(const Name: string): Boolean;

procedure Pbkdf2HmacSha512(const Pwd: PByte; PwdLen: SizeInt;
                           const Salt: PByte; SaltLen: SizeInt;
                           Iterations: Integer; Out_: PByte; OutLen: SizeInt);

{ Deriva clave+checkCode del password y comprueba el check-code.  False si la
  contraseña es incorrecta. }
function DeriveKeyAndCheck(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt;
                           Key: PByte): Boolean;


{ --- escritura del cifrado (espejo de generateEncryption de Encryption.hs) --- }

{ Bytes al azar del RNG criptográfico del sistema. Linux: /dev/urandom (getrandom
  necesita syscall o libc nueva, así que urandom es lo portable). Windows:
  RtlGenRandom (SystemFunction036), que existe desde XP y anda en Win7. }
function OsRandom(Buf: PByte; Len: SizeInt): Boolean;

{ Genera el cifrado para ESCRIBIR, como generateEncryption: salt de KeySize bytes e
  IV del tamaño de bloque, del RNG; PBKDF2-HMAC-SHA512 con NumIterations partiendo en
  clave + check-code de 2 bytes; y los dos strings, el del ARCHIVO (con :s y :c, SIN
  :k) y el del encoder (CON :k).
  OJO, que es lo que hace que los archivos se puedan abrir: el hex se escribe NORMAL
  (int2char), pero FreeArc lo DECODIFICA con buggy_decode16. La clave que realmente
  usa el cifrado es buggy_decode16(encode16(clave_de_PBKDF2)), no la de PBKDF2. Si el
  encoder cifrara con la de PBKDF2, arc.exe descifraría con la efectiva y saldría
  basura; el check-code igual coincidiría, así que el síntoma sería CRC/descompresión
  fallida y NO "contraseña incorrecta". Por eso el stage recibe el string CON :k y
  saca la clave efectiva decodificándolo con la misma función buggy del decoder. }
function MakeEncryption(const Cipher: string; const Password: RawByteString;
                        out ArchiveMethod, EncoderMethod: string): Boolean;

  { Etapa de CIFRADO (espejo de TDecryptStage), para escribir archivos cifrados.
    Recibe el string del método CON :k, como el decoder, y saca la clave EFECTIVA
    decodificando ese :k con el mismo conversor buggy: PBKDF2 no se vuelve a hacer acá
    (va una sola vez, en MakeEncryption). El estado del modo persiste entre Write, así
    que un Write de 1 byte y uno de 1 MB dan exactamente lo mismo. En CTR es simétrico;
    en CFB la realimentación es el TEXTO CIFRADO, o sea que sale de la salida, no de la
    entrada como en el decoder. }
type
  TEncryptStage = class(TOutStage)
  private
    FPar: TCryptParams;
    FKey: array of Byte;
    FCounter, FPad, FIV, FEmit: array[0..15] of Byte;
    FPadLen, FBlockSize: Integer;
    FRk: array[0..63] of LongWord;
    FOut: array of Byte;      // el cifrado va acá: el buffer del llamador no se toca
    function  BlockEncrypt(const Src: array of Byte; var Dst: array of Byte): Boolean;
    procedure ModeStart;
    procedure ModeEncrypt(Src, Dst: PByte; Len: SizeInt);
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
  public
    constructor Create(ATarget: TOutStage; const APar: TCryptParams);
  end;

{ Cifra un buffer suelto con el esquema ya derivado. Es para -hp: el directorio y el
  footer, que van cifrados aparte de los datos. }
function EncryptBuffer(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt;
                       Src: PByte; Len: SizeInt; Dest: PByte): Boolean;

{ DEBUG temporal: un bloque de cada cifrado, para verificar contra las fuentes. }
function AesEcb(const KeyHex, BlockHex: string): string;
function BlowfishTestVec(const KeyHex, PtHex: string): string;
function SerpentTestVec(const KeyHex, PtHex: string): string;
function TwofishTestVec(const KeyHex, PtHex: string): string;
function DerivedCheckHex(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt): string;

{ Arma el método con clave (lo que hace generateDecryption con el :k). }
function KeyedMethod(const Par: TCryptParams; const Key: PByte): string;

{ SHA-512 de un buffer (expuesto para tests y utilidades). }
function Sha512Data(Data: PByte; Len: SizeInt): TBytes;

{ Descifra un buffer en memoria (para bloques pequeños, p.ej. cabeceras). }
function DecryptMem(const Par: TCryptParams; const Key: PByte;
                    Src: PByte; Len: SizeInt; Dst: PByte): Boolean;

implementation

uses
  parc_bytes, parc_methods;

{ ---------------------------------------------------------------- SHA-512 }

type
  TSha512 = record
    H: array[0..7] of QWord;
    Buf: array[0..127] of Byte;
    CurLen: SizeInt;
    Len: QWord;
  end;

const
  SHA512_K: array[0..79] of QWord = (
    QWord($428a2f98d728ae22), QWord($7137449123ef65cd), QWord($b5c0fbcfec4d3b2f), QWord($e9b5dba58189dbbc),
    QWord($3956c25bf348b538), QWord($59f111f1b605d019), QWord($923f82a4af194f9b), QWord($ab1c5ed5da6d8118),
    QWord($d807aa98a3030242), QWord($12835b0145706fbe), QWord($243185be4ee4b28c), QWord($550c7dc3d5ffb4e2),
    QWord($72be5d74f27b896f), QWord($80deb1fe3b1696b1), QWord($9bdc06a725c71235), QWord($c19bf174cf692694),
    QWord($e49b69c19ef14ad2), QWord($efbe4786384f25e3), QWord($0fc19dc68b8cd5b5), QWord($240ca1cc77ac9c65),
    QWord($2de92c6f592b0275), QWord($4a7484aa6ea6e483), QWord($5cb0a9dcbd41fbd4), QWord($76f988da831153b5),
    QWord($983e5152ee66dfab), QWord($a831c66d2db43210), QWord($b00327c898fb213f), QWord($bf597fc7beef0ee4),
    QWord($c6e00bf33da88fc2), QWord($d5a79147930aa725), QWord($06ca6351e003826f), QWord($142929670a0e6e70),
    QWord($27b70a8546d22ffc), QWord($2e1b21385c26c926), QWord($4d2c6dfc5ac42aed), QWord($53380d139d95b3df),
    QWord($650a73548baf63de), QWord($766a0abb3c77b2a8), QWord($81c2c92e47edaee6), QWord($92722c851482353b),
    QWord($a2bfe8a14cf10364), QWord($a81a664bbc423001), QWord($c24b8b70d0f89791), QWord($c76c51a30654be30),
    QWord($d192e819d6ef5218), QWord($d69906245565a910), QWord($f40e35855771202a), QWord($106aa07032bbd1b8),
    QWord($19a4c116b8d2d0c8), QWord($1e376c085141ab53), QWord($2748774cdf8eeb99), QWord($34b0bcb5e19b48a8),
    QWord($391c0cb3c5c95a63), QWord($4ed8aa4ae3418acb), QWord($5b9cca4f7763e373), QWord($682e6ff3d6b2b8a3),
    QWord($748f82ee5defb2fc), QWord($78a5636f43172f60), QWord($84c87814a1f0ab72), QWord($8cc702081a6439ec),
    QWord($90befffa23631e28), QWord($a4506cebde82bde9), QWord($bef9a3f7b2c67915), QWord($c67178f2e372532b),
    QWord($ca273eceea26619c), QWord($d186b8c721c0c207), QWord($eada7dd6cde0eb1e), QWord($f57d4f7fee6ed178),
    QWord($06f067aa72176fba), QWord($0a637dc5a2c898a6), QWord($113f9804bef90dae), QWord($1b710b35131c471b),
    QWord($28db77f523047d84), QWord($32caab7b40c72493), QWord($3c9ebe0a15c9bebc), QWord($431d67c49c100d4c),
    QWord($4cc5d4becb3e42b6), QWord($597f299cfc657e2a), QWord($5fcb6fab3ad6faec), QWord($6c44198c4a475817));

function Ror64(x: QWord; n: Integer): QWord; inline;
begin
  Result := RorQWord(x, n);      { intrínseco de FPC }
end;

procedure Sha512Compress(var S: TSha512);
var
  W: array[0..79] of QWord;
  a, b, c, d, e, f, g, h, t0, t1: QWord;
  i: Integer;
begin
  { ojo: LOAD64H es BIG-endian: el primer byte es el más significativo }
  for i := 0 to 15 do
    W[i] := (QWord(S.Buf[i * 8]) shl 56) or (QWord(S.Buf[i * 8 + 1]) shl 48) or
            (QWord(S.Buf[i * 8 + 2]) shl 40) or (QWord(S.Buf[i * 8 + 3]) shl 32) or
            (QWord(S.Buf[i * 8 + 4]) shl 24) or (QWord(S.Buf[i * 8 + 5]) shl 16) or
            (QWord(S.Buf[i * 8 + 6]) shl 8) or QWord(S.Buf[i * 8 + 7]);
  for i := 16 to 79 do
    W[i] := (Ror64(W[i-2],19) xor Ror64(W[i-2],61) xor (W[i-2] shr 6)) + W[i-7] +
            (Ror64(W[i-15],1) xor Ror64(W[i-15],8) xor (W[i-15] shr 7)) + W[i-16];
  a := S.H[0]; b := S.H[1]; c := S.H[2]; d := S.H[3];
  e := S.H[4]; f := S.H[5]; g := S.H[6]; h := S.H[7];
  for i := 0 to 79 do
  begin
    t0 := h + (Ror64(e,14) xor Ror64(e,18) xor Ror64(e,41)) +
          ((e and f) xor ((not e) and g)) + SHA512_K[i] + W[i];
    t1 := (Ror64(a,28) xor Ror64(a,34) xor Ror64(a,39)) + ((a and b) xor (a and c) xor (b and c));
    h := g; g := f; f := e; e := d + t0;
    d := c; c := b; b := a; a := t0 + t1;
  end;
  Inc(S.H[0], a); Inc(S.H[1], b); Inc(S.H[2], c); Inc(S.H[3], d);
  Inc(S.H[4], e); Inc(S.H[5], f); Inc(S.H[6], g); Inc(S.H[7], h);
end;

procedure Sha512Init(out S: TSha512);
begin
  S.CurLen := 0; S.Len := 0;
  S.H[0] := QWord($6a09e667f3bcc908); S.H[1] := QWord($bb67ae8584caa73b);
  S.H[2] := QWord($3c6ef372fe94f82b); S.H[3] := QWord($a54ff53a5f1d36f1);
  S.H[4] := QWord($510e527fade682d1); S.H[5] := QWord($9b05688c2b3e6c1f);
  S.H[6] := QWord($1f83d9abfb41bd6b); S.H[7] := QWord($5be0cd19137e2179);
end;

procedure Sha512Update(var S: TSha512; Data: PByte; Len: SizeInt);
var
  n: SizeInt;
begin
  Inc(S.Len, QWord(Len) * 8);
  while Len > 0 do
  begin
    n := 128 - S.CurLen;
    if n > Len then n := Len;
    if n > 0 then Move(Data^, S.Buf[S.CurLen], n);
    Inc(S.CurLen, n);
    Inc(Data, n);
    Dec(Len, n);
    if S.CurLen = 128 then
    begin
      Sha512Compress(S);
      S.CurLen := 0;
    end;
  end;
end;

procedure Sha512Final(var S: TSha512; out Digest: array of Byte);
var
  i, j: Integer;
begin
  { la longitud ya se fue acumulando en Len (en bits) }
  S.Buf[S.CurLen] := $80;
  Inc(S.CurLen);
  if S.CurLen > 112 then
  begin
    while S.CurLen < 128 do begin S.Buf[S.CurLen] := 0; Inc(S.CurLen); end;
    Sha512Compress(S);
    S.CurLen := 0;
  end;
  while S.CurLen < 120 do begin S.Buf[S.CurLen] := 0; Inc(S.CurLen); end;
  for i := 0 to 7 do
    S.Buf[120 + i] := Byte((S.Len shr (56 - i * 8)) and $FF);
  Sha512Compress(S);
  { ojo: el digest va BIG-endian (STORE64H), no little-endian }
  for i := 0 to 7 do
    for j := 0 to 7 do
      Digest[i * 8 + j] := Byte((S.H[i] shr (56 - j * 8)) and $FF);
end;

{ ----------------------------------------------------- HMAC-SHA512 / PBKDF2 }

procedure HmacSha512(Key: PByte; KeyLen: SizeInt; Data: PByte; DataLen: SizeInt;
                     out Mac: array of Byte);
var
  S: TSha512;
  k: array[0..127] of Byte;
  pad: array[0..127] of Byte;
  inner: array[0..63] of Byte;
  i: Integer;
begin
  FillChar(k, SizeOf(k), 0);
  if KeyLen > 128 then
  begin
    Sha512Init(S); Sha512Update(S, Key, KeyLen);
    Sha512Final(S, k);
  end
  else if KeyLen > 0 then
    Move(Key^, k[0], KeyLen);
  for i := 0 to 127 do pad[i] := k[i] xor $36;
  Sha512Init(S);
  Sha512Update(S, @pad[0], 128);
  Sha512Update(S, Data, DataLen);
  Sha512Final(S, inner);
  for i := 0 to 127 do pad[i] := k[i] xor $5C;
  Sha512Init(S);
  Sha512Update(S, @pad[0], 128);
  Sha512Update(S, @inner[0], 64);
  Sha512Final(S, Mac);
end;

procedure Pbkdf2HmacSha512(const Pwd: PByte; PwdLen: SizeInt;
                           const Salt: PByte; SaltLen: SizeInt;
                           Iterations: Integer; Out_: PByte; OutLen: SizeInt);
var
  blkno: LongWord;
  u, t: array[0..63] of Byte;
  it: Integer;
  i, left, take: SizeInt;
  saltbuf: array of Byte;
  dst: PByte;
begin
  if Iterations < 1 then Iterations := 1;
  if OutLen <= 0 then Exit;
  SetLength(saltbuf, SaltLen + 4);
  if SaltLen > 0 then Move(Salt^, saltbuf[0], SaltLen);
  dst := Out_;
  left := OutLen;
  blkno := 1;
  while left > 0 do
  begin
    saltbuf[SaltLen]     := Byte((blkno shr 24) and $FF);
    saltbuf[SaltLen + 1] := Byte((blkno shr 16) and $FF);
    saltbuf[SaltLen + 2] := Byte((blkno shr 8) and $FF);
    saltbuf[SaltLen + 3] := Byte(blkno and $FF);
    Inc(blkno);
    HmacSha512(Pwd, PwdLen, @saltbuf[0], SaltLen + 4, u);
    Move(u[0], t[0], 64);
    for it := 1 to Iterations - 1 do
    begin
      HmacSha512(Pwd, PwdLen, @u[0], 64, u);
      for i := 0 to 63 do t[i] := t[i] xor u[i];
    end;
    take := 64;
    if take > left then take := left;
    Move(t[0], dst^, take);
    Inc(dst, take);
    Dec(left, take);
  end;
end;

function Sha512Data(Data: PByte; Len: SizeInt): TBytes;
var
  S: TSha512;
  d: array[0..63] of Byte;
begin
  Sha512Init(S);
  Sha512Update(S, Data, Len);
  Sha512Final(S, d);
  SetLength(Result, 64);
  Move(d[0], Result[0], 64);
end;

{ ------------------------------------------------------------------- AES }

const
  AES_SBOX: array[0..255] of Byte = (
   $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
   $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
   $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
   $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
   $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
   $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
   $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
   $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
   $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
   $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
   $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
   $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
   $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
   $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
   $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
   $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);

  AES_RCON: array[0..10] of Byte =
    ($00,$01,$02,$04,$08,$10,$20,$40,$80,$1b,$36);

var
  FSERP: array[0..139] of LongWord;
  FK: array[0..17] of LongWord;
  FS: array[0..3, 0..255] of LongWord;

var
  AES_T: array[0..1023] of LongWord;
  AES_READY: Boolean = False;

function XTime(x: LongWord): LongWord; inline;
begin
  Result := ((x shl 1) xor (LongWord(Ord((x and $80) <> 0)) * $1B)) and $FF;
end;

procedure AesInit;
var
  i: LongWord;
  a1, a2, a3: LongWord;
begin
  if AES_READY then Exit;
  for i := 0 to 255 do
  begin
    a1 := AES_SBOX[i];
    a2 := XTime(a1);
    a3 := a2 xor a1;
    AES_T[i]         := a2 or (a1 shl 8) or (a1 shl 16) or (a3 shl 24);
    AES_T[$100 + i]  := a3 or (a2 shl 8) or (a1 shl 16) or (a1 shl 24);
    AES_T[$200 + i]  := a1 or (a3 shl 8) or (a2 shl 16) or (a1 shl 24);
    AES_T[$300 + i]  := a1 or (a1 shl 8) or (a3 shl 16) or (a2 shl 24);
  end;
  AES_READY := True;
end;

{ Aes_SetKey_Enc: w[0] = nº de dobles rondas; las claves de ronda van desde w[4] }
procedure AesSetKeyEnc(w: PLongWord; Key: PByte; KeySize: Integer);
var
  i, wSize, ks: Integer;
  t: LongWord;
begin
  wSize := KeySize + 28;
  ks := KeySize div 4;
  w[0] := LongWord(ks div 2) + 3;
  Inc(w, 4);
  for i := 0 to ks - 1 do
    w[i] := LongWord(Key[i * 4]) or (LongWord(Key[i * 4 + 1]) shl 8) or
            (LongWord(Key[i * 4 + 2]) shl 16) or (LongWord(Key[i * 4 + 3]) shl 24);
  for i := ks to wSize - 1 do
  begin
    t := w[i - 1];
    if (i mod ks) = 0 then
      t := LongWord(AES_SBOX[(t shr 8) and $FF] xor AES_RCON[i div ks]) or
           (LongWord(AES_SBOX[(t shr 16) and $FF]) shl 8) or
           (LongWord(AES_SBOX[(t shr 24) and $FF]) shl 16) or
           (LongWord(AES_SBOX[t and $FF]) shl 24)
    else if (ks > 6) and ((i mod ks) = 4) then
      t := LongWord(AES_SBOX[t and $FF]) or (LongWord(AES_SBOX[(t shr 8) and $FF]) shl 8) or
           (LongWord(AES_SBOX[(t shr 16) and $FF]) shl 16) or (LongWord(AES_SBOX[(t shr 24) and $FF]) shl 24);
    w[i] := w[i - ks] xor t;
  end;
end;

{ HT4(m,i,s,p) del Aes_Encode de 7-Zip, expandido:
    m[i] = T[0<<8 | gb0(s[(i+0)&3])] ^ T[1<<8 | gb1(s[(i+1)&3])]
         ^ T[2<<8 | gb2(s[(i+2)&3])] ^ T[3<<8 | gb3(s[(i+3)&3])] ^ w[p+i]  }
procedure Ht4(var m: array of LongWord; i: Integer;
              const s: array of LongWord; w: PLongWord; p: Integer); inline;
begin
  m[i] := AES_T[LongWord(Byte(s[(i + 0) and 3]))] xor
          AES_T[$100 + LongWord(Byte(s[(i + 1) and 3] shr 8))] xor
          AES_T[$200 + LongWord(Byte(s[(i + 2) and 3] shr 16))] xor
          AES_T[$300 + LongWord(Byte(s[(i + 3) and 3] shr 24))] xor w[p + i];
end;

procedure Ht16(var m: array of LongWord; const s: array of LongWord; w: PLongWord; p: Integer); inline;
begin
  Ht4(m, 2, s, w, p);
  Ht4(m, 0, s, w, p);
  Ht4(m, 3, s, w, p);
  Ht4(m, 1, s, w, p);
end;

procedure Ft4(dest: PLongWord; i: Integer; const m: array of LongWord;
              w: PLongWord); inline;
begin
  { ojo: FT usa (i + x); el (i - x) es el del DESCIFRADO (FD) }
  dest[i] := LongWord(AES_SBOX[Byte(m[(i + 0) and 3])]) or
             (LongWord(AES_SBOX[Byte(m[(i + 1) and 3] shr 8)]) shl 8) or
             (LongWord(AES_SBOX[Byte(m[(i + 2) and 3] shr 16)]) shl 16) or
             (LongWord(AES_SBOX[Byte(m[(i + 3) and 3] shr 24)]) shl 24) xor w[i];
end;

procedure AesEncode(w: PLongWord; dest, src: PLongWord);
var
  s, m: array[0..3] of LongWord;
  numRounds2: LongWord;
begin
  numRounds2 := w[0];
  Inc(w, 4);
  s[0] := src[0] xor w[0];
  s[1] := src[1] xor w[1];
  s[2] := src[2] xor w[2];
  s[3] := src[3] xor w[3];
  Inc(w, 4);
  while True do
  begin
    Ht16(m, s, w, 0);
    Dec(numRounds2);
    if numRounds2 = 0 then Break;
    Ht16(s, m, w, 4);
    Inc(w, 8);
  end;
  Inc(w, 4);
  Ft4(dest, 0, m, w);
  Ft4(dest, 1, m, w);
  Ft4(dest, 2, m, w);
  Ft4(dest, 3, m, w);
end;

{ -------------------------------------------------------- Blowfish }

const
BF_ORIG_P: array[0..17] of LongWord = (
    $243F6A88, $85A308D3, $13198A2E, $03707344, $A4093822, $299F31D0,
    $082EFA98, $EC4E6C89, $452821E6, $38D01377, $BE5466CF, $34E90C6C,
    $C0AC29B7, $C97C50DD, $3F84D5B5, $B5470917, $9216D5D9, $8979FB1B);

  BF_ORIG_S: array[0..3, 0..255] of LongWord = (
   (
     $D1310BA6, $98DFB5AC, $2FFD72DB, $D01ADFB7, $B8E1AFED, $6A267E96,
     $BA7C9045, $F12C7F99, $24A19947, $B3916CF7, $0801F2E2, $858EFC16,
     $636920D8, $71574E69, $A458FEA3, $F4933D7E, $0D95748F, $728EB658,
     $718BCD58, $82154AEE, $7B54A41D, $C25A59B5, $9C30D539, $2AF26013,
     $C5D1B023, $286085F0, $CA417918, $B8DB38EF, $8E79DCB0, $603A180E,
     $6C9E0E8B, $B01E8A3E, $D71577C1, $BD314B27, $78AF2FDA, $55605C60,
     $E65525F3, $AA55AB94, $57489862, $63E81440, $55CA396A, $2AAB10B6,
     $B4CC5C34, $1141E8CE, $A15486AF, $7C72E993, $B3EE1411, $636FBC2A,
     $2BA9C55D, $741831F6, $CE5C3E16, $9B87931E, $AFD6BA33, $6C24CF5C,
     $7A325381, $28958677, $3B8F4898, $6B4BB9AF, $C4BFE81B, $66282193,
     $61D809CC, $FB21A991, $487CAC60, $5DEC8032, $EF845D5D, $E98575B1,
     $DC262302, $EB651B88, $23893E81, $D396ACC5, $0F6D6FF3, $83F44239,
     $2E0B4482, $A4842004, $69C8F04A, $9E1F9B5E, $21C66842, $F6E96C9A,
     $670C9C61, $ABD388F0, $6A51A0D2, $D8542F68, $960FA728, $AB5133A3,
     $6EEF0B6C, $137A3BE4, $BA3BF050, $7EFB2A98, $A1F1651D, $39AF0176,
     $66CA593E, $82430E88, $8CEE8619, $456F9FB4, $7D84A5C3, $3B8B5EBE,
     $E06F75D8, $85C12073, $401A449F, $56C16AA6, $4ED3AA62, $363F7706,
     $1BFEDF72, $429B023D, $37D0D724, $D00A1248, $DB0FEAD3, $49F1C09B,
     $075372C9, $80991B7B, $25D479D8, $F6E8DEF7, $E3FE501A, $B6794C3B,
     $976CE0BD, $04C006BA, $C1A94FB6, $409F60C4, $5E5C9EC2, $196A2463,
     $68FB6FAF, $3E6C53B5, $1339B2EB, $3B52EC6F, $6DFC511F, $9B30952C,
     $CC814544, $AF5EBD09, $BEE3D004, $DE334AFD, $660F2807, $192E4BB3,
     $C0CBA857, $45C8740F, $D20B5F39, $B9D3FBDB, $5579C0BD, $1A60320A,
     $D6A100C6, $402C7279, $679F25FE, $FB1FA3CC, $8EA5E9F8, $DB3222F8,
     $3C7516DF, $FD616B15, $2F501EC8, $AD0552AB, $323DB5FA, $FD238760,
     $53317B48, $3E00DF82, $9E5C57BB, $CA6F8CA0, $1A87562E, $DF1769DB,
     $D542A8F6, $287EFFC3, $AC6732C6, $8C4F5573, $695B27B0, $BBCA58C8,
     $E1FFA35D, $B8F011A0, $10FA3D98, $FD2183B8, $4AFCB56C, $2DD1D35B,
     $9A53E479, $B6F84565, $D28E49BC, $4BFB9790, $E1DDF2DA, $A4CB7E33,
     $62FB1341, $CEE4C6E8, $EF20CADA, $36774C01, $D07E9EFE, $2BF11FB4,
     $95DBDA4D, $AE909198, $EAAD8E71, $6B93D5A0, $D08ED1D0, $AFC725E0,
     $8E3C5B2F, $8E7594B7, $8FF6E2FB, $F2122B64, $8888B812, $900DF01C,
     $4FAD5EA0, $688FC31C, $D1CFF191, $B3A8C1AD, $2F2F2218, $BE0E1777,
     $EA752DFE, $8B021FA1, $E5A0CC0F, $B56F74E8, $18ACF3D6, $CE89E299,
     $B4A84FE0, $FD13E0B7, $7CC43B81, $D2ADA8D9, $165FA266, $80957705,
     $93CC7314, $211A1477, $E6AD2065, $77B5FA86, $C75442F5, $FB9D35CF,
     $EBCDAF0C, $7B3E89A0, $D6411BD3, $AE1E7E49, $00250E2D, $2071B35E,
     $226800BB, $57B8E0AF, $2464369B, $F009B91E, $5563911D, $59DFA6AA,
     $78C14389, $D95A537F, $207D5BA2, $02E5B9C5, $83260376, $6295CFA9,
     $11C81968, $4E734A41, $B3472DCA, $7B14A94A, $1B510052, $9A532915,
     $D60F573F, $BC9BC6E4, $2B60A476, $81E67400, $08BA6FB5, $571BE91F,
     $F296EC6B, $2A0DD915, $B6636521, $E7B9F9B6, $FF34052E, $C5855664,
     $53B02D5D, $A99F8FA1, $08BA4799, $6E85076A),
   (
     $4B7A70E9, $B5B32944, $DB75092E, $C4192623, $AD6EA6B0, $49A7DF7D,
     $9CEE60B8, $8FEDB266, $ECAA8C71, $699A17FF, $5664526C, $C2B19EE1,
     $193602A5, $75094C29, $A0591340, $E4183A3E, $3F54989A, $5B429D65,
     $6B8FE4D6, $99F73FD6, $A1D29C07, $EFE830F5, $4D2D38E6, $F0255DC1,
     $4CDD2086, $8470EB26, $6382E9C6, $021ECC5E, $09686B3F, $3EBAEFC9,
     $3C971814, $6B6A70A1, $687F3584, $52A0E286, $B79C5305, $AA500737,
     $3E07841C, $7FDEAE5C, $8E7D44EC, $5716F2B8, $B03ADA37, $F0500C0D,
     $F01C1F04, $0200B3FF, $AE0CF51A, $3CB574B2, $25837A58, $DC0921BD,
     $D19113F9, $7CA92FF6, $94324773, $22F54701, $3AE5E581, $37C2DADC,
     $C8B57634, $9AF3DDA7, $A9446146, $0FD0030E, $ECC8C73E, $A4751E41,
     $E238CD99, $3BEA0E2F, $3280BBA1, $183EB331, $4E548B38, $4F6DB908,
     $6F420D03, $F60A04BF, $2CB81290, $24977C79, $5679B072, $BCAF89AF,
     $DE9A771F, $D9930810, $B38BAE12, $DCCF3F2E, $5512721F, $2E6B7124,
     $501ADDE6, $9F84CD87, $7A584718, $7408DA17, $BC9F9ABC, $E94B7D8C,
     $EC7AEC3A, $DB851DFA, $63094366, $C464C3D2, $EF1C1847, $3215D908,
     $DD433B37, $24C2BA16, $12A14D43, $2A65C451, $50940002, $133AE4DD,
     $71DFF89E, $10314E55, $81AC77D6, $5F11199B, $043556F1, $D7A3C76B,
     $3C11183B, $5924A509, $F28FE6ED, $97F1FBFA, $9EBABF2C, $1E153C6E,
     $86E34570, $EAE96FB1, $860E5E0A, $5A3E2AB3, $771FE71C, $4E3D06FA,
     $2965DCB9, $99E71D0F, $803E89D6, $5266C825, $2E4CC978, $9C10B36A,
     $C6150EBA, $94E2EA78, $A5FC3C53, $1E0A2DF4, $F2F74EA7, $361D2B3D,
     $1939260F, $19C27960, $5223A708, $F71312B6, $EBADFE6E, $EAC31F66,
     $E3BC4595, $A67BC883, $B17F37D1, $018CFF28, $C332DDEF, $BE6C5AA5,
     $65582185, $68AB9802, $EECEA50F, $DB2F953B, $2AEF7DAD, $5B6E2F84,
     $1521B628, $29076170, $ECDD4775, $619F1510, $13CCA830, $EB61BD96,
     $0334FE1E, $AA0363CF, $B5735C90, $4C70A239, $D59E9E0B, $CBAADE14,
     $EECC86BC, $60622CA7, $9CAB5CAB, $B2F3846E, $648B1EAF, $19BDF0CA,
     $A02369B9, $655ABB50, $40685A32, $3C2AB4B3, $319EE9D5, $C021B8F7,
     $9B540B19, $875FA099, $95F7997E, $623D7DA8, $F837889A, $97E32D77,
     $11ED935F, $16681281, $0E358829, $C7E61FD6, $96DEDFA1, $7858BA99,
     $57F584A5, $1B227263, $9B83C3FF, $1AC24696, $CDB30AEB, $532E3054,
     $8FD948E4, $6DBC3128, $58EBF2EF, $34C6FFEA, $FE28ED61, $EE7C3C73,
     $5D4A14D9, $E864B7E3, $42105D14, $203E13E0, $45EEE2B6, $A3AAABEA,
     $DB6C4F15, $FACB4FD0, $C742F442, $EF6ABBB5, $654F3B1D, $41CD2105,
     $D81E799E, $86854DC7, $E44B476A, $3D816250, $CF62A1F2, $5B8D2646,
     $FC8883A0, $C1C7B6A3, $7F1524C3, $69CB7492, $47848A0B, $5692B285,
     $095BBF00, $AD19489D, $1462B174, $23820E00, $58428D2A, $0C55F5EA,
     $1DADF43E, $233F7061, $3372F092, $8D937E41, $D65FECF1, $6C223BDB,
     $7CDE3759, $CBEE7460, $4085F2A7, $CE77326E, $A6078084, $19F8509E,
     $E8EFD855, $61D99735, $A969A7AA, $C50C06C2, $5A04ABFC, $800BCADC,
     $9E447A2E, $C3453484, $FDD56705, $0E1E9EC9, $DB73DBD3, $105588CD,
     $675FDA79, $E3674340, $C5C43465, $713E38D8, $3D28F89E, $F16DFF20,
     $153E21E7, $8FB03D4A, $E6E39F2B, $DB83ADF7),
   (
     $E93D5A68, $948140F7, $F64C261C, $94692934, $411520F7, $7602D4F7,
     $BCF46B2E, $D4A20068, $D4082471, $3320F46A, $43B7D4B7, $500061AF,
     $1E39F62E, $97244546, $14214F74, $BF8B8840, $4D95FC1D, $96B591AF,
     $70F4DDD3, $66A02F45, $BFBC09EC, $03BD9785, $7FAC6DD0, $31CB8504,
     $96EB27B3, $55FD3941, $DA2547E6, $ABCA0A9A, $28507825, $530429F4,
     $0A2C86DA, $E9B66DFB, $68DC1462, $D7486900, $680EC0A4, $27A18DEE,
     $4F3FFEA2, $E887AD8C, $B58CE006, $7AF4D6B6, $AACE1E7C, $D3375FEC,
     $CE78A399, $406B2A42, $20FE9E35, $D9F385B9, $EE39D7AB, $3B124E8B,
     $1DC9FAF7, $4B6D1856, $26A36631, $EAE397B2, $3A6EFA74, $DD5B4332,
     $6841E7F7, $CA7820FB, $FB0AF54E, $D8FEB397, $454056AC, $BA489527,
     $55533A3A, $20838D87, $FE6BA9B7, $D096954B, $55A867BC, $A1159A58,
     $CCA92963, $99E1DB33, $A62A4A56, $3F3125F9, $5EF47E1C, $9029317C,
     $FDF8E802, $04272F70, $80BB155C, $05282CE3, $95C11548, $E4C66D22,
     $48C1133F, $C70F86DC, $07F9C9EE, $41041F0F, $404779A4, $5D886E17,
     $325F51EB, $D59BC0D1, $F2BCC18F, $41113564, $257B7834, $602A9C60,
     $DFF8E8A3, $1F636C1B, $0E12B4C2, $02E1329E, $AF664FD1, $CAD18115,
     $6B2395E0, $333E92E1, $3B240B62, $EEBEB922, $85B2A20E, $E6BA0D99,
     $DE720C8C, $2DA2F728, $D0127845, $95B794FD, $647D0862, $E7CCF5F0,
     $5449A36F, $877D48FA, $C39DFD27, $F33E8D1E, $0A476341, $992EFF74,
     $3A6F6EAB, $F4F8FD37, $A812DC60, $A1EBDDF8, $991BE14C, $DB6E6B0D,
     $C67B5510, $6D672C37, $2765D43B, $DCD0E804, $F1290DC7, $CC00FFA3,
     $B5390F92, $690FED0B, $667B9FFB, $CEDB7D9C, $A091CF0B, $D9155EA3,
     $BB132F88, $515BAD24, $7B9479BF, $763BD6EB, $37392EB3, $CC115979,
     $8026E297, $F42E312D, $6842ADA7, $C66A2B3B, $12754CCC, $782EF11C,
     $6A124237, $B79251E7, $06A1BBE6, $4BFB6350, $1A6B1018, $11CAEDFA,
     $3D25BDD8, $E2E1C3C9, $44421659, $0A121386, $D90CEC6E, $D5ABEA2A,
     $64AF674E, $DA86A85F, $BEBFE988, $64E4C3FE, $9DBC8057, $F0F7C086,
     $60787BF8, $6003604D, $D1FD8346, $F6381FB0, $7745AE04, $D736FCCC,
     $83426B33, $F01EAB71, $B0804187, $3C005E5F, $77A057BE, $BDE8AE24,
     $55464299, $BF582E61, $4E58F48F, $F2DDFDA2, $F474EF38, $8789BDC2,
     $5366F9C3, $C8B38E74, $B475F255, $46FCD9B9, $7AEB2661, $8B1DDF84,
     $846A0E79, $915F95E2, $466E598E, $20B45770, $8CD55591, $C902DE4C,
     $B90BACE1, $BB8205D0, $11A86248, $7574A99E, $B77F19B6, $E0A9DC09,
     $662D09A1, $C4324633, $E85A1F02, $09F0BE8C, $4A99A025, $1D6EFE10,
     $1AB93D1D, $0BA5A4DF, $A186F20F, $2868F169, $DCB7DA83, $573906FE,
     $A1E2CE9B, $4FCD7F52, $50115E01, $A70683FA, $A002B5C4, $0DE6D027,
     $9AF88C27, $773F8641, $C3604C06, $61A806B5, $F0177A28, $C0F586E0,
     $006058AA, $30DC7D62, $11E69ED7, $2338EA63, $53C2DD94, $C2C21634,
     $BBCBEE56, $90BCB6DE, $EBFC7DA1, $CE591D76, $6F05E409, $4B7C0188,
     $39720A3D, $7C927C24, $86E3725F, $724D9DB9, $1AC15BB4, $D39EB8FC,
     $ED545578, $08FCA5B5, $D83D7CD3, $4DAD0FC4, $1E50EF5E, $B161E6F8,
     $A28514D9, $6C51133C, $6FD5C7E7, $56E14EC4, $362ABFCE, $DDC6C837,
     $D79A3234, $92638212, $670EFA8E, $406000E0),
   (
     $3A39CE37, $D3FAF5CF, $ABC27737, $5AC52D1B, $5CB0679E, $4FA33742,
     $D3822740, $99BC9BBE, $D5118E9D, $BF0F7315, $D62D1C7E, $C700C47B,
     $B78C1B6B, $21A19045, $B26EB1BE, $6A366EB4, $5748AB2F, $BC946E79,
     $C6A376D2, $6549C2C8, $530FF8EE, $468DDE7D, $D5730A1D, $4CD04DC6,
     $2939BBDB, $A9BA4650, $AC9526E8, $BE5EE304, $A1FAD5F0, $6A2D519A,
     $63EF8CE2, $9A86EE22, $C089C2B8, $43242EF6, $A51E03AA, $9CF2D0A4,
     $83C061BA, $9BE96A4D, $8FE51550, $BA645BD6, $2826A2F9, $A73A3AE1,
     $4BA99586, $EF5562E9, $C72FEFD3, $F752F7DA, $3F046F69, $77FA0A59,
     $80E4A915, $87B08601, $9B09E6AD, $3B3EE593, $E990FD5A, $9E34D797,
     $2CF0B7D9, $022B8B51, $96D5AC3A, $017DA67D, $D1CF3ED6, $7C7D2D28,
     $1F9F25CF, $ADF2B89B, $5AD6B472, $5A88F54C, $E029AC71, $E019A5E6,
     $47B0ACFD, $ED93FA9B, $E8D3C48D, $283B57CC, $F8D56629, $79132E28,
     $785F0191, $ED756055, $F7960E44, $E3D35E8C, $15056DD4, $88F46DBA,
     $03A16125, $0564F0BD, $C3EB9E15, $3C9057A2, $97271AEC, $A93A072A,
     $1B3F6D9B, $1E6321F5, $F59C66FB, $26DCF319, $7533D928, $B155FDF5,
     $03563482, $8ABA3CBB, $28517711, $C20AD9F8, $ABCC5167, $CCAD925F,
     $4DE81751, $3830DC8E, $379D5862, $9320F991, $EA7A90C2, $FB3E7BCE,
     $5121CE64, $774FBE32, $A8B6E37E, $C3293D46, $48DE5369, $6413E680,
     $A2AE0810, $DD6DB224, $69852DFD, $09072166, $B39A460A, $6445C0DD,
     $586CDECF, $1C20C8AE, $5BBEF7DD, $1B588D40, $CCD2017F, $6BB4E3BB,
     $DDA26A7E, $3A59FF45, $3E350A44, $BCB4CDD5, $72EACEA8, $FA6484BB,
     $8D6612AE, $BF3C6F47, $D29BE463, $542F5D9E, $AEC2771B, $F64E6370,
     $740E0D8D, $E75B1357, $F8721671, $AF537D5D, $4040CB08, $4EB4E2CC,
     $34D2466A, $0115AF84, $E1B00428, $95983A1D, $06B89FB4, $CE6EA048,
     $6F3F3B82, $3520AB82, $011A1D4B, $277227F8, $611560B1, $E7933FDC,
     $BB3A792B, $344525BD, $A08839E1, $51CE794B, $2F32C9B7, $A01FBAC9,
     $E01CC87E, $BCC7D1F6, $CF0111C3, $A1E8AAC7, $1A908749, $D44FBD9A,
     $D0DADECB, $D50ADA38, $0339C32A, $C6913667, $8DF9317C, $E0B12B4F,
     $F79E59B7, $43F5BB3A, $F2D519FF, $27D9459C, $BF97222C, $15E6FC2A,
     $0F91FC71, $9B941525, $FAE59361, $CEB69CEB, $C2A86459, $12BAA8D1,
     $B6C1075E, $E3056A0C, $10D25065, $CB03A442, $E0EC6E0E, $1698DB3B,
     $4C98A0BE, $3278E964, $9F1F9532, $E0D392DF, $D3A0342B, $8971F21E,
     $1B0A7441, $4BA3348C, $C5BE7120, $C37632D8, $DF359F8D, $9B992F2E,
     $E60B6F47, $0FE3F11D, $E54CDA54, $1EDAD891, $CE6279CF, $CD3E7E6F,
     $1618B166, $FD2C1D05, $848FD2C5, $F6FB2299, $F523F357, $A6327623,
     $93A83531, $56CCCD02, $ACF08162, $5A75EBB5, $6E163697, $88D273CC,
     $DE966292, $81B949D0, $4C50901B, $71C65614, $E6C6C7BD, $327A140A,
     $45E1D006, $C3F27B9A, $C9AA53FD, $62A80F00, $BB25BFE2, $35BDD2F6,
     $71126905, $B2040222, $B6CBCF7C, $CD769C2B, $53113EC0, $1640E3D3,
     $38ABBD60, $2547ADF0, $BA38209C, $F746CE76, $77AFA1C5, $20756060,
     $85CBFE4E, $8AE88DD8, $7AAAF9B0, $4CF9AA7E, $1948C25C, $02FB8A8C,
     $01C36AE4, $D6EBE1F9, $90D4F869, $A65CDEA0, $3F09252D, $C208E69F,
     $B74E6132, $CE77E25B, $578FDFE3, $3AC372E6));

function ByteOf(x: LongWord; n: Integer): LongWord; inline;
begin
  Result := (x shr (n * 8)) and $FF;
end;

{ Blowfish (LibTomCrypt ciphers/blowfish.c), sólo la dirección de cifrado. }


function BlowfishF(x: LongWord): LongWord; inline;
begin
  Result := ((FS[0][ByteOf(x,3)] + FS[1][ByteOf(x,2)]) xor FS[2][ByteOf(x,1)]) + FS[3][ByteOf(x,0)];
end;

procedure BlowfishEnc(Src, Dst: PByte);
var
  L, R: LongWord;
  rr: Integer;
begin
  L := (LongWord(Src[0]) shl 24) or (LongWord(Src[1]) shl 16) or (LongWord(Src[2]) shl 8) or LongWord(Src[3]);
  R := (LongWord(Src[4]) shl 24) or (LongWord(Src[5]) shl 16) or (LongWord(Src[6]) shl 8) or LongWord(Src[7]);
  rr := 0;
  while rr < 16 do
  begin
    L := L xor FK[rr];      Inc(rr); R := R xor BlowfishF(L);
    R := R xor FK[rr];      Inc(rr); L := L xor BlowfishF(R);
    L := L xor FK[rr];      Inc(rr); R := R xor BlowfishF(L);
    R := R xor FK[rr];      Inc(rr); L := L xor BlowfishF(R);
  end;
  R := R xor FK[17];
  L := L xor FK[16];
  Dst[0] := Byte(R shr 24); Dst[1] := Byte(R shr 16); Dst[2] := Byte(R shr 8); Dst[3] := Byte(R);
  Dst[4] := Byte(L shr 24); Dst[5] := Byte(L shr 16); Dst[6] := Byte(L shr 8); Dst[7] := Byte(L);
end;{ ------------------------------------------------------------- Serpent }

procedure Sb0(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := a xor d;
  t2 := a and d;
  t3 := c xor t1;
  t6 := b and t1;
  t4 := b xor t3;
  t10 := (not t3);
  h := t2 xor t4;
  t7 := a xor t6;
  t14 := (not t7);
  t8 := c or t7;
  t11 := t3 xor t7;
  g := t4 xor t8;
  t12 := h and t11;
  f := t10 xor t12;
  e := t12 xor t14;
end;

procedure Sb1(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := (not a);
  t2 := b xor t1;
  t3 := a or t2;
  t4 := d or t2;
  t5 := c xor t3;
  g := d xor t5;
  t7 := b xor t4;
  t8 := t2 xor g;
  t9 := t5 and t7;
  h := t8 xor t9;
  t11 := t5 xor t7;
  f := h xor t11;
  t13 := t8 and t11;
  e := t5 xor t13;
end;

procedure Sb2(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := (not a);
  t2 := b xor d;
  t3 := c and t1;
  t13 := d or t1;
  e := t2 xor t3;
  t5 := c xor t1;
  t6 := c xor e;
  t7 := b and t6;
  t10 := e or t5;
  h := t5 xor t7;
  t9 := d or t7;
  t11 := t9 and t10;
  t14 := t2 xor h;
  g := a xor t11;
  t15 := g xor t13;
  f := t14 xor t15;
end;

procedure Sb3(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := a xor c;
  t2 := d xor t1;
  t3 := a and t2;
  t4 := d xor t3;
  t5 := b and t4;
  g := t2 xor t5;
  t7 := a or g;
  t8 := b or d;
  t11 := a or d;
  t9 := t4 and t7;
  f := t8 xor t9;
  t12 := b xor t11;
  t13 := g xor t9;
  t15 := t3 xor t8;
  h := t12 xor t13;
  t16 := c and t15;
  e := t12 xor t16;
end;

procedure Sb4(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := a xor d;
  t2 := d and t1;
  t3 := c xor t2;
  t4 := b or t3;
  h := t1 xor t4;
  t6 := (not b);
  t7 := t1 or t6;
  e := t3 xor t7;
  t9 := a and e;
  t10 := t1 xor t6;
  t11 := t4 and t10;
  g := t9 xor t11;
  t13 := a xor t3;
  t14 := t10 and g;
  f := t13 xor t14;
end;

procedure Sb5(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := (not a);
  t2 := a xor b;
  t3 := a xor d;
  t4 := c xor t1;
  t5 := t2 or t3;
  e := t4 xor t5;
  t7 := d and e;
  t8 := t2 xor e;
  t10 := t1 or e;
  f := t7 xor t8;
  t11 := t2 or t7;
  t12 := t3 xor t10;
  t14 := b xor t7;
  g := t11 xor t12;
  t15 := f and t12;
  h := t14 xor t15;
end;

procedure Sb6(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := (not a);
  t2 := a xor d;
  t3 := b xor t2;
  t4 := t1 or t2;
  t5 := c xor t4;
  f := b xor t5;
  t13 := (not t5);
  t7 := t2 or f;
  t8 := d xor t7;
  t9 := t5 and t8;
  g := t3 xor t9;
  t11 := t5 xor t8;
  e := g xor t11;
  t14 := t3 and t11;
  h := t13 xor t14;
end;

procedure Sb7(var a, b, c, d, e, f, g, h: LongWord);
var
  t1,t2,t3,t4,t5,t6,t7,t8,t9,t10,t11,t12,t13,t14,t15,t16: LongWord;
begin
  t1 := (not c);
  t2 := b xor c;
  t3 := b or t1;
  t4 := d xor t3;
  t5 := a and t4;
  t7 := a xor d;
  h := t2 xor t5;
  t8 := b xor t5;
  t9 := t2 or t8;
  t11 := d and t3;
  f := t7 xor t9;
  t12 := t5 xor f;
  t15 := t1 or t4;
  t13 := h and t12;
  g := t11 xor t13;
  t16 := t12 xor g;
  e := t15 xor t16;
end;

procedure SerpentRot(var a, b, c, d: LongWord);
begin
  a := RolDWord(a, 13);
  c := RolDWord(c, 3);
  d := d xor c xor (a shl 3);
  b := b xor a xor c;
  d := RolDWord(d, 7);
  b := RolDWord(b, 1);
  a := a xor b xor d;
  c := c xor d xor (b shl 7);
  a := RolDWord(a, 5);
  c := RolDWord(c, 22);
end;

procedure SerpentSb(n: Integer; var a, b, c, d, e, f, g, h: LongWord);
begin
  case n of
    0: Sb0(a,b,c,d,e,f,g,h);
    1: Sb1(a,b,c,d,e,f,g,h);
    2: Sb2(a,b,c,d,e,f,g,h);
    3: Sb3(a,b,c,d,e,f,g,h);
    4: Sb4(a,b,c,d,e,f,g,h);
    5: Sb5(a,b,c,d,e,f,g,h);
    6: Sb6(a,b,c,d,e,f,g,h);
  else
    Sb7(a,b,c,d,e,f,g,h);
  end;
end;

{ Serpent (LibTomCrypt ciphers/serpent.c), sólo la dirección de cifrado.
  La clave de ronda va en little-endian y son 132 palabras + 8 del arranque. }
procedure SerpentSetup(Key: PByte; KeyLen: Integer);
var
  i, lk: LongWord;
  a, b, c, d, e, f, g, h: LongWord;
  bits: LongWord;
begin
  bits := KeyLen * 8;
  lk := (bits + 31) div 32;
  for i := 0 to lk - 1 do
    FSERP[i] := LongWord(Key[i*4]) or (LongWord(Key[i*4+1]) shl 8) or
                (LongWord(Key[i*4+2]) shl 16) or (LongWord(Key[i*4+3]) shl 24);
  if bits < 256 then
  begin
    i := lk;
    while i < 8 do begin FSERP[i] := 0; Inc(i); end;
    i := bits div 32;
    lk := LongWord(1) shl (bits mod 32);
    FSERP[i] := (FSERP[i] and (lk - 1)) or lk;
  end;
  for i := 0 to 131 do
  begin
    lk := FSERP[i] xor FSERP[i+3] xor FSERP[i+5] xor FSERP[i+7] xor $9E3779B9 xor i;
    FSERP[i+8] := (lk shl 11) or (lk shr 21);
  end;
  for i := 0 to 32 do
  begin
    a := FSERP[4*i+8]; b := FSERP[4*i+9]; c := FSERP[4*i+10]; d := FSERP[4*i+11];
    SerpentSb(Integer((3 - i) mod 8 + 8) mod 8, a, b, c, d, e, f, g, h);
    FSERP[4*i+8] := e; FSERP[4*i+9] := f; FSERP[4*i+10] := g; FSERP[4*i+11] := h;
  end;
end;

procedure SerpentEnc(Src, Dst: PByte);
var
  a, b, c, d, e, f, g, h: LongWord;
  r: Integer;
begin
  a := LongWord(Src[0]) or (LongWord(Src[1]) shl 8) or (LongWord(Src[2]) shl 16) or (LongWord(Src[3]) shl 24);
  b := LongWord(Src[4]) or (LongWord(Src[5]) shl 8) or (LongWord(Src[6]) shl 16) or (LongWord(Src[7]) shl 24);
  c := LongWord(Src[8]) or (LongWord(Src[9]) shl 8) or (LongWord(Src[10]) shl 16) or (LongWord(Src[11]) shl 24);
  d := LongWord(Src[12]) or (LongWord(Src[13]) shl 8) or (LongWord(Src[14]) shl 16) or (LongWord(Src[15]) shl 24);
  for r := 0 to 31 do
    if (r and 1) = 0 then
    begin
      a := a xor FSERP[4*r+8]; b := b xor FSERP[4*r+9];
      c := c xor FSERP[4*r+10]; d := d xor FSERP[4*r+11];
      SerpentSb(r and 7, a, b, c, d, e, f, g, h);
      if r <> 31 then SerpentRot(e, f, g, h);
    end
    else
    begin
      e := e xor FSERP[4*r+8]; f := f xor FSERP[4*r+9];
      g := g xor FSERP[4*r+10]; h := h xor FSERP[4*r+11];
      SerpentSb(r and 7, e, f, g, h, a, b, c, d);
      if r <> 31 then SerpentRot(a, b, c, d);
    end;
  a := a xor FSERP[4*32+8]; b := b xor FSERP[4*32+9];
  c := c xor FSERP[4*32+10]; d := d xor FSERP[4*32+11];
  Dst[0] := Byte(a); Dst[1] := Byte(a shr 8); Dst[2] := Byte(a shr 16); Dst[3] := Byte(a shr 24);
  Dst[4] := Byte(b); Dst[5] := Byte(b shr 8); Dst[6] := Byte(b shr 16); Dst[7] := Byte(b shr 24);
  Dst[8] := Byte(c); Dst[9] := Byte(c shr 8); Dst[10] := Byte(c shr 16); Dst[11] := Byte(c shr 24);
  Dst[12] := Byte(d); Dst[13] := Byte(d shr 8); Dst[14] := Byte(d shr 16); Dst[15] := Byte(d shr 24);
end;

{ ------------------------------------------------------------- Twofish }

const
  TF_MDS: array[0..3, 0..3] of Byte = (
    ($01, $EF, $5B, $5B),
    ($5B, $EF, $EF, $01),
    ($EF, $5B, $01, $EF),
    ($EF, $01, $EF, $5B));
  TF_RS: array[0..3, 0..7] of Byte = (
    ($01, $A4, $55, $87, $5A, $58, $DB, $9E),
    ($A4, $56, $82, $F3, $1E, $C6, $68, $E5),
    ($02, $A1, $FC, $C1, $47, $AE, $3D, $19),
    ($A4, $55, $87, $5A, $58, $DB, $9E, $03));
  TF_QBOX: array[0..1, 0..3, 0..15] of Byte = (
   (
     ($08, $01, $07, $0D, $06, $0F, $03, $02, $00, $0B, $05, $09, $0E, $0C, $0A, $04),
     ($0E, $0C, $0B, $08, $01, $02, $03, $05, $0F, $04, $0A, $06, $07, $00, $09, $0D),
     ($0B, $0A, $05, $0E, $06, $0D, $09, $00, $0C, $08, $0F, $03, $02, $04, $07, $01),
     ($0D, $07, $0F, $04, $01, $02, $06, $0E, $09, $0B, $03, $00, $08, $05, $0C, $0A)),
   (
     ($02, $08, $0B, $0D, $0F, $07, $06, $0E, $03, $01, $09, $04, $00, $0A, $0C, $05),
     ($01, $0E, $02, $0B, $04, $0C, $03, $07, $06, $0D, $0A, $05, $0F, $09, $00, $08),
     ($04, $0C, $07, $05, $01, $06, $09, $0A, $00, $0E, $0D, $08, $02, $0B, $03, $0F),
     ($0B, $09, $05, $01, $0C, $03, $0D, $0E, $06, $04, $07, $0F, $02, $00, $08, $0A)));

var
  FTFK: array[0..39] of LongWord;
  FTF_S: array[0..3, 0..255] of LongWord;

function TFGfMult(a, b, p: LongWord): LongWord;
var
  res: LongWord;
  BB, PP: array[0..1] of LongWord;
  i: Integer;
begin
  PP[0] := 0; PP[1] := p;
  BB[0] := 0; BB[1] := b;
  res := 0;
  for i := 0 to 6 do
  begin
    res := res xor BB[a and 1];
    a := a shr 1;
    BB[1] := PP[BB[1] shr 7] xor (BB[1] shl 1);
  end;
  Result := res xor BB[a and 1];
end;

function TFSbox(i, x: LongWord): LongWord;
var
  a0, b0, a1, b1, a2, b2, a3, b3, a4, b4: LongWord;
begin
  a0 := (x shr 4) and 15;
  b0 := x and 15;
  a1 := a0 xor b0;
  b1 := (a0 xor ((b0 shl 3) or (b0 shr 1)) xor (a0 shl 3)) and 15;
  a2 := TF_QBOX[i][0][a1];
  b2 := TF_QBOX[i][1][b1];
  a3 := a2 xor b2;
  b3 := (a2 xor ((b2 shl 3) or (b2 shr 1)) xor (a2 shl 3)) and 15;
  a4 := TF_QBOX[i][2][a3];
  b4 := TF_QBOX[i][3][b3];
  Result := (b4 shl 4) + a4;
end;

function TFMdsColumnMult(v: LongWord; col: Integer): LongWord;
var x01, x5B, xEF: LongWord;
begin
  x01 := v;
  x5B := TFGfMult(v, $5B, $169);
  xEF := TFGfMult(v, $EF, $169);
  case col of
    0: Result := x01 or (x5B shl 8) or (xEF shl 16) or (xEF shl 24);
    1: Result := xEF or (xEF shl 8) or (x5B shl 16) or (x01 shl 24);
    2: Result := x5B or (xEF shl 8) or (x01 shl 16) or (xEF shl 24);
  else
    Result := x5B or (x01 shl 8) or (xEF shl 16) or (x5B shl 24);
  end;
end;

procedure TFMdsMult(Inb, Outb: PByte);
var x: Integer; tmp: LongWord;
begin
  tmp := 0;
  for x := 0 to 3 do tmp := tmp xor TFMdsColumnMult(Inb[x], x);
  Outb[0] := Byte(tmp); Outb[1] := Byte(tmp shr 8);
  Outb[2] := Byte(tmp shr 16); Outb[3] := Byte(tmp shr 24);
end;

procedure TFRSMult(Inb, Outb: PByte);
var x, y: Integer;
begin
  for x := 0 to 3 do
  begin
    Outb[x] := 0;
    for y := 0 to 7 do
      Outb[x] := Outb[x] xor Byte(TFGfMult(Inb[y], TF_RS[x][y], $14D) and $FF);
  end;
end;

procedure TFHFunc(Inb, Outb, M: PByte; k, offset: Integer);
var x: Integer; y: array[0..3] of Byte;
begin
  for x := 0 to 3 do y[x] := Inb[x];
  { ojo: en el C el switch cae de un caso al siguiente (no hay break) }
  if k = 4 then
  begin
    y[0] := Byte(TFSbox(1, y[0]) xor M[4 * (6 + offset) + 0]);
    y[1] := Byte(TFSbox(0, y[1]) xor M[4 * (6 + offset) + 1]);
    y[2] := Byte(TFSbox(0, y[2]) xor M[4 * (6 + offset) + 2]);
    y[3] := Byte(TFSbox(1, y[3]) xor M[4 * (6 + offset) + 3]);
  end;
  if k >= 3 then
  begin
    y[0] := Byte(TFSbox(1, y[0]) xor M[4 * (4 + offset) + 0]);
    y[1] := Byte(TFSbox(1, y[1]) xor M[4 * (4 + offset) + 1]);
    y[2] := Byte(TFSbox(0, y[2]) xor M[4 * (4 + offset) + 2]);
    y[3] := Byte(TFSbox(0, y[3]) xor M[4 * (4 + offset) + 3]);
  end;
  y[0] := Byte(TFSbox(1, TFSbox(0, TFSbox(0, y[0]) xor M[4 * (2 + offset) + 0]) xor M[4 * (0 + offset) + 0]));
  y[1] := Byte(TFSbox(0, TFSbox(0, TFSbox(1, y[1]) xor M[4 * (2 + offset) + 1]) xor M[4 * (0 + offset) + 1]));
  y[2] := Byte(TFSbox(1, TFSbox(1, TFSbox(0, y[2]) xor M[4 * (2 + offset) + 2]) xor M[4 * (0 + offset) + 2]));
  y[3] := Byte(TFSbox(0, TFSbox(1, TFSbox(1, y[3]) xor M[4 * (2 + offset) + 3]) xor M[4 * (0 + offset) + 3]));
  TFMdsMult(@y[0], Outb);
end;

{ Key schedule y cifrado. La clave va en little-endian y el bloque también. }
procedure TwofishSetup(Key: PByte; KeyLen: Integer);
var
  k, x, y: Integer;
  S: array[0..15] of Byte;
  tmp, tmp2, M: array[0..31] of Byte;
  A, B: LongWord;
  tmpx0, tmpx1: Byte;
begin
  k := KeyLen div 8;
  for x := 0 to KeyLen - 1 do M[x] := Key[x];
  for x := 0 to k - 1 do TFRSMult(@M[x * 8], @S[x * 4]);
  for x := 0 to 19 do
  begin
    for y := 0 to 3 do tmp[y] := Byte(x + x);
    TFHFunc(@tmp[0], @tmp2[0], @M[0], k, 0);
    A := LongWord(tmp2[0]) or (LongWord(tmp2[1]) shl 8) or (LongWord(tmp2[2]) shl 16) or (LongWord(tmp2[3]) shl 24);
    for y := 0 to 3 do tmp[y] := Byte(x + x + 1);
    TFHFunc(@tmp[0], @tmp2[0], @M[0], k, 1);
    B := LongWord(tmp2[0]) or (LongWord(tmp2[1]) shl 8) or (LongWord(tmp2[2]) shl 16) or (LongWord(tmp2[3]) shl 24);
    B := RolDWord(B, 8);
    FTFK[x + x] := A + B;
    FTFK[x + x + 1] := RolDWord(B + B + A, 9);
  end;
  if k = 2 then
    for x := 0 to 255 do
    begin
      tmpx0 := Byte(TFSbox(0, x));
      tmpx1 := Byte(TFSbox(1, x));
      FTF_S[0][x] := TFMdsColumnMult(TFSbox(1, TFSbox(0, tmpx0 xor S[0]) xor S[4]), 0);
      FTF_S[1][x] := TFMdsColumnMult(TFSbox(0, TFSbox(0, tmpx1 xor S[1]) xor S[5]), 1);
      FTF_S[2][x] := TFMdsColumnMult(TFSbox(1, TFSbox(1, tmpx0 xor S[2]) xor S[6]), 2);
      FTF_S[3][x] := TFMdsColumnMult(TFSbox(0, TFSbox(1, tmpx1 xor S[3]) xor S[7]), 3);
    end
  else if k = 3 then
    for x := 0 to 255 do
    begin
      tmpx0 := Byte(TFSbox(0, x));
      tmpx1 := Byte(TFSbox(1, x));
      FTF_S[0][x] := TFMdsColumnMult(TFSbox(1, TFSbox(0, TFSbox(0, tmpx1 xor S[0]) xor S[4]) xor S[8]), 0);
      FTF_S[1][x] := TFMdsColumnMult(TFSbox(0, TFSbox(0, TFSbox(1, tmpx1 xor S[1]) xor S[5]) xor S[9]), 1);
      FTF_S[2][x] := TFMdsColumnMult(TFSbox(1, TFSbox(1, TFSbox(0, tmpx0 xor S[2]) xor S[6]) xor S[10]), 2);
      FTF_S[3][x] := TFMdsColumnMult(TFSbox(0, TFSbox(1, TFSbox(1, tmpx0 xor S[3]) xor S[7]) xor S[11]), 3);
    end
  else
    for x := 0 to 255 do
    begin
      tmpx0 := Byte(TFSbox(0, x));
      tmpx1 := Byte(TFSbox(1, x));
      FTF_S[0][x] := TFMdsColumnMult(TFSbox(1, TFSbox(0, TFSbox(0, TFSbox(1, tmpx1 xor S[0]) xor S[4]) xor S[8]) xor S[12]), 0);
      FTF_S[1][x] := TFMdsColumnMult(TFSbox(0, TFSbox(0, TFSbox(1, TFSbox(1, tmpx0 xor S[1]) xor S[5]) xor S[9]) xor S[13]), 1);
      FTF_S[2][x] := TFMdsColumnMult(TFSbox(1, TFSbox(1, TFSbox(0, TFSbox(0, tmpx0 xor S[2]) xor S[6]) xor S[10]) xor S[14]), 2);
      FTF_S[3][x] := TFMdsColumnMult(TFSbox(0, TFSbox(1, TFSbox(1, TFSbox(0, tmpx1 xor S[3]) xor S[7]) xor S[11]) xor S[15]), 3);
    end;
end;

function TFG(x: LongWord): LongWord; inline;
begin
  Result := FTF_S[0][x and $FF] xor FTF_S[1][(x shr 8) and $FF] xor
            FTF_S[2][(x shr 16) and $FF] xor FTF_S[3][(x shr 24) and $FF];
end;

function TFG1(x: LongWord): LongWord; inline;
begin
  Result := FTF_S[1][x and $FF] xor FTF_S[2][(x shr 8) and $FF] xor
            FTF_S[3][(x shr 16) and $FF] xor FTF_S[0][(x shr 24) and $FF];
end;

procedure TwofishEnc(Src, Dst: PByte);
var
  a, b, c, d, ta, tb, tc, td, t1, t2: LongWord;
  r, ki: Integer;
begin
  a := LongWord(Src[0]) or (LongWord(Src[1]) shl 8) or (LongWord(Src[2]) shl 16) or (LongWord(Src[3]) shl 24);
  b := LongWord(Src[4]) or (LongWord(Src[5]) shl 8) or (LongWord(Src[6]) shl 16) or (LongWord(Src[7]) shl 24);
  c := LongWord(Src[8]) or (LongWord(Src[9]) shl 8) or (LongWord(Src[10]) shl 16) or (LongWord(Src[11]) shl 24);
  d := LongWord(Src[12]) or (LongWord(Src[13]) shl 8) or (LongWord(Src[14]) shl 16) or (LongWord(Src[15]) shl 24);
  a := a xor FTFK[0]; b := b xor FTFK[1]; c := c xor FTFK[2]; d := d xor FTFK[3];
  ki := 8;
  for r := 0 to 7 do
  begin
    t2 := TFG1(b);
    t1 := TFG(a) + t2;
    c := RorDWord(c xor (t1 + FTFK[ki]), 1);
    d := RolDWord(d, 1) xor (t2 + t1 + FTFK[ki + 1]);
    t2 := TFG1(d);
    t1 := TFG(c) + t2;
    a := RorDWord(a xor (t1 + FTFK[ki + 2]), 1);
    b := RolDWord(b, 1) xor (t2 + t1 + FTFK[ki + 3]);
    ki := ki + 4;
  end;
  ta := c xor FTFK[4]; tb := d xor FTFK[5];
  tc := a xor FTFK[6]; td := b xor FTFK[7];
  Dst[0] := Byte(ta); Dst[1] := Byte(ta shr 8); Dst[2] := Byte(ta shr 16); Dst[3] := Byte(ta shr 24);
  Dst[4] := Byte(tb); Dst[5] := Byte(tb shr 8); Dst[6] := Byte(tb shr 16); Dst[7] := Byte(tb shr 24);
  Dst[8] := Byte(tc); Dst[9] := Byte(tc shr 8); Dst[10] := Byte(tc shr 16); Dst[11] := Byte(tc shr 24);
  Dst[12] := Byte(td); Dst[13] := Byte(td shr 8); Dst[14] := Byte(td shr 16); Dst[15] := Byte(td shr 24);
end;

{ ------------------------------------------------------------- parámetros }

function CipherMaxKeySize(const Name: string): Integer;
begin
  if Name = 'aes' then Result := 32
  else if Name = 'blowfish' then Result := 56
  else if Name = 'serpent' then Result := 32
  else if Name = 'twofish' then Result := 32
  else Result := 0;
end;

procedure BlowfishSetup(Key: PByte; KeyLen: Integer);
var
  x, y, z: Integer;
  A: LongWord;
  B: array[0..7] of Byte;
begin
  y := 0;
  for x := 0 to 17 do
  begin
    A := 0;
    for z := 0 to 3 do
    begin
      A := (A shl 8) or LongWord(Key[y]);
      Inc(y);
      if y = KeyLen then y := 0;
    end;
    FK[x] := BF_ORIG_P[x] xor A;
  end;
  for x := 0 to 3 do
    for y := 0 to 255 do FS[x][y] := BF_ORIG_S[x][y];
  for x := 0 to 7 do B[x] := 0;
  for x := 0 to 8 do
  begin
    BlowfishEnc(@B[0], @B[0]);
    FK[x*2]   := LongWord(B[0]) shl 24 or (LongWord(B[1]) shl 16) or (LongWord(B[2]) shl 8) or LongWord(B[3]);
    FK[x*2+1] := LongWord(B[4]) shl 24 or (LongWord(B[5]) shl 16) or (LongWord(B[6]) shl 8) or LongWord(B[7]);
  end;
  for x := 0 to 3 do
    for y := 0 to 255 do
      if (y and 1) = 0 then
      begin
        BlowfishEnc(@B[0], @B[0]);
        FS[x][y]   := LongWord(B[0]) shl 24 or (LongWord(B[1]) shl 16) or (LongWord(B[2]) shl 8) or LongWord(B[3]);
        FS[x][y+1] := LongWord(B[4]) shl 24 or (LongWord(B[5]) shl 16) or (LongWord(B[6]) shl 8) or LongWord(B[7]);
      end;
end;



function CipherBlockSize(const Name: string): Integer;
begin
  if Name = 'aes' then Result := 16
  else if Name = 'blowfish' then Result := 8
  else if Name = 'serpent' then Result := 16
  else if Name = 'twofish' then Result := 16
  else Result := 0;
end;

function IsCipherName(const Name: string): Boolean;
begin
  Result := CipherMaxKeySize(Name) > 0;
end;

function HexVal(c: Char): Integer;
begin
  case c of
    '0'..'9': Result := Ord(c) - Ord('0');
    'a'..'f': Result := Ord(c) - Ord('a') + 10;
    'A'..'F': Result := Ord(c) - Ord('A') + 10;
  else
    Result := -1;
  end;
end;

function DecodeHex(const S: string; var Buf: array of Byte): Integer;
var
  i, hi, lo: Integer;
begin
  Result := 0;
  i := 1;
  while i + 1 <= Length(S) do
  begin
    hi := HexVal(S[i]);
    lo := HexVal(S[i + 1]);
    if (hi < 0) or (lo < 0) then Break;
    if Result >= Length(Buf) then Break;
    Buf[Result] := Byte(hi * 16 + lo);
    Inc(Result);
    Inc(i, 2);
  end;
end;

{ Decodificador "buggy" de FreeArc (buggy_char2int): para las letras NO suma 10,
  así que 'a'..'f' -> 0..5.  El C++ usa éste para :k y :i salvo que el método
  traiga ':f'; y el ENCODER usó el mismo, así que la clave/IV efectivos son esta
  decodificación del hex.  El salt y el check-code, en cambio, los decodifica el
  Haskell con decode16 (hex normal). }
function BuggyHexVal(c: Char): Integer;
begin
  if (c >= '0') and (c <= '9') then Result := Ord(c) - Ord('0')
  else Result := Ord(LowerCase(c)) - Ord('a');
end;

function DecodeHexBuggy(const S: string; var Buf: array of Byte): Integer;
var
  i: Integer;
begin
  Result := 0;
  i := 1;
  while i + 1 <= Length(S) do
  begin
    if Result >= Length(Buf) then Break;
    Buf[Result] := Byte(BuggyHexVal(S[i]) * 16 + BuggyHexVal(S[i + 1]));
    Inc(Result);
    Inc(i, 2);
  end;
end;

function EncodeHex(const Buf: array of Byte; Len: Integer): string;
const
  HEXD: array[0..15] of Char = '0123456789abcdef';
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Len - 1 do
    Result := Result + HEXD[Buf[i] shr 4] + HEXD[Buf[i] and $F];
end;

function ParseCryptParams(const Params: TStringArray): TCryptParams;
var
  p, name, mode: string;
  k, sl: Integer;
begin
  Result.Cipher := ''; Result.KeySize := 0; Result.IVSize := 0;
  Result.Mode := 'ctr'; Result.Fixed := False; Result.NumIterations := 1000;
  Result.Rounds := 0;
  Result.KeyHex := ''; Result.IVHex := ''; Result.SaltHex := ''; Result.CheckHex := '';
  { Params[0] es "cifrado-<bits>/<modo>"; el resto son los parámetros }
  p := Params[0];
  mode := 'ctr';
  sl := Pos('/', p);
  if sl > 0 then
  begin
    mode := Copy(p, sl + 1, MaxInt);
    p := Copy(p, 1, sl - 1);
  end;
  name := p;
  sl := Pos('-', p);
  if sl > 0 then
  begin
    name := Copy(p, 1, sl - 1);
    Result.KeySize := StrToIntDef(Copy(p, sl + 1, MaxInt), 0) div 8;
  end;
  Result.Cipher := name;
  Result.Mode := mode;
  if not IsCipherName(name) then
    raise EUnsupportedMethod.Create('cifrado no soportado: ' + Params[0]);
  if (mode <> 'ctr') and (mode <> 'cfb') then
    raise EUnsupportedMethod.Create('modo de cifrado no soportado: ' + mode);
  if Result.KeySize = 0 then Result.KeySize := CipherMaxKeySize(name);
  if (Result.KeySize > CipherMaxKeySize(name)) or (Result.KeySize < 1) then
    raise EUnsupportedMethod.Create('tamaño de clave inválido en ' + Params[0]);
  Result.IVSize := CipherBlockSize(name);
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then Continue;
    if p = 'f' then begin Result.Fixed := True; Continue; end;
    case p[1] of
      'k': Result.KeyHex := Copy(p, 2, MaxInt);
      'i': Result.IVHex := Copy(p, 2, MaxInt);
      's': Result.SaltHex := Copy(p, 2, MaxInt);
      'c': Result.CheckHex := Copy(p, 2, MaxInt);
      'n': Result.NumIterations := StrToIntDef(Copy(p, 2, MaxInt), 1000);
      'r': Result.Rounds := StrToIntDef(Copy(p, 2, MaxInt), 0);
    else
      raise EUnsupportedMethod.Create('parámetro de cifrado desconocido: ' + p);
    end;
  end;
end;

function DeriveKeyAndCheck(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt;
                           Key: PByte): Boolean;
var
  salt, cc, dk: array of Byte;
  nsalt, ncc: Integer;
begin
  Result := False;
  SetLength(salt, (Length(Par.SaltHex) div 2) + 1);
  nsalt := DecodeHex(Par.SaltHex, salt);
  { el largo del check-code es el DECODIFICADO (como hace el C con length
    checkCode): si el hex trae basura al final (p.ej. un CR) no debe contar }
  SetLength(cc, (Length(Par.CheckHex) div 2) + 1);
  ncc := DecodeHex(Par.CheckHex, cc);
  SetLength(dk, Par.KeySize + ncc);
  Pbkdf2HmacSha512(Pwd, PwdLen, @salt[0], nsalt, Par.NumIterations, @dk[0], Length(dk));
  Move(dk[0], Key^, Par.KeySize);
  if ncc = 0 then
    Exit(True);
  Result := CompareByte(cc[0], dk[Par.KeySize], ncc) = 0;
end;

function TwofishTestVec(const KeyHex, PtHex: string): string;
var
  key, pt, ct: array of Byte;
begin
  SetLength(key, Length(KeyHex) div 2);
  SetLength(pt, 16); SetLength(ct, 16);
  DecodeHex(KeyHex, key);
  DecodeHex(PtHex, pt);
  TwofishSetup(@key[0], Length(key));
  TwofishEnc(@pt[0], @ct[0]);
  Result := EncodeHex(ct, 16);
end;

function SerpentTestVec(const KeyHex, PtHex: string): string;
var
  key, pt, ct: array of Byte;
begin
  SetLength(key, Length(KeyHex) div 2);
  SetLength(pt, 16); SetLength(ct, 16);
  DecodeHex(KeyHex, key);
  DecodeHex(PtHex, pt);
  SerpentSetup(@key[0], Length(key));
  SerpentEnc(@pt[0], @ct[0]);
  Result := EncodeHex(ct, 16);
end;

function BlowfishTestVec(const KeyHex, PtHex: string): string;
var
  key, pt, ct: array of Byte;
begin
  SetLength(key, Length(KeyHex) div 2);
  SetLength(pt, 8); SetLength(ct, 8);
  DecodeHex(KeyHex, key);
  DecodeHex(PtHex, pt);
  BlowfishSetup(@key[0], Length(key));
  BlowfishEnc(@pt[0], @ct[0]);
  Result := EncodeHex(ct, 8);
end;

function AesEcb(const KeyHex, BlockHex: string): string;
var
  key, blk: array of Byte;
  rk: array[0..63] of LongWord;
  s, d: array[0..3] of LongWord;
  i: Integer;
begin
  SetLength(key, Length(KeyHex) div 2);
  SetLength(blk, 16);
  DecodeHex(KeyHex, key);
  DecodeHex(BlockHex, blk);
  AesInit;
  AesSetKeyEnc(@rk[0], @key[0], Length(key));
  for i := 0 to 3 do
    s[i] := LongWord(blk[i*4]) or (LongWord(blk[i*4+1]) shl 8) or (LongWord(blk[i*4+2]) shl 16) or (LongWord(blk[i*4+3]) shl 24);
  AesEncode(@rk[0], @d[0], @s[0]);
  SetLength(blk, 16);
  for i := 0 to 3 do
  begin
    blk[i*4] := Byte(d[i] and $FF); blk[i*4+1] := Byte((d[i] shr 8) and $FF);
    blk[i*4+2] := Byte((d[i] shr 16) and $FF); blk[i*4+3] := Byte((d[i] shr 24) and $FF);
  end;
  Result := EncodeHex(blk, 16);
end;

function DerivedCheckHex(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt): string;
var
  salt, dk: array of Byte;
  nsalt, ncc: Integer;
begin
  SetLength(salt, (Length(Par.SaltHex) div 2) + 1);
  nsalt := DecodeHex(Par.SaltHex, salt);
  SetLength(dk, (Length(Par.CheckHex) div 2) + 1);
  ncc := DecodeHex(Par.CheckHex, dk);
  SetLength(dk, Par.KeySize + ncc);
  Pbkdf2HmacSha512(Pwd, PwdLen, @salt[0], nsalt, Par.NumIterations, @dk[0], Length(dk));
  Result := EncodeHex(dk, Length(dk));
end;

function KeyedMethod(const Par: TCryptParams; const Key: PByte): string;
var
  kb: array of Byte;
begin
  SetLength(kb, Par.KeySize);
  Move(Key^, kb[0], Par.KeySize);
  Result := Par.Cipher + '-' + IntToStr(Par.KeySize * 8) + '/' + Par.Mode;
  if Par.Fixed then Result := Result + ':f';
  Result := Result + ':n' + IntToStr(Par.NumIterations) + ':r' + IntToStr(Par.Rounds);
  Result := Result + ':k' + EncodeHex(kb, Par.KeySize);
  if Par.IVHex <> '' then Result := Result + ':i' + Par.IVHex;
end;

{ ------------------------------------------------------------- el descifrado }

function DecryptMem(const Par: TCryptParams; const Key: PByte;
                    Src: PByte; Len: SizeInt; Dst: PByte): Boolean;
var
  st: TDecryptStage;
  srcStage: TInStage;
  n: SizeInt;
begin
  Result := False;
  if Len <= 0 then Exit(True);
  srcStage := TMemStage.Create(Src, Len);
  st := TDecryptStage.Create(srcStage, Par);   { toma posesión de srcStage }
  try
    n := st.Read(Dst, Len);
    Result := n > 0;
  finally
    st.Free;                                   { libera también srcStage }
  end;
end;

constructor TDecryptStage.Create(ASource: TInStage; const APar: TCryptParams);
var
  iv: array of Byte;
  n: Integer;
begin
  if not IsCipherName(APar.Cipher) then
    raise EUnsupportedMethod.Create('cifrado no soportado: ' + APar.Cipher);
  if APar.KeyHex = '' then
    raise EUnsupportedMethod.Create('cifrado sin clave: falta derivarla del password');
  if (APar.Mode <> 'ctr') and (APar.Mode <> 'cfb') then
    raise EUnsupportedMethod.Create('modo de cifrado no soportado: ' + APar.Mode);
  if APar.KeySize > CipherMaxKeySize(APar.Cipher) then
    raise EUnsupportedMethod.Create('clave demasiado larga para ' + APar.Cipher);
  inherited Create(ASource);
  FPar := APar;
  FBlockSize := CipherBlockSize(APar.Cipher);
  SetLength(FKey, APar.KeySize);
  if APar.Fixed then
    n := DecodeHex(APar.KeyHex, FKey)
  else
    n := DecodeHexBuggy(APar.KeyHex, FKey);
  if n <> APar.KeySize then
    Corrupt('cifrado: clave con largo inválido');
  SetLength(iv, APar.IVSize);
  FillChar(iv[0], APar.IVSize, 0);
  if APar.IVHex <> '' then
  begin
    if APar.Fixed then n := DecodeHex(APar.IVHex, iv)
    else n := DecodeHexBuggy(APar.IVHex, iv);
    if n <> APar.IVSize then Corrupt('cifrado: IV con largo inválido');
  end;
  Move(iv[0], FCounter[0], APar.IVSize);
  Move(iv[0], FIV[0], APar.IVSize);
  FPadLen := 0;
  if APar.Cipher = 'aes' then
  begin
    AesInit;
    AesSetKeyEnc(@FRk[0], @FKey[0], APar.KeySize);
  end
  else if APar.Cipher = 'blowfish' then
    BlowfishSetup(@FKey[0], APar.KeySize)
  else if APar.Cipher = 'serpent' then
    SerpentSetup(@FKey[0], APar.KeySize)
  else if APar.Cipher = 'twofish' then
    TwofishSetup(@FKey[0], APar.KeySize)
  else
    raise EUnsupportedMethod.Create('cifrado todavía no implementado: ' + APar.Cipher);
  ModeStart;
end;

function TDecryptStage.BlockEncrypt(const Src: array of Byte; var Dst: array of Byte): Boolean;
var
  s, d: array[0..3] of LongWord;
  i: Integer;
begin
  if FPar.Cipher = 'blowfish' then
  begin
    BlowfishEnc(@Src[0], @Dst[0]);
    Exit(True);
  end;
  if FPar.Cipher = 'serpent' then
  begin
    SerpentEnc(@Src[0], @Dst[0]);
    Exit(True);
  end;
  if FPar.Cipher = 'twofish' then
  begin
    TwofishEnc(@Src[0], @Dst[0]);
    Exit(True);
  end;
  for i := 0 to 3 do
    s[i] := LongWord(Src[i * 4]) or (LongWord(Src[i * 4 + 1]) shl 8) or
            (LongWord(Src[i * 4 + 2]) shl 16) or (LongWord(Src[i * 4 + 3]) shl 24);
  AesEncode(@FRk[0], @d[0], @s[0]);
  for i := 0 to 3 do
  begin
    Dst[i * 4]     := Byte(d[i] and $FF);
    Dst[i * 4 + 1] := Byte((d[i] shr 8) and $FF);
    Dst[i * 4 + 2] := Byte((d[i] shr 16) and $FF);
    Dst[i * 4 + 3] := Byte((d[i] shr 24) and $FF);
  end;
  Result := True;
end;

procedure TDecryptStage.ModeStart;
begin
  BlockEncrypt(FCounter, FPad);       { bloque 0: keystream = E(IV) }
  if FPar.Mode = 'cfb' then
    BlockEncrypt(FIV, FIV);           { CFB: la keystream del 1er bloque es E(IV) }
  FPadLen := 0;
end;

procedure TDecryptStage.ModeDecrypt(Buf: PByte; Len: SizeInt);
var
  i, j: Integer;
  c: Byte;
begin
  for i := 0 to Len - 1 do
  begin
    if FPadLen = FBlockSize then
    begin
      if FPar.Mode = 'ctr' then
      begin
        { contador little-endian }
        j := 0;
        while j < FBlockSize do
        begin
          FCounter[j] := Byte(FCounter[j] + 1);
          if FCounter[j] <> 0 then Break;
          Inc(j);
        end;
        BlockEncrypt(FCounter, FPad);
      end
      else
        BlockEncrypt(FPad, FIV);      { CFB: E(cifrado anterior) }
      FPadLen := 0;
    end;
    if FPar.Mode = 'ctr' then
      Buf^ := Buf^ xor FPad[FPadLen]
    else
    begin
      c := Buf^;
      Buf^ := Buf^ xor FIV[FPadLen];
      FPad[FPadLen] := c;
    end;
    Inc(Buf);
    Inc(FPadLen);
  end;
end;

function TDecryptStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n: SizeInt;
begin
  n := Source.Read(Buf, Count);
  if n > 0 then ModeDecrypt(Buf, n);
  Result := n;
end;

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
    got := FileRead(f, Buf^, Len);
    Result := got = Len;
  finally
    FileClose(f);
  end;
end;
{$ENDIF}

function MakeEncryption(const Cipher: string; const Password: RawByteString;
                        out ArchiveMethod, EncoderMethod: string): Boolean;
var
  par: TCryptParams;
  salt, iv, dk, key, check: array of Byte;
  ksz: Integer;
  base: string;
begin
  Result := False;
  ArchiveMethod := ''; EncoderMethod := '';
  par := ParseCryptParams(Cipher.Split([':']));
  if (par.KeySize < 1) or (par.IVSize < 1) then Exit;
  ksz := par.KeySize;
  SetLength(salt, ksz);
  SetLength(iv, par.IVSize);
  if not OsRandom(PByte(@salt[0]), ksz) then Exit;
  if not OsRandom(PByte(@iv[0]), par.IVSize) then Exit;
  SetLength(dk, ksz + 2);
  if Length(Password) > 0 then
    Pbkdf2HmacSha512(PByte(@Password[1]), Length(Password), PByte(@salt[0]), ksz,
                     par.NumIterations, PByte(@dk[0]), ksz + 2)
  else
    Pbkdf2HmacSha512(nil, 0, PByte(@salt[0]), ksz,
                     par.NumIterations, PByte(@dk[0]), ksz + 2);
  key := Copy(dk, 0, ksz);
  check := Copy(dk, ksz, 2);
  base := par.Cipher + '-' + IntToStr(ksz * 8) + '/' + par.Mode +
          ':n' + IntToStr(par.NumIterations) + ':r' + IntToStr(par.Rounds);
  ArchiveMethod := base + ':s' + EncodeHex(salt, ksz) + ':c' + EncodeHex(check, 2) +
                   ':i' + EncodeHex(iv, par.IVSize);
  EncoderMethod := base + ':k' + EncodeHex(key, ksz) + ':i' + EncodeHex(iv, par.IVSize);
  Result := True;
end;


{ --- TEncryptStage ------------------------------------------------------- }

constructor TEncryptStage.Create(ATarget: TOutStage; const APar: TCryptParams);
var
  i: Integer;
  h: string;
begin
  if (APar.KeySize < 1) or (APar.IVSize < 1) then
    Corrupt('parámetros de cifrado inválidos');
  if APar.KeyHex = '' then Corrupt('el cifrado del encoder necesita :k');
  FPar := APar;
  SetLength(FKey, APar.KeySize);
  { El :k viene en hex NORMAL (lo escribe MakeEncryption) y se decodifica con el
    conversor BUGGY, igual que en el decoder: de ahí sale la clave EFECTIVA. }
  h := APar.KeyHex;
  if Length(h) div 2 < APar.KeySize then Corrupt('clave :k demasiado corta');
  for i := 0 to APar.KeySize - 1 do
    FKey[i] := Byte(BuggyHexVal(h[i * 2 + 1]) * 16 + BuggyHexVal(h[i * 2 + 2]));
  FBlockSize := CipherBlockSize(APar.Cipher);
  if FBlockSize > 16 then FBlockSize := 16;
  if APar.Cipher = 'aes' then
  begin
    AesInit;
    AesSetKeyEnc(@FRk[0], @FKey[0], APar.KeySize);
  end
  else if APar.Cipher = 'blowfish' then BlowfishSetup(@FKey[0], APar.KeySize)
  else if APar.Cipher = 'serpent'  then SerpentSetup(@FKey[0], APar.KeySize)
  else if APar.Cipher = 'twofish'  then TwofishSetup(@FKey[0], APar.KeySize)
  else
    Corrupt('cifrado no soportado: ' + APar.Cipher);
  if Length(APar.IVHex) < APar.IVSize * 2 then Corrupt('falta el :i');
  for i := 0 to APar.IVSize - 1 do
    FIV[i] := Byte(BuggyHexVal(APar.IVHex[i * 2 + 1]) * 16 + BuggyHexVal(APar.IVHex[i * 2 + 2]));
  for i := 0 to 15 do FCounter[i] := FIV[i];
  inherited Create(ATarget);
  ModeStart;
end;

function TEncryptStage.BlockEncrypt(const Src: array of Byte; var Dst: array of Byte): Boolean;
var
  s, d: array[0..3] of LongWord;
  i: Integer;
begin
  if FPar.Cipher = 'blowfish' then begin BlowfishEnc(@Src[0], @Dst[0]); Exit(True); end;
  if FPar.Cipher = 'serpent'  then begin SerpentEnc(@Src[0], @Dst[0]);  Exit(True); end;
  if FPar.Cipher = 'twofish'  then begin TwofishEnc(@Src[0], @Dst[0]);  Exit(True); end;
  for i := 0 to 3 do
    s[i] := LongWord(Src[i * 4]) or (LongWord(Src[i * 4 + 1]) shl 8) or
            (LongWord(Src[i * 4 + 2]) shl 16) or (LongWord(Src[i * 4 + 3]) shl 24);
  AesEncode(@FRk[0], @d[0], @s[0]);
  for i := 0 to 3 do
  begin
    Dst[i * 4]     := Byte(d[i] and $FF);
    Dst[i * 4 + 1] := Byte((d[i] shr 8) and $FF);
    Dst[i * 4 + 2] := Byte((d[i] shr 16) and $FF);
    Dst[i * 4 + 3] := Byte((d[i] shr 24) and $FF);
  end;
  Result := True;
end;

procedure TEncryptStage.ModeStart;
begin
  BlockEncrypt(FCounter, FPad);       { CTR: keystream del bloque 0 = E(IV) }
  if FPar.Mode = 'cfb' then
    BlockEncrypt(FIV, FPad);          { CFB: keystream del 1er bloque = E(IV) }
  FPadLen := 0;
end;

procedure TEncryptStage.ModeEncrypt(Src, Dst: PByte; Len: SizeInt);
var
  i, j: Integer;
  c: Byte;
begin
  for i := 0 to Len - 1 do
  begin
    if FPadLen = FBlockSize then
    begin
      if FPar.Mode = 'ctr' then
      begin
        j := 0;
        while j < FBlockSize do
        begin
          FCounter[j] := Byte(FCounter[j] + 1);
          if FCounter[j] <> 0 then Break;
          Inc(j);
        end;
        BlockEncrypt(FCounter, FPad);
      end
      else
        BlockEncrypt(FEmit, FPad);   { CFB: realimenta el TEXTO CIFRADO }
      FPadLen := 0;
    end;
    c := Src[i] xor FPad[FPadLen];
    Dst[i] := c;
    if FPar.Mode = 'cfb' then FEmit[FPadLen] := c;
    Inc(FPadLen);
  end;
end;

procedure TEncryptStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  // Cifrar en un buffer propio: una etapa no modifica lo que le pasan (el llamador puede
  // reusar el buffer, p. ej. el writer ya calculó el CRC sobre él)
  if Length(FOut) = 0 then SetLength(FOut, 1 shl 16);
  while Count > 0 do
  begin
    n := Count;
    if n > Length(FOut) then n := Length(FOut);
    ModeEncrypt(Buf, @FOut[0], n);
    Emit(@FOut[0], n);
    Inc(Buf, n);
    Dec(Count, n);
  end;
end;

function EncryptBuffer(const Par: TCryptParams; const Pwd: PByte; PwdLen: SizeInt;
                       Src: PByte; Len: SizeInt; Dest: PByte): Boolean;
var
  p: TCryptParams;
  key: array of Byte;
  sink: TMemSink;
  st: TEncryptStage;
  d: TBytes;
begin
  Result := False;
  if Len = 0 then Exit(True);
  p := Par;
  if p.KeyHex = '' then
  begin
    SetLength(key, p.KeySize);
    if not DeriveKeyAndCheck(p, Pwd, PwdLen, @key[0]) then Exit;
    p.KeyHex := EncodeHex(key, p.KeySize);
  end;
  sink := TMemSink.Create;
  st := TEncryptStage.Create(sink, p);
  try
    st.Write(Src, Len);
    st.Finish;
    d := sink.Bytes;
  finally
    st.Free;      { libera también el sink }
  end;
  if Length(d) <> Len then Exit;
  Move(d[0], Dest^, Len);
  Result := True;
end;


end.
