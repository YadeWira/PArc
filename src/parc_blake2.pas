{ parc_blake2 — BLAKE2b (RFC 7693) y Argon2 (RFC 9106: Argon2d, Argon2i y Argon2id, versión 0x13).

  Código propio escrito a partir de los RFC. BLAKE2b se usa para derivar las subclaves del
  cifrado (modo con clave) y dentro de Argon2 (H, H' y la función de compresión G, que es la
  ronda de BLAKE2b sin mensaje con la multiplicación de BlaMka).

  Argon2: los carriles (lanes) de cada rebanada (slice) son independientes, así que se
  calculan en hasta Threads hilos; el resultado no depende de cuántos hilos se usen.
  Memoria: m' = 4·p·floor(m / 4p) bloques de 1 KiB. }
unit parc_blake2;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils;

type
  TBlake2b = record
    H: array[0..7] of QWord;
    T0, T1: QWord;                   // contador de bytes (128 bits)
    Buf: array[0..127] of Byte;
    BufLen: Integer;
    OutLen: Integer;
  end;

{ BLAKE2b con salida de OutLen (1..64) bytes y clave opcional (KeyLen 0..64). }
procedure Blake2bInit(out S: TBlake2b; OutLen: Integer; Key: PByte = nil; KeyLen: Integer = 0);
procedure Blake2bUpdate(var S: TBlake2b; Data: PByte; Len: SizeInt);
procedure Blake2bFinal(var S: TBlake2b; Digest: PByte);
procedure Blake2b(Digest: PByte; OutLen: Integer; Data: PByte; Len: SizeInt;
                  Key: PByte = nil; KeyLen: Integer = 0);

type
  TArgon2Type = (a2d = 0, a2i = 1, a2id = 2);

  EArgon2 = class(Exception);

{ Argon2 (RFC 9106 §3) con salida de TagLen bytes. MemKiB = m (KiB), Passes = t, Lanes = p.
  Secret (K) y AD (X) son opcionales (PArc no los usa; están para los vectores del RFC).
  Threads: cuántos carriles se calculan a la vez (1 = todo en este hilo). Lanza EArgon2 si
  los parámetros son inválidos y EOutOfMemory si no se puede reservar la memoria. }
procedure Argon2(Kind: TArgon2Type; Pwd: PByte; PwdLen: SizeInt; Salt: PByte; SaltLen: SizeInt;
                 Passes, MemKiB, Lanes: LongWord; Tag: PByte; TagLen: LongWord;
                 Secret: PByte = nil; SecretLen: SizeInt = 0; AD: PByte = nil; ADLen: SizeInt = 0;
                 Threads: Integer = 1);

implementation

const
  B2IV: array[0..7] of QWord = (
    QWord($6a09e667f3bcc908), QWord($bb67ae8584caa73b), QWord($3c6ef372fe94f82b), QWord($a54ff53a5f1d36f1),
    QWord($510e527fade682d1), QWord($9b05688c2b3e6c1f), QWord($1f83d9abfb41bd6b), QWord($5be0cd19137e2179));

  B2Sigma: array[0..11, 0..15] of Byte = (
    ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15),
    (14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3),
    (11,  8, 12,  0,  5,  2, 15, 13, 10, 14,  3,  6,  7,  1,  9,  4),
    ( 7,  9,  3,  1, 13, 12, 11, 14,  2,  6,  5, 10,  4,  0, 15,  8),
    ( 9,  0,  5,  7,  2,  4, 10, 15, 14,  1, 11, 12,  6,  8,  3, 13),
    ( 2, 12,  6, 10,  0, 11,  8,  3,  4, 13,  7,  5, 15, 14,  1,  9),
    (12,  5,  1, 15, 14, 13,  4, 10,  0,  7,  6,  3,  9,  2,  8, 11),
    (13, 11,  7, 14, 12,  1,  3,  9,  5,  0, 15,  4,  8,  6,  2, 10),
    ( 6, 15, 14,  9, 11,  3,  0,  8, 12,  2, 13,  7,  1,  4, 10,  5),
    (10,  2,  8,  4,  7,  6,  1,  5, 15, 11,  9, 14,  3, 12, 13,  0),
    ( 0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15),
    (14, 10,  4,  8,  9, 15, 13,  6,  1, 12,  0,  2, 11,  7,  5,  3));

