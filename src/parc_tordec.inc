{ Plantilla del lazo de tor_decompress0 para los codificadores Huffman (3) y aritmético (4)
  (incluida desde parc_tornado, una vez por codificador). Macros: TD_NAME nombre del método,
  TD_FAST el del lazo rápido que usa, TD_FASTPAS el del lazo rápido en Pascal que define esta
  plantilla (puede ser el mismo, o TD_FAST puede ser una versión en ensamblador); TD_ARITH
  codificador aritmético (si no, Huffman).

  Dos niveles:
  - Lazo rápido (TD_FAST): HufDecode/ArithDecode, LZMatch y la copia del match expandidos,
    con el estado (entrada, bitbuf o range/code, salida) en variables locales. Es una función
    aparte y sin ninguna llamada: así FPC deja esas variables en registros (con llamadas en el
    mismo procedimiento las manda a la pila). Solo decodifica un símbolo si puede hacerlo
    entero sin tocar los casos raros: quedan al menos TD_MARGIN bytes de entrada antes de
    FInLim (ninguna lectura del símbolo dispara Refill), el contador aritmético no llega a
    Rescale, el símbolo Huffman no es EOB, y el match es simple.
  - Si no, con el estado guardado en los campos, ese símbolo va por el código general
    (HufDecode, ArithDecode, LZMatch, Special), que es el de siempre: el resultado y los
    errores de datos corruptos (Corrupt) son exactamente los mismos. }

function TTornadoStage.TD_FASTPAS: Integer;
var
  op, oend, ip, ilsafe, src: PByte;
{$IFDEF TD_ARITH}
  rng, cod, count, s, nb: LongWord;
{$ELSE}
  bb: QWord;
  bc: Integer;
  c, nb: LongWord;
  xs: SmallInt;
{$ENDIF}
  x, lcode, l, len, dist: LongWord;
  dcode, d: LongInt;
  k: SizeInt;
