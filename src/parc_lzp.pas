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
  SysUtils, parc_stream, parc_outstream;

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

{ LZPEncode (C_LZP.cpp): devuelve el tamaño comprimido, o 0 si no conviene.
  Hash tiene que tener 1 shl HashSizeLog elementos. }
function LzpEncode(InB, OutB: PByte; Size: SizeInt; MinLen, HashSize, Barrier,
  SmallestLen: Integer; var Hash: array of SizeInt): SizeInt;

{ Etapa de COMPRESIÓN lzp. Va por bloques de BlockSize, así que la memoria es de
  uno o dos bloques. Si el bloque no comprime lo suficiente (MinCompression, el
  "N%" del método) o no comprime nada, se escribe como bloque NEGATIVO (stored),
  igual que el compresor del C. }
type
  TLzpEncStage = class(TOutStage)
  private
    FPar: TLzpParams;
    FMinCompression: Integer;
    FIn, FOut: array of Byte;
    FHash: array of SizeInt;
    FInLen: SizeInt;
    FEngineErr: Boolean;
    procedure VolcarBloque;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    constructor Create(ATarget: TOutStage; const APar: TLzpParams; AMinCompression: Integer);
  end;

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


{ Traducción de LZPEncode (C_LZP.cpp:66). Ip/InEnd/Op/OutEnd son offsets.
  En el C la variable `i` tiene TRES roles distintos en la misma iteración:
  (1) el contexto de 4 bytes, lzpC(In); (2) el largo del match, que se compara de
  a 4 y después de a 1; (3) el resto del largo para la cola de a 254. Y `k` pasa
  de ser el hash a ser el largo (In += (k=i)) y después el contador descendente del
  backfill. Acá van como Ctx / MatchLen / Resto / H / Back, por separado, para no
  confundirlos. }
function LzpEncode(InB, OutB: PByte; Size: SizeInt; MinLen, HashSize, Barrier,
  SmallestLen: Integer; var Hash: array of SizeInt): SizeInt;
var
  Mask: LongWord;
  Ctx, H: LongWord;
  MatchLen, Resto, Back: SizeInt;
  n, n1: LongWord;
  Ip, InEnd, Op, OutEnd, p, ml, j: SizeInt;
  EsMatch, ContextoIgual: Boolean;
begin
  Result := 0;
  if Size < 32 then Exit;
  if (HashSize < 1) or (Length(Hash) < HashSize) then Exit;
  Mask := LongWord(HashSize) - 1;
  { LZP_INIT: la tabla apunta a Pattern+5 y los primeros 12 bytes se copian tal cual }
  for j := 0 to HashSize - 1 do Hash[j] := 5;
  Move(InB^, OutB^, 12);
  Ip := 12; Op := 12; InEnd := Size; OutEnd := Size;
  n1 := 1; n := 1;
  Ctx := C32(InB, Ip);
  H := H32(Ctx, InB, Ip, Mask);
  repeat
    p := Hash[H];
    Dec(n);
    if n = 0 then begin Hash[H] := Ip; n := n1; end;
    EsMatch := False;
    ContextoIgual := Ctx = C32(InB, p);
    if ContextoIgual then
    begin
      if Ip - p > Barrier then ml := SmallestLen else ml := MinLen;
      if (Ip + ml <= InEnd) and (C32(InB, p + ml) = C32(InB, Ip + ml)) then
      begin
        MatchLen := 4;
        while (Ip + MatchLen <= InEnd) and
              (C32(InB, p + MatchLen) = C32(InB, Ip + MatchLen)) do
          Inc(MatchLen, 4);
        Dec(MatchLen, 4);
        while (Ip + MatchLen < InEnd) and
              (InB[Ip + MatchLen] = InB[p + MatchLen]) do
          Inc(MatchLen);
        EsMatch := MatchLen >= ml;
      end;
    end;
    if not EsMatch then
    begin
      OutB[Op] := InB[Ip]; Inc(Op); Inc(Ip);
      { El escape 255 se emite SOLO en el camino MATCH_NOT_FOUND, o sea cuando el
        contexto SÍ coincide (i == lzpC(p)) pero el match salió corto. Si el
        contexto es distinto, un 0xB5 literal se copia SIN escape, porque el
        decoder en ese caso no consume la cola. Confundir los dos caminos emite
        exactamente un 0xFF de más por cada 0xB5 con contexto distinto. }
      if ContextoIgual and (OutB[Op - 1] = LZP_MATCH_FLAG) then
      begin
        Dec(OutEnd); OutB[OutEnd] := 255;
      end;
    end
    else
    begin
      Hash[H] := Ip;
      if (Ip - p > (SizeInt(n1) + 1) * HashSize) and (n1 < 7) then Inc(n1);
      OutB[Op] := LZP_MATCH_FLAG; Inc(Op);
      Back := MatchLen;              { In += (k=i): k pasa a ser el largo del match }
      Inc(Ip, MatchLen);
      Resto := MatchLen - ml;
      while (Resto >= 254) and (Op < OutEnd) do
      begin
        Dec(OutEnd); OutB[OutEnd] := 0;
        Dec(Resto, 254);
      end;
      Dec(OutEnd); OutB[OutEnd] := Byte(Resto + 1);
      while True do
      begin
        Back := Back - (2 * SizeInt(n1) + 1);
        if not (Back > 0) then Break;      { el C compara con signo: int(k) > 0 }
        j := Ip - Back;
        Hash[H32(C32(InB, j), InB, j, Mask)] := j;
      end;
    end;
    Ctx := C32(InB, Ip);
    H := H32(Ctx, InB, Ip, Mask);
  until (Ip >= InEnd) or (Op >= OutEnd);
  if Op >= OutEnd then Exit;
  { memmove(Out, OutEnd, OutStart+Size-OutEnd): la cola quedó escrita al revés }
  Move(OutB[OutEnd], OutB[Op], Size - OutEnd);
  Result := Size - (OutEnd - Op);
