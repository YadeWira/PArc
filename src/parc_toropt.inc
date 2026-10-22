{ Plantilla del parser óptimo (tor_compress_chunk_optimal) para las combinaciones 9..11
  (tor:11..tor:15), incluida desde parc_torfast.inc una vez por combinación. Es RunOptimal con el
  match finder y el codificador fijos: CombineMF<CachingMatchFinder<N>, Hash3<aux,L3,L2>> sin
  despacho virtual, los precios del codificador (aritmético o Huffman) sin elegir Kind en cada
  llamada, y Evaluate/EvalLitRep/EvalMatches en el mismo lazo. Las funciones repiten las de las
  clases (TCachingMF, TExactMF/TMFN, THash3MF, TCombineMF) y de TTorEngine con sus mismas tablas:
  el stream es el mismo. Macros:
    OP_NAME     nombre del método
    OP_FINDALL  nombre de la función de búsqueda (find_all_matches)
    OP_N        N de CachingMatchFinder (5 o 6)
    OP_L3/OP_L2 bits de Hash3
    OP_MFN      el auxiliar es MatchFinderN<4> (si no, ExactMatchFinder<4>)
    OP_ARITH    precios del codificador aritmético (si no, Huffman) }

function OP_FINDALL(const F: TOptMF; p, bufend: PByte; m: PLongWord): PLongWord;
label
  len4, len5, len6, len7;
var
  h, x0, x1, v0, v1, t, k, len, len1: LongWord;
  table, tabend: PLongWord;
  bs, qq, q1: PByte;
{$IFDEF OP_MFN}
  maxLen: LongWord;
{$ENDIF}
  j: SizeInt;
