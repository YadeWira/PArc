{ plz_bench: mide un método cualquiera (plz, tor, lz4, lzma...) en memoria por las cadenas de
  PArc (CreateEncoderChain / CreateDecoderChain, un hilo de etapa) y, con plz, también el
  camino memoria a memoria de 4x4. Imprime método, bytes, comprimido, CPU y pared de
  compresión, CPU y pared de descompresión (el mínimo de las corridas; CPU del proceso).
    plz_bench <método> <entrada> [corridas]
  Se compila con los objetos del build (el codificador C++ de Tornado):
    fpc -O3 -Fusrc -Fobuild/linux64/units -Flbuild/linux64/units ... tests/plz_bench.lpr }
program plz_bench;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix, Unix, Linux,{$ENDIF}
  Classes, SysUtils, parc_bytes, parc_stream, parc_outstream, parc_plz, parc_plzenc,
  parc_methods, parc_encoders;

function ReadFileBytes(const Name: string): TBytes;
var
  F: TFileStream;
  p, n: Int64;
begin
  F := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    // de a trozos: ReadBuffer/WriteBuffer cuentan en LongInt
    p := 0;
    while p < Length(Result) do
    begin
      n := Length(Result) - p;
      if n > 1 shl 30 then n := 1 shl 30;
      F.ReadBuffer(Result[p], n);
      Inc(p, n);
    end;
  finally
    F.Free;
  end;
end;

procedure WriteFileBytes(const Name: string; P: PByte; N: SizeInt);
var
  F: TFileStream;
  k: SizeInt;
begin
  F := TFileStream.Create(Name, fmCreate);
  try
    while N > 0 do
    begin
      k := N;
      if k > 1 shl 30 then k := 1 shl 30;
      F.WriteBuffer(P^, k);
      Inc(P, k);
      Dec(N, k);
    end;
  finally
    F.Free;
  end;
end;

{$IFDEF UNIX}
function CpuNow: Double;
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_PROCESS_CPUTIME_ID, @T);
  Result := T.tv_sec + T.tv_nsec / 1e9;
end;

function WallNow: Double;
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result := T.tv_sec + T.tv_nsec / 1e9;
end;
{$ELSE}
function CpuNow: Double;
begin
  Result := Now * 86400;
end;

function WallNow: Double;
begin
  Result := Now * 86400;
end;
{$ENDIF}

var
  Src, Dst, Back: TBytes;
  Sink: TMemSink;
  Enc: TOutStage;
  Dec: TInStage;
  Fo: TFileStream;
  Buf: array[0..65535] of Byte;
  n, Chunk, p, Runs, r: SizeInt;
  Seed: LongWord;
  Meth: string;
  c0, w0, CE, WE, CD, WD, CEm, WEm, CDm, WDm: Double;
  Sz, SzMem: SizeInt;
  Ok: Boolean;

procedure CompressChain(const M: string; out Res: TBytes);
var
  S: TMemSink;
  E: TOutStage;
begin
  S := TMemSink.Create;
  E := CreateEncoderChain(M, S);
  try
    E.Write(@Src[0], Length(Src));
    E.Finish;
    Res := S.Bytes;
  finally
    E.Free;
  end;
end;

procedure DecompressChain(const M: string; const C: TBytes; var Res: TBytes);
var
  D: TInStage;
  Extra: Byte;
begin
  D := CreateDecoderChain(M, TMemStage.Create(@C[0], Length(C)));
  try
    if Length(Res) > 0 then D.ReadExact(@Res[0], Length(Res));
    if D.Read(@Extra, 1) <> 0 then raise Exception.Create('more bytes than expected');
  finally
    D.Free;
  end;
end;

begin
  if ParamCount >= 2 then
  begin
    Meth := ParamStr(1);
    Src := ReadFileBytes(ParamStr(2));
    Runs := 2;
    if ParamCount >= 3 then Runs := StrToInt(ParamStr(3));
    CE := 1e9; WE := 1e9; CD := 1e9; WD := 1e9;
    CEm := 1e9; WEm := 1e9; CDm := 1e9; WDm := 1e9;
    SzMem := 0;
    for r := 1 to Runs do
    begin
      c0 := CpuNow; w0 := WallNow;
      CompressChain(Meth, Dst);
      if CpuNow - c0 < CE then CE := CpuNow - c0;
      if WallNow - w0 < WE then WE := WallNow - w0;
      Sz := Length(Dst);
      SetLength(Back, Length(Src));
      c0 := CpuNow; w0 := WallNow;
      DecompressChain(Meth, Dst, Back);
      if CpuNow - c0 < CD then CD := CpuNow - c0;
      if WallNow - w0 < WD then WD := WallNow - w0;
      if (Length(Src) > 0) and not CompareMem(@Src[0], @Back[0], Length(Src)) then
      begin
        WriteLn('MISMATCH ', Meth);
        ExitCode := 1;
        Exit;
      end;
      if Copy(Meth, 1, 4) = 'plz:' then
      begin
        c0 := CpuNow; w0 := WallNow;
        Ok := PlzEncodeMem(Meth.Split([':']), PByte(Src), Length(Src), Dst);
        if CpuNow - c0 < CEm then CEm := CpuNow - c0;
        if WallNow - w0 < WEm then WEm := WallNow - w0;
        if Ok then
        begin
          SzMem := Length(Dst);
          FillChar(Back[0], Length(Back), 0);
          c0 := CpuNow; w0 := WallNow;
          if not PlzDecodeMem(PByte(Dst), Length(Dst), PByte(Back), Length(Back)) or
             not CompareMem(@Src[0], @Back[0], Length(Src)) then
          begin
            WriteLn('MISMATCH mem ', Meth);
            ExitCode := 1;
            Exit;
          end;
          if CpuNow - c0 < CDm then CDm := CpuNow - c0;
          if WallNow - w0 < WDm then WDm := WallNow - w0;
        end;
      end;
    end;
    WriteLn(Format('%s,%d,%d,%.3f,%.3f,%.3f,%.3f', [Meth, Length(Src), Sz, CE, WE, CD, WD]));
    if SzMem > 0 then
      WriteLn(Format('%s(mem),%d,%d,%.3f,%.3f,%.3f,%.3f', [Meth, Length(Src), SzMem, CEm, WEm, CDm, WDm]));
  end
  else
  begin
    WriteLn('uso: plz_bench <método> <entrada> [corridas]');
    ExitCode := 1;
  end;
end.
