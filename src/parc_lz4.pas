{ LZ4 (método `lz4` de FreeArc, Compression/LZ4/C_LZ4.cpp).
  Stream: byte de versión (=1) y bloques [Int32 LE InSize][datos] hasta EOF; InSize < 0 = bloque
  guardado sin comprimir (-InSize bytes). Cada bloque es LZ4 "block format", que no cambió desde
  2011: el decodificador sigue la semántica de LZ4_decompress_safe de LZ4 1.10, con todos los
  chequeos de límites (las versiones de 2012 que trae FreeArc tienen CVE-2014-4611). }
unit parc_lz4;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

const
  LZ4_FORMAT_VERSION = 1;

type
  TLz4Stage = class(TInStage)
  private
    FIn, FOut: array of Byte;
    FLen, FPos: SizeInt;
    FStarted, FEof: Boolean;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; ABlockSize: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Decodifica un bloque LZ4. Devuelve la cantidad de bytes producidos, o -1 si los datos son
  inválidos o no entran en DstCap. }
function Lz4DecodeBlock(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;

{ Variante memoria-a-memoria de FreeArc (LZ4_METHOD::DeCompressMem, usada dentro de 4x4):
  byte de versión + un único bloque LZ4. }
function Lz4DecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;

implementation

uses
  parc_bytes;

function Lz4DecodeBlock(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
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

    // La última secuencia termina con literales justo al final de la entrada
    if ip = SrcLen then Break;

    // Match: offset de 16 bits LE (0 inválido) + largo en los 4 bits bajos (+4)
    if SrcLen - ip < 2 then Exit;
    Offset := Src[ip] or (SizeInt(Src[ip + 1]) shl 8);
    Inc(ip, 2);
    if (Offset = 0) or (Offset > op) then Exit;
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
    // Copia hacia adelante byte a byte: el solapamiento (offset < largo) replica datos
    if Offset >= MatchLen then
      Move(Dst[op - Offset], Dst[op], MatchLen)
    else
      for i := 0 to MatchLen - 1 do
        Dst[op + i] := Dst[op - Offset + i];
    Inc(op, MatchLen);
  end;
  Result := op;
end;

function Lz4DecodeMem(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstLen: SizeInt): Boolean;
begin
  Result := (SrcLen > 0) and (Src[0] = LZ4_FORMAT_VERSION) and
            (Lz4DecodeBlock(Src + 1, SrcLen - 1, Dst, DstLen) = DstLen);
end;

{ TLz4Stage }

constructor TLz4Stage.Create(ASource: TInStage; ABlockSize: SizeInt);
begin
  if ABlockSize <= 0 then ABlockSize := 1 shl 20;
  inherited Create(ASource);
  SetLength(FOut, ABlockSize);
end;

function TLz4Stage.NextBlock: Boolean;
var
  Hdr: array[0..3] of Byte;
  InSize: LongInt;
  n: SizeInt;
begin
  if not FStarted then
  begin
    FStarted := True;
    if not Source.ReadExactOrEof(@Hdr[0], 1) then Exit(False);
    if Hdr[0] <> LZ4_FORMAT_VERSION then Corrupt('lz4: versión de formato desconocida');
  end;
  if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit(False);
  InSize := LongInt(LongWord(Hdr[0]) or (LongWord(Hdr[1]) shl 8) or (LongWord(Hdr[2]) shl 16) or (LongWord(Hdr[3]) shl 24));
  if InSize < 0 then
  begin
    // Bloque guardado: se copia tal cual
    if InSize = Low(LongInt) then Corrupt('lz4: tamaño de bloque inválido');
    n := -InSize;
    if n > Length(FOut) then SetLength(FOut, n);
    Source.ReadExact(@FOut[0], n);
    FLen := n;
  end
  else
  begin
    if SizeInt(InSize) > Length(FIn) then SetLength(FIn, InSize);
    if InSize > 0 then Source.ReadExact(@FIn[0], InSize);
    FLen := Lz4DecodeBlock(@FIn[0], InSize, @FOut[0], Length(FOut));
    if FLen < 0 then Corrupt('lz4: datos inválidos');
  end;
  FPos := 0;
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
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

end.