function Ror64(x: QWord; n: Integer): QWord; inline;
begin
  Result := (x shr n) or (x shl (64 - n));
end;

function LoadLE64(p: PByte): QWord; inline;
begin
  {$IFDEF ENDIAN_LITTLE}
  Result := PQWord(p)^;
  {$ELSE}
  Result := QWord(p[0]) or (QWord(p[1]) shl 8) or (QWord(p[2]) shl 16) or (QWord(p[3]) shl 24) or
            (QWord(p[4]) shl 32) or (QWord(p[5]) shl 40) or (QWord(p[6]) shl 48) or (QWord(p[7]) shl 56);
  {$ENDIF}
end;

procedure StoreLE64(p: PByte; v: QWord); inline;
var
  i: Integer;
begin
  for i := 0 to 7 do begin p[i] := Byte(v); v := v shr 8; end;
end;

procedure StoreLE32(p: PByte; v: LongWord); inline;
begin
  p[0] := Byte(v); p[1] := Byte(v shr 8); p[2] := Byte(v shr 16); p[3] := Byte(v shr 24);
end;

{ ----------------------------------------------------------------------------- BLAKE2b }

procedure Blake2bCompress(var S: TBlake2b; Block: PByte; Last: Boolean);
var
  m: array[0..15] of QWord;
  v: array[0..15] of QWord;
  i, r: Integer;

  procedure G(a, b, c, d: Integer; x, y: QWord); inline;
  begin
    v[a] := v[a] + v[b] + x;  v[d] := Ror64(v[d] xor v[a], 32);
    v[c] := v[c] + v[d];      v[b] := Ror64(v[b] xor v[c], 24);
    v[a] := v[a] + v[b] + y;  v[d] := Ror64(v[d] xor v[a], 16);
    v[c] := v[c] + v[d];      v[b] := Ror64(v[b] xor v[c], 63);
  end;

begin
  for i := 0 to 15 do m[i] := LoadLE64(Block + 8 * i);
  for i := 0 to 7 do begin v[i] := S.H[i]; v[i + 8] := B2IV[i]; end;
  v[12] := v[12] xor S.T0;
  v[13] := v[13] xor S.T1;
  if Last then v[14] := not v[14];
  for r := 0 to 11 do
  begin
    G(0, 4,  8, 12, m[B2Sigma[r, 0]], m[B2Sigma[r, 1]]);
    G(1, 5,  9, 13, m[B2Sigma[r, 2]], m[B2Sigma[r, 3]]);
    G(2, 6, 10, 14, m[B2Sigma[r, 4]], m[B2Sigma[r, 5]]);
    G(3, 7, 11, 15, m[B2Sigma[r, 6]], m[B2Sigma[r, 7]]);
    G(0, 5, 10, 15, m[B2Sigma[r, 8]], m[B2Sigma[r, 9]]);
    G(1, 6, 11, 12, m[B2Sigma[r, 10]], m[B2Sigma[r, 11]]);
    G(2, 7,  8, 13, m[B2Sigma[r, 12]], m[B2Sigma[r, 13]]);
    G(3, 4,  9, 14, m[B2Sigma[r, 14]], m[B2Sigma[r, 15]]);
  end;
  for i := 0 to 7 do S.H[i] := S.H[i] xor v[i] xor v[i + 8];
end;

procedure Blake2bInit(out S: TBlake2b; OutLen: Integer; Key: PByte; KeyLen: Integer);
var
  i: Integer;