begin
  bs := F.Bs;
  // ---- Hash3: 2 y 3 bytes ----
  h := Mul32(V16(p), K1) shr (32 - OP_L2);
  qq := bs + F.HT2[h];  F.HT2[h] := p - bs;
  if (p + 2 <= bufend) and (V16(p) = V16(qq)) then
  begin
    m^ := 2; Inc(m); m^ := p - qq; Inc(m);
  end;
  h := Mul32(V24(p), K3) shr (32 - OP_L3);
  qq := bs + F.HT3[h];  F.HT3[h] := p - bs;
  if (p + 3 <= bufend) and (V24(p) = V24(qq)) then
  begin
    m^ := 3; Inc(m); m^ := p - qq; Inc(m);
  end;
  // ---- auxiliar de 4 bytes ----
  h := (Mul32(V32(p), K1) shr F.XShift) and F.XMask;
{$IFDEF OP_MFN}
  // MatchFinderN<4>::find_all_matches
  maxLen := 3;
  x0 := F.XHT[h];  F.XHT[h] := p - bs;
  qq := bs + x0;
  if V32(p) = V32(qq) then
  begin
    len := 4;
    while (p + len + 4 <= bufend) and (V32(p + len) = V32(qq + len)) do Inc(len, 4);
    while (p + len < bufend) and (p[len] = qq[len]) do Inc(len);
    if len >= 4 then
    begin
      maxLen := len;
      m^ := len; Inc(m); m^ := p - qq; Inc(m);
    end;
  end;
  j := 1;
  while j < F.XRow do
  begin
    x1 := F.XHT[h + LongWord(j)];  F.XHT[h + LongWord(j)] := x0;
    qq := bs + x1;
    if p[maxLen] = qq[maxLen] then
    begin
      len := 0;
      while (p + len < bufend) and (p[len] = qq[len]) do Inc(len);
      if len >= maxLen then
      begin
        maxLen := len;
        m^ := len; Inc(m); m^ := p - qq; Inc(m);
      end;
    end;
    Inc(j);
    x0 := x1;
  end;
{$ELSE}
  // ExactMatchFinder<4>::find_all_matches: el primero que acepte
  x0 := p - bs;
  j := 0;
  while j < F.XRow do
  begin
    x1 := F.XHT[h + LongWord(j)];  F.XHT[h + LongWord(j)] := x0;
    qq := bs + x1;
    if (p <= bufend) and (V32(p) = V32(qq)) then
    begin
      m^ := 4; Inc(m); m^ := p - qq; Inc(m);
      Break;
    end;
    Inc(j);
    x0 := x1;
  end;
{$ENDIF}
  // ---- CachingMatchFinder<N>::find_all_matches ----
{$IF OP_N = 5}
  table := F.HT + SizeInt((LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 1), K2)) shr F.HShift)) * F.Row2;
{$ELSE}
  table := F.HT + SizeInt((LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 2), K2)) shr F.HShift)) * F.Row2;
{$ENDIF}
  tabend := table + F.Row2;
  x1 := p - bs;
  v1 := V32(p + OP_N - 1);
  k := v1;
  q1 := nil;
  while True do
  begin
    table := CScan(table, tabend, x1, v1, k, $FF);
    if table = nil then Break;
    t := v1 xor k;
    begin
      q1 := bs + x1;
      if (t = 0) and AcceptOptimalMatch(OP_N + 3, p, q1, bufend) then goto len7
      else if ((t and $FF00) <> 0) and AcceptOptimalMatch(OP_N, p, q1, bufend) then
        begin m^ := OP_N; Inc(m); m^ := p - q1; Inc(m); goto len4; end
      else if ((t and $FF0000) <> 0) and AcceptOptimalMatch(OP_N + 1, p, q1, bufend) then
        begin m^ := OP_N + 1; Inc(m); m^ := p - q1; Inc(m); goto len5; end
      else if AcceptOptimalMatch(OP_N + 2, p, q1, bufend) then
        begin m^ := OP_N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len4:
  while True do
  begin
    table := CScan(table, tabend, x1, v1, k, $FFFF);
    if table = nil then Break;
    t := v1 xor k;
    begin
      q1 := bs + x1;
      if (t = 0) and AcceptOptimalMatch(OP_N + 3, p, q1, bufend) then goto len7
      else if ((t and $FF0000) <> 0) and AcceptOptimalMatch(OP_N + 1, p, q1, bufend) then
        begin m^ := OP_N + 1; Inc(m); m^ := p - q1; Inc(m); goto len5; end
      else if AcceptOptimalMatch(OP_N + 2, p, q1, bufend) then
        begin m^ := OP_N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len5:
  while True do
  begin
    table := CScan(table, tabend, x1, v1, k, $FFFFFF);
    if table = nil then Break;
    t := v1 xor k;
    begin
      q1 := bs + x1;
      if (t = 0) and AcceptOptimalMatch(OP_N + 3, p, q1, bufend) then goto len7
      else if AcceptOptimalMatch(OP_N + 2, p, q1, bufend) then
        begin m^ := OP_N + 2; Inc(m); m^ := p - q1; Inc(m); goto len6; end;
    end;
  end;
  Exit(m);

len6:
  while True do
  begin
    table := CScan(table, tabend, x1, v1, k, $FFFFFFFF);
    if table = nil then Break;
    q1 := bs + x1;
    if AcceptOptimalMatch(OP_N + 3, p, q1, bufend) then goto len7;
  end;
  Exit(m);

len7:
  len := OP_N + 3;
  while (p + len < bufend) and (V32(p + len) = V32(q1 + len)) do Inc(len, 4);
  while (p + len < bufend) and (p[len] = q1[len]) do Inc(len);
  m^ := len; Inc(m); m^ := p - q1; Inc(m);
  while table <> tabend do
  begin
    x0 := x1; x1 := table^; table^ := x0; Inc(table);
    v0 := v1; v1 := table^; table^ := v0; Inc(table);
    t := v1 xor k;
    q1 := bs + x1;
    if (t = 0) and (p[len] = q1[len]) and (V32(p) = V32(q1)) then
    begin
      len1 := 4;
      while (p + len1 < bufend) and (V32(p + len1) = V32(q1 + len1)) do Inc(len1, 4);
      while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
      if len1 > len then
      begin
        len := len1;
        m^ := len; Inc(m); m^ := p - q1; Inc(m);
      end;
    end;
  end;
  Result := m;
end;

{ Una posición del parser óptimo: evaluate_literal_and_repdist, find_all_matches y
  evaluate_matches (EvalLitRep, MF.FindAllMatches y EvalMatches). Devuelve el largo como
  RunOptimal (para silence). }