begin
  // Pocas variables vivas (salida y entrada como punteros, el resto en los campos): con más,
  // FPC manda a la pila las que más se usan
  Result := TDR_SLOW;
  op := FOut + FOutput;
  oend := FOut + FWriteEnd;
  ip := PByte(FIn) + FInPos;
  ilsafe := PByte(FIn) + FInLim - TD_MARGIN;
{$IFDEF TD_ARITH}
  rng := FRange;
  cod := FCode;
{$ELSE}
  bb := FBitBuf;
  bc := FBitCount;
{$ENDIF}
  repeat
    if ip > ilsafe then Break;
{$IFDEF TD_ARITH}
    if FARemainder <= 1 then Break;
    // ArithDecode
    rng := rng shr RANGE_BITS;
    count := cod div rng;
    if count >= RANGE then Exit(TDR_BADARITH);
    s := FAIndex[count div (RANGE div INDEXES)];
    while FACum[s] + FACnt[s] - 1 < count do Inc(s);
    cod := cod - FACum[s] * rng;
    rng := rng * FACnt[s];
    while rng < (1 shl 24) do
    begin
      rng := rng shl 8;
      cod := (cod shl 8) + ip^;
      Inc(ip);
    end;
    Inc(FALive[s]);
    Dec(FARemainder);
    x := s;
{$ELSE}
    // HufDecode (sin consumir si es EOB: eso va por el camino general)
    if bc <= 32 then
    begin
      bb := bb or (QWord(PLongWord(ip)^) shl bc);
      Inc(ip, 4);
      Inc(bc, 32);
    end;
    c := LongWord(bb) and FHufMask;
    xs := FHufFast[c and ((1 shl FAST_BITS) - 1)];
    if xs < 0 then x := FHufIndex[c] else x := xs;
    if x = EOB_CODE then Break;
    nb := FHufBits[x];
    bb := bb shr nb;
    Dec(bc, nb);
    Inc(FHufCounter[x]);
    Inc(FHufBlock);
    if FHufBlock > 2 * HUFBLOCKSIZE then Exit(TDR_BADBLOCK);
{$ENDIF}

    if x < 256 then
    begin
      op^ := Byte(x);
      Inc(op);
      if op >= oend then begin Result := TDR_WRITE; Break; end;
      Continue;
    end;

    // LZMatch
    if x = REPCHAR then
    begin
      len := 1;
      dist := LongWord(FPrevDists[FPrev - 1]);
    end
    else
    begin
      if x >= EOB_CODE then Exit(TDR_BADCODE);
      // getlen
      lcode := x mod LEN_CODES;
      nb := extra_lbits2[lcode];
{$IFDEF TD_ARITH}
      if nb = 0 then
      begin
        if cod >= rng then Exit(TDR_BADARITH);
        l := lc2_base[lcode];
      end
      else if nb <= 24 then
      begin
        rng := rng shr nb;
        count := cod div rng;
        if count >= (LongWord(1) shl nb) then Exit(TDR_BADARITH);
        cod := cod - count * rng;
        while rng < (1 shl 24) do
        begin
          rng := rng shl 8;
          cod := (cod shl 8) + ip^;
          Inc(ip);
        end;
        l := lc2_base[lcode] + count;
      end
      else
      begin
        // ArithGetBits(n>24): 15 bits y después n-15
        rng := rng shr 15;
        count := cod div rng;
        if count >= (1 shl 15) then Exit(TDR_BADARITH);
        cod := cod - count * rng;
        while rng < (1 shl 24) do
        begin
          rng := rng shl 8;
          cod := (cod shl 8) + ip^;
          Inc(ip);
        end;
        l := count;
        rng := rng shr (nb - 15);
        count := cod div rng;
        if count >= (LongWord(1) shl (nb - 15)) then Exit(TDR_BADARITH);
        cod := cod - count * rng;
        while rng < (1 shl 24) do
        begin
          rng := rng shl 8;
          cod := (cod shl 8) + ip^;
          Inc(ip);
        end;
        l := lc2_base[lcode] + ((count shl 15) + l);
      end;
{$ELSE}
      if bc <= 32 then
      begin
        bb := bb or (QWord(PLongWord(ip)^) shl bc);
        Inc(ip, 4);
        Inc(bc, 32);
      end;
      l := lc2_base[lcode] + (LongWord(bb) and ((LongWord(1) shl nb) - 1));
      bb := bb shr nb;
      Dec(bc, nb);
{$ENDIF}
      if l > 100 then
      begin
        if l <= 104 then len := l - 100 + IMPOSSIBLE_LEN
        else len := l - 4 + FMinLen;
      end
      else
        len := l + FMinLen;
      // getdist
      dcode := LongInt(x - 256) div LEN_CODES - REPDIST_CODES;
      if dcode < 0 then
      begin
        case dcode of
          -4: d := FPrevDists[FPrev - 1];
          -3:
            begin
              d := FPrevDists[FPrev - 2];
              FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
              FPrevDists[FPrev - 1] := d;
            end;
          -2:
            begin
              d := FPrevDists[FPrev - 3];
              FPrevDists[FPrev - 3] := FPrevDists[FPrev - 2];
              FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
              FPrevDists[FPrev - 1] := d;
            end;
        else
          begin
            d := FPrevDists[FPrev - 4];
            FPrevDists[FPrev - 4] := FPrevDists[FPrev - 3];
            FPrevDists[FPrev - 3] := FPrevDists[FPrev - 2];
            FPrevDists[FPrev - 2] := FPrevDists[FPrev - 1];
            FPrevDists[FPrev - 1] := d;
          end;
        end;
      end
      else
      begin
        nb := extra_dbits[dcode];         // 4..30, nunca 0
{$IFDEF TD_ARITH}
        if nb <= 24 then
        begin
          rng := rng shr nb;
          count := cod div rng;
          if count >= (LongWord(1) shl nb) then Exit(TDR_BADARITH);
          cod := cod - count * rng;
          while rng < (1 shl 24) do
          begin
            rng := rng shl 8;
            cod := (cod shl 8) + ip^;
            Inc(ip);
          end;
        end
        else
        begin
          rng := rng shr 15;
          count := cod div rng;
          if count >= (1 shl 15) then Exit(TDR_BADARITH);
          cod := cod - count * rng;
          while rng < (1 shl 24) do
          begin
            rng := rng shl 8;
            cod := (cod shl 8) + ip^;
            Inc(ip);
          end;
          l := count;
          rng := rng shr (nb - 15);
          count := cod div rng;
          if count >= (LongWord(1) shl (nb - 15)) then Exit(TDR_BADARITH);
          cod := cod - count * rng;
          while rng < (1 shl 24) do
          begin
            rng := rng shl 8;
            cod := (cod shl 8) + ip^;
            Inc(ip);
          end;
          count := (count shl 15) + l;
        end;
        d := LongInt(dc_base[dcode] + count + 1);
{$ELSE}
        if bc <= 32 then
        begin
          bb := bb or (QWord(PLongWord(ip)^) shl bc);
          Inc(ip, 4);
          Inc(bc, 32);
        end;
        d := LongInt(dc_base[dcode] + (LongWord(bb) and ((LongWord(1) shl nb) - 1)) + 1);
        bb := bb shr nb;
        Dec(bc, nb);
{$ENDIF}
        if FPrev = Length(FPrevDists) then
        begin
          FPrevDists[0] := FPrevDists[Length(FPrevDists) - 3];
          FPrevDists[1] := FPrevDists[Length(FPrevDists) - 2];
          FPrevDists[2] := FPrevDists[Length(FPrevDists) - 1];
          FPrev := REPDIST_CODES - 1;
        end;
        FPrevDists[FPrev] := d;
        Inc(FPrev);
      end;
      dist := LongWord(d);
    end;

    // Match simple (>99% de los casos): `output-outbuf>=dist && write_end-output>len`
    if (SizeInt(dist) <= op - FOut) and (oend - op > SizeInt(len)) and (dist <> 0) then
    begin
      // CopyMatch sin Move (no hay llamadas en este lazo): de a 8 bytes si dist >= 8,
      // que da lo mismo que byte a byte aunque se solapen; el resto byte a byte
      src := op - dist;
      k := 0;
      if dist >= 8 then
        while k + 8 <= SizeInt(len) do
        begin
          PQWord(op + k)^ := PQWord(src + k)^;
          Inc(k, 8);
        end;
      while k < SizeInt(len) do
      begin
        op[k] := src[k];
        Inc(k);
      end;
      Inc(op, len);
    end
    else
    begin
      // match lento, fin de datos o tabla: Special con el estado guardado
      FPendLen := len;
      FPendDist := dist;
      Result := TDR_SPECIAL;
      Break;
    end;
  until False;

  // ---- Guardar el estado ----
  FOutput := op - FOut;
  FInPos := ip - PByte(FIn);
{$IFDEF TD_ARITH}
  FRange := rng;
  FCode := cod;
{$ELSE}
  FBitBuf := bb;
  FBitCount := bc;
{$ENDIF}
end;

