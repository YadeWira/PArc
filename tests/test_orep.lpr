{ Pruebas de las etapas de OREP (parc_orep): ida y vuelta por TOrepEncStage/TOrepDecStage con
  escrituras y lecturas de tamaños al azar, igualdad con OrepEncodeBuf (la misma salida que la
  unidad de OREP), y streams dañados (bytes cambiados, cortados, con basura al final, encabezado
  con más memoria de la que declara el método): solo EArcCorrupt, nunca otro error ni un cuelgue.

  Uso: test_orep suite <archivo>...        ida y vuelta con varios métodos
       test_orep corrupt <archivo> <n> <semilla> }
program test_orep;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, parc_bytes, parc_stream, parc_outstream, parc_orep, orep;

var
  Fails: Integer = 0;

procedure Bad(const Msg: string);
begin
  Inc(Fails);
  WriteLn('  FAIL ', Msg);
end;

function LoadFile(const Name: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Name, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if Length(Result) > 0 then F.ReadBuffer(Result[0], Length(Result));
  finally
    F.Free;
  end;
end;

function MethodOf(const Text: string): TOrepMethod;
begin
  Result := ParseOrepMethod(Text.Split([':']));
end;

{ Codifica con la etapa, escribiendo de a trozos de tamaño al azar (hasta MaxPiece). }
function Encode(const Data: TBytes; const Method: string; MaxPiece: Integer): TBytes;
var
  Sink: TMemSink;
  St: TOrepEncStage;
  Pos, n: SizeInt;
begin
  Sink := TMemSink.Create;
  St := TOrepEncStage.Create(Sink, MethodOf(Method));
  try
    Pos := 0;
    while Pos < Length(Data) do
    begin
      n := 1 + Random(MaxPiece);
      if n > Length(Data) - Pos then n := Length(Data) - Pos;
      St.Write(@Data[Pos], n);
      Inc(Pos, n);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;   // libera también Sink
  end;
end;

{ Decodifica leyendo de a trozos de tamaño al azar; lanza lo que lance la etapa. }
function Decode(const Stream: TBytes; const Method: string; MaxPiece: Integer): TBytes;
var
  St: TOrepDecStage;
  Buf: array of Byte;
  n, Len: SizeInt;
  P: PByte;
begin
  P := nil;
  if Length(Stream) > 0 then P := @Stream[0];
  St := TOrepDecStage.Create(TMemStage.Create(P, Length(Stream)), MethodOf(Method));
  try
    SetLength(Buf, MaxPiece);
    Len := 0;
    Result := nil;
    repeat
      n := St.Read(@Buf[0], 1 + Random(MaxPiece));
      if n > 0 then
      begin
        if Len + n > Length(Result) then SetLength(Result, 2 * (Len + n));
        Move(Buf[0], Result[Len], n);
        Inc(Len, n);
      end;
    until n = 0;
    SetLength(Result, Len);
  finally
    St.Free;
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

procedure Suite(const Names: array of string);
const
  Methods: array[0..11] of string = ('orep', 'orep:96mb:l256', 'orep:16mb:l64:a4',
    'orep:8mb:l512:s16:c2', 'orep:1mb:l16:a1', 'orep:2mb:l32:a1:s64', 'orep:4mb:l64:b64kb',
    'orep:64mb:l128:b64mb', 'orep:4mb:l64:d1mb', 'orep:256kb:l4096:a4096', 'orep:1kb:l16',
    'orep:4mb:l20:a3:s7:c1:b128kb');
var
  Inputs: array of TBytes;
  i, m, k: Integer;
  Enc, Dec, Ref: TBytes;
  P: TOrepParams;
  Dst: PByte;
  DstLen: SizeUInt;
begin
  SetLength(Inputs, Length(Names) + 4);
  for i := 0 to High(Names) do Inputs[i] := LoadFile(Names[i]);
  // vacía, 1 byte, 100 bytes iguales y un período corto largo (anclas forzadas)
  k := Length(Names);
  Inputs[k] := nil;
  SetLength(Inputs[k + 1], 1); Inputs[k + 1][0] := 7;
  SetLength(Inputs[k + 2], 100); FillChar(Inputs[k + 2][0], 100, 1);
  SetLength(Inputs[k + 3], 3 shl 20);
  for i := 0 to High(Inputs[k + 3]) do Inputs[k + 3][i] := Byte((i mod 37) * 11);
  for m := 0 to High(Methods) do
    for i := 0 to High(Inputs) do
    begin
      try
        Enc := Encode(Inputs[i], Methods[m], 1 + Random(3 shl 20));
        Dec := Decode(Enc, Methods[m], 1 + Random(1 shl 20));
        if not SameBytes(Dec, Inputs[i]) then
          Bad(Format('%s, entrada %d (%d bytes): ida y vuelta distinta', [Methods[m], i, Length(Inputs[i])]))
        else
        begin
          // la misma salida que OrepEncodeBuf de la unidad, con la misma ventana (sin SizeHint:
          // la etapa no lo usa) y con cualquier cantidad de hilos
          for k := 1 to 3 do
          begin
            P := OrepParamsOf(MethodOf(Methods[m]), k * 2 - 1);
            P.SizeHint := QWord(MethodOf(Methods[m]).Window);
            if OrepEncodeBuf(PByte(Inputs[i]), Length(Inputs[i]), P, Dst, DstLen) <> OREP_OK then
              Bad(Methods[m] + ': OrepEncodeBuf falló')
            else
            begin
              SetLength(Ref, DstLen);
              if DstLen > 0 then Move(Dst^, Ref[0], DstLen);
              FreeMem(Dst);
              if not SameBytes(Ref, Enc) then
                Bad(Format('%s, entrada %d: etapa <> OrepEncodeBuf con %d hilos', [Methods[m], i, P.Threads]));
            end;
          end;
        end;
      except
        on E: Exception do Bad(Format('%s, entrada %d: %s: %s', [Methods[m], i, E.ClassName, E.Message]));
      end;
    end;
  WriteLn(Format('  suite: %d métodos x %d entradas', [Length(Methods), Length(Inputs)]));
end;

procedure Corrupt(const Name: string; Iters, Seed: Integer);
const
  Method = 'orep:2mb:l32:b64kb';
  Methods2: array[0..2] of string = ('orep:4mb:b64kb', 'orep:8mb:b1mb', 'orep:64mb:b64mb');
var
  Data, Enc, D, Dec: TBytes;
  i, j, n, Kind, Caught, Same: Integer;
  Big: TBytes;
begin
  Data := LoadFile(Name);
  Enc := Encode(Data, Method, 1 shl 20);
  RandSeed := Seed;
  Caught := 0;
  Same := 0;
  for i := 1 to Iters do
  begin
    D := Copy(Enc);
    Kind := Random(4);
    case Kind of
      0: begin   // bytes cambiados
           n := 1 + Random(8);
           for j := 1 to n do D[Random(Length(D))] := Byte(Random(256));
         end;
      1: SetLength(D, Random(Length(D)));                    // cortado
      2: begin                                               // basura al final
           n := 1 + Random(64);
           SetLength(D, Length(D) + n);
           for j := Length(D) - n to High(D) do D[j] := Byte(Random(256));
         end;
      3: D[Random(28)] := D[Random(28)] xor Byte(1 + Random(255));   // encabezado
    end;
    try
      Dec := Decode(D, Method, 1 + Random(1 shl 20));
      if SameBytes(Dec, Data) and SameBytes(D, Enc) then Inc(Same)
      else if SameBytes(Dec, Data) then Inc(Same)   // el cambio no tocó nada (p. ej. igual byte)
      else Bad(Format('daño %d (tipo %d): decodificó otra cosa sin error', [i, Kind]));
    except
      on E: EArcCorrupt do Inc(Caught);
      on E: Exception do Bad(Format('daño %d (tipo %d): %s: %s', [i, Kind, E.ClassName, E.Message]));
    end;
  end;
  // Un encabezado que pide más memoria que la que declara el método
  try
    Decode(Encode(Data, 'orep:64mb', 1 shl 20), 'orep:2mb', 1 shl 16);
    Bad('ventana del stream más grande que la del método: sin error');
  except
    on E: EArcCorrupt do Inc(Caught);
    on E: Exception do Bad('ventana más grande: ' + E.ClassName + ': ' + E.Message);
  end;
  // Regresión (OREP 0.0.10): tras un encabezado rechazado por el límite de memoria, los streams
  // siguientes en el mismo proceso (con otros tamaños de bloque, y por el pool de
  // decodificadores) tienen que salir bien: el decodificador rechazado no se reusa
  for j := 1 to 3 do
  begin
    try
      Decode(Encode(Data, 'orep:64mb:b64mb', 1 shl 20), 'orep:2mb:b64kb', 1 shl 16);
      Bad('límite de memoria: sin error');
    except
      on E: EArcCorrupt do Inc(Caught);
      on E: Exception do Bad('límite de memoria: ' + E.ClassName + ': ' + E.Message);
    end;
    for Kind := 0 to 2 do
    begin
      D := Encode(Data, Methods2[Kind], 1 shl 20);
      try
        if not SameBytes(Decode(D, Methods2[Kind], 1 + Random(1 shl 20)), Data) then
          Bad('después de un rechazo: ' + Methods2[Kind] + ' distinto');
      except
        on E: Exception do Bad('después de un rechazo: ' + Methods2[Kind] + ': ' + E.Message);
      end;
    end;
  end;
  // Un stream vacío no es un stream de OREP
  try
    SetLength(Big, 0);
    Decode(Big, Method, 16);
    Bad('stream vacío: sin error');
  except
    on E: EArcCorrupt do Inc(Caught);
    on E: Exception do Bad('stream vacío: ' + E.ClassName + ': ' + E.Message);
  end;
  WriteLn(Format('  corrupt: %d detectados, %d sin cambio en la salida, %d fallas', [Caught, Same, Fails]));
end;

var
  Files: array of string;
  a: Integer;
begin
  Randomize;
  if (ParamCount >= 2) and (ParamStr(1) = 'suite') then
  begin
    RandSeed := 12345;
    SetLength(Files, ParamCount - 1);
    for a := 2 to ParamCount do Files[a - 2] := ParamStr(a);
    Suite(Files);
  end
  else if (ParamCount = 4) and (ParamStr(1) = 'corrupt') then
    Corrupt(ParamStr(2), StrToInt(ParamStr(3)), StrToInt(ParamStr(4)))
  else
  begin
    WriteLn('uso: test_orep suite <archivos> | corrupt <archivo> <n> <semilla>');
    Halt(2);
  end;
  if Fails > 0 then Halt(1);
end.
