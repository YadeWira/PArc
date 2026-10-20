{ SREP 3.93 (Compression/SREP/srep.cpp): preprocesador LZ77 de Bulat Ziganshin.
  Decodificador de los formatos v1/v2 (I/O LZ) y v3 (Future-LZ), que es el que produce FreeArc
  con el `-m3f` de arc.ini. v4 (Index-LZ) todavía no.

  Bloque: [compsize][origsize][statsize][hash] + statsize bytes de STATs + compsize bytes de
  literales. En v3 cada STAT es (lit_len, offset_lo, offset_hi, len_code); un match puede tener
  su destino en un bloque posterior ("future"), así que se guarda y se aplica cuando llega su
  bloque. Acá se decodifica todo en un buffer (el tamaño lo declara el stream). }
unit parc_srep;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, parc_stream, parc_bytes;

const
  SREP_SIGNATURE = $50455253;        // 'SREP'
  SREP_BULAT     = $26351817;

{ Versión del stream (1..3), -1 si no es srep, 4 si es Index-LZ (todavía sin soporte). }
function SrepStreamVersion(Src: PByte; SrcLen: Integer): Integer;

{ Tamaño descomprimido que declara el stream (-1 si no se puede leer). }
function SrepDecodedSize(Src: PByte; SrcLen: Integer): Int64;

{ Descomprime un stream srep completo (v1..v3). DstLen tiene que ser el tamaño original. }
function SrepDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Int64): Boolean;

{ Comprime con el formato v3 (Future-LZ) que usa FreeArc: matches de al menos BASE_LEN
  bytes, agrupados por el bloque de su origen. Devuelve el stream srep. }
function SrepEncode(Src: PByte; SrcLen: Int64): TBytes;

type
  { Descomprime un bloque srep como stream. }
  TSrepStage = class(TInStage)
  private
    FOut: TBytes;
    FPos: Integer;
  public
    constructor Create(ASource: TInStage);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

type
  TSrepMatch = record
    Dest, Src, Len: Int64;
  end;

  TMatchHeap = record
    Items: array of TSrepMatch;
    Count: Integer;
  end;

procedure HeapPush(var H: TMatchHeap; const M: TSrepMatch);
var
  i, p: Integer;
  T: TSrepMatch;
begin
  if H.Count = Length(H.Items) then
    SetLength(H.Items, H.Count * 2 + 16);
  i := H.Count;
  H.Items[i] := M;
  Inc(H.Count);
  while i > 0 do
  begin
    p := (i - 1) div 2;
    if H.Items[p].Dest <= H.Items[i].Dest then Break;
    T := H.Items[p]; H.Items[p] := H.Items[i]; H.Items[i] := T;
    i := p;
  end;
end;

function HeapPop(var H: TMatchHeap): TSrepMatch;
var
  i, c: Integer;
  T: TSrepMatch;
begin
  Result := H.Items[0];
  Dec(H.Count);
  H.Items[0] := H.Items[H.Count];
  i := 0;
  while True do
  begin
    c := i * 2 + 1;
    if c >= H.Count then Break;
    if (c + 1 < H.Count) and (H.Items[c + 1].Dest < H.Items[c].Dest) then Inc(c);
    if H.Items[i].Dest <= H.Items[c].Dest then Break;
    T := H.Items[i]; H.Items[i] := H.Items[c]; H.Items[c] := T;
    i := c;
  end;
end;