function TTorEngine.OP_NAME(const F: TOptMF; pp: PByte): LongInt;
var
  Co: TTorCoder;
  len, j, lim: LongInt;
  src, dst, base: SizeInt;
  price, dist, match_len, np, dcode, dbits, sym, lcode: LongWord;
  pd: PLongWord;
  i: Integer;
  mm, me: PLongWord;
  pr: PLongWord;
  xs: ^TOptInfo;
{$IFDEF OP_ARITH}
  ap: PLongWord;
{$ELSE}
  hb: PByte;
{$ENDIF}
begin
  Co := C;
{$IFDEF OP_ARITH}
  ap := @Co.APrice[0];
  {$define OP_PRICE := ap}
  {$define OP_EXTRA := * 1024}
{$ELSE}
  hb := @Co.HufBits[0];
  {$define OP_PRICE := hb}
  {$define OP_EXTRA := }
{$ENDIF}
  pr := @Prices[0];
  xs := @X[0];
  len := OPT_MIN_LEN;
  src := pp - BaseP;
  price := pr[src];
  // literal: Evaluate(pp, 1, 0, price + LitPrice(pp^))
  np := price + OP_PRICE[pp^];
  if pr[src + 1] > np then
  begin
    pr[src + 1] := np;
    xs[src + 1].len := 1;
    xs[src + 1].dist := 0;
  end;
  if src <> 0 then
  begin
    // repdists
    dist := xs[src].dist;
    if dist = 0 then
    begin
      pd := @xs[src - 1].prevdist[0];
      dist := pd^; Inc(pd);
    end
    else
      pd := @xs[src - xs[src].len].prevdist[0];
    for i := 0 to REPDIST_CODES - 1 do
    begin
      xs[src].prevdist[i] := dist;
      if Int64(dist) > (pp - Buf) then Break;
      if pp[len - 1] = (pp - dist)[len - 1] then
      begin
        match_len := CheckMatchLen(pp, pp - dist, LongWord(LastP - pp));
        while LongWord(len) <= match_len do
        begin
          // RepdistPrice(len - 2, i): símbolo 256 + i*16 + lcode, extra = bits del largo
          if len - OPT_MIN_LEN > 600 then lcode := 15 else lcode := Lc2.Code[len - OPT_MIN_LEN];
          np := price + OP_PRICE[256 + LongWord(i) * 16 + lcode] + Lc2.Extra[lcode] OP_EXTRA;
          dst := src + len;
          if pr[dst] > np then
          begin
            pr[dst] := np;
            xs[dst].len := len;
            xs[dst].dist := dist;
          end;
          Inc(len);
        end;
        if len > M.FastBytes then
        begin
          for j := i + 1 to REPDIST_CODES - 1 do
          begin
            xs[src].prevdist[j] := pd^; Inc(pd);
          end;
          Break;
        end;
      end;
      dist := pd^; Inc(pd);
    end;
  end;
  if len > M.FastBytes then Exit(len);
  // matches
  mm := @Matches[0];
  me := OP_FINDALL(F, pp, MatchEnd, mm);
  if mm < me then
  begin
    base := LastP - pp;
    repeat
      match_len := mm^; Inc(mm);
      dist := mm^; Inc(mm);
      lim := match_len;
      if lim > base then lim := base;
      if len <= lim then
      begin
        // MatchPrice(len-2, dist): dcode fijo para esta distancia
        if dist < 512 then dcode := Dc.Code[dist]
        else if dist < 512 * 256 then dcode := Dc.Code[512 + (dist shr 8)]
        else dcode := Dc.Code[1024 + (dist shr 16)];
        dbits := Dc.Extra[dcode];
        sym := 256 + (dcode + REPDIST_CODES) * 16;
        repeat
          if len - OPT_MIN_LEN > 600 then lcode := 15 else lcode := Lc2.Code[len - OPT_MIN_LEN];
          np := price + OP_PRICE[sym + lcode] + (Lc2.Extra[lcode] + dbits) OP_EXTRA;
          dst := src + len;
          if pr[dst] > np then
          begin
            pr[dst] := np;
            xs[dst].len := len;
            xs[dst].dist := dist;
          end;
          Inc(len);
        until len > lim;
      end;
    until not (mm < me);
  end;
  Result := len;
end;
{$undef OP_PRICE}
{$undef OP_EXTRA}