begin
  if (OutLen < 1) or (OutLen > 64) or (KeyLen < 0) or (KeyLen > 64) then
    raise Exception.Create('blake2b: invalid parameters');
  for i := 0 to 7 do S.H[i] := B2IV[i];
  S.H[0] := S.H[0] xor $01010000 xor (QWord(KeyLen) shl 8) xor QWord(OutLen);
  S.T0 := 0; S.T1 := 0;
  S.BufLen := 0;
  S.OutLen := OutLen;
  FillChar(S.Buf, SizeOf(S.Buf), 0);
  if KeyLen > 0 then
  begin
    // la clave, rellenada con ceros a un bloque entero, es el primer bloque del mensaje
    Move(Key^, S.Buf[0], KeyLen);
    S.BufLen := 128;
  end;
end;

procedure Blake2bUpdate(var S: TBlake2b; Data: PByte; Len: SizeInt);
var
  n: SizeInt;
begin
  while Len > 0 do
  begin
    // el último bloque se guarda hasta Final (lleva la marca de fin): solo se comprime un
    // bloque lleno cuando llegan más bytes
    if S.BufLen = 128 then
    begin
      Inc(S.T0, 128);
      if S.T0 < 128 then Inc(S.T1);
      Blake2bCompress(S, @S.Buf[0], False);
      S.BufLen := 0;
    end;
    n := 128 - S.BufLen;
    if n > Len then n := Len;
    Move(Data^, S.Buf[S.BufLen], n);
    Inc(S.BufLen, n);
    Inc(Data, n);
    Dec(Len, n);
  end;
end;

procedure Blake2bFinal(var S: TBlake2b; Digest: PByte);
var
  Full: array[0..63] of Byte;
  i: Integer;
begin
  Inc(S.T0, S.BufLen);
  if S.T0 < QWord(S.BufLen) then Inc(S.T1);
  FillChar(S.Buf[S.BufLen], 128 - S.BufLen, 0);
  Blake2bCompress(S, @S.Buf[0], True);
  for i := 0 to 7 do StoreLE64(@Full[8 * i], S.H[i]);
  Move(Full[0], Digest^, S.OutLen);
  FillChar(Full, SizeOf(Full), 0);
  FillChar(S, SizeOf(S), 0);
end;

procedure Blake2b(Digest: PByte; OutLen: Integer; Data: PByte; Len: SizeInt; Key: PByte; KeyLen: Integer);
var
  S: TBlake2b;
begin
  Blake2bInit(S, OutLen, Key, KeyLen);
  Blake2bUpdate(S, Data, Len);
  Blake2bFinal(S, Digest);
end;

{ ------------------------------------------------------------------------------ Argon2 }

const
  ARGON2_VERSION = $13;
  BLOCK_QWORDS = 128;           // 1 KiB
  SYNC_POINTS = 4;              // rebanadas por pasada

type
  TA2Block = array[0..BLOCK_QWORDS - 1] of QWord;
  PA2Block = ^TA2Block;

