{ Validación de parc_grzip contra archivos .arc reales de FreeArc, sin pasar por el CLI.
    tests/test_grzip [-r] [-x DIR] <archivo.arc>...
      Cada bloque de datos con método "grzip[:...]" se decodifica con TGrzipStage (streaming) y
      cada "4x4:...grzip..." con un lector 4x4 mínimo (formato de C_4x4.cpp) que decodifica cada
      bloque con GrzipDecodeMem. Se verifica el CRC de cada archivo en orden dentro del bloque
      (como parc_extract). Otros métodos se saltean.
      -r: lee la salida con tamaños de lectura aleatorios (1 byte .. 1MB).
      -x DIR: además escribe los archivos en DIR/<ruta> (para diff -r contra unarc x).
      Sale con 0 si todos los CRC coinciden y hubo al menos un bloque grzip.
    tests/test_grzip -s <archivo.arc>...
      Estadística de los tipos de bloque grzip presentes (recorre los encabezados de 28 bytes).
    tests/test_grzip -f <casos> <semilla> <archivo.arc>
      Fuzzing: por caso, toma un bloque grzip al azar, corrompe 1..16 bytes (o lo trunca) y lo
      decodifica entero. Válido: decodifica (CRC cualquiera) o lanza EArcCorrupt. Cualquier otra
      excepción es falla. (Los cuelgues se detectan desde afuera con timeout.) }
program test_grzip;
{$mode objfpc}{$H+}
uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, Classes, parc_bytes, parc_stream, parc_crc, parc_archive, parc_grzip;

type
  { 4x4: U32 versión (=0) y bloques [Int32 OutSize][U32 InSize][datos]; OutSize=-1: guardado. }
  T4x4GrzStage = class(TInStage)
  private
    FOut: TBytes;
    FPos, FLen: SizeInt;
    FStarted: Boolean;
    FParams: TStringArray;
  public
    Blocks: Integer;
    constructor Create(ASource: TInStage; const Inner: string);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

constructor T4x4GrzStage.Create(ASource: TInStage; const Inner: string);
begin
  inherited Create(ASource);
  FParams := Inner.Split([':']);
end;

function T4x4GrzStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
var
  hdr: array[0..3] of Byte;
  OutSize: LongInt;
  InSize: LongWord;
  InBuf: TBytes;
