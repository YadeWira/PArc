{ REP: coincidencias de largo alcance (Compression/REP/rep.cpp, rep_decompress, Bulat Ziganshin).
  Stream: U32 BlockSize (tamaño de la ventana) y bloques hasta un U32 = 0:
    U32 ComprSize, y ComprSize bytes con: U32 num, lens[num], offsets[num], datalens[num+1]
    (Int32 LE) y los literales concatenados.
  Cada bloque alterna literal i / match i (el último literal no lleva match). Las distancias
  son circulares módulo BlockSize (el compresor vuelve al inicio de su buffer al llenarlo),
  así que la ventana tiene que medir exactamente BlockSize. }
unit parc_rep;

{$mode objfpc}{$H+}
{$R-}{$Q-}

interface

uses
  SysUtils, parc_stream;

type
  TRepStage = class(TInStage)
  private
    FWin: array of Byte;       // ventana circular de BlockSize bytes
    FWinSize: SizeInt;
    FWPos: SizeInt;            // posición de escritura en la ventana
    FTotal: QWord;             // bytes producidos en total
    FBlock: array of Byte;     // bloque comprimido actual
    FNum: SizeInt;             // cantidad de matches del bloque
    FTabLens, FTabOffs, FTabData: SizeInt;   // offsets de las tablas dentro de FBlock
    FLitPos: SizeInt;          // próximo literal dentro de FBlock
    FItem: SizeInt;            // índice i del par literal/match actual
    FInMatch: Boolean;         // procesando el match i (si no, el literal i)
    FRemain: SizeInt;          // bytes que faltan del elemento actual
    FMatchDist: SizeInt;
    FHaveBlock, FStarted, FEof: Boolean;
    function Tab(Base, i: SizeInt): LongInt; inline;
    function NextBlock: Boolean;
    procedure StartItem;
  public
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

implementation

uses
  parc_bytes;

function TRepStage.Tab(Base, i: SizeInt): LongInt;
var
  p: SizeInt;
begin
  p := Base + 4 * i;
  Result := LongInt(LongWord(FBlock[p]) or (LongWord(FBlock[p + 1]) shl 8) or
                    (LongWord(FBlock[p + 2]) shl 16) or (LongWord(FBlock[p + 3]) shl 24));
end;

function TRepStage.NextBlock: Boolean;
var
  ComprSize: LongWord;
  i: SizeInt;
  LitTotal: Int64;
begin
  Result := False;
  if not FStarted then
  begin
    FStarted := True;
    // Un empty stream (sin siquiera el tamaño de ventana) es un bloque sin datos
    if not Source.ReadExactOrEof(@ComprSize, 4) then Exit;
    FWinSize := LeToN(ComprSize);
    if (FWinSize <= 0) or (FWinSize > High(SizeInt) div 2) then Corrupt('rep: invalid window size');
    SetLength(FWin, FWinSize);
  end;
  ComprSize := Source.ReadU32;
  if ComprSize = 0 then Exit;   // marca de fin
  if ComprSize < 8 then Corrupt('rep: invalid block');
  if ComprSize > Length(FBlock) then SetLength(FBlock, ComprSize);
  Source.ReadExact(@FBlock[0], ComprSize);
  FNum := LongInt(LongWord(FBlock[0]) or (LongWord(FBlock[1]) shl 8) or (LongWord(FBlock[2]) shl 16) or (LongWord(FBlock[3]) shl 24));
  if (FNum < 0) or (Int64(FNum) * 12 + 8 > ComprSize) then Corrupt('rep: invalid tables');
  FTabLens := 4;
  FTabOffs := FTabLens + 4 * FNum;
  FTabData := FTabOffs + 4 * FNum;
  FLitPos := FTabData + 4 * (FNum + 1);
  // Los literales tienen que ocupar exactamente el resto del bloque
  LitTotal := 0;
  for i := 0 to FNum do
  begin
    if Tab(FTabData, i) < 0 then Corrupt('rep: invalid literal length');
    Inc(LitTotal, Tab(FTabData, i));
  end;
  if LitTotal <> Int64(ComprSize) - FLitPos then Corrupt('rep: literals do not match the block');
  FItem := 0;
  FInMatch := False;
  StartItem;
  Result := True;
end;

procedure TRepStage.StartItem;
begin
  if FInMatch then
  begin
    FRemain := Tab(FTabLens, FItem);
    FMatchDist := Tab(FTabOffs, FItem);
    if FRemain < 0 then Corrupt('rep: invalid match length');
    // La distancia apunta a datos ya producidos y dentro de la ventana
    if (FMatchDist <= 0) or (FMatchDist > FWinSize) or (QWord(FMatchDist) > FTotal) then
      if FRemain > 0 then Corrupt('rep: invalid distance');
  end
  else
    FRemain := Tab(FTabData, FItem);
end;

function TRepStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  n, Src, k: SizeInt;
begin
  Result := 0;
  while Result < Count do
  begin
    if not FHaveBlock or ((FRemain = 0) and not FInMatch and (FItem = FNum)) then
    begin
      // Terminó el bloque (o no hay ninguno): pasar al siguiente
      if FEof then Break;
      if Result > 0 then Break;   // entregamos lo que hay antes de leer más
      FHaveBlock := NextBlock;
      if not FHaveBlock then
      begin
        FEof := True;
        Break;
      end;
      Continue;
    end;
    if FRemain = 0 then
    begin
      // Siguiente elemento: literal i -> match i -> literal i+1 ...
      if FInMatch then
      begin
        FInMatch := False;
        Inc(FItem);
      end
      else
        FInMatch := True;
      StartItem;
      Continue;
    end;

    n := FRemain;
    if n > Count - Result then n := Count - Result;
    if n > FWinSize - FWPos then n := FWinSize - FWPos;
    if not FInMatch then
    begin
      Move(FBlock[FLitPos], FWin[FWPos], n);
      Inc(FLitPos, n);
    end
    else
    begin
      Src := FWPos - FMatchDist;
      if Src < 0 then Inc(Src, FWinSize);
      // Byte a byte en orden creciente: si la distancia es menor que el largo, se replican datos
      for k := 0 to n - 1 do
      begin
        FWin[FWPos + k] := FWin[Src];
        Inc(Src);
        if Src = FWinSize then Src := 0;
      end;
    end;
    Move(FWin[FWPos], Buf[Result], n);
    Inc(Result, n);
    Inc(FWPos, n);
    if FWPos = FWinSize then FWPos := 0;
    Inc(FTotal, n);
    Dec(FRemain, n);
  end;
end;

end.