end;

{ --- TLzpEncStage --- }

constructor TLzpEncStage.Create(ATarget: TOutStage; const APar: TLzpParams;
                                AMinCompression: Integer);
begin
  if APar.BlockSize <= 0 then raise EUnsupportedMethod.Create('lzp: tamaño de bloque inválido');
  if (APar.MinMatchLen < 1) or (APar.SmallestLen < 1) then
    raise EUnsupportedMethod.Create('lzp: largo mínimo inválido');
  FPar := APar;
  FMinCompression := AMinCompression;
  SetLength(FIn, FPar.BlockSize);
  SetLength(FOut, FPar.BlockSize + 64);
  SetLength(FHash, SizeInt(1) shl FPar.HashSizeLog);
  FInLen := 0;
  inherited Create(ATarget);
end;

procedure TLzpEncStage.VolcarBloque;
var
  OutSize: SizeInt;
  hdr: array[0..3] of Byte;
  n: SizeInt;
begin
  if FInLen <= 0 then Exit;
  OutSize := LzpEncode(@FIn[0], @FOut[0], FInLen, FPar.MinMatchLen,
                       SizeInt(1) shl FPar.HashSizeLog, Integer(FPar.Barrier),
                       FPar.SmallestLen, FHash);
  { Igual que el C: si no comprimió (0) o no alcanza MinCompression, se guarda
    como bloque negativo (stored). }
  if (OutSize = 0) or ((FMinCompression > 0) and
      (OutSize * 100 >= FInLen * FMinCompression)) then
  begin
    n := -FInLen;
    hdr[0] := Byte(LongWord(n)); hdr[1] := Byte(LongWord(n) shr 8);
    hdr[2] := Byte(LongWord(n) shr 16); hdr[3] := Byte(LongWord(n) shr 24);
    Emit(@hdr[0], 4);
    Emit(@FIn[0], FInLen);
  end
  else
  begin
    n := OutSize;
    hdr[0] := Byte(LongWord(n)); hdr[1] := Byte(LongWord(n) shr 8);
    hdr[2] := Byte(LongWord(n) shr 16); hdr[3] := Byte(LongWord(n) shr 24);
    Emit(@hdr[0], 4);
    Emit(@FOut[0], OutSize);
  end;
  FInLen := 0;
end;

procedure TLzpEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    n := FPar.BlockSize - FInLen;
    if n > Count then n := Count;
    Move(Buf^, FIn[FInLen], n);
    Inc(FInLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FInLen >= FPar.BlockSize then VolcarBloque;
  end;
end;

procedure TLzpEncStage.DoFinish;
begin
  VolcarBloque;
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