function LoadU32(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function SrepStreamVersion(Src: PByte; SrcLen: Integer): Integer;
var
  Start: Integer;
begin
  Result := -1;
  if (SrcLen >= 4) and (LoadU32(Src) = SREP_BULAT) then Start := 0
  else if (SrcLen >= 5) and (Src[0] = 1) and (LoadU32(Src + 1) = SREP_BULAT) then Start := 1
  else Exit;
  if SrcLen < Start + 16 then Exit;
  if (LoadU32(Src + Start + 4) <> SREP_SIGNATURE) then Exit;
  Result := Integer(LoadU32(Src + Start + 8)) and 255;
end;

{ Cabecera común: devuelve la versión (1..4) y deja Start (0 = .srep, 1 = bloque de .arc),
  HashSize y Seed. -1 si no es un stream srep. }
function SrepHeader(Src: PByte; SrcLen: Integer; out Ver, Start, HashSize, Seed: Integer): Boolean;
var
  H: LongWord;
begin
  Result := False;
  if (SrcLen >= 4) and (LoadU32(Src) = SREP_BULAT) then Start := 0
  else if SrcLen >= 1 then
  begin
    if Src[0] = 0 then Exit;                       // bloque "guardado tal cual"
    if (SrcLen >= 5) and (LoadU32(Src + 1) = SREP_BULAT) then Start := 1
    else Exit;
  end
  else Exit;
  if SrcLen < Start + 16 then Exit;
  if LoadU32(Src + Start + 4) <> SREP_SIGNATURE then Exit;
  H := LoadU32(Src + Start + 8);
  Ver := H and 255;
  if (Ver < 1) or (Ver > 4) then Exit;
  Seed := (H shr 16) and 255;
  HashSize := ((H shr 24) + 16) and 255;
  Result := True;
end;

{ Datos del footer del v4 (Index-LZ). }
function SrepV4Footer(Src: PByte; SrcLen, Start, Seed: Integer;
  out StatSize, FooterSize: Int64; out BlockCount: Integer): Boolean;
var
  F: Integer;
begin
  Result := False;
  if SrcLen < Start + 16 + 24 then Exit;
  F := SrcLen - 24;
  StatSize := Int64(LoadU32(Src + F)) + (Int64(LoadU32(Src + F + 4)) shl 32);
  FooterSize := LoadU32(Src + F + 8);
  if (LoadU32(Src + F + 12) and 255) <> 1 then Exit;
  if (LoadU32(Src + F + 16) <> LongWord(not SREP_SIGNATURE)) or
     (LoadU32(Src + F + 20) <> LongWord(not SREP_BULAT)) then Exit;
  if (FooterSize < 24) or (StatSize < 0) then Exit;
  if Int64(Start) + 16 + Seed + FooterSize + StatSize > SrcLen then Exit;
  if (FooterSize - 24) mod 4 <> 0 then Exit;
  BlockCount := (FooterSize - 24) div 4;
  Result := True;
end;

function SrepDecodedSize(Src: PByte; SrcLen: Integer): Int64;
var
  Ver, Start, HashSize, Seed, Hdr, Pos, I: Integer;
  Comp, Orig: LongWord;
  StatSize, FooterSize: Int64;
  BlockCount: Integer;
begin
  Result := -1;
  if SrcLen < 1 then Exit;
  if Src[0] = 0 then Exit(SrcLen - 1);            // bloque guardado tal cual
  if not SrepHeader(Src, SrcLen, Ver, Start, HashSize, Seed) then Exit;
  Hdr := 12 + HashSize;
  Pos := Start + 16 + Seed;
  Result := 0;
  if Ver = 4 then
  begin
    if not SrepV4Footer(Src, SrcLen, Start, Seed, StatSize, FooterSize, BlockCount) then Exit(-1);
    for I := 0 to BlockCount - 1 do
    begin
      if Pos + Hdr > SrcLen then Exit(-1);
      Comp := LoadU32(Src + Pos);
      Orig := LoadU32(Src + Pos + 4);
      Inc(Pos, Hdr);
      if Int64(Pos) + Int64(Comp) > SrcLen then Exit(-1);
      Inc(Pos, Integer(Comp));
      Inc(Result, Int64(Orig));
    end;
  end
  else
    while Pos + Hdr <= SrcLen do
    begin
      Comp := LoadU32(Src + Pos);
      Orig := LoadU32(Src + Pos + 4);
      Inc(Pos, Hdr);
      if (Comp = 0) and (Orig = 0) then Break;
      if Int64(Pos) + Int64(LoadU32(Src + Pos - Hdr + 8)) + Int64(Comp) > SrcLen then Exit(-1);
      Inc(Pos, Integer(LoadU32(Src + Pos - Hdr + 8)) + Integer(Comp));
      Inc(Result, Int64(Orig));
    end;
end;

function SrepDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Int64): Boolean;
var
  Ver, Start, Seed, HashSize, Hdr, Pos, I, BlockCount: Integer;
  BaseLen: LongWord;
  Comp, Orig, Stat, BlockStat: LongWord;
  OutPos, BlockStart, BlockEnd, StatPos, LitPos, LitAvail, N: Int64;
  L1: Int64;
  RoundMatches, V4: Boolean;
  Heap: TMatchHeap;
  M: TSrepMatch;
  Lit, OffLo, OffHi, LenCode, Offset: Int64;
  Step: Integer;
  StatSize, FooterSize, PixelUnused: Int64;
  V4StatPos, V4StatEnd, V4ListPos: Int64;

  procedure CopyMatch(DestPos, SrcStart, Len: Int64); inline;
  var
    k: Int64;
  begin
    for k := 0 to Len - 1 do
      Dst[DestPos + k] := Dst[SrcStart + k];
  end;

  function StatWord(K: Int64): LongWord; inline;
  begin
    Result := LoadU32(Src + StatPos + K * 4);
  end;

