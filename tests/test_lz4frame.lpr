{ test_lz4frame: codifica o decodifica un frame LZ4 suelto con las etapas de PArc, para
  compararlas con la herramienta `lz4` (tests/lz4frame.sh).
    test_lz4frame enc <método lz4:...> <entrada> <salida>
    test_lz4frame dec <entrada> <salida>      (rc 2 si el frame está dañado) }
program test_lz4frame;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, parc_bytes, parc_stream, parc_outstream, parc_lz4, parc_lz4enc;

var
  Fi, Fo: TFileStream;
  Sink: TStreamSink;
  Enc: TLz4EncStage;
  Dec: TLz4Stage;
  Buf: array[0..65535] of Byte;
  n: SizeInt;
begin
  if (ParamCount = 4) and (ParamStr(1) = 'enc') then
  begin
    Fi := TFileStream.Create(ParamStr(3), fmOpenRead);
    Fo := TFileStream.Create(ParamStr(4), fmCreate);
    Sink := TStreamSink.Create(Fo);
    Enc := TLz4EncStage.Create(Sink, ParamStr(2).Split([':']));
    repeat
      n := Fi.Read(Buf, SizeOf(Buf));
      if n > 0 then Enc.Write(@Buf[0], n);
    until n = 0;
    Enc.Finish;
    Enc.Free;
    Fo.Free;
    Fi.Free;
  end
  else if (ParamCount = 3) and (ParamStr(1) = 'dec') then
  begin
    Fi := TFileStream.Create(ParamStr(2), fmOpenRead);
    Fo := TFileStream.Create(ParamStr(3), fmCreate);
    Dec := TLz4Stage.Create(TFileSliceStage.Create(Fi, 0, Fi.Size));
    try
      try
        repeat
          n := Dec.Read(@Buf[0], SizeOf(Buf));
          if n > 0 then Fo.WriteBuffer(Buf, n);
        until n = 0;
      except
        on E: EArcCorrupt do
        begin
          WriteLn(E.Message);
          ExitCode := 2;
        end;
      end;
    finally
      Dec.Free;
      Fo.Free;
      Fi.Free;
    end;
  end
  else
  begin
    WriteLn('uso: test_lz4frame enc <método> <in> <out> | dec <in> <out>');
    ExitCode := 1;
  end;
end.