{ El lazo completo: el rápido mientras se pueda y, cuando no, un símbolo por el camino general }
procedure TTornadoStage.TD_NAME;
var
  o, we: SizeInt;
  x, len, dist: LongWord;
begin
  we := FWriteEnd;
  repeat
    case TD_FAST of
      TDR_SPECIAL:
        begin
          // El lazo rápido decodificó un match que no es simple
          o := FOutput;
          if Special(FPendLen, FPendDist, o) then Exit;
          FOutput := o;
          Continue;
        end;
      TDR_WRITE:
        begin
          // Un literal llegó a write_end
          StartWrite;
          Exit;
        end;
      TDR_BADCODE: Corrupt('tor: invalid code');
      TDR_BADARITH: Corrupt('tor: arithmetic decoder error');
      TDR_BADBLOCK: Corrupt('tor: huffman block without EOB');
    end;
    // ---- Un símbolo por el camino general ----
    o := FOutput;
{$IFDEF TD_ARITH}
    x := ArithDecode;
{$ELSE}
    x := HufDecode;
{$ENDIF}
    if x < 256 then
    begin
      FOut[o] := Byte(x);
      Inc(o);
      FOutput := o;
      if o >= we then
      begin
        StartWrite;
        Exit;
      end;
      Continue;
    end;
    LZMatch(x, len, dist);
    if (SizeInt(dist) <= o) and (we - o > SizeInt(len)) and (dist <> 0) then
    begin
      CopyMatch(FOut + o, dist, len);
      Inc(o, len);
    end
    else if Special(len, dist, o) then Exit;
    FOutput := o;
  until False;
end;