{ H' (RFC 9106 §3.3): hash de largo variable. }
procedure HPrime(Out_: PByte; OutLen: LongWord; In_: PByte; InLen: SizeInt);
var
  S: TBlake2b;
  L: array[0..3] of Byte;
  V: array[0..63] of Byte;
  r, i: LongWord;
begin
  StoreLE32(@L[0], OutLen);
  if OutLen <= 64 then
  begin
    Blake2bInit(S, OutLen);
    Blake2bUpdate(S, @L[0], 4);
    Blake2bUpdate(S, In_, InLen);
    Blake2bFinal(S, Out_);
    Exit;
  end;
  r := (OutLen + 31) div 32 - 2;
  Blake2bInit(S, 64);
  Blake2bUpdate(S, @L[0], 4);
  Blake2bUpdate(S, In_, InLen);
  Blake2bFinal(S, @V[0]);
  Move(V[0], Out_^, 32);
  for i := 2 to r do
  begin
    Blake2b(@V[0], 64, @V[0], 64);
    Move(V[0], Out_[32 * (i - 1)], 32);
  end;
  Blake2b(Out_ + 32 * r, OutLen - 32 * r, @V[0], 64);
  FillChar(V, SizeOf(V), 0);
end;

function BlaMka(x, y: QWord): QWord; inline;
begin
  Result := x + y + 2 * (QWord(LongWord(x)) * QWord(LongWord(y)));
end;

{ GB de RFC 9106 §3.6 sobre cuatro palabras del bloque. }
procedure GB(var a, b, c, d: QWord); inline;
begin
  a := BlaMka(a, b);  d := Ror64(d xor a, 32);
  c := BlaMka(c, d);  b := Ror64(b xor c, 24);
  a := BlaMka(a, b);  d := Ror64(d xor a, 16);
  c := BlaMka(c, d);  b := Ror64(b xor c, 63);
end;

{ La permutación P sobre 16 palabras dadas por sus índices en R (dos por registro de 16 bytes). }
procedure PermP(R: PQWord; i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15: Integer); inline;
begin
  GB(R[i0], R[i4], R[i8],  R[i12]);
  GB(R[i1], R[i5], R[i9],  R[i13]);
  GB(R[i2], R[i6], R[i10], R[i14]);
  GB(R[i3], R[i7], R[i11], R[i15]);
  GB(R[i0], R[i5], R[i10], R[i15]);
  GB(R[i1], R[i6], R[i11], R[i12]);
  GB(R[i2], R[i7], R[i8],  R[i13]);
  GB(R[i3], R[i4], R[i9],  R[i14]);
end;

{ Next := G(Prev, Ref) (xor Next si WithXor: pasadas > 0 de la versión 0x13). }
procedure FillBlock(Prev, Ref, Next: PA2Block; WithXor: Boolean);
var
  R, Tmp: TA2Block;
  i: Integer;
  p: PQWord;
begin
  for i := 0 to BLOCK_QWORDS - 1 do R[i] := Ref^[i] xor Prev^[i];
  if WithXor then
    for i := 0 to BLOCK_QWORDS - 1 do Tmp[i] := R[i] xor Next^[i]
  else
    Tmp := R;
  // filas: 8 de 16 palabras seguidas
  for i := 0 to 7 do
  begin
    p := @R[16 * i];
    PermP(p, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);
  end;
  // columnas: 8 de dos palabras por fila
  for i := 0 to 7 do
  begin
    p := @R[2 * i];
    PermP(p, 0, 1, 16, 17, 32, 33, 48, 49, 64, 65, 80, 81, 96, 97, 112, 113);
  end;
  for i := 0 to BLOCK_QWORDS - 1 do Next^[i] := Tmp[i] xor R[i];
end;

type
  TArgon2Ctx = record
    Mem: PA2Block;
    LaneLen, SegLen, MemBlocks, Lanes, Passes: LongWord;
    Kind: TArgon2Type;
  end;
  PArgon2Ctx = ^TArgon2Ctx;

function IndexAlpha(const C: TArgon2Ctx; Pass, Slice, Index: LongWord; Pseudo: LongWord;
  SameLane: Boolean): LongWord;
var
  Area, Start: LongWord;
  Rel: QWord;
begin
  if Pass = 0 then
  begin
    if Slice = 0 then Area := Index - 1
    else if SameLane then Area := Slice * C.SegLen + Index - 1
    else if Index = 0 then Area := Slice * C.SegLen - 1
    else Area := Slice * C.SegLen;
  end
  else
  begin
    if SameLane then Area := C.LaneLen - C.SegLen + Index - 1
    else if Index = 0 then Area := C.LaneLen - C.SegLen - 1
    else Area := C.LaneLen - C.SegLen;
  end;
  Rel := Pseudo;
  Rel := (Rel * Rel) shr 32;
  Rel := Area - 1 - ((QWord(Area) * Rel) shr 32);
  if (Pass <> 0) and (Slice <> SYNC_POINTS - 1) then Start := (Slice + 1) * C.SegLen
  else Start := 0;
  Result := LongWord((Start + Rel) mod C.LaneLen);
end;

procedure FillSegment(const C: TArgon2Ctx; Pass, Lane, Slice: LongWord);
var
  Indep: Boolean;
  Zero, Input, Addr: TA2Block;
  StartIdx, i, CurOff, PrevOff, RefLane, RefIdx: LongWord;
  Pseudo: QWord;
begin
  Indep := (C.Kind = a2i) or ((C.Kind = a2id) and (Pass = 0) and (Slice < SYNC_POINTS div 2));
  if Indep then
  begin
    FillChar(Zero, SizeOf(Zero), 0);
    FillChar(Input, SizeOf(Input), 0);
    Input[0] := Pass; Input[1] := Lane; Input[2] := Slice; Input[3] := C.MemBlocks;
    Input[4] := C.Passes; Input[5] := Ord(C.Kind);
  end;
  StartIdx := 0;
  if (Pass = 0) and (Slice = 0) then
  begin
    StartIdx := 2;
    if Indep then
    begin
      Inc(Input[6]);
      FillBlock(@Zero, @Input, @Addr, False);
      FillBlock(@Zero, @Addr, @Addr, False);
    end;
  end;
  CurOff := Lane * C.LaneLen + Slice * C.SegLen + StartIdx;
  if CurOff mod C.LaneLen = 0 then PrevOff := CurOff + C.LaneLen - 1
  else PrevOff := CurOff - 1;
  for i := StartIdx to C.SegLen - 1 do
  begin
    if CurOff mod C.LaneLen = 1 then PrevOff := CurOff - 1;
    if Indep then
    begin
      if i mod BLOCK_QWORDS = 0 then
      begin
        Inc(Input[6]);
        FillBlock(@Zero, @Input, @Addr, False);
        FillBlock(@Zero, @Addr, @Addr, False);
      end;
      Pseudo := Addr[i mod BLOCK_QWORDS];
    end
    else
      Pseudo := C.Mem[PrevOff][0];
    RefLane := LongWord(Pseudo shr 32) mod C.Lanes;
    if (Pass = 0) and (Slice = 0) then RefLane := Lane;
    RefIdx := IndexAlpha(C, Pass, Slice, i, LongWord(Pseudo), RefLane = Lane);
    FillBlock(@C.Mem[PrevOff], @C.Mem[C.LaneLen * RefLane + RefIdx], @C.Mem[CurOff], Pass <> 0);
    Inc(CurOff);
    Inc(PrevOff);
  end;
end;

type
  { Lo que calcula un hilo: los segmentos de un grupo de carriles en una rebanada. }
  TLaneJob = record
    Ctx: PArgon2Ctx;
    Pass, Slice, LaneFrom, LaneTo: LongWord;
  end;
  PLaneJob = ^TLaneJob;

{ (BeginThread + WaitForThreadTerminate: TThread.WaitFor en el hilo principal espera de a
  100 ms revisando Synchronize, y eso costaba ~1 s en los 12 puntos de sincronización) }
function LaneThread(P: Pointer): PtrInt;
var
  l: LongWord;
begin
  with PLaneJob(P)^ do
    for l := LaneFrom to LaneTo do FillSegment(Ctx^, Pass, l, Slice);
  Result := 0;
end;

procedure Argon2(Kind: TArgon2Type; Pwd: PByte; PwdLen: SizeInt; Salt: PByte; SaltLen: SizeInt;
                 Passes, MemKiB, Lanes: LongWord; Tag: PByte; TagLen: LongWord;
                 Secret: PByte; SecretLen: SizeInt; AD: PByte; ADLen: SizeInt; Threads: Integer);
var
  H: TBlake2b;
  H0: array[0..71] of Byte;    // H0 (64) + LE32(columna) + LE32(carril)
  W: array[0..3] of Byte;
  C: TArgon2Ctx;
  Raw: Pointer;
  Blk: array[0..1023] of Byte;
  Acc: TA2Block;
  l, Pass, Slice, i, Per: LongWord;
  Jobs: array of TLaneJob;
  Th: array of TThreadID;
  n, k: Integer;

  procedure U32(v: LongWord);
  begin
    StoreLE32(@W[0], v);
    Blake2bUpdate(H, @W[0], 4);
  end;

begin
  if (Lanes < 1) or (Lanes > $FFFFFF) or (Passes < 1) or (TagLen < 4) or
     (MemKiB < 8 * Lanes) or (SaltLen < 8) then
    raise EArgon2.Create('argon2: invalid parameters');
  // H0 (§3.2)
  Blake2bInit(H, 64);
  U32(Lanes); U32(TagLen); U32(MemKiB); U32(Passes); U32(ARGON2_VERSION); U32(Ord(Kind));
  U32(PwdLen);    Blake2bUpdate(H, Pwd, PwdLen);
  U32(SaltLen);   Blake2bUpdate(H, Salt, SaltLen);
  U32(SecretLen); Blake2bUpdate(H, Secret, SecretLen);
  U32(ADLen);     Blake2bUpdate(H, AD, ADLen);
  Blake2bFinal(H, @H0[0]);

  C.Kind := Kind;
  C.Lanes := Lanes;
  C.Passes := Passes;
  C.MemBlocks := 4 * Lanes * (MemKiB div (4 * Lanes));
  C.LaneLen := C.MemBlocks div Lanes;
  C.SegLen := C.LaneLen div SYNC_POINTS;
  Raw := GetMem(QWord(C.MemBlocks) * 1024 + 63);
  if Raw = nil then OutOfMemoryError;
  try
    C.Mem := PA2Block((PtrUInt(Raw) + 63) and not PtrUInt(63));
    // las dos primeras columnas de cada carril
    for l := 0 to Lanes - 1 do
      for i := 0 to 1 do
      begin
        StoreLE32(@H0[64], i);
        StoreLE32(@H0[68], l);
        HPrime(@Blk[0], 1024, @H0[0], 72);
        for k := 0 to BLOCK_QWORDS - 1 do C.Mem[l * C.LaneLen + i][k] := LoadLE64(@Blk[8 * k]);
      end;
    FillChar(H0, SizeOf(H0), 0);

    if Threads > Integer(Lanes) then Threads := Lanes;
    if Threads < 1 then Threads := 1;
    Per := (Lanes + LongWord(Threads) - 1) div LongWord(Threads);
    for Pass := 0 to Passes - 1 do
      for Slice := 0 to SYNC_POINTS - 1 do
        if Threads = 1 then
          for l := 0 to Lanes - 1 do FillSegment(C, Pass, l, Slice)
        else
        begin
          // un hilo por grupo de carriles; esperar a todos es el punto de sincronización
          SetLength(Th, Threads);
          SetLength(Jobs, Threads);
          n := 0;
          l := 0;
          try
            while l < Lanes do
            begin
              Jobs[n].Ctx := @C;
              Jobs[n].Pass := Pass;
              Jobs[n].Slice := Slice;
              Jobs[n].LaneFrom := l;
              if l + Per - 1 < Lanes then Jobs[n].LaneTo := l + Per - 1 else Jobs[n].LaneTo := Lanes - 1;
              Inc(l, Per);
              if l >= Lanes then
                LaneThread(@Jobs[n])   // el último grupo, en este hilo
              else
              begin
                Th[n] := BeginThread(@LaneThread, @Jobs[n]);
                if Th[n] = TThreadID(0) then LaneThread(@Jobs[n])   // sin hilo: acá mismo
                else Inc(n);
              end;
            end;
          finally
            for k := 0 to n - 1 do
            begin
              WaitForThreadTerminate(Th[k], 0);
              CloseThread(Th[k]);
            end;
          end;
        end;

    // C = xor de la última columna; la etiqueta es H'(C)
    Acc := C.Mem[C.LaneLen - 1];
    for l := 1 to Lanes - 1 do
      for k := 0 to BLOCK_QWORDS - 1 do Acc[k] := Acc[k] xor C.Mem[l * C.LaneLen + C.LaneLen - 1][k];
    for k := 0 to BLOCK_QWORDS - 1 do StoreLE64(@Blk[8 * k], Acc[k]);
    HPrime(Tag, TagLen, @Blk[0], 1024);
  finally
    FillChar(C.Mem^, QWord(C.MemBlocks) * 1024, 0);
    FreeMem(Raw);
    FillChar(Blk, SizeOf(Blk), 0);
    FillChar(Acc, SizeOf(Acc), 0);
  end;
end;

end.