begin
  Result := False;
  if SrcLen < 1 then Exit;
  if Src[0] = 0 then
  begin
    if DstLen <> SrcLen - 1 then Exit;
    if DstLen > 0 then Move(Src[1], Dst[0], DstLen);
    Exit(True);
  end;
  if not SrepHeader(Src, SrcLen, Ver, Start, HashSize, Seed) then Exit;
  BaseLen := LoadU32(Src + Start + 12);
  if BaseLen = 0 then Exit;
  RoundMatches := Ver = 1;
  if RoundMatches then L1 := BaseLen else L1 := 1;
  if RoundMatches then Step := 3 else Step := 4;
  Hdr := 12 + HashSize;
  Pos := Start + 16 + Seed;
  V4 := Ver = 4;

  V4StatPos := 0; V4StatEnd := 0; V4ListPos := 0; BlockCount := 0;
  if V4 then
  begin
    if not SrepV4Footer(Src, SrcLen, Start, Seed, StatSize, FooterSize, BlockCount) then Exit;
    V4ListPos := SrcLen - FooterSize;
    V4StatPos := SrcLen - FooterSize - StatSize;
    V4StatEnd := SrcLen - FooterSize;
    if V4StatPos < Pos then Exit;
    if Int64(BlockCount) * 4 > FooterSize - 24 then Exit;
  end;

  Heap.Count := 0;
  SetLength(Heap.Items, 0);
  OutPos := 0;
  I := 0;

  while True do
  begin
    if V4 then
    begin
      if I >= BlockCount then Break;
      BlockStat := LoadU32(Src + V4ListPos + I * 4);
      Inc(I);
      if Pos + Hdr > SrcLen then Exit;
      Comp := LoadU32(Src + Pos);
      Orig := LoadU32(Src + Pos + 4);
      Inc(Pos, Hdr);
      if Int64(Pos) + Int64(Comp) > SrcLen then Exit;
      if (BlockStat < 0) or (V4StatPos + BlockStat > V4StatEnd) then Exit;
      Stat := BlockStat;
      StatPos := V4StatPos;
      Inc(V4StatPos, BlockStat);
      LitPos := Pos;
      Inc(Pos, Integer(Comp));
    end
    else
    begin
      if Pos + Hdr > SrcLen then Break;
      Comp := LoadU32(Src + Pos);
      Orig := LoadU32(Src + Pos + 4);
      Stat := LoadU32(Src + Pos + 8);
      Inc(Pos, Hdr);
      if (Comp = 0) and (Orig = 0) then Break;
      if (Stat mod 4 <> 0) or (Int64(Pos) + Int64(Stat) + Int64(Comp) > SrcLen) then Exit;
      StatPos := Pos;
      LitPos := Pos + Int64(Stat);
      Inc(Pos, Integer(Stat) + Integer(Comp));
    end;

    BlockStart := OutPos;
    BlockEnd := OutPos + Int64(Orig);
    if BlockEnd > DstLen then Exit;
    LitAvail := Comp;

    if Ver >= 3 then
    begin
      // STATs: matches con origen en este bloque o en uno futuro
      N := Int64(Stat) div 4;
      M.Src := BlockStart;
      Lit := 0;
      while Lit + 4 <= N do
      begin
        { lit_len, offset_lo, offset_hi, len_code }
        Offset := (StatWord(Lit + 1) + (Int64(StatWord(Lit + 2)) shl 32)) * L1;
        M.Dest := M.Src + StatWord(Lit) + Offset;
        M.Len := Int64(StatWord(Lit + 3)) * L1 + BaseLen;
        if (M.Src + StatWord(Lit) < BlockStart) or (M.Src + StatWord(Lit) >= BlockEnd) or
           (M.Len > BlockEnd - (M.Src + StatWord(Lit))) or (M.Dest <= M.Src + StatWord(Lit)) then Exit;
        Inc(M.Src, StatWord(Lit));
        if M.Dest + M.Len > DstLen then Exit;
        HeapPush(Heap, M);
        Inc(Lit, 4);
      end;

      while (Heap.Count > 0) and (Heap.Items[0].Dest < BlockEnd) do
      begin
        M := HeapPop(Heap);
        if (M.Dest < OutPos) or (M.Dest - OutPos > LitAvail) then Exit;
        Lit := M.Dest - OutPos;
        if Lit > 0 then
        begin
          Move(Src[LitPos], Dst[OutPos], Lit);
          Inc(LitPos, Lit); Dec(LitAvail, Lit); Inc(OutPos, Lit);
        end;
        CopyMatch(M.Dest, M.Src, M.Len);
        OutPos := M.Dest + M.Len;
      end;

      if BlockEnd - OutPos <> LitAvail then Exit;
      if LitAvail > 0 then
      begin
        Move(Src[LitPos], Dst[OutPos], LitAvail);
        Inc(OutPos, LitAvail);
      end;
    end
    else
    begin
      // v1/v2: I/O LZ; los matches miran hacia atrás
      N := Int64(Stat) div 4;
      I := 0;
      while I + Step <= N do
      begin
        Lit := StatWord(I);
        OffLo := StatWord(I + 1);
        Inc(I, 2);
        if not RoundMatches then
        begin
          OffHi := StatWord(I);
          Inc(I);
          Inc(OffLo, OffHi shl 32);
        end;
        LenCode := StatWord(I);
        Inc(I);
        M.Dest := OutPos + Lit;
        M.Src := (M.Dest div L1) * L1 - OffLo * L1;
        M.Len := LenCode * L1 + BaseLen;
        if (M.Src < 0) or (M.Src >= M.Dest) or (M.Dest + M.Len > BlockEnd) then Exit;
        if Lit > LitAvail then Exit;
        if Lit > 0 then
        begin
          Move(Src[LitPos], Dst[OutPos], Lit);
          Inc(LitPos, Lit); Dec(LitAvail, Lit); Inc(OutPos, Lit);
        end;
        CopyMatch(M.Dest, M.Src, M.Len);
        OutPos := M.Dest + M.Len;
      end;
      if BlockEnd - OutPos <> LitAvail then Exit;
      if LitAvail > 0 then
      begin
        Move(Src[LitPos], Dst[OutPos], LitAvail);
        Inc(OutPos, LitAvail);
      end;
    end;
  end;

  if V4 then
  begin
    if V4StatPos <> V4StatEnd then Exit;
  end;
  Result := (OutPos = DstLen) and (Heap.Count = 0);
