{ LZ4 (método `lz4`): decodificador del formato LZ4 Frame (lz4_Frame_format.md de LZ4, Yann
  Collet), el mismo que escribe y lee la herramienta `lz4`, y del "block format" de LZ4.

  Stream: un frame LZ4 completo.
    Magic 0x184D2204 (U32 LE)
    FLG: versión 01 (bits 7-6), B.Indep (5), B.Checksum (4), C.Size (3), C.Checksum (2),
         reservado 0 (1), DictID (0)
    BD:  Block MaxSize en los bits 6-4 (4 = 64 KB, 5 = 256 KB, 6 = 1 MB, 7 = 4 MB), el resto 0
    [Content Size U64 LE si C.Size] [Dictionary ID U32 si DictID: no se admite]
    HC:  (XXH32(FLG..fin del descriptor, 0) shr 8) and $FF
    Bloques: U32 LE con el bit 31 = guardado sin comprimir y el resto = largo (<= MaxSize),
             los datos, y XXH32 del bloque si B.Checksum. U32 0 = fin (EndMark).
    [XXH32 de todo el contenido si C.Checksum]
  Con B.Indep = 0 cada bloque puede referirse a los últimos 64 KB de los anteriores (lo que
  escribe `lz4` por defecto); PArc escribe bloques independientes (parc_lz4enc).

  El decodificador de bloques sigue la semántica de LZ4_decompress_safe: todos los accesos
  están acotados y un stream dañado da Corrupt, nunca una lectura o escritura fuera de los
  buffers. Lo de este archivo es código propio de PArc escrito a partir de la especificación. }
unit parc_lz4;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

const
  LZ4_FRAME_MAGIC = $184D2204;
  LZ4_WINDOW = 1 shl 16;   // alcance de un match (offset de 16 bits)

type
  TLz4Stage = class(TInStage)
  private
    FIn: array of Byte;
    FOut: array of Byte;     // [historia de hasta 64 KB][bloque actual]
    FHist: SizeInt;          // bytes de historia antes del bloque (solo con bloques enlazados)
    FLen, FPos: SizeInt;     // el bloque decodificado está en FOut[FHist .. FHist+FLen)
    FMaxBlock: SizeInt;
    FIndep, FBlockSum, FContentSum, FHasSize: Boolean;
    FContentSize, FTotal: QWord;
    FHash: Pointer;          // estado XXH32 del contenido (si C.Checksum)
    FStarted, FEof: Boolean;
    procedure ReadHeader;
    function NextBlock: Boolean;
    procedure Finish;
  public
    destructor Destroy; override;
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Decodifica un bloque LZ4 en Dst. Prefix = cuántos bytes válidos hay justo antes de Dst a
  los que un match puede referirse (0 con bloques independientes). Devuelve la cantidad de
  bytes producidos, o -1 si los datos son inválidos o no entran en DstCap. }
function Lz4DecodeBlock(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt;
  Prefix: SizeInt = 0): SizeInt;

{ Memoria a memoria (dentro de 4x4): Src es un frame entero que tiene que dar DstLen bytes. }
function Lz4DecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;

{ XXH32 (xxHash, Yann Collet), escrito a partir de su especificación: el checksum del
  descriptor y los opcionales de bloque y contenido del frame. }
type
  TXxh32 = record
    Total: QWord;
    V: array[0..3] of LongWord;
    Mem: array[0..15] of Byte;
    MemLen: Integer;
    Seed: LongWord;
  end;
  PXxh32 = ^TXxh32;
procedure Xxh32Init(out S: TXxh32; Seed: LongWord);
procedure Xxh32Update(var S: TXxh32; P: PByte; Len: SizeInt);
function Xxh32Final(const S: TXxh32): LongWord;
function Xxh32(P: PByte; Len: SizeInt; Seed: LongWord): LongWord;

{ Block MaxSize del descriptor (4..7) para un tamaño de bloque; -1 si pasa de 4 MB. }
function Lz4BlockCode(BlockSize: SizeInt): Integer;

implementation

uses
  parc_bytes;

{ ---- XXH32 ---- }

const
  P32_1 = 2654435761;
  P32_2 = 2246822519;
  P32_3 = 3266489917;
  P32_4 = 668265263;
  P32_5 = 374761393;

function Rotl(x: LongWord; r: Integer): LongWord; inline;
begin
  Result := (x shl r) or (x shr (32 - r));
end;

function Rd32(P: PByte): LongWord; inline;
begin
  Result := LongWord(P[0]) or (LongWord(P[1]) shl 8) or (LongWord(P[2]) shl 16) or (LongWord(P[3]) shl 24);
end;

function Round32(Acc, Input: LongWord): LongWord; inline;
begin
  Result := Rotl(Acc + Input * P32_2, 13) * P32_1;
end;

procedure Xxh32Init(out S: TXxh32; Seed: LongWord);
begin
  S := Default(TXxh32);
  S.Seed := Seed;
  S.V[0] := Seed + P32_1 + P32_2;
  S.V[1] := Seed + P32_2;
  S.V[2] := Seed;
  S.V[3] := Seed - P32_1;
