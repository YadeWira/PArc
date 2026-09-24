{ Prueba del decodificador Tornado: tests/test_tornado <comp.tor> <orig> <modos> [semilla]
  modos (letras combinables):
    s  streaming normal (TTornadoStage, AllAtOnce=False), fuente con lecturas cortas al azar
       y consumidor con Read de tamaño variable
    S  igual pero AllAtOnce=True (compress_all_at_once, como dentro de 4x4)
    m  memoria a memoria (TornadoDecodeMem, DstCap exacto) y además DstCap-1 debe fallar
    b  benchmark: streaming con lecturas de 1MB, imprime MB/s (no compara)
    f  fuzz: 300 variantes corruptas (bytes cambiados, truncado); tienen que decodificar o
       lanzar EArcCorrupt, nunca otra excepción ni colgarse (salida limitada)
    w/W  decodifica (normal / AllAtOnce) y escribe la salida en <orig> (para comparar con el
       decodificador C; W con TOR_AAO=1 reproduce también sus rarezas si los datos no entran)
  Sale con 0 si todo coincide. }
program test_tornado;
{$mode objfpc}{$H+}
uses SysUtils, Classes, DateUtils, parc_stream, parc_bytes, parc_tornado;

type
  { Fuente que entrega los bytes en trozos de largo aleatorio (1..MaxPiece). }
  TChoppyStage = class(TInStage)
  private
    FData: TBytes;
    FPos, FMax: SizeInt;
  public
    constructor Create(const Data: TBytes; MaxPiece: SizeInt);
    function Read(Buf: PByte; Count: SizeInt): SizeInt; override;
  end;

constructor TChoppyStage.Create(const Data: TBytes; MaxPiece: SizeInt);
begin
  inherited Create(nil);
  FData := Data;
  FMax := MaxPiece;
end;

function TChoppyStage.Read(Buf: PByte; Count: SizeInt): SizeInt;
begin
  Result := Length(FData) - FPos;
  if Result > Count then Result := Count;
  if (FMax > 0) and (Result > 1) then Result := 1 + Random(Result);
  if Result > FMax then Result := FMax;
  if Result <= 0 then Exit(0);
  Move(FData[FPos], Buf^, Result);
  Inc(FPos, Result);
end;

function LoadFile(const N: string): TBytes;
var f: TFileStream;
begin
  f := TFileStream.Create(N, fmOpenRead or fmShareDenyNone);
  try SetLength(Result, f.Size); if f.Size > 0 then f.ReadBuffer(Result[0], f.Size); finally f.Free; end;
end;

var
  Comp, Orig: TBytes;

function TestStream(AllAtOnce: Boolean): string;
var
  st: TTornadoStage;
  Outb: TBytes;
  pos, n, want: SizeInt;
  extra: Byte;
begin
  Result := '';
  SetLength(Outb, Length(Orig) + 1);
  // Fuente con trozos de hasta 1..70000 bytes (a veces 1-7: fuerza el Refill con pocos bytes)
  if Random(3) = 0 then n := 1 + Random(7) else n := 1 + Random(70000);
  st := TTornadoStage.Create(TChoppyStage.Create(Comp, n), AllAtOnce);
  try
    pos := 0;
    repeat
      case Random(3) of
        0: want := 1 + Random(16);
        1: want := 1 + Random(100000);
      else want := 1 + Random(3 shl 20);
      end;
      if want > Length(Outb) - pos then want := Length(Outb) - pos;
      if want <= 0 then
      begin
        // salida de más: el stream tiene que terminar acá
        if st.Read(@extra, 1) <> 0 then Exit('produce más bytes que el original');
        Break;
      end;
      n := st.Read(@Outb[pos], want);
      Inc(pos, n);
    until n = 0;
    if pos <> Length(Orig) then Exit(Format('largo %d, esperado %d', [pos, Length(Orig)]));
    if (pos > 0) and not CompareMem(@Outb[0], @Orig[0], pos) then Exit('contenido distinto');
    if st.Read(@extra, 1) <> 0 then Exit('Read después del fin no devuelve 0');
  finally
    st.Free;
  end;
end;

function TestMem: string;
var
  Outb: TBytes;
  w: SizeInt;
begin
  Result := '';
  SetLength(Outb, Length(Orig) + 16);
  if not TornadoDecodeMem(PByte(Comp), Length(Comp), PByte(Outb), Length(Orig), w) then
    Exit('TornadoDecodeMem: salida demasiado chica');
  if w <> Length(Orig) then Exit(Format('mem: largo %d, esperado %d', [w, Length(Orig)]));
  if (w > 0) and not CompareMem(@Outb[0], @Orig[0], w) then Exit('mem: contenido distinto');
  if Length(Orig) > 0 then
    if TornadoDecodeMem(PByte(Comp), Length(Comp), PByte(Outb), Length(Orig) - 1, w) then
      Exit('mem: con DstCap-1 debió fallar');
