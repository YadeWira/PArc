{ Regresión: liberar (o reusar) un trabajo apenas WaitJob/WaitJobQuiet vuelve no puede pisar al
  hilo del pool que todavía está señalando su evento (Run publicaba FFinished y recién después
  llamaba a RTLEventSetEvent: el que esperaba destruía el evento en el medio).
  Se compila con -dPARC_RACE_TEST, que agranda esa ventana con una pausa y cuenta los trabajos
  destruidos con Run todavía adentro:
    fpc -O2 -dPARC_RACE_TEST -Fusrc -FUbuild/tests/race -FEbuild/tests tests/test_jobfree.lpr
    PARC_THREADS=4 build/tests/test_jobfree
  Sale con 0 si no hubo ninguno. }
program test_jobfree;
{$mode objfpc}{$H+}
{$IFNDEF PARC_RACE_TEST}
  {$FATAL compilar con -dPARC_RACE_TEST}
{$ENDIF}
uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils, parc_parallel;

type
  TSpinJob = class(TParallelJob)
  public
    procedure Process; override;
  end;

procedure TSpinJob.Process;
var
  i: Integer;
  x: Cardinal;
begin
  x := 1;
  for i := 1 to 200000 do x := x * 1664525 + 1013904223;
  OutSize := x and 1;
end;

const
  NJOBS = 3;
  ROUNDS = 40;
var
  Pool: TJobPool;
  Jobs: array[0..NJOBS - 1] of TParallelJob;
  r, i, Reused: Integer;
begin
  RaceSleepMs := 5;
  Reused := 0;
  Pool := TJobPool.Create(NJOBS, NJOBS);
  try
    for r := 1 to ROUNDS do
    begin
      for i := 0 to NJOBS - 1 do
      begin
        Jobs[i] := TSpinJob.Create;
        Pool.Submit(Jobs[i]);
      end;
      for i := 0 to NJOBS - 1 do
      begin
        Pool.WaitJobQuiet(Jobs[i]);
        if Odd(r) then
        begin
          // Reuso inmediato (como los trabajos de hashing de REP): tiene que volver a esperar
          Jobs[i].ResetForReuse;
          Pool.Submit(Jobs[i]);
          Pool.WaitJob(Jobs[i]);
          Inc(Reused);
        end;
        Jobs[i].Free;   // como TParallelBlockStage.ReleaseJob
      end;
    end;
  finally
    Pool.Free;
  end;
  WriteLn('trabajos: ', ROUNDS * NJOBS, ' reusados: ', Reused, ' destruidos con Run adentro: ', RaceHits);
  if RaceHits <> 0 then Halt(1);
end.