end;

{ TSrepStage }

constructor TSrepStage.Create(ASource: TInStage);
var
  In_: TBytes;
  Cap, N, K: Integer;
  Size: Int64;
begin
  inherited Create(ASource);
  In_ := nil;
  Cap := 64 * 1024;
  SetLength(In_, Cap);
  N := 0;
  while True do
  begin
    if N = Cap then
    begin
      Cap := Cap * 2;
      SetLength(In_, Cap);
    end;
    K := ASource.Read(@In_[N], Cap - N);
    if K <= 0 then Break;
    Inc(N, K);
  end;
  SetLength(In_, N);
  if N = 0 then raise EArcCorrupt.Create('srep: bloque vacío');
  Size := SrepDecodedSize(@In_[0], N);
  if Size < 0 then raise EArcCorrupt.Create('srep: cabecera inválida');
  SetLength(FOut, Integer(Size));
  if not SrepDecode(@In_[0], N, @FOut[0], Size) then
    raise EArcCorrupt.Create('srep: datos dañados');
  FPos := 0;
end;

function TSrepStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := Length(FOut) - FPos;
  if Result > Count then Result := Count;
  if Result > 0 then
  begin
    Move(FOut[FPos], Buf^, Result);
    Inc(FPos, Result);
  end;
end;


