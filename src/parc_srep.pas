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

type
  { Formato que PArc todavía no sabe leer (v4/Index-LZ). }
  ESrepUnsupported = class(Exception);

const
  SREP_SIGNATURE = $50455253;        // 'SREP'
  SREP_BULAT     = $26351817;

{ Versión del stream (1..3), -1 si no es srep, 4 si es Index-LZ (todavía sin soporte). }
function SrepStreamVersion(Src: PByte; SrcLen: Integer): Integer;

{ Tamaño descomprimido que declara el stream (-1 si no se puede leer). }
function SrepDecodedSize(Src: PByte; SrcLen: Integer): Int64;

{ Descomprime un stream srep completo (v1..v3). DstLen tiene que ser el tamaño original. }
function SrepDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Int64): Boolean;

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

function SrepDecodedSize(Src: PByte; SrcLen: Integer): Int64;
var
  H, Ver, Seed, HashSize, Hdr, Pos, Start: Integer;
  Comp, Orig, Stat: LongWord;
begin
  Result := -1;
  // En un .arc el bloque antepone un byte: 0 = guardado tal cual, 1 = stream srep.
  // Un .srep suelto arranca directamente con la firma.
  if (SrcLen >= 4) and (LoadU32(Src) = SREP_BULAT) then Start := 0
  else if SrcLen >= 1 then
  begin
    if Src[0] = 0 then Exit(SrcLen - 1);
    if (SrcLen >= 5) and (LoadU32(Src + 1) = SREP_BULAT) then Start := 1
    else Exit;
  end
  else Exit;
  if SrcLen < Start + 16 then Exit;
  if (LoadU32(Src + Start) <> SREP_BULAT) or (LoadU32(Src + Start + 4) <> SREP_SIGNATURE) then Exit;
  H := Integer(LoadU32(Src + Start + 8));
  Ver := H and 255;
  if (Ver < 1) or (Ver > 3) then Exit;
  Seed := (H shr 16) and 255;
  HashSize := ((H shr 24) + 16) and 255;
  Hdr := 12 + HashSize;
  Pos := Start + 16 + Seed;
  Result := 0;
  while Pos + Hdr <= SrcLen do
  begin
    Comp := LoadU32(Src + Pos);
    Orig := LoadU32(Src + Pos + 4);
    Stat := LoadU32(Src + Pos + 8);
    Inc(Pos, Hdr);
    if (Comp = 0) and (Orig = 0) then Break;
    if Int64(Pos) + Int64(Stat) + Int64(Comp) > SrcLen then Exit(-1);
    Inc(Pos, Integer(Stat) + Integer(Comp));
    Inc(Result, Int64(Orig));
  end;
end;

function SrepDecode(Src: PByte; SrcLen: Integer; Dst: PByte; DstLen: Int64): Boolean;
var
  H, Ver, Seed, HashSize, Hdr, Pos, Start: Integer;
  BaseLen: LongWord;
  Comp, Orig, Stat: LongWord;
  OutPos, BlockStart, BlockEnd, StatPos, LitPos, LitAvail, i, N: Int64;
  L1: Int64;
  RoundMatches: Boolean;
  Heap: TMatchHeap;
  M: TSrepMatch;
  Lit, OffLo, OffHi, LenCode, Offset: Int64;
  Step: Integer;

  procedure CopyMatch(DestPos, SrcStart, Len: Int64); inline;
  var
    k: Int64;
  begin
    // byte a byte: el match puede solaparse con su destino (LZ normal)
    for k := 0 to Len - 1 do
      Dst[DestPos + k] := Dst[SrcStart + k];
  end;

  function StatWord(K: Int64): LongWord; inline;
  begin
    Result := LoadU32(Src + StatPos + K * 4);
  end;

