{ LZP (método `lzp` de FreeArc, Compression/LZP/C_LZP.cpp; algoritmo de D. Shkarin basado en el
  LZP de GRZipII). Stream: bloques [Int32 LE InSize][datos] hasta EOF; InSize < 0 = bloque
  guardado sin comprimir. El tamaño de salida de un bloque no se guarda: como mucho BlockSize
  (parámetro b, default 8mb).
  Bloque codificado: los primeros 12 bytes van tal cual. Después, en la parte delantera van
  literales y banderas LZP_MATCH_FLAG (0xB5); los largos de los matches se guardan AL FINAL del
  bloque, en orden inverso (cada 0 suma 254; un 255 en esa cola indica que el 0xB5 era literal).
  El C trabaja con punteros, pero solo compara diferencias entre ellos, así que acá son offsets
  dentro del buffer de salida y el resultado es el mismo en 32 y 64 bits. }
unit parc_lzp;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TLzpParams = record
    BlockSize: SizeInt;
    MinMatchLen, HashSizeLog, SmallestLen: Integer;
    Barrier: Int64;
  end;

  TLzpStage = class(TInStage)
  private
    FPar: TLzpParams;
    FIn, FOut: array of Byte;
    FHash: array of SizeInt;
    FLen, FPos: SizeInt;
    FEof: Boolean;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; const APar: TLzpParams);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Parámetros como parse_LZP. }
function ParseLzpParams(const Params: TStringArray): TLzpParams;

{ LZPDecode: devuelve los bytes producidos o -1 si los datos son inválidos. Hash tiene que tener
  1 shl HashSizeLog elementos (se reusa entre bloques para no realocar). }
function LzpDecode(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt;
  const Par: TLzpParams; var Hash: array of SizeInt): SizeInt;

implementation

uses
  parc_bytes, parc_methods;

const
  LZP_MATCH_FLAG = $B5;

function ParseLzpParams(const Params: TStringArray): TLzpParams;
var
  k: Integer;
  p: string;
  m: QWord;
  n: Integer;
begin
  Result.BlockSize := 8 shl 20;
  Result.MinMatchLen := 64;
  Result.HashSizeLog := 18;
  Result.Barrier := High(LongInt);
  Result.SmallestLen := 32;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if p = '' then Continue;
    case p[1] of
      'b': if ParseMem(Copy(p, 2, MaxInt), m) then Result.BlockSize := m;
      'l': Result.MinMatchLen := StrToIntDef(Copy(p, 2, MaxInt), Result.MinMatchLen);
      'h': Result.HashSizeLog := StrToIntDef(Copy(p, 2, MaxInt), Result.HashSizeLog);
      'd': if ParseMem(Copy(p, 2, MaxInt), m) then Result.Barrier := m;
      's': Result.SmallestLen := StrToIntDef(Copy(p, 2, MaxInt), Result.SmallestLen);
    else
      if p[Length(p)] = '%' then Continue;                  // MinCompression: solo compresor
      n := StrToIntDef(p, -1);
      if n >= 0 then Result.MinMatchLen := n                 // entero pelado = MinMatchLen
      else if ParseMem(p, m) then Result.BlockSize := m;     // memoria = BlockSize
    end;
  end;
end;

{ lzpC(p): el UINT de los 4 bytes anteriores a p. }
function C32(Buf: PByte; Ofs: SizeInt): LongWord; inline;
begin
  Result := LongWord(Buf[Ofs - 4]) or (LongWord(Buf[Ofs - 3]) shl 8) or
            (LongWord(Buf[Ofs - 2]) shl 16) or (LongWord(Buf[Ofs - 1]) shl 24);
end;

{ lzpH: (c + 5*ROR(c,17) + 3*lzpC(p-1)) & HashMask, en aritmética de 32 bits. }
function H32(c: LongWord; Buf: PByte; Ofs: SizeInt; Mask: LongWord): LongWord; inline;
begin
  Result := (c + 5 * RorDWord(c, 17) + 3 * C32(Buf, Ofs - 1)) and Mask;
end;

{ Traducción de LZPDecode (C_LZP.cpp). Ip/InEnd = offsets en Src, Op = offset en Dst. }
function LzpDecode(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt;
  const Par: TLzpParams; var Hash: array of SizeInt): SizeInt;
var
  HashSize, Mask, i, n, n1, k: LongWord;
  Ip, InEnd, Op, p: SizeInt;
  j: SizeInt;
  Len: SizeInt;
  IsLiteral: Boolean;
