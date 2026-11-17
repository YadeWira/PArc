{ test_lz4frame: codifica o decodifica un frame LZ4 suelto con las etapas de PArc, para
  compararlas con la herramienta `lz4` (tests/lz4frame.sh).
    test_lz4frame enc <método lz4:...> <entrada> <salida>
    test_lz4frame dec <entrada> <salida>      (rc 2 si el frame está dañado)
    test_lz4frame blocks <fast|hc> <entrada>   bloques de 1 MB: "<modo> <bytes> <FNV-1a hex>",
                                               para compararlo con LZ4 en C (mismos bytes) }
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
  Src, Dst: TBytes;
  p, k, r, i: SizeInt;
  Tot: Int64;
  H: LongWord;
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
  else if (ParamCount = 3) and (ParamStr(1) = 'blocks') then
  begin
    Fi := TFileStream.Create(ParamStr(3), fmOpenRead);
    SetLength(Src, Fi.Size);
    if Fi.Size > 0 then Fi.ReadBuffer(Src[0], Fi.Size);
    Fi.Free;
    SetLength(Dst, Lz4CompressBound(1 shl 20));
    Tot := 0;
    H := 2166136261;
    p := 0;
    while p < Length(Src) do
    begin
      k := Length(Src) - p;
      if k > 1 shl 20 then k := 1 shl 20;
      if ParamStr(2) = 'hc' then r := Lz4CompressHCBlock(@Src[p], k, @Dst[0], Length(Dst))
      else r := Lz4CompressFastBlock(@Src[p], k, @Dst[0], Length(Dst));
      Inc(Tot, r);
      for i := 0 to r - 1 do H := (H xor Dst[i]) * 16777619;
      Inc(p, k);
    end;
    WriteLn(Format('%s %d %.8x', [ParamStr(2), Tot, H]));
  end
  else
  begin
    WriteLn('uso: test_lz4frame enc <método> <in> <out> | dec <in> <out>');
    ExitCode := 1;
  end;
end.