end;

procedure Dump(AllAtOnce: Boolean; const FileName: string);
var
  st: TTornadoStage;
  f: TFileStream;
  buf: TBytes;
  n: SizeInt;
begin
  SetLength(buf, 1 shl 20);
  f := TFileStream.Create(FileName, fmCreate);
  st := TTornadoStage.Create(TMemStage.Create(PByte(Comp), Length(Comp)), AllAtOnce);
  try
    repeat
      n := st.Read(@buf[0], Length(buf));
      if n > 0 then f.WriteBuffer(buf[0], n);
    until n = 0;
  finally
    st.Free;
    f.Free;
  end;
end;

function Fuzz: string;
var
  it, k, n, pos: SizeInt;
  Bad: TBytes;
  st: TTornadoStage;
  buf: TBytes;
  lim: Int64;
  nCorrupt, nOk: Integer;
begin
  Result := '';
  SetLength(buf, 1 shl 16);
  nCorrupt := 0; nOk := 0;
  for it := 1 to 300 do
  begin
    Bad := Copy(Comp);
    case it mod 4 of
      0: SetLength(Bad, Random(Length(Bad) + 1));                       // truncado
      1: for k := 1 to 1 + Random(3) do                                 // pocos bytes
           if Length(Bad) > 6 then Bad[6 + Random(Length(Bad) - 6)] := Random(256);
      2: for k := 1 to 1 + Random(40) do                                // muchos bytes
           if Length(Bad) > 6 then Bad[6 + Random(Length(Bad) - 6)] := Random(256);
      3: begin                                                          // encabezado o bits sueltos
           if Length(Bad) > 0 then
           begin
             pos := Random(Length(Bad));
             if pos < 6 then pos := 6 * Ord(Random(2) = 0) + Random(2);  // método o minlen
             if pos < Length(Bad) then Bad[pos] := Bad[pos] xor (1 shl Random(8));
           end;
         end;
    end;
    lim := 4 * Int64(Length(Orig)) + (8 shl 20);
    st := TTornadoStage.Create(TChoppyStage.Create(Bad, 1 + Random(5000)), Random(2) = 0);
    try
      try
        repeat
          n := st.Read(@buf[0], 1 + Random(Length(buf)));
          Dec(lim, n);
        until (n = 0) or (lim < 0);
        Inc(nOk);
      except
        on E: EArcCorrupt do Inc(nCorrupt);
        on E: Exception do Exit(Format('fuzz %d: %s: %s', [it, E.ClassName, E.Message]));
      end;
    finally
      st.Free;
    end;
  end;
  WriteLn(Format('fuzz: %d EArcCorrupt, %d sin error', [nCorrupt, nOk]));
end;

procedure Bench;
var
  st: TTornadoStage;
  Outb: TBytes;
  t0: TDateTime;
  total, n: Int64;
  ms: Int64;
  rep: Integer;
  best: Int64;
begin
  SetLength(Outb, 1 shl 20);
  best := High(Int64);
  for rep := 1 to 3 do
  begin
    t0 := Now;
    st := TTornadoStage.Create(TMemStage.Create(PByte(Comp), Length(Comp)), False);
    total := 0;
    try
      repeat
        n := st.Read(@Outb[0], Length(Outb));
        Inc(total, n);
      until n = 0;
    finally
      st.Free;
    end;
    ms := MilliSecondsBetween(Now, t0);
    if ms < best then best := ms;
  end;
  if best = 0 then best := 1;
  WriteLn(Format('%d bytes en %d ms: %.1f MB/s', [total, best, total / 1048576 / (best / 1000)]));
end;

var
  Modes, err: string;
  i, k: Integer;
begin
  if ParamCount < 3 then
  begin
    WriteLn('uso: test_tornado <comp.tor> <orig> <modos s|S|m|b> [semilla]');
    Halt(2);
  end;
  Comp := LoadFile(ParamStr(1));
  Modes := ParamStr(3);
  if Pos('b', Modes) > 0 then begin Bench; Halt(0); end;
  if (Modes = 'w') or (Modes = 'W') then begin Dump(Modes = 'W', ParamStr(2)); Halt(0); end;
  Orig := LoadFile(ParamStr(2));
  if ParamCount >= 4 then RandSeed := StrToInt(ParamStr(4)) else RandSeed := 12345;
  err := '';
  try
    for i := 1 to Length(Modes) do
      case Modes[i] of
        's': for k := 1 to 2 do if err = '' then err := TestStream(False);
        'S': for k := 1 to 2 do if err = '' then err := TestStream(True);
        'm': if err = '' then err := TestMem;
        'f': if err = '' then err := Fuzz;
      end;
  except
    on E: Exception do err := E.ClassName + ': ' + E.Message;
  end;
  if err = '' then Halt(0);
  WriteLn('FAIL ', err);
  Halt(1);
end.