begin
  while FPos >= FLen do
  begin
    if not FStarted then
    begin
      FStarted := True;
      if not Source.ReadExactOrEof(@hdr[0], 4) then Exit(0);
      if (hdr[0] or hdr[1] or hdr[2] or hdr[3]) <> 0 then Corrupt('4x4: versión desconocida');
    end;
    if not Source.ReadExactOrEof(@hdr[0], 4) then Exit(0);
    OutSize := LongInt(LongWord(hdr[0]) or (LongWord(hdr[1]) shl 8) or (LongWord(hdr[2]) shl 16) or (LongWord(hdr[3]) shl 24));
    InSize := Source.ReadU32;
    if (InSize > $7FFFFFFF) or (OutSize < -1) or (OutSize > 256 shl 20) then Corrupt('4x4: tamaño inválido');
    SetLength(InBuf, InSize + 1);
    if InSize > 0 then Source.ReadExact(@InBuf[0], InSize);
    Inc(Blocks);
    if OutSize = -1 then
    begin
      FOut := InBuf;
      FLen := InSize;
    end
    else
    begin
      SetLength(FOut, OutSize + 1);
      if not GrzipDecodeMem(PByte(InBuf), InSize, PByte(FOut), OutSize, FParams) then
        Corrupt('4x4: grzip no da el tamaño del bloque');
      FLen := OutSize;
    end;
    FPos := 0;
  end;
  Result := FLen - FPos;
  if Result > Count then Result := Count;
  Move(FOut[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

function IsGrzip(const M: string): Boolean;
begin
  Result := ((M = 'grzip') or (Copy(M, 1, 6) = 'grzip:')) and (Pos('+', M) = 0);
end;

{ Método interno de 4x4 (como Inner4x4Method de parc_methods). }
function Inner4x4(const M: string): string;
var
  P: TStringArray;
  k: Integer;
begin
  Result := '';
  P := M.Split([':']);
  for k := 1 to High(P) do
    if not ((P[k] <> '') and ((P[k][1] in ['0'..'9']) or ((Length(P[k]) > 1) and (P[k][2] in ['0'..'9'])))) then
      Exit(string.Join(':', P, k, Length(P) - k));
end;

function Is4x4Grzip(const M: string): Boolean;
begin
  Result := (Copy(M, 1, 4) = '4x4:') and (Pos('+', M) = 0) and IsGrzip(Inner4x4(M));
end;

function MakeChain(const M: string; Src: TInStage): TInStage;
begin
  if IsGrzip(M) then Result := TGrzipStage.Create(Src, M.Split([':']))
  else Result := T4x4GrzStage.Create(Src, Inner4x4(M));
end;

var
  Stats: TStringList;

function I32(const D: TBytes; P: SizeInt): LongInt;
begin
  Result := LongInt(LongWord(D[P]) or (LongWord(D[P+1]) shl 8) or (LongWord(D[P+2]) shl 16) or (LongWord(D[P+3]) shl 24));
end;

procedure CountKind(const K: string);
var
  i: Integer;
begin
  i := Stats.IndexOf(K);
  if i < 0 then Stats.AddObject(K, TObject(PtrInt(1)))
  else Stats.Objects[i] := TObject(PtrInt(Stats.Objects[i]) + 1);
end;

{ Recorre bloques grzip en D[P..P+Len) y cuenta el tipo de cada uno. }
procedure WalkGrzip(const D: TBytes; P, Len: SizeInt; Sub: Boolean);
var
  E, n: SizeInt;
  Mode, Fbp: LongInt;
  Kind: string;
begin
  E := P + Len;
  while P + 28 <= E do
  begin
    Mode := I32(D, P + 4);
    n := I32(D, P + 16);
    if Sub then Kind := '  sub ' else Kind := '';
    if Mode = -1 then
    begin
      if I32(D, P + 8) = 0 then Kind := Kind + 'guardado' else Kind := Kind + 'guardado+LZP';
    end
    else if Mode = -2 then
    begin
      Kind := Kind + Format('registros RecMode=%d', [I32(D, P + 8)]);
      CountKind(Kind);
      WalkGrzip(D, P + 28, n, True);
      Inc(P, 28 + n);
      Continue;
    end
    else
    begin
      Fbp := I32(D, P + 12);
      if (Mode and 2) <> 0 then Kind := Kind + 'ST4' else if (Fbp and $40000000) <> 0 then Kind := Kind + 'BWT-strong' else Kind := Kind + 'BWT-fast';
      if (Mode and 4) <> 0 then Kind := Kind + '+MTF' else Kind := Kind + '+WFC';
      if (Mode div 256) <> 0 then Kind := Kind + Format('+LZP(l%d,h%d)', [(Mode div 65536) mod 32767, (Mode div 256) mod 256])
      else Kind := Kind + ' sin LZP';
    end;
    CountKind(Kind);
    Inc(P, 28 + n);
  end;
  if P <> E then CountKind('!! resto inesperado');
end;

procedure RunStats(first: Integer);
var
  A: TArchive;
  a_, b, i: Integer;
  Blk: TArcBlock;
  Src: TInStage;
  D: TBytes;
  P, InSize: SizeInt;
  OutSize: LongInt;
begin
  Stats := TStringList.Create;
  for a_ := first to ParamCount do
  begin
    A := TArchive.Open(ParamStr(a_));
    try
      for b := 0 to High(A.DataBlocks) do
      begin
        Blk := A.DataBlocks[b];
        if not (IsGrzip(Blk.Method) or Is4x4Grzip(Blk.Method)) then Continue;
        Src := A.OpenBlockData(Blk);
        try
          SetLength(D, Blk.CompSize);
          if Blk.CompSize > 0 then Src.ReadExact(@D[0], Blk.CompSize);
        finally
          Src.Free;
        end;
        if IsGrzip(Blk.Method) then WalkGrzip(D, 0, Length(D), False)
        else
        begin
          P := 4;
          while P + 8 <= Length(D) do
          begin
            OutSize := I32(D, P); InSize := I32(D, P + 4);
            if OutSize = -1 then CountKind('4x4 guardado') else WalkGrzip(D, P + 8, InSize, False);
            Inc(P, 8 + InSize);
          end;
        end;
      end;
    finally
      A.Free;
    end;
  end;
  for i := 0 to Stats.Count - 1 do WriteLn(Format('%6d  %s', [PtrInt(Stats.Objects[i]), Stats[i]]));
  Halt(0);
end;

var
  RandRead: Boolean = False;
  XDir: string = '';

{ Lee Count bytes de la cadena, en tramos aleatorios si RandRead. }
procedure ReadChunked(Chain: TInStage; Buf: PByte; Count: SizeInt);
var
  n, want: SizeInt;
begin
  if not RandRead then
  begin
    Chain.ReadExact(Buf, Count);
    Exit;
  end;
  while Count > 0 do
  begin
    case Random(4) of
      0: want := 1 + Random(16);
      1: want := 1 + Random(4096);
      2: want := 1 + Random(65536);
    else want := 1 + Random(1 shl 20);
    end;
    if want > Count then want := Count;
    n := Chain.Read(Buf, want);
    if n <= 0 then Corrupt('datos truncados');
    Inc(Buf, n);
    Dec(Count, n);
  end;
end;

procedure RunCheck(first: Integer);
var
  A: TArchive;
  a_, b, i, nOk, nBad, nBlocks: Integer;
  Blk: TArcBlock;
  Chain: TInStage;
  Buf: TBytes;
  Remaining, n: Int64;
  Crc: LongWord;
  extra: Byte;
  FS: TFileStream;
  OutName: string;
begin
  nOk := 0; nBad := 0; nBlocks := 0;
  SetLength(Buf, 1 shl 20);
  for a_ := first to ParamCount do
  begin
    A := TArchive.Open(ParamStr(a_));
    try
      for b := 0 to High(A.DataBlocks) do
      begin
        Blk := A.DataBlocks[b];
        if not (IsGrzip(Blk.Method) or Is4x4Grzip(Blk.Method)) then
        begin
          WriteLn(Format('%s: bloque %d "%s" salteado', [ExtractFileName(ParamStr(a_)), b, Blk.Method]));
          Continue;
        end;
        Inc(nBlocks);
        Chain := MakeChain(Blk.Method, A.OpenBlockData(Blk));
        try
          try
            for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
            begin
              if A.Files[i].IsDir then Continue;
              FS := nil;
              if XDir <> '' then
              begin
                OutName := IncludeTrailingPathDelimiter(XDir) + SanitizePath(A.Files[i].Name);
                ForceDirectories(ExtractFileDir(OutName));
                FS := TFileStream.Create(OutName, fmCreate);
              end;
              try
                Crc := CRC_INIT;
                Remaining := A.Files[i].Size;
                while Remaining > 0 do
                begin
                  if Remaining > Length(Buf) then n := Length(Buf) else n := Remaining;
                  ReadChunked(Chain, @Buf[0], n);
                  Crc := UpdateCRC(Crc, @Buf[0], n);
                  if FS <> nil then FS.WriteBuffer(Buf[0], n);
                  Dec(Remaining, n);
                end;
              finally
                FS.Free;
              end;
              Crc := Crc xor CRC_INIT;
              if Crc = A.Files[i].Crc then Inc(nOk)
              else
              begin
                Inc(nBad);
                WriteLn(Format('  CRC MAL %s (esperado %.8x, obtenido %.8x)', [A.Files[i].Name, A.Files[i].Crc, Crc]));
              end;
            end;
            if Chain.Read(@extra, 1) <> 0 then
            begin
              Inc(nBad);
              WriteLn('  el bloque descomprime a más bytes que la suma de sus archivos');
            end;
            Write(Format('%s: bloque %d "%s", %d archivos, %d -> %d bytes', [ExtractFileName(ParamStr(a_)), b,
              Blk.Method, Blk.FileCount, Blk.CompSize, Blk.OrigSize]));
            if Chain is T4x4GrzStage then Write(Format(' (%d bloques 4x4)', [T4x4GrzStage(Chain).Blocks]));
            WriteLn;
          except
            on E: Exception do
            begin
              Inc(nBad);
              WriteLn(Format('  ERROR en bloque %d: %s: %s', [b, E.ClassName, E.Message]));
            end;
          end;
        finally
          Chain.Free;
        end;
      end;
    finally
      A.Free;
    end;
  end;
  WriteLn(Format('bloques grzip: %d, CRC ok: %d, fallas: %d', [nBlocks, nOk, nBad]));
  if (nBad = 0) and (nBlocks > 0) then Halt(0) else Halt(1);
end;

procedure RunFuzz;
var
  A: TArchive;
  Cases, c, k, nb, nCorrupt, nDecoded, nFail, nFlip: Integer;
  Idx: array of Integer;
  Blk: TArcBlock;
  Raw, Data: TBytes;
  Src, Chain: TInStage;
  Buf: TBytes;
  Total, CompLen: Int64;
  n: SizeInt;
begin
  Cases := StrToInt(ParamStr(2));
  RandSeed := StrToInt(ParamStr(3));
  A := TArchive.Open(ParamStr(4));
  nCorrupt := 0; nDecoded := 0; nFail := 0;
  SetLength(Buf, 1 shl 16);
  try
    for k := 0 to High(A.DataBlocks) do
      if IsGrzip(A.DataBlocks[k].Method) or Is4x4Grzip(A.DataBlocks[k].Method) then
      begin
        SetLength(Idx, Length(Idx) + 1);
        Idx[High(Idx)] := k;
      end;
    if Length(Idx) = 0 then begin WriteLn('sin bloques grzip'); Halt(1); end;
    for c := 1 to Cases do
    begin
      nb := Idx[Random(Length(Idx))];
      Blk := A.DataBlocks[nb];
      Src := A.OpenBlockData(Blk);
      try
        CompLen := Blk.CompSize;
        SetLength(Raw, CompLen);
        if CompLen > 0 then Src.ReadExact(@Raw[0], CompLen);
      finally
        Src.Free;
      end;
      Data := Copy(Raw);
      case Random(10) of
        0: SetLength(Data, Random(Length(Data) + 1));                       // truncado
        1: for k := 0 to Random(4) do                                          // en los encabezados
             if Length(Data) > 0 then Data[Random(Length(Data)) mod 64] := Random(256);
      else
        begin
          nFlip := 1 + Random(16);
          for k := 1 to nFlip do
            if Length(Data) > 0 then
              if Random(2) = 0 then Data[Random(Length(Data))] := Random(256)
              else Data[Random(Length(Data))] := Data[Random(Length(Data))] xor (1 shl Random(8));
        end;
      end;
      Chain := nil;
      try
        try
          Chain := MakeChain(Blk.Method, TMemStage.Create(PByte(Data), Length(Data)));
          Total := 0;
          repeat
            n := Chain.Read(@Buf[0], 1 + Random(Length(Buf)));
            Inc(Total, n);
            if Total > Blk.OrigSize + (64 shl 20) then Corrupt('demasiada salida');
          until n = 0;
          Inc(nDecoded);
        except
          on E: EArcCorrupt do Inc(nCorrupt);
          on E: Exception do
          begin
            Inc(nFail);
            WriteLn(Format('  FALLA caso %d (bloque %d): %s: %s', [c, nb, E.ClassName, E.Message]));
          end;
        end;
      finally
        Chain.Free;
      end;
    end;
  finally
    A.Free;
  end;
  WriteLn(Format('fuzz: %d casos, %d EArcCorrupt, %d decodificados, %d fallas', [Cases, nCorrupt, nDecoded, nFail]));
  if nFail = 0 then Halt(0) else Halt(1);
end;

var
  first: Integer;
begin
  Randomize;
  if (ParamCount >= 4) and (ParamStr(1) = '-f') then RunFuzz;
  if (ParamCount >= 2) and (ParamStr(1) = '-s') then RunStats(2);
  first := 1;
  while (first <= ParamCount) and (Copy(ParamStr(first), 1, 1) = '-') do
  begin
    if ParamStr(first) = '-r' then RandRead := True
    else if ParamStr(first) = '-x' then
    begin
      Inc(first);
      XDir := ParamStr(first);
    end;
    Inc(first);
  end;
  RunCheck(first);
end.