{ ---------------------------------------------------------------------------------------- }
{ Codificador (formato v3)                                                                  }
{ ---------------------------------------------------------------------------------------- }

const
  SREP_BASE_LEN = 512;          // -l512 de srep: largo mínimo de un match representable
  SREP_BLOCK    = 8 * 1024 * 1024;
  SREP_HASH_MIN_BITS = 16;      // tabla de hash según el tamaño del input
  SREP_HASH_MAX_BITS = 22;

type
  TEncMatch = record
    Src, Dest, Len: Int64;
  end;

  TEncOut = record
    Data: TBytes;
    Len: Int64;
  end;

procedure OutRaw(var O: TEncOut; P: PByte; N: Int64);
begin
  if N <= 0 then Exit;
  if O.Len + N > Length(O.Data) then
  begin
    while O.Len + N > Length(O.Data) do
      if Length(O.Data) = 0 then SetLength(O.Data, 1 shl 20) else SetLength(O.Data, Length(O.Data) * 2);
  end;
  Move(P^, O.Data[O.Len], N);
  Inc(O.Len, N);
end;

procedure OutU32(var O: TEncOut; V: LongWord);
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(V and $FF); B[1] := Byte((V shr 8) and $FF);
  B[2] := Byte((V shr 16) and $FF); B[3] := Byte((V shr 24) and $FF);
  OutRaw(O, @B[0], 4);
end;

procedure SortBySrc(var M: array of TEncMatch; var Idx: array of Integer; Lo, Hi: Integer);
var
  i, j, Piv, T: Integer;
begin
  if Lo >= Hi then Exit;
  Piv := M[Idx[(Lo + Hi) div 2]].Src;
  i := Lo; j := Hi;
  repeat
    while M[Idx[i]].Src < Piv do Inc(i);
    while M[Idx[j]].Src > Piv do Dec(j);
    if i <= j then
    begin
      T := Idx[i]; Idx[i] := Idx[j]; Idx[j] := T;
      Inc(i); Dec(j);
    end;
  until i > j;
  if Lo < j then SortBySrc(M, Idx, Lo, j);
  if i < Hi then SortBySrc(M, Idx, i, Hi);
end;

function HashKey(P: PByte; Bits: Integer): LongWord; inline;
var
  V: QWord;
begin
  Move(P^, V, 8);
  V := V * QWord($9E3779B97F4A7C15);
  Result := LongWord(V shr (64 - Bits));
end;

function SrepEncode(Src: PByte; SrcLen: Int64): TBytes;
const
  CANDIDATES = 4;               // posiciones por bucket de hash a comparar
  LAZY_GAIN  = 64;              // bytes de mejora para dejar un literal y tomar el match siguiente