begin
  Result := -1;
  HashSize := LongWord(1) shl Par.HashSizeLog;
  Mask := HashSize - 1;
  if (SrcLen < 12) or (DstCap < 12) or (Length(Hash) < SizeInt(HashSize)) then Exit;
  // LZP_INIT: la tabla apunta a Pattern+5 y los primeros 12 bytes se copian tal cual
  for j := 0 to HashSize - 1 do Hash[j] := 5;
  Move(Src^, Dst^, 12);
  Ip := 12;
  Op := 12;
  InEnd := SrcLen;
  n1 := 1;
  n := 1;
  i := C32(Dst, Op);
  k := H32(i, Dst, Op, Mask);
  repeat
    if Ip >= InEnd then Exit;
    if Src[Ip] <> LZP_MATCH_FLAG then
    begin
      Inc(Ip);
      Dec(n);
      if n = 0 then begin Hash[k] := Op; n := n1; end;
      if Op >= DstCap then Exit;
      Dst[Op] := Src[Ip - 1];
      Inc(Op);
    end
    else
    begin
      Inc(Ip);
      p := Hash[k];
      Dec(n);
      if n = 0 then begin Hash[k] := Op; n := n1; end;
      // `if (i != lzpC(p) || *--InEnd == 255)`: con contexto distinto el 0xB5 es literal y no
      // consume nada de la cola; si coincide, se consume un byte de la cola (255 = literal)
      IsLiteral := i <> C32(Dst, p);
      if not IsLiteral then
      begin
        Dec(InEnd);
        if InEnd < Ip then Exit;        // la cola se cruzó con la parte delantera
        IsLiteral := Src[InEnd] = 255;
      end;
      if IsLiteral then
      begin
        if Op >= DstCap then Exit;
        Dst[Op] := Src[Ip - 1];
        Inc(Op);
      end
      else
      begin
        Hash[k] := Op;
        if (Op - p > SizeInt((n1 + 1) * HashSize)) and (n1 < 7) then Inc(n1);
        if Op - p > Par.Barrier then Len := Par.SmallestLen - 1 else Len := Par.MinMatchLen - 1;
        while Src[InEnd] = 0 do
        begin
          Inc(Len, 254);
          Dec(InEnd);
          if InEnd < Ip then Exit;
        end;
        Inc(Len, Src[InEnd]);
        if (Len <= 0) or (Len > DstCap - Op) then Exit;
        k := 2 * n1 + 2;
        repeat
          Dec(k);
          if k = 0 then
          begin
            k := 2 * n1 + 1;
            Hash[H32(C32(Dst, Op), Dst, Op, Mask)] := Op;
          end;
          Dst[Op] := Dst[p];
          Inc(Op);
          Inc(p);
          Dec(Len);
        until Len = 0;
      end;
    end;
    i := C32(Dst, Op);
    k := H32(i, Dst, Op, Mask);
  until Ip >= InEnd;
  Result := Op;
end;

{ TLzpStage }

constructor TLzpStage.Create(ASource: TInStage; const APar: TLzpParams);
begin
  if (APar.HashSizeLog < 1) or (APar.HashSizeLog > 30) then
    raise EUnsupportedMethod.Create('lzp: tamaño de hash inválido');
  if APar.BlockSize <= 0 then raise EUnsupportedMethod.Create('lzp: tamaño de bloque inválido');
  if (APar.MinMatchLen < 1) or (APar.SmallestLen < 1) then raise EUnsupportedMethod.Create('lzp: largo mínimo inválido');
  inherited Create(ASource);
  FPar := APar;
end;

function TLzpStage.NextBlock: Boolean;
var
  Hdr: array[0..3] of Byte;
  InSize: LongInt;
  n: SizeInt;
begin
  if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit(False);
  InSize := LongInt(LongWord(Hdr[0]) or (LongWord(Hdr[1]) shl 8) or (LongWord(Hdr[2]) shl 16) or (LongWord(Hdr[3]) shl 24));
  if InSize = Low(LongInt) then Corrupt('lzp: tamaño de bloque inválido');
  if InSize < 0 then
  begin
    n := -InSize;
    if n > Length(FOut) then SetLength(FOut, n);
    Source.ReadExact(@FOut[0], n);
    FLen := n;
  end
  else
  begin
    if InSize > Length(FIn) then SetLength(FIn, InSize);
    if InSize > 0 then Source.ReadExact(@FIn[0], InSize);
    if Length(FOut) < FPar.BlockSize then SetLength(FOut, FPar.BlockSize);
    if Length(FHash) = 0 then SetLength(FHash, SizeInt(1) shl FPar.HashSizeLog);
    FLen := LzpDecode(@FIn[0], InSize, @FOut[0], FPar.BlockSize, FPar, FHash);
    if FLen < 0 then Corrupt('lzp: datos inválidos');
  end;
  FPos := 0;
  Result := True;
end;

function TLzpStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
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