end;

procedure Xxh32Update(var S: TXxh32; P: PByte; Len: SizeInt);
var
  n: SizeInt;
begin
  Inc(S.Total, Len);
  if S.MemLen > 0 then
  begin
    n := 16 - S.MemLen;
    if n > Len then n := Len;
    Move(P^, S.Mem[S.MemLen], n);
    Inc(S.MemLen, n);
    Inc(P, n);
    Dec(Len, n);
    if S.MemLen < 16 then Exit;
    S.V[0] := Round32(S.V[0], Rd32(@S.Mem[0]));
    S.V[1] := Round32(S.V[1], Rd32(@S.Mem[4]));
    S.V[2] := Round32(S.V[2], Rd32(@S.Mem[8]));
    S.V[3] := Round32(S.V[3], Rd32(@S.Mem[12]));
    S.MemLen := 0;
  end;
  while Len >= 16 do
  begin
    S.V[0] := Round32(S.V[0], Rd32(P));
    S.V[1] := Round32(S.V[1], Rd32(P + 4));
    S.V[2] := Round32(S.V[2], Rd32(P + 8));
    S.V[3] := Round32(S.V[3], Rd32(P + 12));
    Inc(P, 16);
    Dec(Len, 16);
  end;
  if Len > 0 then
  begin
    Move(P^, S.Mem[0], Len);
    S.MemLen := Len;
  end;
end;

function Xxh32Final(const S: TXxh32): LongWord;
var
  h: LongWord;
  i: Integer;
begin
  if S.Total >= 16 then
    h := Rotl(S.V[0], 1) + Rotl(S.V[1], 7) + Rotl(S.V[2], 12) + Rotl(S.V[3], 18)
  else
    h := S.Seed + P32_5;
  h := h + LongWord(S.Total);
  i := 0;
  while i + 4 <= S.MemLen do
  begin
    h := Rotl(h + Rd32(@S.Mem[i]) * P32_3, 17) * P32_4;
    Inc(i, 4);
  end;
  while i < S.MemLen do
  begin
    h := Rotl(h + S.Mem[i] * P32_5, 11) * P32_1;
    Inc(i);
  end;
  h := h xor (h shr 15);
  h := h * P32_2;
  h := h xor (h shr 13);
  h := h * P32_3;
  h := h xor (h shr 16);
  Result := h;
end;

function Xxh32(P: PByte; Len: SizeInt; Seed: LongWord): LongWord;
var
  S: TXxh32;
begin
  Xxh32Init(S, Seed);
  Xxh32Update(S, P, Len);
  Result := Xxh32Final(S);
end;

function Lz4BlockCode(BlockSize: SizeInt): Integer;
begin
  Result := 4;
  while (Result <= 7) and (BlockSize > SizeInt(1) shl (8 + 2 * Result)) do Inc(Result);
  if Result > 7 then Result := -1;
end;

{ ---- bloque ---- }

function Lz4DecodeBlock(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt;
  Prefix: SizeInt): SizeInt;
var
  ip, op: SizeInt;
  Token, b: Byte;
  LitLen, MatchLen, Offset, i: SizeInt;
begin
  Result := -1;
  ip := 0;
  op := 0;
  if SrcLen <= 0 then Exit;
  while True do
  begin
    if ip >= SrcLen then Exit;
    Token := Src[ip];
    Inc(ip);

    // Literales: 4 bits altos; 15 = siguen bytes de extensión hasta uno distinto de 255
    LitLen := Token shr 4;
    if LitLen = 15 then
      repeat
        if ip >= SrcLen then Exit;
        b := Src[ip];
        Inc(ip);
        Inc(LitLen, b);
        if LitLen > SrcLen then Exit;   // no puede haber más literales que entrada
      until b <> 255;
    if (LitLen > SrcLen - ip) or (LitLen > DstCap - op) then Exit;
    Move(Src[ip], Dst[op], LitLen);
    Inc(ip, LitLen);
    Inc(op, LitLen);

    // La última secuencia termina con literales justo al final del bloque
    if ip = SrcLen then Break;

    // Match: offset de 16 bits LE (0 inválido) + largo en los 4 bits bajos (+4)
    if SrcLen - ip < 2 then Exit;
    Offset := Src[ip] or (SizeInt(Src[ip + 1]) shl 8);
    Inc(ip, 2);
    if (Offset = 0) or (Offset > op + Prefix) then Exit;
    MatchLen := Token and 15;
    if MatchLen = 15 then
      repeat
        if ip >= SrcLen then Exit;
        b := Src[ip];
        Inc(ip);
        Inc(MatchLen, b);
        if MatchLen > DstCap then Exit;
      until b <> 255;
    Inc(MatchLen, 4);
    if MatchLen > DstCap - op then Exit;
    // Hacia adelante byte a byte cuando se solapa (offset < largo: repite el patrón)
    if Offset >= MatchLen then
      Move(Dst[op - Offset], Dst[op], MatchLen)
    else
      for i := 0 to MatchLen - 1 do
        Dst[op + i] := Dst[op - Offset + i];
    Inc(op, MatchLen);
  end;
  Result := op;
