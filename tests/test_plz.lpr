{ test_plz: herramienta de pruebas del códec plz (tests/plz.sh). Sólo usa las unidades del
  códec (no hace falta el build de PArc).
    test_plz enc <método> <entrada> <salida> [trozo]   etapa de streaming (trozo: bytes por
                                                     Write; 0 = al azar con semilla fija)
    test_plz encmem <método> <entrada> <salida>      memoria a memoria (como dentro de 4x4);
                                                     rc 3 si no achica
    test_plz dec <entrada> <salida>                  streaming; rc 2 si el stream está dañado
    test_plz decmem <entrada> <salida> <tamaño>      memoria a memoria; rc 2 si está dañado
    test_plz fuzz <stream> <original> <n> <semilla>  n streams dañados (bits, bytes, cortes,
                       trozos al azar, inserciones) por los dos decodificadores: cada uno tiene
                       que terminar en EArcCorrupt o en datos (nunca otra excepción ni un
                       cuelgue). Imprime cuántos dieron error, cuántos datos iguales y
                       distintos; rc 1 si alguno falló de otra forma. }
program test_plz;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, parc_bytes, parc_stream, parc_outstream, parc_plz, parc_plzenc;

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

var
  Rng: QWord = 88172645463325252;

function Rand(N: LongWord): LongWord;
begin
  Rng := Rng xor (Rng shl 13);
  Rng := Rng xor (Rng shr 7);
  Rng := Rng xor (Rng shl 17);
  if N = 0 then Result := 0 else Result := LongWord(Rng shr 16) mod N;
end;

{ Decodifica S en streaming, hasta Limit bytes. 0 = error limpio (EArcCorrupt), 1 = datos
  iguales a O, 2 = datos distintos, 3 = otra excepción. }
function TryStream(const S, O: TBytes; Limit: SizeInt): Integer;
var
  Dec: TPlzStage;
  Buf: array[0..65535] of Byte;
  n, Tot: SizeInt;
  Same: Boolean;
begin
  Dec := TPlzStage.Create(TMemStage.Create(PByte(S), Length(S)));
  try
    try
      Tot := 0;
      Same := True;
      repeat
        n := Dec.Read(@Buf[0], SizeOf(Buf));
        if n > 0 then
        begin
          if (Tot + n > Length(O)) or not CompareMem(@Buf[0], @O[Tot], n) then Same := False;
          Inc(Tot, n);
        end;
      until (n = 0) or (Tot > Limit);
      if Same and (Tot = Length(O)) then Result := 1 else Result := 2;
    except
      on E: EArcCorrupt do Result := 0;
      on E: Exception do
      begin
        WriteLn('  stream: ', E.ClassName, ': ', E.Message);
        Result := 3;
      end;
    end;
  finally
    Dec.Free;
  end;
end;

function TryMem(const S, O: TBytes): Integer;
var
  D: TBytes;
begin
  SetLength(D, Length(O));
  try
    if not PlzDecodeMem(PByte(S), Length(S), PByte(D), Length(D)) then Result := 0
    else if (Length(O) = 0) or CompareMem(@D[0], @O[0], Length(O)) then Result := 1
    else Result := 2;
  except
    on E: Exception do
    begin
      WriteLn('  mem: ', E.ClassName, ': ', E.Message);
      Result := 3;
    end;
  end;
end;

var
  Src, Dst, Orig, M: TBytes;
  Sink: TMemSink;
  Enc: TOutStage;
  Dec: TInStage;
  Fo: TFileStream;
  Buf: array[0..65535] of Byte;
  n, Chunk, p, i, k, Pos, Len: SizeInt;
  Seed: LongWord;
  Cnt: array[0..1, 0..3] of Integer;
  r: Integer;
