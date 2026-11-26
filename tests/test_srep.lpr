{ Pruebas de la etapa srep (parc_osrep, OSREP -m6): ida y vuelta por TSrepEncStage/TSrepDecStage
  con escrituras y lecturas de tamaños al azar y varios juegos de parámetros, el byte del bloque
  (0 = tal cual, 1 = stream de OSREP), igualdad con OsrepM6Encode (la misma salida que la unidad
  de OSREP), un bloque de SREP de FreeArc (error claro), y streams dañados (bytes cambiados,
  cortados, con basura al final): solo EArcCorrupt, nunca otro error ni un cuelgue.

  Uso: test_srep suite
       test_srep corrupt <n> <semilla> }
program test_srep;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, parc_bytes, parc_stream, parc_outstream, parc_methods, parc_osrep, osrep_m6;

var
  Fails: Integer = 0;
  Checks: Integer = 0;

procedure Bad(const Msg: string);
begin
  Inc(Fails);
  WriteLn('  FAIL ', Msg);
end;

procedure Check(Cond: Boolean; const Msg: string);
begin
  Inc(Checks);
  if not Cond then Bad(Msg);
end;

{ Codifica con escrituras de tamaños al azar }
function Encode(const Method: string; const D: TBytes): TBytes;
var
  Sink: TMemSink;
  St: TSrepEncStage;
  P, N: SizeInt;
begin
  Sink := TMemSink.Create;
  St := TSrepEncStage.Create(Sink, ParseSrepMethod(Method.Split([':'])), 0);
  try
    P := 0;
    while P < Length(D) do
    begin
      N := 1 + Random(200000);
      if N > Length(D) - P then N := Length(D) - P;
      St.Write(@D[P], N);
      Inc(P, N);
    end;
    St.Finish;
    Result := Sink.Bytes;
  finally
    St.Free;
  end;
end;

{ Decodifica con lecturas de tamaños al azar }
function Decode(const E: TBytes): TBytes;
var
  St: TInStage;
  Buf: array[0..65535] of Byte;
  N, Len: SizeInt;
begin
  Result := nil;
  Len := 0;
  St := TSrepDecStage.Create(TMemStage.Create(PByte(E), Length(E)));
  try
    repeat
      N := St.Read(@Buf[0], 1 + Random(SizeOf(Buf)));
      if N > 0 then
      begin
        SetLength(Result, Len + N);
        Move(Buf[0], Result[Len], N);
        Inc(Len, N);
      end;
    until N = 0;
  finally
    St.Free;
  end;
end;

