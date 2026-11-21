{ Regresión: TParallelBlockStage entrega los bloques en el orden del stream aunque la cola crezca
  por la lectura adelantada en bytes (ReadAheadBytes) y después el pool crezca en hilos (CanGrow).
  Si la cola ya había crecido por bytes, crecer en hilos no la agrandaba, y el bloque siguiente
  se escribía en la cola llena encima del de FHead (con 4x4 de -m3 con 4 hilos: "not an OREP
  stream" o un Access violation con REP, de vez en cuando).
  La etapa corre dentro de un trabajo de un pool con Share = 1: empieza con un hilo y puede
  crecer hasta el presupuesto, como al extraer varios bloques sólidos en paralelo.
    fpc -O2 -Fusrc -FUbuild/tests/units -FEbuild/tests tests/test_blockorder.lpr
    PARC_THREADS=4 build/tests/test_blockorder
  Sale con 0 si todo salió en orden. }
program test_blockorder;
{$mode objfpc}{$H+}
uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, parc_stream, parc_parallel;

const
  NBLOCKS = 3000;
  BLOCK = 4096;

type
  { Un bloque chico: se llena con su número de orden (lento a propósito, para que los hilos
    estén ocupados y el pool quiera crecer). }
  TSeqJob = class(TParallelJob)
  public
    Seq: Integer;
    procedure Process; override;
  end;

  TSeqStage = class(TParallelBlockStage)
  private
    FNext: Integer;
  protected
    function ReadJob: TParallelJob; override;
  end;

  TOuterJob = class(TParallelJob)
  public
    Bad: Integer;
    procedure Process; override;
  end;

procedure TSeqJob.Process;
var
  i: Integer;
  x: Cardinal;
begin
  x := Seq;
  for i := 1 to 20000 + (Seq mod 7) * 20000 do x := x * 1664525 + 1013904223;
  OutSize := BLOCK;
  SetLength(OutBuf, BLOCK);
  for i := 0 to BLOCK div 4 - 1 do PLongInt(@OutBuf[4 * i])^ := Seq;
  if x = 0 then OutBuf[0] := 0;   // (que el bucle no se elimine)
end;

function TSeqStage.ReadJob: TParallelJob;
var
  J: TSeqJob;
begin
  if FNext >= NBLOCKS then Exit(nil);
  J := TSeqJob.Create;
  J.Seq := FNext;
  Inc(FNext);
  Result := J;
end;

procedure TOuterJob.Process;
var
  St: TSeqStage;
  Buf: array[0..BLOCK - 1] of Byte;
  Seq, i: Integer;
begin
  Bad := 0;
  St := TSeqStage.Create(nil, 16, 16);
  try
    St.ReadAheadBytes := 64 shl 20;   // muchos bloques chicos: la cola crece por bytes
    for Seq := 0 to NBLOCKS - 1 do
    begin
      St.ReadExact(@Buf[0], BLOCK);
      for i := 0 to BLOCK div 4 - 1 do
        if PLongInt(@Buf[4 * i])^ <> Seq then
        begin
          if Bad < 5 then WriteLn('  bloque ', Seq, ': llegó el ', PLongInt(@Buf[4 * i])^);
          Inc(Bad);
          Break;
        end;
    end;
    if St.Read(@Buf[0], 1) <> 0 then Inc(Bad);
  finally
    St.Free;
  end;
end;

var
  Pool: TJobPool;
  Outer: TOuterJob;
  r, Fails: Integer;
begin
  Fails := 0;
  for r := 1 to 5 do
  begin
    Pool := TJobPool.Create(1, 1);
    Pool.Share := 1;   // la etapa empieza con un hilo (como un bloque de extracción en paralelo)
    Outer := TOuterJob.Create;
    try
      Pool.Submit(Outer);
      Pool.WaitJob(Outer);
      Inc(Fails, Outer.Bad);
    finally
      Pool.Free;
      Outer.Free;
    end;
  end;
  WriteLn('bloques: ', 5 * NBLOCKS, ' fuera de orden: ', Fails);
  if Fails <> 0 then Halt(1);
end.