end;

{ ---- frame ---- }

function Lz4DecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;
var
  Dec: TLz4Stage;
  n, r: SizeInt;
  Extra: Byte;
begin
  Result := False;
  Dec := TLz4Stage.Create(TMemStage.Create(Src, SrcLen));
  try
    try
      n := 0;
      while n < DstLen do
      begin
        r := Dec.Read(Dst + n, DstLen - n);
        if r = 0 then Exit;
        Inc(n, r);
      end;
      Result := Dec.Read(@Extra, 1) = 0;   // ni un byte de más
    except
      on EArcCorrupt do Result := False;
    end;
  finally
    Dec.Free;   // libera también la fuente
  end;
end;

destructor TLz4Stage.Destroy;
begin
  if FHash <> nil then Dispose(PXxh32(FHash));
  inherited Destroy;
end;

procedure TLz4Stage.ReadHeader;
var
  H: array[0..14] of Byte;
  Flg, Bd: Byte;
  n, Code: Integer;
begin
  Source.ReadExact(@H[0], 4);
  if Rd32(@H[0]) <> LZ4_FRAME_MAGIC then Corrupt('lz4: not an LZ4 frame');
  Source.ReadExact(@H[0], 2);
  Flg := H[0];
  Bd := H[1];
  if (Flg shr 6 <> 1) or (Flg and 2 <> 0) or (Bd and $8F <> 0) then Corrupt('lz4: unsupported frame header');
  if Flg and 1 <> 0 then Corrupt('lz4: frames with a dictionary are not supported');
  Code := (Bd shr 4) and 7;
  if Code < 4 then Corrupt('lz4: invalid block size');
  FMaxBlock := SizeInt(1) shl (8 + 2 * Code);
  FIndep := Flg and $20 <> 0;
  FBlockSum := Flg and $10 <> 0;
  FHasSize := Flg and 8 <> 0;
  FContentSum := Flg and 4 <> 0;
  n := 2;
  if FHasSize then
  begin
    Source.ReadExact(@H[2], 8);
    FContentSize := QWord(Rd32(@H[2])) or (QWord(Rd32(@H[6])) shl 32);
    n := 10;
  end;
  Source.ReadExact(@H[n], 1);
  if H[n] <> (Xxh32(@H[0], n, 0) shr 8) and $FF then Corrupt('lz4: bad frame header checksum');
  if FContentSum then
  begin
    New(PXxh32(FHash));
    Xxh32Init(PXxh32(FHash)^, 0);
  end;
  SetLength(FIn, FMaxBlock);
  if FIndep then SetLength(FOut, FMaxBlock) else SetLength(FOut, LZ4_WINDOW + FMaxBlock);
end;

procedure TLz4Stage.Finish;
var
  H: array[0..3] of Byte;
begin
  if FContentSum then
  begin
    Source.ReadExact(@H[0], 4);
    if Rd32(@H[0]) <> Xxh32Final(PXxh32(FHash)^) then Corrupt('lz4: content checksum mismatch');
  end;
  if FHasSize and (FTotal <> FContentSize) then Corrupt('lz4: content size mismatch');
end;

function TLz4Stage.NextBlock: Boolean;
var
  H: array[0..3] of Byte;
  W: LongWord;
  n, Keep: SizeInt;
  Dst: PByte;
begin
  if not FStarted then
  begin
    FStarted := True;
    ReadHeader;
  end;
  // Con bloques enlazados, los últimos 64 KB de lo decodificado quedan como historia
  if not FIndep then
  begin
    Keep := FHist + FLen;
    if Keep > LZ4_WINDOW then Keep := LZ4_WINDOW;
    if Keep > 0 then Move(FOut[FHist + FLen - Keep], FOut[0], Keep);
    FHist := Keep;
  end;
  FLen := 0;
  FPos := 0;
  Source.ReadExact(@H[0], 4);
  W := Rd32(@H[0]);
  if W = 0 then
  begin
    Finish;
    Exit(False);
  end;
  n := W and $7FFFFFFF;
  if (n = 0) or (n > FMaxBlock) then Corrupt('lz4: invalid block size');
  Source.ReadExact(@FIn[0], n);
  if FBlockSum then
  begin
    Source.ReadExact(@H[0], 4);
    if Rd32(@H[0]) <> Xxh32(@FIn[0], n, 0) then Corrupt('lz4: block checksum mismatch');
  end;
  Dst := @FOut[FHist];
  if W and $80000000 <> 0 then
  begin
    Move(FIn[0], Dst^, n);
    FLen := n;
  end
  else
  begin
    FLen := Lz4DecodeBlock(@FIn[0], n, Dst, FMaxBlock, FHist);
    if FLen < 0 then Corrupt('lz4: invalid data');
  end;
  Inc(FTotal, FLen);
  if FContentSum then Xxh32Update(PXxh32(FHash)^, Dst, FLen);
  Result := True;
end;

function TLz4Stage.Read(Buf: PByte; Count: SizeInt): SizeInt;
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
  Move(FOut[FHist + FPos], Buf^, Result);
  Inc(FPos, Result);
end;

end.