function Same(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function RandBytes(N: SizeInt): TBytes;
var
  i: SizeInt;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := Random(256);
end;

{ Un trozo al azar de 256 KB repetido muchas veces, con cambios y desplazamientos, entre ruido }
function Repetitive(N: SizeInt): TBytes;
var
  Chunk: TBytes;
  P, L, k: SizeInt;
begin
  Chunk := RandBytes(256 * 1024);
  SetLength(Result, N);
  P := 0;
  while P < N do
  begin
    L := 1000 + Random(Length(Chunk) - 1000);
    if L > N - P then L := N - P;
    k := Random(Length(Chunk) - L + 1);
    Move(Chunk[k], Result[P], L);
    if (L > 10) and (Random(2) = 0) then Result[P + Random(L)] := Random(256);
    Inc(P, L);
    L := Random(3000);
    if L > N - P then L := N - P;
    for k := 0 to L - 1 do Result[P + k] := Random(256);
    Inc(P, L);
  end;
end;

function TextLike(N: SizeInt): TBytes;
const
  W: array[0..11] of string = ('the ', 'archive ', 'block ', 'match ', 'of ', 'and ',
    'stream ', 'decoder ', 'PArc ', 'OSREP ', #10, 'begin end; ');
var
  S: string;
begin
  S := '';
  while Length(S) < N do S := S + W[Random(12)];
  SetLength(Result, N);
  if N > 0 then Move(S[1], Result[0], N);
end;

procedure Suite;
const
  Methods: array[0..6] of string = ('srep', 'srep:l32:a1', 'srep:l64:a1:b64kb', 'srep:l4096:a4096',
    'osrep:1024', 'srep:m3f:l512', 'srep:a4:b1mb');
var
  Inputs: array of TBytes;
  Names: array of string;
  i, j: Integer;
  E, D, Ref: TBytes;
  M: TSrepMethod;
  P: TOsrepM6Params;
  Cap, OutLen: QWord;

  procedure Add(const N: string; const B: TBytes);
  begin
    SetLength(Inputs, Length(Inputs) + 1);
    SetLength(Names, Length(Names) + 1);
    Inputs[High(Inputs)] := B;
    Names[High(Names)] := N;
  end;

begin
  Add('empty', nil);
  Add('1 byte', RandBytes(1));
  Add('100 bytes', RandBytes(100));
  Add('random 1 MB', RandBytes(1 shl 20));
  Add('repetitive 5 MB', Repetitive(5 shl 20));
  Add('text 3 MB', TextLike(3 shl 20));
  Add('zeros 2 MB', nil);
  SetLength(Inputs[High(Inputs)], 2 shl 20);
  FillChar(Inputs[High(Inputs)][0], 2 shl 20, 0);
  for j := 0 to High(Methods) do
    for i := 0 to High(Inputs) do
    begin
      E := Encode(Methods[j], Inputs[i]);
      try
        D := Decode(E);
        Check(Same(D, Inputs[i]), Methods[j] + ' ' + Names[i] + ': round trip');
      except
        on X: Exception do Bad(Methods[j] + ' ' + Names[i] + ': ' + X.ClassName + ' ' + X.Message);
      end;
      if Length(Inputs[i]) = 0 then
        Check(Length(E) = 0, Methods[j] + ' empty: empty block')
      else
      begin
        Check(Length(E) <= Length(Inputs[i]) + 1, Methods[j] + ' ' + Names[i] + ': never larger than stored');
        // the same bytes as the OSREP unit
        if E[0] = 1 then
        begin
          M := ParseSrepMethod(Methods[j].Split([':']));
          OsrepM6ParamsDefault(P);
          P.MinLen := M.MinLen; P.Align := M.Align; P.BlockSize := M.Block;
          Cap := OsrepM6Bound(Length(Inputs[i]), P);
          SetLength(Ref, Cap);
          Check(OsrepM6Encode(@Inputs[i][0], Length(Inputs[i]), @Ref[0], Cap, OutLen, P) = OSREP_M6_OK,
            Methods[j] + ' ' + Names[i] + ': OsrepM6Encode');
          Check((QWord(Length(E)) = OutLen + 1) and CompareMem(@E[1], @Ref[0], OutLen),
            Methods[j] + ' ' + Names[i] + ': same stream as OsrepM6Encode');
        end
        else
          Check(E[0] = 0, Methods[j] + ' ' + Names[i] + ': flag 0 or 1');
      end;
      if (Names[i] = 'random 1 MB') then
        Check((Length(E) > 0) and (E[0] = 0), Methods[j] + ' random: stored');
      if (Names[i] = 'repetitive 5 MB') or (Names[i] = 'zeros 2 MB') then
        Check((Length(E) > 0) and (E[0] = 1) and (Length(E) < Length(Inputs[i]) div 2),
          Methods[j] + ' ' + Names[i] + ': OSREP stream, smaller');
    end;
  // parameters
  for i := 0 to 5 do
  begin
    try
      case i of
        0: ParseSrepMethod(['srep', 'l31']);
        1: ParseSrepMethod(['srep', 'l65537']);
        2: ParseSrepMethod(['srep', 'a0']);
        3: ParseSrepMethod(['srep', 'b32kb']);
        4: ParseSrepMethod(['srep', 'x1']);
        5: ParseSrepMethod(['srep', 'b512mb']);
      end;
      Bad('invalid parameter accepted (' + IntToStr(i) + ')');
    except
      on EUnsupportedMethod do Inc(Checks);
    end;
  end;
  Check(SrepMethodText(ParseSrepMethod(['srep'])) = 'srep', 'canonical srep');
  Check(SrepMethodText(ParseSrepMethod(['osrep', '64', 'a1', 'b1mb', 'm3f'])) = 'srep:l64:a1:b1mb',
    'canonical srep:l64:a1:b1mb');
  // a FreeArc SREP block (what PArc 0.0.5 wrote): a clear error
  E := TBytes.Create(1, $17, $18, $35, $26, Ord('S'), Ord('R'), Ord('E'), Ord('P'), 3, 1, 0, 0, 0, 0, 0, 0, 0);
  try
    Decode(E);
    Bad('FreeArc SREP block accepted');
  except
    on X: EUnsupportedMethod do Check(Pos('FreeArc SREP', X.Message) > 0, 'FreeArc SREP: message');
    on X: Exception do Bad('FreeArc SREP block: ' + X.ClassName + ' ' + X.Message);
  end;
end;

procedure Corrupt_(Iters, Seed: Integer);
var
  Orig, E, C, D: TBytes;
  it, k, n, Accepted, Rejected: Integer;
  Kind: Integer;
begin
  Orig := Repetitive(3 shl 20);
  E := Encode('srep:l64:a1:b64kb', Orig);
  RandSeed := Seed;
  Accepted := 0;
  Rejected := 0;
  for it := 1 to Iters do
  begin
    C := Copy(E);
    Kind := it mod 4;
    case Kind of
      0, 1:
        begin
          // 1..3 bytes changed (half the time in the first 64 bytes: header and table)
          n := 1 + Random(3);
          for k := 1 to n do
            if Random(2) = 0 then C[Random(64)] := C[Random(64)] xor (1 + Random(255))
            else C[Random(Length(C))] := C[Random(Length(C))] xor (1 + Random(255));
        end;
      2: SetLength(C, Random(Length(C)));          // cut
      3:
        begin
          // garbage at the end
          n := 1 + Random(100);
          SetLength(C, Length(C) + n);
          for k := Length(C) - n to High(C) do C[k] := Random(256);
        end;
    end;
    try
      // as in an archive: the block must give exactly the original size
      D := DecompressMem('srep', PByte(C), Length(C), Length(Orig));
      if Same(D, Orig) then Inc(Accepted)
      else Bad('corrupt ' + IntToStr(it) + ': wrong data accepted');
    except
      on EArcCorrupt do Inc(Rejected);
      on X: Exception do Bad('corrupt ' + IntToStr(it) + ': ' + X.ClassName + ' ' + X.Message);
    end;
  end;
  Inc(Checks, Iters);
  WriteLn('  corrupt: ', Iters, ' streams, ', Rejected, ' rejected, ', Accepted, ' decoded to the original');
end;

begin
  RandSeed := 12345;
  if (ParamCount >= 1) and (ParamStr(1) = 'suite') then Suite
  else if (ParamCount >= 3) and (ParamStr(1) = 'corrupt') then
    Corrupt_(StrToInt(ParamStr(2)), StrToInt(ParamStr(3)))
  else
  begin
    WriteLn('usage: test_srep suite | corrupt <n> <seed>');
    Halt(2);
  end;
  WriteLn('  ', Checks, ' checks, ', Fails, ' failures');
  if Fails > 0 then Halt(1);
end.
