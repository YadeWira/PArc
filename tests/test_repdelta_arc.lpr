{ Compatibilidad de parc_repenc/parc_deltaenc con FreeArc real, sin pasar por el CLI:
    tests/test_repdelta_arc <archivo.arc>...
  Para cada bloque de datos cuyo método es solo "rep[:...]" o "delta[:...]" (creados por
  arc.exe, p. ej. `arc a -mrep:b1mb:l64 x.arc ...`, o por PArc):
    1. lo descomprime con TRepStage/TDeltaStage y verifica el CRC de cada archivo;
    2. vuelve a comprimir lo descomprimido con TRepEncStage/TDeltaEncStage y los parámetros
       del método del bloque, y compara con los bytes guardados en el .arc.
  El paso 2 informa "idéntico" o "distinto": arc.exe puede leer su entrada en pedazos
  parciales (el resultado de rep/delta depende del patrón de lectura) y usa HTBUFS según su
  cantidad de hilos, así que "distinto" no es error mientras el paso 1 pase.
  Opciones (antes de los archivos): --strict exige identidad; --threads=N usa HTBUFS de N
  hilos (arc.exe usa tantos como núcleos); --as=METODO recomprime con ese método en vez del
  guardado (que omite ":cN").
  Sale con 0 si todos los CRC coinciden y hubo al menos un bloque rep/delta. }
program test_repdelta_arc;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, parc_bytes, parc_stream, parc_crc, parc_archive, parc_outstream,
  parc_rep, parc_filters, parc_repenc, parc_deltaenc;

function StageKind(const M: string): Integer;   // 1 rep, 2 delta, 0 otro
var
  Name: string;
begin
  Result := 0;
  if Pos('+', M) > 0 then Exit;
  Name := M.Split([':'])[0];
  if Name = 'rep' then Result := 1
  else if Name = 'delta' then Result := 2;
end;

function ReadAll(S: TInStage): TBytes;
var
  n, len: SizeInt;
begin
  SetLength(Result, 1 shl 20);
  len := 0;
  repeat
    if len = Length(Result) then SetLength(Result, 2 * len);
    n := S.Read(@Result[len], Length(Result) - len);
    Inc(len, n);
  until n = 0;
  SetLength(Result, len);
end;

function Encode(const Method: string; const Data: TBytes; Threads: Integer): TBytes;
var
  Sink: TMemSink;
  St: TOutStage;
  Parts: TStringArray;
  rp: TRepEncParams;
begin
  Sink := TMemSink.Create;
  Parts := Method.Split([':']);
  try
    if Parts[0] = 'rep' then
    begin
      rp := ParseRepEncParams(Parts);
      rp.Threads := Threads;
      St := TRepEncStage.Create(Sink, rp);
    end
    else
      St := TDeltaEncStage.Create(Sink, Parts);
  except
    Sink.Free;
    raise;
  end;
  try
    if Length(Data) > 0 then St.Write(@Data[0], Length(Data));
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

var
  A: TArchive;
  a_, b, i, k, nOk, nBad, nBlocks, nSame, nDiff, Threads: Integer;
  Blk: TArcBlock;
  Raw, Dec, Enc: TBytes;
  Src: TInStage;
  Chain: TInStage;
  Pos_: SizeInt;
  Crc: LongWord;
  Strict, Same: Boolean;
  Arg, AsMethod, M: string;
begin
  nOk := 0; nBad := 0; nBlocks := 0; nSame := 0; nDiff := 0;
  Strict := False;
  Threads := 1;
  AsMethod := '';
  for a_ := 1 to ParamCount do
  begin
    Arg := ParamStr(a_);
    if Arg = '--strict' then begin Strict := True; Continue; end;
    if Copy(Arg, 1, 10) = '--threads=' then begin Threads := StrToInt(Copy(Arg, 11, MaxInt)); Continue; end;
    // El método guardado en el .arc omite ChunkSize (ShowCompressionMethod con purify):
    // --as=METODO recomprime con otro método (p. ej. el de la línea de comandos original)
    if Copy(Arg, 1, 5) = '--as=' then begin AsMethod := Copy(Arg, 6, MaxInt); Continue; end;
    A := TArchive.Open(Arg);
    try
      for b := 0 to High(A.DataBlocks) do
      begin
        Blk := A.DataBlocks[b];
        k := StageKind(Blk.Method);
        if k = 0 then
        begin
          WriteLn(Format('%s: bloque %d "%s" salteado', [ExtractFileName(Arg), b, Blk.Method]));
          Continue;
        end;
        Inc(nBlocks);
        try
          Src := A.OpenBlockData(Blk);
          Raw := ReadAll(Src);
          Src.Free;
          // 1. Descomprimir con el decodificador de PArc y verificar los CRC
          if k = 1 then Chain := TRepStage.Create(TMemStage.Create(PByte(Raw), Length(Raw)))
          else Chain := TDeltaStage.Create(TMemStage.Create(PByte(Raw), Length(Raw)));
          try
            Dec := ReadAll(Chain);
          finally
            Chain.Free;
          end;
          Pos_ := 0;
          for i := Blk.FirstFile to Blk.FirstFile + Blk.FileCount - 1 do
          begin
            if A.Files[i].IsDir then Continue;
            if Pos_ + A.Files[i].Size > Length(Dec) then
            begin
              Inc(nBad);
              WriteLn('  el bloque descomprime a menos bytes que la suma de sus archivos');
              Break;
            end;
            Crc := CalcCRC(@Dec[Pos_], A.Files[i].Size);
            Inc(Pos_, A.Files[i].Size);
            if Crc = A.Files[i].Crc then Inc(nOk)
            else
            begin
              Inc(nBad);
              WriteLn(Format('  CRC MAL %s', [A.Files[i].Name]));
            end;
          end;
          if Pos_ <> Length(Dec) then
          begin
            Inc(nBad);
            WriteLn('  el bloque descomprime a otra cantidad de bytes que la suma de sus archivos');
          end;
          // 2. Recomprimir con nuestro codificador y comparar con lo que hay en el .arc
          if AsMethod <> '' then M := AsMethod else M := Blk.Method;
          Enc := Encode(M, Dec, Threads);
          Same := SameBytes(Enc, Raw);
          if Same then Inc(nSame) else Inc(nDiff);
          if Strict and not Same then Inc(nBad);
          WriteLn(Format('%s: bloque %d "%s", %d archivos, %d -> %d bytes; recomprimido: %s', [ExtractFileName(Arg), b,
            Blk.Method, Blk.FileCount, Blk.OrigSize, Blk.CompSize,
            BoolToStr(Same, 'idéntico', Format('DISTINTO (%d bytes)', [Length(Enc)]))]));
        except
          on E: Exception do
          begin
            Inc(nBad);
            WriteLn(Format('  ERROR en bloque %d: %s: %s', [b, E.ClassName, E.Message]));
          end;
        end;
      end;
    finally
      A.Free;
    end;
  end;
  WriteLn(Format('bloques rep/delta: %d, CRC ok: %d, fallas: %d, recompresión idéntica: %d, distinta: %d',
    [nBlocks, nOk, nBad, nSame, nDiff]));
  if (nBad = 0) and (nBlocks > 0) then Halt(0) else Halt(1);
end.
