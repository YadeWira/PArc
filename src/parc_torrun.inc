{ Plantilla del lazo principal de tor_compress_chunk para los caminos rápidos (incluida desde
  parc_torfast.inc, una vez por combinación). Es TTorEngine.Run con el match finder y el
  codificador fijos. Macros:
    TF_NAME   nombre del método
    TF_MF2    MatchFinder2 (si no, CachingMatchFinder<4>)
    TF_LAZY   LazyMatching<Hash3<...>> (min_length 2), con TF_FIND / TF_UPDATE el find_matchlen
              y update_hash de Hash3<...> (H3Find/H3Update o H7Find/H7Update)
    TF_NOPF   sin prefetch de la fila de p+PFD de CachingMatchFinder<4>
    TF_PFY    prefetch de la fila de p+2 de CycledCachingMatchFinder<5>
    TF_ARITH  codificador aritmético (si no, Huffman) }

procedure TTorEngine.TF_NAME(Resuming: Boolean);
const
{$IFDEF TF_LAZY}
  MINL = 2;
{$ELSE}
  MINL = 4;
{$ENDIF}
var
  F: TFastMF;
  Co: TTorCoder;
  pp, mend, special, tend, q: PByte;
  len: LongWord;
{$IFDEF TF_LAZY}
  LZ: TLazyMF;
  nlen, plen, nd, pd: LongWord;
  nq, pq: PByte;
{$ENDIF}
  SkipRead: Boolean;
begin
  FastSetup(F);
  Co := C;
  SkipRead := False;
  if Resuming then
  begin
    ReadPart2;
    if not (P < BufEnd) then
    begin
      FinishStream;
      Exit;
    end;
    SkipRead := True;      // tras leer, el C codifica al menos un elemento antes de volver a mirar
  end;
  pp := P;
  mend := MatchEnd;
  special := pp;
  if UseTables then tend := TableEnd else tend := Buf + M.Buffer + LOOKAHEAD;
{$IFDEF TF_LAZY}
  LZ := TLazyMF(MF);
  nlen := LZ.NextLen;
  nq := LZ.NextQ;
{$ENDIF}
  while True do
  begin
    if pp >= special then
    begin
{$IFDEF TF_LAZY}
      LZ.NextLen := nlen;
      LZ.NextQ := nq;
{$ENDIF}
      special := FastSpecial(pp, SkipRead);
      if special = nil then Exit;
    end;
    // Tablas que conviene restar
    if pp > tend then
    begin
{$IFDEF TF_LAZY}
      LZ.NextLen := nlen;
      if FastTables(pp) then nlen := LZ.NextLen;    // invalidate_match
{$ELSE}
      FastTables(pp);
{$ENDIF}
      tend := TableEnd;
    end;

{$IFDEF TF_LAZY}
    // LazyMatching::find_matchlen
    {$IFNDEF TF_NOPF}prefetch(F.HT[CRow4(pp + PFD, F.HShift) * F.Row2]);{$ENDIF}
    {$IFDEF TF_PFY}YPrefetch(F, pp + 2);{$ENDIF}
    if nlen = 0 then nlen := TF_FIND(F, pp, mend, nq);
    plen := nlen;
    pq := nq;
    nlen := TF_FIND(F, pp + 1, mend, nq);
    nd := LongWord(pp + 1 - nq);
    pd := LongWord(pp - pq);
    // Extender el match de p+1 un byte hacia atrás si es mejor que el de p
    if (nlen >= MINL) and (nq[-1] = pp^) and
       ((nlen + 1 >= plen) and (nd < pd) or
        (nlen + 1 = plen + 1) and not ChangePair(pd, nd) or
        (nlen + 1 > plen + 1) or
        (nlen + 1 + 1 >= plen) and (plen >= MINL) and ChangePair(nd, pd)) then
    begin
      pq := nq - 1;
      len := nlen + 1;
    end
    // Truncar el match actual si el de la próxima posición es mejor
    else if (nlen >= plen) and (nd < pd div 4) or
       (nlen = plen + 1) and not ChangePair(pd, nd) or
       (nlen > plen + 1) or
       (nlen + 1 >= plen) and (plen >= MINL) and ChangePair(nd, pd) then
      len := MINL - 1
    else
      len := plen;
    q := pq;
{$ELSE}
  {$IFDEF TF_MF2}
    len := M2Find(F, pp, mend, q);
  {$ELSE}
    prefetch(F.HT[CRow4(pp + 1, F.HShift) * F.Row2]);
    len := CFind4(F, pp, mend, q);
  {$ENDIF}
{$ENDIF}

    if len < MINL then
    begin
{$IFDEF TF_ARITH}
      Co.LitA(pp);
{$ELSE}
      Co.LitH(pp);
{$ENDIF}
      Inc(pp);
    end
    else
    begin
{$IFDEF TF_PFY}
      YPrefetch(F, pp + len);
      YPrefetch(F, pp + len + 1);
{$ENDIF}
{$IFNDEF TF_MF2}{$IFNDEF TF_NOPF}
  {$IFDEF TF_LAZY}
      // filas de la actualización (desde p+1) y de las dos búsquedas siguientes (p+len, p+len+1)
      CPrefetch4(F, pp + 1, len - 1, M.UpdateStep);
      prefetch(F.HT[CRow4(pp + len + 1, F.HShift) * F.Row2]);
  {$ELSE}
      CPrefetch4(F, pp, len, M.UpdateStep);
  {$ENDIF}
{$ENDIF}{$ENDIF}
{$IFDEF TF_ARITH}
      Co.EncodeMatchA(LongInt(len) - MINL, LongInt(LongWord(pp - q)) - 1);
{$ELSE}
      Co.EncodeMatchH(LongInt(len) - MINL, LongInt(LongWord(pp - q)) - 1);
{$ENDIF}
      // update_hash
{$IFDEF TF_MF2}
      M2Update(F, pp, len);
{$ELSE}
  {$IFDEF TF_LAZY}
      TF_UPDATE(F, pp, len, M.UpdateStep);
      nlen := 0;
  {$ELSE}
      CUpdate4(F, pp, len, M.UpdateStep);
  {$ENDIF}
{$ENDIF}
      Inc(pp, len);
    end;
  end;
end;