var
  H: array of Int64;            // CANDIDATES posiciones por bucket
  Matches: array of TEncMatch;
  IdxSrc: array of Integer;
  Lit: TBytes;
  Z: array[0..15] of Byte;
  NM, I, J, J2, NStats, K: Int64;
  P, Q, QQ, BestSrc, BestLen, MaxLen, KEnd, Cur, LB: Int64;
  HBits: Integer;
  Out_: TEncOut;
  Stats: array of LongWord;
  LitLen, PrevSrc, Off, LenCode: Int64;

  procedure AddMatch(ASrc, ADest, ALen: Int64);
  begin
    if NM = Length(Matches) then SetLength(Matches, NM * 2 + 1024);
    Matches[NM].Src := ASrc;
    Matches[NM].Dest := ADest;
    Matches[NM].Len := ALen;
    Inc(NM);
  end;

  procedure AddLit(Pt: PByte; N: Int64);
  begin
    if N <= 0 then Exit;
    if LitLen + N > Length(Lit) then SetLength(Lit, (LitLen + N) * 2 + 1024);
    Move(Pt^, Lit[LitLen], N);
    Inc(LitLen, N);
  end;

  procedure Insert(Pos: Int64);
  var
    HB: Int64;
  begin
    if (Pos < 0) or (Pos + 8 > SrcLen) then Exit;
    HB := Int64(HashKey(Src + Pos, HBits)) * CANDIDATES;
    H[HB + 3] := H[HB + 2];
    H[HB + 2] := H[HB + 1];
    H[HB + 1] := H[HB];
    H[HB] := Pos;
  end;

  { Busca el match más largo en Pos entre los candidatos del bucket. }
  procedure FindBest(Pos: Int64; out BSrc, BLen: Int64);
  var
    HB, Cand: Int64;
    C, ML: Int64;
  begin
    BSrc := -1; BLen := 0;
    if Pos + SREP_BASE_LEN > SrcLen then Exit;
    HB := Int64(HashKey(Src + Pos, HBits)) * CANDIDATES;
    for C := 0 to CANDIDATES - 1 do
    begin
      Cand := H[HB + C];
      if (Cand < 0) or (Cand >= Pos) then Continue;
      if Pos - Cand > Int64(512) * 1024 * 1024 then Continue;
      if LoadU32(Src + Cand) <> LoadU32(Src + Pos) then Continue;
      ML := SrcLen - Pos;
      if ((Cand div SREP_BLOCK) + 1) * SREP_BLOCK - Cand < ML then
        ML := ((Cand div SREP_BLOCK) + 1) * SREP_BLOCK - Cand;
      if ((Pos div SREP_BLOCK) + 1) * SREP_BLOCK - Pos < ML then
        ML := ((Pos div SREP_BLOCK) + 1) * SREP_BLOCK - Pos;
      J := 0;
      while (J < ML) and (Src[Cand + J] = Src[Pos + J]) do Inc(J);
      if (J >= SREP_BASE_LEN) and (J > BLen) then
      begin
        BLen := J; BSrc := Cand;
      end;
    end;
  end;