begin
  if (ParamCount >= 4) and (ParamStr(1) = 'enc') then
  begin
    Src := ReadFileBytes(ParamStr(3));
    Chunk := 65536;
    if ParamCount >= 5 then Chunk := StrToInt(ParamStr(5));
    Sink := TMemSink.Create;
    Enc := TPlzEncStage.Create(Sink, ParamStr(2).Split([':']));
    p := 0;
    Seed := 12345;
    while p < Length(Src) do
    begin
      n := Chunk;
      if Chunk = 0 then
      begin
        Seed := Seed * 1103515245 + 12345;
        n := 1 + (Seed shr 8) mod 300000;
      end;
      if n > Length(Src) - p then n := Length(Src) - p;
      Enc.Write(@Src[p], n);
      Inc(p, n);
    end;
    Enc.Finish;
    Dst := Sink.Bytes;
    Enc.Free;
    WriteFileBytes(ParamStr(4), PByte(Dst), Length(Dst));
  end
  else if (ParamCount = 4) and (ParamStr(1) = 'encmem') then
  begin
    Src := ReadFileBytes(ParamStr(3));
    if not PlzEncodeMem(ParamStr(2).Split([':']), PByte(Src), Length(Src), Dst) then
    begin
      WriteLn('does not shrink');
      ExitCode := 3;
      Exit;
    end;
    WriteFileBytes(ParamStr(4), PByte(Dst), Length(Dst));
  end
  else if (ParamCount = 3) and (ParamStr(1) = 'dec') then
  begin
    Src := ReadFileBytes(ParamStr(2));
    Fo := TFileStream.Create(ParamStr(3), fmCreate);
    Dec := TPlzStage.Create(TMemStage.Create(PByte(Src), Length(Src)));
    try
      try
        repeat
          n := Dec.Read(@Buf[0], SizeOf(Buf));
          if n > 0 then Fo.WriteBuffer(Buf, n);
        until n = 0;
        // Nada después del fin del stream
        if Dec.Source.Read(@Buf[0], 1) <> 0 then
          raise EArcCorrupt.Create('plz: data after the end of the stream');
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
    end;
  end
  else if (ParamCount = 4) and (ParamStr(1) = 'decmem') then
  begin
    Src := ReadFileBytes(ParamStr(2));
    SetLength(Dst, StrToInt(ParamStr(4)));
    if not PlzDecodeMem(PByte(Src), Length(Src), PByte(Dst), Length(Dst)) then
    begin
      WriteLn('damaged');
      ExitCode := 2;
      Exit;
    end;
    WriteFileBytes(ParamStr(3), PByte(Dst), Length(Dst));
  end
  else if (ParamCount = 5) and (ParamStr(1) = 'fuzz') then
  begin
    Src := ReadFileBytes(ParamStr(2));
    Orig := ReadFileBytes(ParamStr(3));
    n := StrToInt(ParamStr(4));
    Rng := Rng xor (QWord(StrToInt(ParamStr(5))) * 2654435761);
    FillChar(Cnt, SizeOf(Cnt), 0);
    for i := 1 to n do
    begin
      M := Copy(Src, 0, Length(Src));
      case Rand(6) of
        0: for k := 0 to Rand(4) do       // bits sueltos
             if Length(M) > 0 then
             begin
               Pos := Rand(Length(M));
               M[Pos] := M[Pos] xor (1 shl Rand(8));
             end;
        1: if Length(M) > 0 then M[Rand(Length(M))] := Rand(256);   // un byte
        2: SetLength(M, Rand(Length(M) + 1));                        // corte
        3: if Length(M) > 0 then                                      // un trozo al azar
           begin
             Pos := Rand(Length(M));
             Len := 1 + Rand(64);
             for k := Pos to Pos + Len - 1 do
               if k < Length(M) then M[k] := Rand(256);
           end;
        4: begin                                                      // bytes insertados
             Pos := Rand(Length(M) + 1);
             Len := 1 + Rand(16);
             SetLength(M, Length(M) + Len);
             if Length(M) - Len - Pos > 0 then Move(M[Pos], M[Pos + Len], Length(M) - Len - Pos);
             for k := Pos to Pos + Len - 1 do M[k] := Rand(256);
           end;
      else
        if Length(M) > 6 then                                         // bytes del encabezado
        begin
          Pos := Rand(12);
          if Pos < Length(M) then M[Pos] := Rand(256);
        end;
      end;
      r := TryStream(M, Orig, Length(Orig) + (64 shl 20));
      Inc(Cnt[0][r]);
      r := TryMem(M, Orig);
      Inc(Cnt[1][r]);
    end;
    WriteLn(Format('stream: error %d, same %d, different %d, other %d', [Cnt[0][0], Cnt[0][1], Cnt[0][2], Cnt[0][3]]));
    WriteLn(Format('mem:    error %d, same %d, different %d, other %d', [Cnt[1][0], Cnt[1][1], Cnt[1][2], Cnt[1][3]]));
    if (Cnt[0][3] > 0) or (Cnt[1][3] > 0) then ExitCode := 1;
  end
  else
  begin
    WriteLn('uso: test_plz enc|encmem|dec|decmem|fuzz ...');
    ExitCode := 1;
  end;
end.
