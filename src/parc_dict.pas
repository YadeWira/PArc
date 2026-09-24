{ DICT: reemplazo de palabras frecuentes por códigos de 1 o 2 bytes (método `dict` de FreeArc,
  Compression/Dict/dict.cpp: DictDecode; C_Dict.cpp: dict_decompress; Bulat Ziganshin).
  Stream: bloques [Int32 LE InSize][datos] hasta EOF; InSize < 0 = bloque guardado. El tamaño
  de salida no se guarda: como mucho BlockSize (parámetro b, default 64mb).
  Bloque codificado:
    256 bytes: largo de la palabra de cada código de 1 byte (0 = el byte es literal,
               1 = USE_DICT2: el byte arranca un código de 2 bytes)
    256 bytes por cada código USE_DICT2: cuántos bytes comparte cada palabra de 2 bytes con la
               anterior (front coding)
    texto de las palabras de 1 byte, sin separador
    word_sep, y el resto de cada palabra de 2 bytes terminado en word_sep
    prefix: código que pasa a USE_DICT2 para expresar los bytes que cedieron su código
    el texto codificado. }
unit parc_dict;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TDictStage = class(TInStage)
  private
    FBlockSize: SizeInt;
    FIn, FOut: array of Byte;
    FLen, FPos: SizeInt;
    FEof: Boolean;
    function NextBlock: Boolean;
  public
    constructor Create(ASource: TInStage; ABlockSize: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

{ Tamaño de bloque como parse_DICT (b<mem>, o una memoria sin nombre; el resto es del compresor). }
function ParseDictBlockSize(const Params: TStringArray): SizeInt;

{ DictDecode: devuelve los bytes producidos o -1 si los datos son inválidos. }
function DictDecode(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;

implementation

uses
  parc_bytes, parc_methods;

const
  USE_DICT2 = 1;

type
  TDictEntry = record
    Len: SizeInt;
    Ptr: SizeInt;   // offset en el buffer de palabras
  end;

function ParseDictBlockSize(const Params: TStringArray): SizeInt;
var
  k: Integer;
  p: string;
  m: QWord;
begin
  Result := 64 shl 20;
  for k := 1 to High(Params) do
  begin
    p := Params[k];
    if Length(p) < 2 then Continue;                 // 'p', 'f': solo compresor
    if (p[1] = 'b') and ParseMem(Copy(p, 2, MaxInt), m) then Result := m
    else if (p[1] in ['0'..'9']) and (StrToIntDef(p, -1) < 0) and ParseMem(p, m) then
      Result := m;                                   // memoria sin nombre = BlockSize
  end;
end;

function DictDecode(Src: PByte; SrcLen: SizeInt; Dst: PByte; DstCap: SizeInt): SizeInt;
var
  Dict1: array[0..255] of TDictEntry;
  Dict2: array of TDictEntry;       // 256*256, índice i*256+j
  Words: array of Byte;             // texto de todas las palabras, contiguo como en el C
  WPos, Ip, Op, PrevPtr, i, j, k, d: SizeInt;
  WordSep, Prefix, c, c2: Byte;

  function GetByte(out b: Byte): Boolean; inline;
  begin
    Result := Ip < SrcLen;
    if Result then
    begin
      b := Src[Ip];
      Inc(Ip);
    end;
  end;

  procedure PutWord(Ofs, Len: SizeInt); inline;
  begin
    if Len > DstCap - Op then Op := -1
    else
    begin
      Move(Words[Ofs], Dst[Op], Len);
      Inc(Op, Len);
    end;
  end;

  procedure EnsureWords(Extra: SizeInt);
  begin
    if WPos + Extra > Length(Words) then
      SetLength(Words, 2 * (WPos + Extra) + 4096);
  end;

begin
  Result := -1;
  Ip := 0;
  WPos := 0;
  SetLength(Dict2, 256 * 256);
  // 1. Largos de las palabras de 1 byte
  for i := 0 to 255 do
  begin
    if not GetByte(c) then Exit;
    Dict1[i].Len := c;
    Dict1[i].Ptr := 0;
  end;
  // 2. Prefijos compartidos de las palabras de 2 bytes
  for i := 0 to 255 do
    if Dict1[i].Len = USE_DICT2 then
      for j := 0 to 255 do
      begin
        if not GetByte(c) then Exit;
        Dict2[i * 256 + j].Len := c;
      end;
  // 3. Texto de las palabras de 1 byte
  for i := 0 to 255 do
  begin
    if Dict1[i].Len = USE_DICT2 then Continue;
    EnsureWords(Dict1[i].Len);
    Dict1[i].Ptr := WPos;
    for k := 1 to Dict1[i].Len do
    begin
      if not GetByte(c) then Exit;
      Words[WPos] := c;
      Inc(WPos);
    end;
  end;
  // 4. Palabras de 2 bytes: prefijo copiado de la anterior + resto hasta word_sep.
  //    Como en el C, la copia es byte a byte desde PrevPtr dentro del mismo buffer: si el
  //    prefijo es más largo que la palabra anterior, sigue leyendo lo que se va escribiendo
  if not GetByte(WordSep) then Exit;
  PrevPtr := -1;
  for i := 0 to 255 do
    if Dict1[i].Len = USE_DICT2 then
      for j := 0 to 255 do
      begin
        d := i * 256 + j;
        EnsureWords(Dict2[d].Len);
        Dict2[d].Ptr := WPos;
        for k := 1 to Dict2[d].Len do
        begin
          if PrevPtr < 0 then Exit;   // copiar de una palabra anterior que no existe
          Words[WPos] := Words[PrevPtr];
          Inc(WPos);
          Inc(PrevPtr);
        end;
        repeat
          if not GetByte(c) then Exit;
          if c = WordSep then Break;
          EnsureWords(1);
          Words[WPos] := c;
          Inc(WPos);
        until False;
        Dict2[d].Len := WPos - Dict2[d].Ptr;
        PrevPtr := Dict2[d].Ptr;
      end;
  // 5. Pseudo-palabras de 1 byte para los caracteres que cedieron su código
  if not GetByte(Prefix) then Exit;
  Dict1[Prefix].Len := USE_DICT2;
  EnsureWords(256);
  for j := 0 to 255 do
  begin
    Dict2[Prefix * 256 + j].Len := 1;
    Dict2[Prefix * 256 + j].Ptr := WPos;
    Words[WPos] := j;
    Inc(WPos);
  end;

  // Texto codificado
  Op := 0;
  while Ip < SrcLen do
  begin
    c := Src[Ip];
    Inc(Ip);
    if Dict1[c].Len = 0 then
    begin
      if Op >= DstCap then Exit;
      Dst[Op] := c;
      Inc(Op);
    end
    else
    begin
      if Dict1[c].Len = USE_DICT2 then
      begin
        if not GetByte(c2) then Exit;
        PutWord(Dict2[c * 256 + c2].Ptr, Dict2[c * 256 + c2].Len);
      end
      else
        PutWord(Dict1[c].Ptr, Dict1[c].Len);
      if Op < 0 then Exit;
    end;
  end;
  Result := Op;
end;

{ TDictStage }

constructor TDictStage.Create(ASource: TInStage; ABlockSize: SizeInt);
begin
  if ABlockSize <= 0 then raise EUnsupportedMethod.Create('dict: tamaño de bloque inválido');
  inherited Create(ASource);
  FBlockSize := ABlockSize;
end;

function TDictStage.NextBlock: Boolean;
var
  Hdr: array[0..3] of Byte;
  InSize: LongInt;
  n: SizeInt;
begin
  if not Source.ReadExactOrEof(@Hdr[0], 4) then Exit(False);
  InSize := LongInt(LongWord(Hdr[0]) or (LongWord(Hdr[1]) shl 8) or (LongWord(Hdr[2]) shl 16) or (LongWord(Hdr[3]) shl 24));
  if InSize = Low(LongInt) then Corrupt('dict: tamaño de bloque inválido');
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
    if Length(FOut) < FBlockSize then SetLength(FOut, FBlockSize);
    FLen := DictDecode(@FIn[0], InSize, @FOut[0], FBlockSize);
    if FLen < 0 then Corrupt('dict: datos inválidos');
  end;
  FPos := 0;
  Result := True;
end;

function TDictStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
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