begin
  Result := False;
  // Igual que SrepDecodedSize: .srep suelto o bloque de .arc con su byte de guardado.
  if (SrcLen >= 4) and (LoadU32(Src) = SREP_BULAT) then Start := 0
  else if SrcLen >= 1 then
  begin
    if Src[0] = 0 then
    begin
      if DstLen <> SrcLen - 1 then Exit;
      if DstLen > 0 then Move(Src[1], Dst[0], DstLen);
      Exit(True);
    end;
    if (SrcLen >= 5) and (LoadU32(Src + 1) = SREP_BULAT) then Start := 1
    else Exit;
  end
  else Exit;
  if SrcLen < Start + 16 then Exit;
  if (LoadU32(Src + Start) <> SREP_BULAT) or (LoadU32(Src + Start + 4) <> SREP_SIGNATURE) then Exit;
  H := Integer(LoadU32(Src + Start + 8));
  Ver := H and 255;
  if (Ver < 1) or (Ver > 3) then Exit;      // v4 (Index-LZ) todavía no
  Seed := (H shr 16) and 255;
  HashSize := ((H shr 24) + 16) and 255;
  BaseLen := LoadU32(Src + Start + 12);
  if BaseLen = 0 then Exit;
  RoundMatches := Ver = 1;
  if RoundMatches then L1 := BaseLen else L1 := 1;
  if RoundMatches then Step := 3 else Step := 4;
  Hdr := 12 + HashSize;
  Pos := Start + 16 + Seed;

  Heap.Count := 0;
  SetLength(Heap.Items, 0);
  OutPos := 0;

  while Pos + Hdr <= SrcLen do
  begin
    Comp := LoadU32(Src + Pos);
    Orig := LoadU32(Src + Pos + 4);
    Stat := LoadU32(Src + Pos + 8);
    Inc(Pos, Hdr);
    if (Comp = 0) and (Orig = 0) then Break;
    if (Stat mod 4 <> 0) or (Int64(Pos) + Int64(Stat) + Int64(Comp) > SrcLen) then Exit;

    BlockStart := OutPos;
    BlockEnd := OutPos + Int64(Orig);
    if BlockEnd > DstLen then Exit;
    StatPos := Pos;
    LitPos := Pos + Int64(Stat);
    LitAvail := Comp;

    if Ver = 3 then
    begin
      // 1. STATs: matches con destino en este bloque o en uno futuro
      N := Int64(Stat) div 4;
      M.Src := BlockStart;
      i := 0;
      while i + 4 <= N do
      begin
        Lit := StatWord(i);
        OffLo := StatWord(i + 1);
        OffHi := StatWord(i + 2);
        LenCode := StatWord(i + 3);
        Inc(i, 4);
        Offset := (OffLo + (OffHi shl 32)) * L1;
        M.Dest := M.Src + Lit + Offset;
        M.Len := LenCode * L1 + BaseLen;
        if (M.Src + Lit < BlockStart) or (M.Src + Lit >= BlockEnd) or
           (M.Len > BlockEnd - (M.Src + Lit)) or (M.Dest <= M.Src + Lit) then Exit;
        Inc(M.Src, Lit);
        if M.Dest + M.Len > DstLen then Exit;
        HeapPush(Heap, M);
      end;

      // 2. matches cuyo destino cae en este bloque, en orden de destino
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

      // 3. literales hasta el final del bloque
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
      i := 0;
      while i + Step <= N do
      begin
        Lit := StatWord(i);
        OffLo := StatWord(i + 1);
        Inc(i, 2);
        if not RoundMatches then
        begin
          OffHi := StatWord(i);
          Inc(i);
          Inc(OffLo, OffHi shl 32);
        end;
        LenCode := StatWord(i);
        Inc(i);
        M.Dest := BlockStart + Lit;
        M.Src := (M.Dest div L1) * L1 - OffLo * L1;
        M.Len := LenCode * L1 + BaseLen;
        if (M.Dest < OutPos) or (M.Src < 0) or (M.Src >= M.Dest) or (M.Dest + M.Len > BlockEnd) then Exit;
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

    Inc(Pos, Integer(Stat) + Integer(Comp));
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
  if SrepStreamVersion(@In_[0], N) = 4 then
    raise ESrepUnsupported.Create('srep: formato v4 (Index-LZ) todavía no soportado');
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

end.