begin
  Result := nil;
  if SrcLen <= 0 then Exit;
  // Tabla proporcional al input (una entrada cada ~16 bytes), acotada a 64-128 MB.
  HBits := SREP_HASH_MIN_BITS;
  while (HBits < SREP_HASH_MAX_BITS) and (Int64(1) shl HBits < SrcLen div 16) do Inc(HBits);
  SetLength(H, (Int64(1) shl HBits) * CANDIDATES);
  for I := 0 to High(H) do H[I] := -1;
  NM := 0;

  // 1. matches: greedy con lazy matching
  P := 0;
  while P + SREP_BASE_LEN <= SrcLen do
  begin
    FindBest(P, BestSrc, BestLen);
    if BestSrc >= 0 then
    begin
      Insert(P);
      // lazy: si en P+1 hay un match bastante mejor, P queda como literal
      if P + 1 + SREP_BASE_LEN <= SrcLen then
      begin
        FindBest(P + 1, QQ, LB);
        if LB > BestLen + LAZY_GAIN then
        begin
          Inc(P);
          BestSrc := QQ;
          BestLen := LB;
        end;
      end;
      AddMatch(BestSrc, P, BestLen);
      J := P + 1;
      while (J < P + BestLen) and (J + 8 <= SrcLen) do
      begin
        Insert(J);
        Inc(J);
      end;
      Inc(P, BestLen);
    end
    else
    begin
      Insert(P);
      Inc(P);
    end;
  end;
  SetLength(H, 0);

  // 2. índice por Src (los stats van agrupados por el bloque del origen)
  SetLength(IdxSrc, NM);
  for I := 0 to NM - 1 do IdxSrc[I] := I;
  if NM > 1 then SortBySrc(Matches, IdxSrc, 0, NM - 1);

  // 3. bloques
  Out_.Data := nil; Out_.Len := 0;
  OutU32(Out_, SREP_BULAT);
  OutU32(Out_, SREP_SIGNATURE);
  OutU32(Out_, 3 + (1 shl 8));
  OutU32(Out_, SREP_BASE_LEN);

  K := 0;
  I := 0;
  J := 0;
  while K < SrcLen do
  begin
    KEnd := K + SREP_BLOCK;
    if KEnd > SrcLen then KEnd := SrcLen;

    // stats con origen en [K,KEnd)
    NStats := 0;
    SetLength(Stats, 0);
    PrevSrc := K;
    while (I < NM) and (Matches[IdxSrc[I]].Src < KEnd) do
    begin
      if Matches[IdxSrc[I]].Src >= K then
      begin
        LitLen := Matches[IdxSrc[I]].Src - PrevSrc;
        if LitLen < 0 then LitLen := 0;
        Off := Matches[IdxSrc[I]].Dest - Matches[IdxSrc[I]].Src;
        LenCode := Matches[IdxSrc[I]].Len - SREP_BASE_LEN;
        SetLength(Stats, NStats * 4 + 4);
        Stats[NStats * 4 + 0] := LongWord(LitLen);
        Stats[NStats * 4 + 1] := LongWord(Off and $FFFFFFFF);
        Stats[NStats * 4 + 2] := LongWord((Off shr 32) and $FFFFFFFF);
        Stats[NStats * 4 + 3] := LongWord(LenCode);
        Inc(NStats);
        PrevSrc := Matches[IdxSrc[I]].Src;
      end;
      Inc(I);
    end;

    // literales: bytes de [K,KEnd) que ningún match cubre
    LitLen := 0;
    SetLength(Lit, 0);
    while (J < NM) and (Matches[J].Dest + Matches[J].Len <= K) do Inc(J);
    Cur := K;
    J2 := J;
    while (J2 < NM) and (Matches[J2].Dest < KEnd) do
    begin
      if Matches[J2].Dest > Cur then AddLit(Src + Cur, Matches[J2].Dest - Cur);
      if Matches[J2].Dest + Matches[J2].Len > Cur then Cur := Matches[J2].Dest + Matches[J2].Len;
      Inc(J2);
    end;
    if Cur < KEnd then AddLit(Src + Cur, KEnd - Cur);
    J := J2;

    OutU32(Out_, LongWord(LitLen));
    OutU32(Out_, LongWord(KEnd - K));
    OutU32(Out_, LongWord(NStats * 16));
    FillChar(Z, SizeOf(Z), 0);
    OutRaw(Out_, @Z[0], 16);
    if NStats > 0 then OutRaw(Out_, @Stats[0], NStats * 16);
    if LitLen > 0 then OutRaw(Out_, @Lit[0], LitLen);

    K := KEnd;
  end;

  SetLength(Result, Out_.Len);
  if Out_.Len > 0 then Move(Out_.Data[0], Result[0], Out_.Len);
end;

end.
