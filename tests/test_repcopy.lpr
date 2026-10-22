{ Copia de matches del decodificador REP (TRepStage, parc_rep): prueba exhaustiva de las
  copias solapadas contra un oráculo byte a byte.
    tests/test_repcopy
  Para cada ventana W, cada distancia 1..64 (y las cercanas a W), cada largo 1..300 y varias
  posiciones de arranque (al principio, a mitad y justo antes del fin de la ventana, para que
  el match dé la vuelta una o varias veces), arma un stream REP de un bloque:
    literal de P bytes al azar + match (largo, distancia)
  y lo decodifica leyendo de a pedazos (todo junto, de a 1 byte y de a pedazos al azar). El
  oráculo es la historia lineal: out[P+j] = out[P+j-dist], válida porque dist <= W.
  Sale con 0 si todo pasa. }
program test_repcopy;

{$mode objfpc}{$H+}

uses
  SysUtils, parc_stream, parc_rep;

var
  NOk, NBad: Int64;

procedure PutU32(var S: TBytes; var Pos: SizeInt; V: LongWord);
begin
  S[Pos] := Byte(V); S[Pos + 1] := Byte(V shr 8);
  S[Pos + 2] := Byte(V shr 16); S[Pos + 3] := Byte(V shr 24);
  Inc(Pos, 4);
end;

{ Stream REP: U32 W, bloque [U32 ComprSize][num=1][lens][offs][datalens: P, 0][literales], U32 0 }
function MakeStream(W, P, Dist, Len: LongInt; const Lit: TBytes): TBytes;
var
  pos: SizeInt;
  compr: LongInt;
begin
  compr := 4 + 4 + 4 + 8 + P;
  SetLength(Result, 4 + 4 + compr + 4);
  pos := 0;
  PutU32(Result, pos, LongWord(W));
  PutU32(Result, pos, LongWord(compr));
  PutU32(Result, pos, 1);
  PutU32(Result, pos, LongWord(Len));
  PutU32(Result, pos, LongWord(Dist));
  PutU32(Result, pos, LongWord(P));
  PutU32(Result, pos, 0);
  if P > 0 then Move(Lit[0], Result[pos], P);
  Inc(pos, P);
  PutU32(Result, pos, 0);
end;

{ Modo 0: lectura de todo junto; 1: de a 1 byte; 2: pedazos al azar de 1..37 bytes }
function Decode(const S: TBytes; Total: SizeInt; Mode: Integer): TBytes;
var
  Src: TMemStage;
  St: TRepStage;
  len, n, want: SizeInt;
begin
  SetLength(Result, Total + 16);
  Src := TMemStage.Create(PByte(S), Length(S));
  St := TRepStage.Create(Src);
  try
    len := 0;
    repeat
      case Mode of
        0: want := Length(Result) - len;
        1: want := 1;
      else
        want := 1 + Random(37);
      end;
      if want > Length(Result) - len then want := Length(Result) - len;
      if want <= 0 then Break;
      n := St.Read(@Result[len], want);
      Inc(len, n);
    until n = 0;
    SetLength(Result, len);
  finally
    St.Free;   // libera también Src
  end;
end;

procedure Check(W, P, Dist, Len: LongInt);
var
  Lit, S, Ref, D: TBytes;
  j: SizeInt;
  Mode: Integer;
  msg: string;
begin
  SetLength(Lit, P);
  for j := 0 to P - 1 do Lit[j] := Random(256);
  SetLength(Ref, P + Len);
  if P > 0 then Move(Lit[0], Ref[0], P);
  for j := P to P + Len - 1 do Ref[j] := Ref[j - Dist];
  S := MakeStream(W, P, Dist, Len, Lit);
  for Mode := 0 to 2 do
  begin
    // De a 1 byte solo en una parte de los casos (es lento)
    if (Mode = 1) and (Len mod 7 <> 0) then Continue;
    msg := '';
    try
      D := Decode(S, P + Len, Mode);
      if Length(D) <> Length(Ref) then
        msg := Format('largo %d, esperado %d', [Length(D), Length(Ref)])
      else if (Length(D) > 0) and not CompareMem(@D[0], @Ref[0], Length(D)) then
      begin
        for j := 0 to High(D) do
          if D[j] <> Ref[j] then begin msg := Format('difiere en %d', [j]); Break; end;
      end;
    except
      on E: Exception do msg := E.ClassName + ': ' + E.Message;
    end;
    if msg = '' then Inc(NOk)
    else
    begin
      Inc(NBad);
      if NBad <= 20 then
        WriteLn(Format('FALLA W=%d P=%d dist=%d len=%d modo=%d: %s', [W, P, Dist, Len, Mode, msg]));
    end;
  end;
end;

const
  Wins: array[0..4] of LongInt = (64, 65, 100, 257, 4096);

var
  wi, t, ti, Dist, Len, P, W: LongInt;
  Targets: array[0..6] of LongInt;
  Dists: array of LongInt;
  k: Integer;
begin
  RandSeed := 12345;
  NOk := 0; NBad := 0;
  for wi := Low(Wins) to High(Wins) do
  begin
    W := Wins[wi];
    // Posición de escritura al empezar el match: 0, 1, mitad, y justo antes del fin
    Targets[0] := 0; Targets[1] := 1; Targets[2] := W div 2; Targets[3] := W - 1;
    Targets[4] := W - 3; Targets[5] := W - 37; Targets[6] := W - 64;
    // Distancias 1..64 y las cercanas a W (W = la distancia máxima)
    SetLength(Dists, 0);
    for Dist := 1 to 64 do
      if Dist <= W then begin SetLength(Dists, Length(Dists) + 1); Dists[High(Dists)] := Dist; end;
    for Dist := W - 2 to W do
      if Dist > 64 then begin SetLength(Dists, Length(Dists) + 1); Dists[High(Dists)] := Dist; end;
    for k := 0 to High(Dists) do
    begin
      Dist := Dists[k];
      for ti := 0 to High(Targets) do
      begin
        t := Targets[ti];
        if (t < 0) or (t >= W) then Continue;
        // El P más chico con P >= Dist y P mod W = t (historia suficiente para la distancia)
        P := t;
        while P < Dist do Inc(P, W);
        for Len := 1 to 300 do Check(W, P, Dist, Len);
      end;
    end;
  end;
  WriteLn(Format('test_repcopy: %d bien, %d mal', [NOk, NBad]));
  if NBad > 0 then Halt(1);
end.
