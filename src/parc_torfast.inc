{ Caminos rápidos del codificador Tornado (incluido desde parc_torenc).
  Las combinaciones de tor:3..tor:7 (3 a 7 de SelectCombo, las de los presets) se codifican con
  un lazo especializado en lugar de la cadena de objetos virtuales: es lo que en el C hacen los
  templates (tor_compress_chunk<MatchFinder,Coder> se compila entero para cada combinación). El
  match finder (MatchFinder2, CachingMatchFinder<4>, CycledCachingMatchFinder<5> +
  ExactMatchFinder<4>, Hash3, LazyMatching) y el codificador quedan sin despacho virtual, con N,
  las claves y los hashes como constantes, y con prefetch de las filas del hash que se van a usar.
  El stream es byte a byte el mismo: estas funciones repiten las de las clases (TMF2, TCachingMF,
  TCycledMF, TExactMF, TCombineMF, THash3MF, TLazyMF) y usan sus mismas tablas, así que las
  operaciones raras (desplazar la ventana, borrar el hash, tablas de datos) siguen pasando por
  los objetos. Las combinaciones del parser óptimo (9..12) y tor:1/tor:2 siguen por Run.
  Las funciones son llamadas comunes (no inline) con los parámetros del hash en un registro
  TFastMF: así el lazo principal tiene pocas variables vivas y FPC las deja en registros (con
  todo expandido en el lazo las manda a la pila). }

const
  // Distancia del prefetch de la fila del match finder en el lazo lazy: p+3 rinde algo más que
  // p+2 en tor:6 (filas de 64 bytes) y da lo mismo en tor:5
  PFD = 3;

{ hashx(4, p) con máscara completa: el número de fila de CachingMatchFinder<4> }
function CRow4(p: PByte; HShift: LongWord): SizeInt; inline;
begin
  Result := SizeInt(Mul32(V32(p), K1) shr HShift);
end;

{ Extensión de un match con 8 bytes por vuelta: el mismo resultado que los lazos de 4 bytes y
  de bytes del C. ExtendC es el de los match finders con caché (bloques de 4 bytes mientras
  p+i < bufend, y como en el C el largo puede pasarse de bufend hasta 3 bytes); Extend2 el de
  MatchFinder2 (el primer byte distinto desde i, sin pasar de bufend). }
function ExtendC(p, q: PByte; i: LongWord; bufend: PByte): LongWord; inline;
{$IFDEF ENDIAN_LITTLE}
var
  x: QWord;
{$ENDIF}
begin
{$IFDEF ENDIAN_LITTLE}
  while p + i + 4 < bufend do
  begin
    x := PQWord(p + i)^ xor PQWord(q + i)^;
    if x <> 0 then
    begin
      i := i + LongWord(BsfQWord(x) shr 3);
      if p + i > bufend then i := bufend - p;
      Exit(i);
    end;
    Inc(i, 8);
  end;
{$ENDIF}
  while (p + i < bufend) and (V32(p + i) = V32(q + i)) do Inc(i, 4);
  while (p + i < bufend) and (p[i] = q[i]) do Inc(i);
  Result := i;
end;

function Extend2(p, q: PByte; i: LongWord; bufend: PByte): LongWord; inline;
{$IFDEF ENDIAN_LITTLE}
var
  x: QWord;
{$ENDIF}
begin
{$IFDEF ENDIAN_LITTLE}
  while p + i + 8 <= bufend do
  begin
    x := PQWord(p + i)^ xor PQWord(q + i)^;
    if x <> 0 then Exit(i + LongWord(BsfQWord(x) shr 3));
    Inc(i, 8);
  end;
{$ENDIF}
  while (p + i < bufend) and (p[i] = q[i]) do Inc(i);
  Result := i;
end;

{ CachingMatchFinder<4>::find_matchlen (TCachingMF.FindMatchLen con N=4). La escalera de goto
  len4..len7 del C es un solo lazo con una máscara: lvl=1..3 son los estados len4..len6 y
  lvl=4 es len7 (la máscara pasa de $FF a $FFFF, $FFFFFF y $FFFFFFFF). }
function CFind4(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
var
  table, tabend: PLongWord;
  x0, x1, v0, v1, k, t, mask, lvl, len, len1: LongWord;
  bs, qq, q1: PByte;
begin
  bs := F.Bs;
  table := F.HT + CRow4(p, F.HShift) * F.Row2;
  tabend := table + F.Row2;
  x1 := p - bs;
  v1 := V32(p + 3);
  k := v1;
  mask := $FF; lvl := 0; qq := nil;
  while table <> tabend do
  begin
    x0 := x1; x1 := table[0]; table[0] := x0;
    v0 := v1; v1 := table[1]; table[1] := v0;
    Inc(table, 2);
    t := v1 xor k;
    if (t and mask) = 0 then
    begin
      qq := bs + x1;
      if t = 0 then begin lvl := 4; Break; end
      else if (t and $FF00) <> 0 then begin lvl := 1; mask := $FFFF; end
      else if (t and $FF0000) <> 0 then begin lvl := 2; mask := $FFFFFF; end
      else begin lvl := 3; mask := $FFFFFFFF; end;
    end;
  end;
  q := qq;
  case lvl of
    0: Result := 3;                         // MinLen-1
    // accept_match(4..6, p, q, bufend)
    1: if (p <= bufend) and (V32(p) = V32(qq)) and (p - qq < 48 * kb) then Result := 4 else Result := 0;
    2: if (p <= bufend) and (V32(p) = V32(qq)) and (p - qq < 192 * kb) and (p[4] = qq[4]) then Result := 5
       else Result := 0;
    3: if (p <= bufend) and (V32(p) = V32(qq)) and (p - qq < 1 * mb) and (V16(p + 4) = V16(qq + 4)) then Result := 6
       else Result := 0;
  else
    begin
      // len7: el match más largo del resto de la fila
      len := 3;
      if V32(p) = V32(qq) then
      begin
        while (p + len < bufend) and (V32(p + len) = V32(qq + len)) do Inc(len, 4);
        while (p + len < bufend) and (p[len] = qq[len]) do Inc(len);
      end;
      while table <> tabend do
      begin
        x0 := x1; x1 := table[0]; table[0] := x0;
        v0 := v1; v1 := table[1]; table[1] := v0;
        Inc(table, 2);
        if v1 = k then
        begin
          q1 := bs + x1;
          if (p[len] = q1[len]) and (V32(p) = V32(q1)) then
          begin
            len1 := 3;
            while (p + len1 < bufend) and (V32(p + len1) = V32(q1 + len1)) do Inc(len1, 4);
            while (p + len1 < bufend) and (p[len1] = q1[len1]) do Inc(len1);
            if len1 > len then begin len := len1; q := q1; end;
          end;
        end;
      end;
      Result := len;
    end;
  end;
end;

{ CachingMatchFinder<4>::update_hash1 (TCachingMF.UpdateHash1) }
procedure CIns4(const F: TFastMF; p: PByte); inline;
var
  t: PLongWord;
  j: SizeInt;
begin
  t := F.HT + CRow4(p, F.HShift) * F.Row2;
  j := F.RowUp - 2;
  while j <> 0 do
  begin
    t[j] := t[j - 2];
    t[j + 1] := t[j - 1];
    Dec(j, 2);
  end;
  t[0] := p - F.Bs;
  t[1] := V32(p + 3);
end;

{ Pide a la caché las filas que va a tocar CUpdate4(p, len, step) (cada inserción va a una fila
  al azar) y la de p+len, la próxima búsqueda. Se llama antes de codificar el match, para que
  las filas lleguen mientras tanto. }
procedure CPrefetch4(const F: TFastMF; p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  prefetch(F.HT[CRow4(p + len, F.HShift) * F.Row2]);
  if len > 3 then
  begin
    prefetch(F.HT[CRow4(p + len - 1, F.HShift) * F.Row2]);
    i := 2;
    while i < len - 1 do
    begin
      prefetch(F.HT[CRow4(p + i, F.HShift) * F.Row2]);
      Inc(i, step);
    end;
  end;
end;

{ CachingMatchFinder<4>::update_hash (TCachingMF.UpdateHash) }
procedure CUpdate4(const F: TFastMF; p: PByte; len, step: LongWord);
var
  i: LongWord;
begin
  if len > 1 then CIns4(F, p + 1);
  i := 2;
  while i < len - 1 do
  begin
    CIns4(F, p + i);
    Inc(i, step);
  end;
  if len > 3 then CIns4(F, p + len - 1);
end;

{ MatchFinder2::find_matchlen (TMF2.FindMatchLen; MinLen = 4) }
function M2Find(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
var
  h, len, len1: LongWord;
  bs, q1, qq: PByte;
  HT: PLongWord;
begin
  bs := F.Bs;
  HT := F.HT;
  h := (Mul32(V32(p), K1) shr F.HShift) and F.HMask;
  q1 := bs + HT[h + 1];  HT[h + 1] := HT[h];
  qq := bs + HT[h];      HT[h] := p - bs;
  if V32(p) = V32(qq) then
  begin
    len := Extend2(p, qq, 3, bufend);
    if p[len] = q1[len] then
    begin
      len1 := Extend2(p, q1, 0, bufend);
      if len1 > len then begin len := len1; qq := q1; end;
    end;
    Result := len;
  end
  else if V32(p) = V32(q1) then
  begin
    qq := q1;
    Result := Extend2(p, qq, 3, bufend);
  end
  else
    Result := 3;
  q := qq;
end;

{ MatchFinder2::update_hash (TMF2.UpdateHash): p+1, p+len-2 y p+len-1 }
procedure M2Update(const F: TFastMF; p: PByte; len: LongWord);
var
  h: LongWord;
  HT: PLongWord;
begin
  HT := F.HT;
  h := (Mul32(V32(p + 1), K1) shr F.HShift) and F.HMask;
  HT[h + 1] := HT[h];  HT[h] := p + 1 - F.Bs;
  Inc(p, len);
  h := (Mul32(V32(p - 2), K1) shr F.HShift) and F.HMask;
  HT[h + 1] := HT[h];  HT[h] := p - 2 - F.Bs;
  h := (Mul32(V32(p - 1), K1) shr F.HShift) and F.HMask;
  HT[h + 1] := HT[h];  HT[h] := p - 1 - F.Bs;
end;

{ Hash3<14,10,FALSE>: los hashes de 3 y 2 bytes }
function H3Row(p: PByte): LongWord; inline;
begin
  Result := Mul32(V24(p), K3) shr (32 - 14);
end;

function H2Row(p: PByte): LongWord; inline;
begin
  Result := Mul32(V16(p), K1) shr (32 - 10);
end;

{ Hash3<CachingMatchFinder<4>,14,10>::find_matchlen (THash3MF.FindMatchLen) }
function H3Find(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
var
  h: LongWord;
  bs, qq: PByte;
begin
  Result := CFind4(F, p, bufend, q);
  bs := F.Bs;
  if Result < 4 then
  begin
    h := H3Row(p);
    qq := bs + F.HT3[h];  F.HT3[h] := p - bs;
    if (p - qq < 6 * kb) and (p + 3 <= bufend) and (V24(p) = V24(qq)) then
    begin
      F.HT2[H2Row(p)] := p - bs;
      Result := 3;
    end
    else
    begin
      h := H2Row(p);
      qq := bs + F.HT2[h];  F.HT2[h] := p - bs;
      if (p - qq < 256) and (p + 2 <= bufend) and (V16(p) = V16(qq)) then Result := 2
      else Result := 1;
    end;
    q := qq;
  end
  else
  begin
    F.HT3[H3Row(p)] := p - bs;
    F.HT2[H2Row(p)] := p - bs;
  end;
end;

{ LazyMatching::update_hash: mf.update_hash(p+1, len-1) de Hash3 sin FULL_UPDATE }
procedure H3Update(const F: TFastMF; p: PByte; len, step: LongWord);
begin
  Inc(p);
  Dec(len);
  CUpdate4(F, p, len, step);
  if len > 1 then F.HT3[H3Row(p + 1)] := p + 1 - F.Bs;
  if len > 3 then F.HT3[H3Row(p + len - 1)] := p + len - 1 - F.Bs;
end;

{ ---- combo 7 (tor:7): LazyMatching<Hash3<CombineMF<CycledCachingMatchFinder<5>,
  ExactMatchFinder<4>>,16,12,TRUE>> ---- }

{ hashx(5, p) con máscara completa: la fila de CycledCachingMatchFinder<5> }
function YRow5(p: PByte; HShift: LongWord): SizeInt; inline;
begin
  Result := SizeInt(LongWord(Mul32(V32(p), K1) + Mul32(V32(p + 1), K2)) shr HShift);
end;

{ CycledCachingMatchFinder<5>::find_matchlen (TCycledMF.FindMatchLen con N=5; mismo lazo con
  goto que la clase, que es el del C). q: el match (como el campo Q de la clase, que en len0
  queda sin tocar). }
function YFind5(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
label
  len4, len5, len6, len7;
var
  len, len1, h, i, x1, v1, t, k: LongWord;
  rowstart, rowend, table, tabend: PLongWord;
  bs, qq, q1: PByte;
begin
  bs := F.Bs;
  h := LongWord(YRow5(p, F.HShift));
  if F.Head[h] = 0 then F.Head[h] := Byte(F.YRow - 1) else F.Head[h] := F.Head[h] - 1;
  i := F.Head[h];
  rowstart := F.HT + SizeInt(h) * F.YRow * 2;
  rowend := rowstart + F.YRow * 2;
  table := rowstart + i * 2;
  tabend := table;
  k := V32(p + 4);
  table^ := p - bs; Inc(table);
  table^ := k; Inc(table);
  if table = rowend then table := rowstart;
  x1 := 0;

  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF00) <> 0 then goto len4
      else if (t and $FF0000) <> 0 then goto len5
      else goto len6;
    end;
  end;
  Exit(4);                                  // MinLen-1

len4:
  qq := bs + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FFFF) = 0 then
    begin
      if t = 0 then goto len7
      else if (t and $FF0000) <> 0 then
        begin if not ChangePair(p - qq, p - (bs + x1)) then goto len5; end
      else goto len6;
    end;
  end;
  q := qq;
  Exit(AcceptMatch(5, p, qq, bufend));

len5:
  qq := bs + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if (t and $FFFFFF) = 0 then
    begin
      if t = 0 then goto len7
      else if not ChangePair(p - qq, p - (bs + x1)) then goto len6;
    end;
  end;
  q := qq;
  Exit(AcceptMatch(6, p, qq, bufend));

len6:
  qq := bs + x1;
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    if t = 0 then
    begin
      q1 := bs + x1;
      if (V32(p + 5) = V32(q1 + 5)) or not ChangePair(p - qq, p - q1) then goto len7;
    end;
  end;
  q := qq;
  Exit(AcceptMatch(7, p, qq, bufend));

len7:
  len := 4;
  qq := bs + x1;
  if V32(p) = V32(qq) then len := ExtendC(p, qq, 4, bufend);
  while table <> tabend do
  begin
    x1 := table^; Inc(table); if x1 = 0 then Break;
    v1 := table^; Inc(table);
    if table = rowend then table := rowstart;
    t := v1 xor k;
    q1 := bs + x1;
    if (t = 0) and (p[len] = q1[len]) and (V32(p) = V32(q1)) then
    begin
      len1 := ExtendC(p, q1, 4, bufend);
      if (len1 > len) and not ((len1 = len + 1) and ChangePair(p - qq, p - q1)) then
      begin
        len := len1; qq := q1;
      end;
    end;
  end;
  q := qq;
  Result := len;
end;

{ Pide a la caché la fila de p y su cabeza (la búsqueda recorre la fila entera) }
procedure YPrefetch(const F: TFastMF; p: PByte); inline;
var
  h: SizeInt;
  t, e: PByte;
begin
  h := YRow5(p, F.HShift);
  prefetch(F.Head[h]);
  t := PByte(F.HT + h * F.YRow * 2);
  e := t + F.YRow * 8;
  while t < e do
  begin
    prefetch(t^);
    Inc(t, 64);
  end;
end;

{ CycledCachingMatchFinder<5>::update_hash1 (TCycledMF.UpdateHash1) }
procedure YIns5(const F: TFastMF; p: PByte); inline;
var
  h, i: LongWord;
  table: PLongWord;
begin
  h := LongWord(YRow5(p, F.HShift));
  if F.Head[h] = 0 then F.Head[h] := Byte(F.YRow - 1) else F.Head[h] := F.Head[h] - 1;
  i := F.Head[h];
  table := F.HT + (SizeInt(h) * F.YRow + i) * 2;
  table[0] := p - F.Bs;
  table[1] := V32(p + 4);
end;

{ ExactMatchFinder<4>: hashx(4, p) con la máscara de BaseMatchFinder }
function XRow4(const F: TFastMF; p: PByte): SizeInt; inline;
begin
  Result := SizeInt((Mul32(V32(p), K1) shr F.XShift) and F.XMask);
end;

{ ExactMatchFinder<4>::find_matchlen (TExactMF.FindMatchLen; q queda sin tocar si no hay match) }
function XFind4(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
var
  t: PLongWord;
  x0, x1: LongWord;
  j: SizeInt;
  q1: PByte;
begin
  t := F.XHT + XRow4(F, p);
  x0 := p - F.Bs;
  j := 0;
  while j < F.XRow do
  begin
    x1 := t[j];  t[j] := x0;
    q1 := F.Bs + x1;
    if not AcceptLenDist(4, p - q1) then Exit(3);
    if (p <= bufend) and (V32(p) = V32(q1)) then     // accept_optimal_match(4)
    begin
      q := q1;
      Exit(4);
    end;
    Inc(j);
    x0 := x1;
  end;
  Result := 3;
end;

{ Hash3<CombineMF<...>,16,12,TRUE>::find_matchlen (THash3MF/TCombineMF.FindMatchLen) }
function H7Find(const F: TFastMF; p, bufend: PByte; var q: PByte): LongWord;
var
  len1, len2, h: LongWord;
  q1, q2, bs: PByte;
begin
  bs := F.Bs;
  // CombineMF. El match de cada finder solo se usa si lo encontró (el Q viejo de las clases
  // nunca decide nada), así que alcanza con nil
  q1 := nil;
  len1 := YFind5(F, p, bufend, q1);
  if len1 > 5 then
  begin
    F.XHT[XRow4(F, p)] := p - bs;           // mf2.update_hash1(p)
    q := q1;
    Result := len1;
  end
  else
  begin
    q2 := nil;
    len2 := XFind4(F, p, bufend, q2);
    if (len1 >= 5) and (len1 > len2) and
       not ((len2 >= 4) and (len1 = len2 + 1) and ChangePair(p - q2, p - q1)) then
    begin
      q := q1; Result := len1;
    end
    else
    begin
      q := q2; Result := len2;
    end;
  end;
  // Hash3
  if Result < 4 then
  begin
    h := Mul32(V24(p), K3) shr (32 - 16);
    q1 := bs + F.HT3[h];  F.HT3[h] := p - bs;
    q := q1;
    if (p - q1 < 6 * kb) and (p + 3 <= bufend) and (V24(p) = V24(q1)) then
    begin
      F.HT2[Mul32(V16(p), K1) shr (32 - 12)] := p - bs;
      Result := 3;
    end
    else
    begin
      h := Mul32(V16(p), K1) shr (32 - 12);
      q1 := bs + F.HT2[h];  F.HT2[h] := p - bs;
      q := q1;
      if (p - q1 < 256) and (p + 2 <= bufend) and (V16(p) = V16(q1)) then Result := 2
      else Result := 1;
    end;
  end
  else
  begin
    F.HT3[Mul32(V24(p), K3) shr (32 - 16)] := p - bs;
    F.HT2[Mul32(V16(p), K1) shr (32 - 12)] := p - bs;
  end;
end;

{ LazyMatching::update_hash -> Hash3<...,TRUE>::update_hash(p+1, len-1): CombineMF (Cycled<5>
  en todas las posiciones, Exact<4> con step) y los hashes de 3 y 2 bytes en todas }
procedure H7Update(const F: TFastMF; p: PByte; len, step: LongWord);
var
  i: LongWord;
  bs: PByte;
begin
  Inc(p);
  Dec(len);
  bs := F.Bs;
  i := 1;
  while i < len do begin YIns5(F, p + i); Inc(i); end;
  if len > 1 then F.XHT[XRow4(F, p + 1)] := p + 1 - bs;
  i := 2;
  while i < len - 1 do begin F.XHT[XRow4(F, p + i)] := p + i - bs; Inc(i, step); end;
  if len > 3 then F.XHT[XRow4(F, p + len - 1)] := p + len - 1 - bs;
  i := 1;
  while i < len do
  begin
    F.HT3[Mul32(V24(p + i), K3) shr (32 - 16)] := p + i - bs;
    F.HT2[Mul32(V16(p + i), K1) shr (32 - 12)] := p + i - bs;
    Inc(i);
  end;
end;

{ Tabla de datos (CHECK_FOR_DATA_TABLE): devuelve True si encontró y codificó una }
function TTorEngine.FastTables(pp: PByte): Boolean;
begin
  P := pp;
  Result := False;
  // La primera condición de CHECK_FOR_DATA_TABLE (casi siempre falsa) antes de llamar
  if (MF.MinLen < 4) and (pp[-1] = pp[1]) then Result := CheckTable(2);
  if not Result and (pp[-1] = pp[3]) then Result := CheckTable(4);
  if Result then LastFound := TableEnd
  else if pp - LastFound > TABLE_DIST then TableEnd := pp + TABLE_SHIFT;
end;

{ Arma el TFastMF del match finder de la combinación }
procedure TTorEngine.FastSetup(out F: TFastMF);
var
  BM: TMF;
begin
  FillChar(F, SizeOf(F), 0);
  F.Bs := Buf;
  BM := MF;
  if Combo in [5, 6, 7] then
  begin
    F.HT3 := THash3MF(TLazyMF(MF).MF).HT3;
    F.HT2 := THash3MF(TLazyMF(MF).MF).HT2;
    BM := THash3MF(TLazyMF(MF).MF).MF;
  end;
  if Combo = 7 then
  begin
    with TCycledMF(TCombineMF(BM).MF1) do
    begin
      F.HT := HT;
      F.HShift := HashShift;
      F.Head := Head;
      F.YRow := RowWidth;
    end;
    with TExactMF(TCombineMF(BM).MF2) do
    begin
      F.XHT := HT;
      F.XShift := HashShift;
      F.XMask := HashMask;
      F.XRow := RowWidth;
    end;
  end
  else if Combo = 3 then
  begin
    F.HT := TMF2(BM).HT;
    F.HShift := TMF2(BM).HashShift;
    F.HMask := TMF2(BM).HashMask;
  end
  else
  begin
    F.HT := TCachingMF(BM).HT;
    F.HShift := TCachingMF(BM).HashShift;
    F.Row2 := TCachingMF(BM).Row2;
    F.RowUp := TCachingMF(BM).RowUp;
  end;
end;

{ Lo que el lazo rápido no mira en cada posición: lectura de datos, cancelación, espacio de
  salida y tablas. Devuelve la próxima posición en la que hay que volver a llamarla (o nil si
  hay que salir de Run: se pidieron datos o terminó el stream). }
function TTorEngine.FastSpecial(pp: PByte; var SkipRead: Boolean): PByte;
const
  SPAN = 4096;               // posiciones entre llamadas
  MAXOUT = 32;               // bytes que puede emitir una posición (largo + 2 x putbits)
var
  lim: PByte;
begin
  Result := nil;
  if (pp >= ReadPoint) and not SkipRead then
  begin
    P := pp;
    if not ReadPart1 then FinishStream;
    Exit;
  end;
  SkipRead := False;
  CheckCancel;
  // Espacio para SPAN posiciones (el C reserva de más al crear el codificador)
  if C.O + SPAN * MAXOUT + 4096 > Length(C.Out) then C.Grow(SPAN * MAXOUT + 4096);
  lim := pp + SPAN;
  if ReadPoint < lim then lim := ReadPoint;
  if lim <= pp then lim := pp + 1;       // tras leer: codificar al menos una posición
  Result := lim;
end;


{ ---- combo 3 (tor:3): MatchFinder2 + Huffman, greedy ----
  En x86_64 cada tramo (hasta la próxima posición especial o el fin de la zona sin tablas) va
  entero en ensamblador (Tor3Span): match finder, literal (con REPCHAR), código del match con
  sus repdist, árbol de Huffman y el flujo de bits en registros, y la actualización del hash.
  En Pascal FPC manda las variables del lazo a la pila y cada llamada (LitH, EncodeMatchH,
  M2Update) encadena el estado del codificador por memoria. La posición que cierra un bloque de
  Huffman (HufRemainder = 1) la hace RunFast3 por el camino Pascal. Con PARC_NOASM o en otras
  CPU, la plantilla de siempre. Mismo stream. }

{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}

type
  { Estado del tramo de RunFast3 (Tor3Span) }
  TTor3State = record
    pp, lim, op, bs, mend: PByte;
    ht: PLongWord;
    co: TTorCoder;
    bb: QWord;
    bc, rem: LongInt;
    hs, hm: LongWord;
    dcc, l2c: PByte;                    // Dc.Code, Lc2.Code
    dce, dcb, l2e, l2b: PLongWord;      // Extra y Base de Dc y Lc2
    // auxiliares del lazo
    len, dist, dbits, dval: LongWord;
  end;

{ r15 el codificador, r14 salida, r13 lim, r12 pp, rbx buf, r11 bitbuf, r10d bitcount,
  r9 el estado, r8 el hash, edi HufRemainder. putbits(n, x): x en rax, n en esi (usa rcx, rdx).
  Sale con pp >= lim o, sin tocar pp, cuando la próxima posición cerraría el bloque de
  Huffman (HufRemainder = 1). }
procedure Tor3Span(var st: TTor3State);
var
  pst: Pointer;
begin
  pst := @st;
  asm
    movq    pst, %r9
    movq    TTor3State.co(%r9), %r15
    movq    TTor3State.op(%r9), %r14
    movq    TTor3State.lim(%r9), %r13
    movq    TTor3State.pp(%r9), %r12
    movq    TTor3State.bs(%r9), %rbx
    movq    TTor3State.bb(%r9), %r11
    movl    TTor3State.bc(%r9), %r10d
    movq    TTor3State.ht(%r9), %r8
    movl    TTor3State.rem(%r9), %edi
  .Lt3_loop:
    cmpq    %r13, %r12
    jae     .Lt3_done
    cmpl    $1, %edi
    je      .Lt3_done
    // ---- MatchFinder2::find_matchlen ----
    movl    (%r12), %eax
    imull   $123456791, %eax, %edx       // K1
    movl    TTor3State.hs(%r9), %ecx
    shrl    %cl, %edx
    andl    TTor3State.hm(%r9), %edx
    movl    (%r8,%rdx,4), %ecx           // x0
    movl    4(%r8,%rdx,4), %esi          // x1
    movl    %ecx, 4(%r8,%rdx,4)
    movq    %r12, %rax
    subq    %rbx, %rax
    movl    %eax, (%r8,%rdx,4)
    movl    (%r12), %eax
    addq    %rbx, %rcx                   // qq
    addq    %rbx, %rsi                   // q1
    cmpl    (%rcx), %eax
    je      .Lt3_m0
    cmpl    (%rsi), %eax
    jne     .Lt3_lit
    movq    %rsi, %rcx                   // qq := q1
    movl    $3, %edx
    call    .Lt3_ext
    jmp     .Lt3_got
  .Lt3_m0:
    movl    $3, %edx
    call    .Lt3_ext                     // len (edx) contra qq (rcx)
    movzbl  (%r12,%rdx), %eax
    cmpb    (%rsi,%rdx), %al
    jne     .Lt3_got
    pushq   %rdx
    pushq   %rcx
    movq    %rsi, %rcx
    xorl    %edx, %edx
    call    .Lt3_ext                     // len1 contra q1
    popq    %rcx
    popq    %rax
    cmpl    %eax, %edx
    ja      .Lt3_q1                      // len1 > len: q1
    movl    %eax, %edx
    jmp     .Lt3_got
  .Lt3_q1:
    movq    %rsi, %rcx
  .Lt3_got:
    cmpl    $4, %edx
    jae     .Lt3_match

    // ---- literal (REPCHAR si repite el byte de la última distancia) ----
  .Lt3_lit:
    movzbl  (%r12), %eax
    movslq  TTorCoder.PrevDist0(%r15), %rdx
    testq   %rdx, %rdx
    js      .Lt3_lit1
    notq    %rdx                         // -(PrevDist0+1)
    movzbl  (%r12,%rdx), %edx
    cmpl    %eax, %edx
    jne     .Lt3_lit1
    movl    $833, %eax                   // REPCHAR
  .Lt3_lit1:
    call    .Lt3_sym
    incq    %r12
    jmp     .Lt3_loop

    // ---- match: LZ77_Coder::encode_match(len-4, pp-q-1) ----
  .Lt3_match:
    movl    %edx, TTor3State.len(%r9)
    movq    %r12, %rax
    subq    %rcx, %rax
    decl    %eax
    movl    %eax, TTor3State.dist(%r9)   // dist
    movl    $0, TTor3State.dbits(%r9)
    // repdist: rota PrevDist0..3 como el C
    movl    TTorCoder.PrevDist0(%r15), %ecx
    movl    %eax, TTorCoder.PrevDist0(%r15)
    xorl    %esi, %esi                   // dcode
    cmpl    %ecx, %eax
    je      .Lt3_dc
    movl    TTorCoder.PrevDist1(%r15), %edx
    movl    %ecx, TTorCoder.PrevDist1(%r15)
    incl    %esi
    cmpl    %edx, %eax
    je      .Lt3_dc
    movl    TTorCoder.PrevDist2(%r15), %ecx
    movl    %edx, TTorCoder.PrevDist2(%r15)
    incl    %esi
    cmpl    %ecx, %eax
    je      .Lt3_dc
    movl    TTorCoder.PrevDist3(%r15), %edx
    movl    %ecx, TTorCoder.PrevDist3(%r15)
    incl    %esi
    cmpl    %edx, %eax
    je      .Lt3_dc
    // DcCode(dist)
    movq    TTor3State.dcc(%r9), %rdx
    cmpl    $512, %eax
    jae     .Lt3_d1
    movzbl  (%rdx,%rax), %esi
    jmp     .Lt3_d3
  .Lt3_d1:
    cmpl    $131072, %eax
    jae     .Lt3_d2
    movl    %eax, %ecx
    shrl    $8, %ecx
    movzbl  512(%rdx,%rcx), %esi
    jmp     .Lt3_d3
  .Lt3_d2:
    movl    %eax, %ecx
    shrl    $16, %ecx
    movzbl  1024(%rdx,%rcx), %esi
  .Lt3_d3:
    movq    TTor3State.dce(%r9), %rdx
    movl    (%rdx,%rsi,4), %ecx
    movl    %ecx, TTor3State.dbits(%r9)
    movq    TTor3State.dcb(%r9), %rdx
    subl    (%rdx,%rsi,4), %eax
    movl    %eax, TTor3State.dval(%r9)
    addl    $4, %esi                     // + REPDIST_CODES
  .Lt3_dc:
    // largo: L = len-4 (+4 si > 100); lcode = 15 si L > 600, si no Lc2.Code[L]
    movl    TTor3State.len(%r9), %edx
    subl    $4, %edx
    cmpl    $100, %edx
    jbe     .Lt3_l0
    addl    $4, %edx
  .Lt3_l0:
    movl    $15, %ecx
    cmpl    $600, %edx
    ja      .Lt3_l1
    movq    TTor3State.l2c(%r9), %rax
    movzbl  (%rax,%rdx), %ecx
  .Lt3_l1:
    pushq   %rcx                         // lcode
    pushq   %rdx                         // L
    // símbolo 256 + dcode*16 + lcode
    movl    %esi, %eax
    shll    $4, %eax
    addl    %ecx, %eax
    addl    $256, %eax
    call    .Lt3_sym
    popq    %rdx                         // L
    popq    %rcx                         // lcode
    movq    TTor3State.l2e(%r9), %rax
    movl    (%rax,%rcx,4), %esi          // lbits
    testl   %esi, %esi
    jz      .Lt3_l2
    movq    TTor3State.l2b(%r9), %rax
    subl    (%rax,%rcx,4), %edx          // L - base
    movl    %esi, %ecx
    movl    $1, %eax
    shll    %cl, %eax
    decl    %eax
    andl    %edx, %eax
    call    .Lt3_put
  .Lt3_l2:
    movl    TTor3State.dbits(%r9), %esi
    testl   %esi, %esi
    jz      .Lt3_upd
    movl    %esi, %ecx
    movl    $1, %eax
    shll    %cl, %eax
    decl    %eax
    andl    TTor3State.dval(%r9), %eax
    call    .Lt3_put
    // ---- MatchFinder2::update_hash: p+1, p+len-2, p+len-1 ----
  .Lt3_upd:
    movl    TTor3State.len(%r9), %eax
    leaq    1(%r12), %rsi
    call    .Lt3_ins
    leaq    -2(%r12,%rax), %rsi
    call    .Lt3_ins
    leaq    -1(%r12,%rax), %rsi
    call    .Lt3_ins
    addq    %rax, %r12
    jmp     .Lt3_loop

    // ---- subrutinas ----
    // ins: inserta la posición rsi en el hash (usa rcx, rdx, rsi; conserva rax)
  .Lt3_ins:
    movl    (%rsi), %edx
    imull   $123456791, %edx, %edx
    movl    TTor3State.hs(%r9), %ecx
    shrl    %cl, %edx
    andl    TTor3State.hm(%r9), %edx
    movl    (%r8,%rdx,4), %ecx
    movl    %ecx, 4(%r8,%rdx,4)
    subq    %rbx, %rsi
    movl    %esi, (%r8,%rdx,4)
    ret
    // ext: edx := Extend2(pp, rcx, edx, mend) (usa rax)
  .Lt3_ext:
    leaq    8(%r12,%rdx), %rax
    cmpq    TTor3State.mend(%r9), %rax
    ja      .Lt3_ext1
    movq    (%r12,%rdx), %rax
    xorq    (%rcx,%rdx), %rax
    jnz     .Lt3_ext0
    addl    $8, %edx
    jmp     .Lt3_ext
  .Lt3_ext0:
    bsfq    %rax, %rax
    shrl    $3, %eax
    addl    %eax, %edx
    ret
  .Lt3_ext1:
    leaq    (%r12,%rdx), %rax
    cmpq    TTor3State.mend(%r9), %rax
    jae     .Lt3_ext2
    movzbl  (%r12,%rdx), %eax
    cmpb    (%rcx,%rdx), %al
    jne     .Lt3_ext2
    incl    %edx
    jmp     .Lt3_ext1
  .Lt3_ext2:
    ret
    // sym: HuffmanEncoder::encode(eax) sin el cierre de bloque (usa rax, rcx, rdx, rsi)
  .Lt3_sym:
    decl    %edi
    incl    TTorCoder.HufCounter(%r15,%rax,4)
    movzbl  TTorCoder.HufBits(%r15,%rax), %esi
    movl    TTorCoder.HufCode(%r15,%rax,4), %eax
    // put: putbits(esi, rax) (usa rcx, rdx)
  .Lt3_put:
    movl    %r10d, %ecx
    movq    %rax, %rdx
    shlq    %cl, %rdx
    orq     %rdx, %r11
    addl    %esi, %r10d
    cmpl    $64, %r10d
    jb      .Lt3_put1
    movq    %r11, (%r14)
    addq    $8, %r14
    subl    $64, %r10d
    movl    %esi, %ecx
    subl    %r10d, %ecx
    shrq    %cl, %rax
    movq    %rax, %r11
  .Lt3_put1:
    ret

  .Lt3_done:
    movq    %r12, TTor3State.pp(%r9)
    movq    %r14, TTor3State.op(%r9)
    movq    %r11, TTor3State.bb(%r9)
    movl    %r10d, TTor3State.bc(%r9)
    movl    %edi, TTor3State.rem(%r9)
  end ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];
end;

procedure TTorEngine.RunFast3(Resuming: Boolean);
var
  F: TFastMF;
  Co: TTorCoder;
  pp, mend, special, tend, q, lim: PByte;
  len: LongWord;
  SkipRead: Boolean;
  st: TTor3State;
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
  st.bs := Buf; st.mend := mend; st.ht := F.HT; st.co := Co; st.hs := F.HShift; st.hm := F.HMask;
  st.dcc := @Dc.Code[0]; st.dce := @Dc.Extra[0]; st.dcb := @Dc.Base[0];
  st.l2c := @Lc2.Code[0]; st.l2e := @Lc2.Extra[0]; st.l2b := @Lc2.Base[0];
  while True do
  begin
    if pp >= special then
    begin
      special := FastSpecial(pp, SkipRead);
      if special = nil then Exit;
    end;
    // Tablas que conviene restar
    if pp > tend then
    begin
      FastTables(pp);
      tend := TableEnd;
    end;
    // Hasta special o hasta pasar tend: las dos condiciones de arriba no cambian en el medio.
    // Si pp ya pasó tend (FastTables no lo movió) se mira una sola posición, como en el C
    if tend < pp then lim := pp + 1
    else if tend < special then lim := tend + 1
    else lim := special;
    if lim > special then lim := special;
    if Co.HufRemainder > 1 then
    begin
      st.pp := pp; st.lim := lim;
      st.op := @Co.Out[0] + Co.O;
      st.bb := Co.BitBuf; st.bc := Co.BitCount; st.rem := Co.HufRemainder;
      Tor3Span(st);
      pp := st.pp;
      Co.O := st.op - @Co.Out[0];
      Co.BitBuf := st.bb; Co.BitCount := st.bc; Co.HufRemainder := st.rem;
      if pp >= lim then Continue;
    end;
    // La posición que cierra el bloque de Huffman, por el camino de siempre
    len := M2Find(F, pp, mend, q);
    if len < 4 then
    begin
      Co.LitH(pp);
      Inc(pp);
    end
    else
    begin
      Co.EncodeMatchH(LongInt(len) - 4, LongInt(LongWord(pp - q)) - 1);
      M2Update(F, pp, len);
      Inc(pp, len);
    end;
  end;
end;

{$ENDIF}

{ ---- combos 1 y 2 (tor:1, tor:2): MatchFinder (una entrada por fila, sin update_hash) con
  LZ77_ByteCoder o LZ77_BitCoder, greedy ----
  El lazo de cada tramo (hasta la próxima posición especial) no llama a nada: el hash, la
  salida y las banderas o el flujo de bits van en variables locales, que FPC deja en registros.
  Mismo stream que Run + TMF1 + TTorCoder.Encode (tipos 1 y 2). Estos codificadores no usan
  tablas ni repdist. }

type
  { Estado del tramo de RunFast1 (Tor1Span) }
  TTor1State = record
    pp, lim, op, bs, anc, mend: PByte;
    ht: PLongWord;
    flags, fbit, hs, hm: LongWord;
  end;

{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
{ El tramo de RunFast1 en ensamblador: el mismo lazo con todo en registros (en Pascal FPC manda
  la mitad de las variables a la pila). r12 pp, r13 lim, r14 salida, r15 buf, rbx hash,
  r11 palabra de banderas (0 = ninguna), r10d banderas, r9d bit de bandera, r8 matchend. }
procedure Tor1Span(var st: TTor1State);
var
  pp, lim, op, bs, anc, mend: PByte;
  ht: PLongWord;
  flags, fbit, hs, hm: LongWord;
begin
  pp := st.pp; lim := st.lim; op := st.op; bs := st.bs; anc := st.anc; mend := st.mend;
  ht := st.ht; flags := st.flags; fbit := st.fbit; hs := st.hs; hm := st.hm;
  asm
    movq    pp, %r12
    movq    lim, %r13
    movq    op, %r14
    movq    bs, %r15
    movq    ht, %rbx
    movq    anc, %r11
    movl    flags, %r10d
    movl    fbit, %r9d
    movq    mend, %r8
  .Lt1_loop:
    // MatchFinder::find_matchlen
    movl    (%r12), %eax
    imull   $123456791, %eax, %edx       // K1
    movl    hs, %ecx
    shrl    %cl, %edx
    andl    hm, %edx
    movl    (%rbx,%rdx,4), %esi
    movq    %r12, %rdi
    subq    %r15, %rdi
    movl    %edi, (%rbx,%rdx,4)
    addq    %r15, %rsi                   // q
    movl    $3, %edx                     // len
    cmpl    (%rsi), %eax
    jne     .Lt1_flag
    // el match: de a 8 bytes mientras entren antes de matchend, después de a uno
  .Lt1_ext8:
    leaq    8(%r12,%rdx), %rax
    cmpq    %r8, %rax
    ja      .Lt1_ext1
    movq    (%r12,%rdx), %rax
    xorq    (%rsi,%rdx), %rax
    jnz     .Lt1_diff
    addl    $8, %edx
    jmp     .Lt1_ext8
  .Lt1_diff:
    bsfq    %rax, %rax
    shrl    $3, %eax
    addl    %eax, %edx
    jmp     .Lt1_flag
  .Lt1_ext1:
    leaq    (%r12,%rdx), %rax
    cmpq    %r8, %rax
    jae     .Lt1_flag
    movzbl  (%r12,%rdx), %eax
    cmpb    (%rsi,%rdx), %al
    jne     .Lt1_flag
    incl    %edx
    jmp     .Lt1_ext1
    // LZ77_ByteCoder::encode
  .Lt1_flag:
    shll    $2, %r9d
    jnz     .Lt1_noflag
    testq   %r11, %r11
    jz      .Lt1_noanc
    movl    %r10d, (%r11)
  .Lt1_noanc:
    xorl    %r10d, %r10d
    movl    $1, %r9d
    movq    %r14, %r11
    addq    $4, %r14
  .Lt1_noflag:
    cmpl    $4, %edx
    jae     .Lt1_match
    movzbl  (%r12), %eax
    movb    %al, (%r14)
    incq    %r14
    incq    %r12
    cmpq    %r13, %r12
    jb      .Lt1_loop
    jmp     .Lt1_done
  .Lt1_match:
    movq    %r12, %rax
    subq    %rsi, %rax                   // dist
    leal    -4(%rdx), %ecx               // largo - MinLen
    cmpl    $16, %ecx
    jae     .Lt1_m2
    cmpl    $4096, %eax
    jae     .Lt1_m2
    shll    $12, %ecx
    addl    %eax, %ecx
    movw    %cx, (%r14)
    addq    $2, %r14
    addl    %r9d, %r10d
    jmp     .Lt1_next
  .Lt1_m2:
    cmpl    $64, %ecx
    jae     .Lt1_m3
    cmpl    $262144, %eax
    jae     .Lt1_m3
    shll    $18, %ecx
    addl    %eax, %ecx
    movl    %ecx, (%r14)
    addq    $3, %r14
    leal    (%r10,%r9,2), %r10d
    jmp     .Lt1_next
  .Lt1_m3:
    cmpl    $16777216, %eax
    jb      .Lt1_m3a
    movb    $255, (%r14)
    movl    %eax, %edi
    shrl    $24, %edi
    movb    %dil, 1(%r14)
    addq    $2, %r14
  .Lt1_m3a:
    cmpl    $254, %ecx
    jb      .Lt1_m3b
    movb    $254, (%r14)
    movl    %ecx, %edi
    shrl    $8, %edi
    movl    %edi, 1(%r14)
    addq    $4, %r14
    andl    $255, %ecx
  .Lt1_m3b:
    shll    $8, %eax
    addl    %ecx, %eax
    movl    %eax, (%r14)
    addq    $4, %r14
    leal    (%r9,%r9,2), %edi
    addl    %edi, %r10d
  .Lt1_next:
    movl    %edx, %edx
    addq    %rdx, %r12
    cmpq    %r13, %r12
    jb      .Lt1_loop
  .Lt1_done:
    movq    %r12, pp
    movq    %r14, op
    movq    %r11, anc
    movl    %r10d, flags
    movl    %r9d, fbit
  end ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];
  st.pp := pp; st.op := op; st.anc := anc; st.flags := flags; st.fbit := fbit;
end;
{$ENDIF}

procedure TTorEngine.RunFast1(Resuming: Boolean);
var
  Co: TTorCoder;
  pp, mend, special, lim, bs, op, base, anc: PByte;
  HT: PLongWord;
  hs, hm, flags, fbit: LongWord;
  SkipRead: Boolean;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
  st: TTor1State;
{$ELSE}
  q: PByte;
  v, h, len, dist, L: LongWord;
{$ENDIF}
begin
  Co := C;
  bs := Buf;
  HT := TBaseMF(MF).HT;
  hs := TBaseMF(MF).HashShift;
  hm := TBaseMF(MF).HashMask;
  SkipRead := False;
  if Resuming then
  begin
    ReadPart2;
    if not (P < BufEnd) then
    begin
      FinishStream;
      Exit;
    end;
    SkipRead := True;
  end;
  pp := P;
  mend := MatchEnd;
  special := pp;
  while True do
  begin
    if pp >= special then
    begin
      special := FastSpecial(pp, SkipRead);
      if special = nil then Exit;
    end;
    lim := special;
    base := @Co.Out[0];
    op := base + Co.O;
    if Co.Anchor >= 0 then anc := base + Co.Anchor else anc := nil;
    flags := Co.Flags;
    fbit := Co.FlagBit;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
    st.pp := pp; st.lim := lim; st.op := op; st.bs := bs; st.anc := anc; st.mend := mend;
    st.ht := HT; st.flags := flags; st.fbit := fbit; st.hs := hs; st.hm := hm;
    Tor1Span(st);
    pp := st.pp; op := st.op; anc := st.anc; flags := st.flags; fbit := st.fbit;
{$ELSE}
    repeat
      // MatchFinder::find_matchlen
      v := V32(pp);
      h := (Mul32(v, K1) shr hs) and hm;
      q := bs + HT[h];
      HT[h] := pp - bs;
      len := 3;
      if v = V32(q) then
      begin
        while (pp + len + 4 < mend) and (V32(pp + len) = V32(q + len)) do Inc(len, 4);
        while (pp + len < mend) and (pp[len] = q[len]) do Inc(len);
      end;
      // LZ77_ByteCoder::encode
      fbit := fbit shl 2;
      if fbit = 0 then
      begin
        if anc <> nil then PLongWord(anc)^ := flags;
        flags := 0; fbit := 1;
        anc := op; Inc(op, 4);
      end;
      if len < 4 then
      begin
        op^ := pp^;
        Inc(op);
        Inc(pp);
      end
      else
      begin
        dist := LongWord(pp - q);
        L := len - 4;
        if (L < 16) and (dist < (1 shl 12)) then
        begin
          PWord(op)^ := Word((L shl 12) + dist);
          Inc(op, 2);
          Inc(flags, fbit);
        end
        else if (L < 64) and (dist < (1 shl 18)) then
        begin
          PLongWord(op)^ := (L shl 18) + dist;
          Inc(op, 3);
          Inc(flags, fbit * 2);
        end
        else
        begin
          if dist >= (1 shl 24) then begin op[0] := 255; op[1] := Byte(dist shr 24); Inc(op, 2); end;
          if L >= 254 then begin op^ := 254; PLongWord(op + 1)^ := L shr 8; Inc(op, 4); L := L and 255; end;
          PLongWord(op)^ := L + (dist shl 8);
          Inc(op, 4);
          Inc(flags, fbit * 3);
        end;
        Inc(pp, len);
      end;
    until pp >= lim;
{$ENDIF}
    Co.O := op - base;
    if anc <> nil then Co.Anchor := anc - base;
    Co.Flags := flags;
    Co.FlagBit := fbit;
  end;
end;

{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
type
  { Estado del tramo de RunFast2 (Tor2Span) }
  TTor2State = record
    pp, lim, op, bs, mend: PByte;
    ht: PLongWord;
    bb: QWord;
    bc: LongInt;
    hs, hm: LongWord;
    lcc, dcc: PByte;                    // Lc.Code, Dc.Code
    lce, lcb, dce, dcb: PLongWord;      // Extra y Base de Lc y Dc
  end;

{ El tramo de RunFast2 en ensamblador. r12 pp, r13 lim, r14 salida, r15 buf, rbx hash,
  r11 bitbuf, r10d bitcount, r8 matchend, r9 el estado. putbits(n, x): x en rax, n en esi. }
procedure Tor2Span(var st: TTor2State);
var
  pst: Pointer;
begin
  pst := @st;
  asm
    movq    pst, %r9
    movq    TTor2State.pp(%r9), %r12
    movq    TTor2State.lim(%r9), %r13
    movq    TTor2State.op(%r9), %r14
    movq    TTor2State.bs(%r9), %r15
    movq    TTor2State.ht(%r9), %rbx
    movq    TTor2State.bb(%r9), %r11
    movl    TTor2State.bc(%r9), %r10d
    movq    TTor2State.mend(%r9), %r8
  .Lt2_loop:
    movl    (%r12), %eax
    imull   $123456791, %eax, %edx       // K1
    movl    TTor2State.hs(%r9), %ecx
    shrl    %cl, %edx
    andl    TTor2State.hm(%r9), %edx
    movl    (%rbx,%rdx,4), %esi
    movq    %r12, %rdi
    subq    %r15, %rdi
    movl    %edi, (%rbx,%rdx,4)
    addq    %r15, %rsi                   // q
    movl    $3, %edx                     // len
    cmpl    (%rsi), %eax
    jne     .Lt2_enc
  .Lt2_ext8:
    leaq    8(%r12,%rdx), %rax
    cmpq    %r8, %rax
    ja      .Lt2_ext1
    movq    (%r12,%rdx), %rax
    xorq    (%rsi,%rdx), %rax
    jnz     .Lt2_diff
    addl    $8, %edx
    jmp     .Lt2_ext8
  .Lt2_diff:
    bsfq    %rax, %rax
    shrl    $3, %eax
    addl    %eax, %edx
    jmp     .Lt2_enc
  .Lt2_ext1:
    leaq    (%r12,%rdx), %rax
    cmpq    %r8, %rax
    jae     .Lt2_enc
    movzbl  (%r12,%rdx), %eax
    cmpb    (%rsi,%rdx), %al
    jne     .Lt2_enc
    incl    %edx
    jmp     .Lt2_ext1
  .Lt2_enc:
    cmpl    $4, %edx
    jae     .Lt2_match
    // literal: putbits(9, byte)
    movzbl  (%r12), %eax
    movl    %r10d, %ecx
    movq    %rax, %rdi
    shlq    %cl, %rdi
    orq     %rdi, %r11
    addl    $9, %r10d
    cmpl    $64, %r10d
    jb      .Lt2_lit1
    movq    %r11, (%r14)
    addq    $8, %r14
    subl    $64, %r10d
    movl    $9, %ecx
    subl    %r10d, %ecx
    shrq    %cl, %rax
    movq    %rax, %r11
  .Lt2_lit1:
    incq    %r12
    cmpq    %r13, %r12
    jb      .Lt2_loop
    jmp     .Lt2_done
  .Lt2_match:
    // se guardan len (pila) y dist: rsi := dist, edx := largo - MinLen
    pushq   %rdx
    movq    %r12, %rax
    subq    %rsi, %rax
    movl    %eax, %esi                   // dist
    subl    $4, %edx                     // L
    // lcode: 7 si L > 600, si no Lc.Code[L]
    movl    $7, %ecx
    cmpl    $600, %edx
    ja      .Lt2_lc
    movq    TTor2State.lcc(%r9), %rdi
    movzbl  (%rdi,%rdx), %ecx
  .Lt2_lc:
    // dcode (en edi)
    movq    TTor2State.dcc(%r9), %rdi
    cmpl    $512, %esi
    jae     .Lt2_d1
    movzbl  (%rdi,%rsi), %edi
    jmp     .Lt2_d3
  .Lt2_d1:
    cmpl    $131072, %esi
    jae     .Lt2_d2
    movl    %esi, %eax
    shrl    $8, %eax
    movzbl  512(%rdi,%rax), %edi
    jmp     .Lt2_d3
  .Lt2_d2:
    movl    %esi, %eax
    shrl    $16, %eax
    movzbl  1024(%rdi,%rax), %edi
  .Lt2_d3:
    // L - Lc.Base[lcode] y dist - Dc.Base[dcode], con sus bits extra, a la pila
    pushq   %rdi
    pushq   %rcx
    // símbolo: 256 + lcode shl 5 + dcode, 9 bits
    movl    %ecx, %eax
    shll    $5, %eax
    addl    %edi, %eax
    addl    $256, %eax
    movl    %r10d, %ecx
    movq    %rax, %rdi
    shlq    %cl, %rdi
    orq     %rdi, %r11
    addl    $9, %r10d
    cmpl    $64, %r10d
    jb      .Lt2_s1
    movq    %r11, (%r14)
    addq    $8, %r14
    subl    $64, %r10d
    movl    $9, %ecx
    subl    %r10d, %ecx
    shrq    %cl, %rax
    movq    %rax, %r11
  .Lt2_s1:
    // bits del largo
    popq    %rcx                         // lcode
    movq    TTor2State.lce(%r9), %rdi
    movl    (%rdi,%rcx,4), %eax          // n
    testl   %eax, %eax
    jz      .Lt2_l1
    movl    %edx, %edi
    movq    TTor2State.lcb(%r9), %rdx
    subl    (%rdx,%rcx,4), %edi          // L - base
    movl    %eax, %ecx                   // n
    movl    $1, %edx
    shll    %cl, %edx
    decl    %edx
    andl    %edx, %edi                   // x
    movl    %eax, %edx                   // n
    movl    %r10d, %ecx
    movq    %rdi, %rax
    shlq    %cl, %rax
    orq     %rax, %r11
    addl    %edx, %r10d
    cmpl    $64, %r10d
    jb      .Lt2_l1
    movq    %r11, (%r14)
    addq    $8, %r14
    subl    $64, %r10d
    movl    %edx, %ecx
    subl    %r10d, %ecx
    shrq    %cl, %rdi
    movq    %rdi, %r11
  .Lt2_l1:
    // bits de la distancia
    popq    %rcx                         // dcode
    movq    TTor2State.dce(%r9), %rdi
    movl    (%rdi,%rcx,4), %eax          // n
    testl   %eax, %eax
    jz      .Lt2_dd
    movq    TTor2State.dcb(%r9), %rdx
    movl    %esi, %edi
    subl    (%rdx,%rcx,4), %edi          // dist - base
    movl    %eax, %ecx
    movl    $1, %edx
    shll    %cl, %edx
    decl    %edx
    andl    %edx, %edi
    movl    %eax, %edx
    movl    %r10d, %ecx
    movq    %rdi, %rax
    shlq    %cl, %rax
    orq     %rax, %r11
    addl    %edx, %r10d
    cmpl    $64, %r10d
    jb      .Lt2_dd
    movq    %r11, (%r14)
    addq    $8, %r14
    subl    $64, %r10d
    movl    %edx, %ecx
    subl    %r10d, %ecx
    shrq    %cl, %rdi
    movq    %rdi, %r11
  .Lt2_dd:
    popq    %rdx
    movl    %edx, %edx
    addq    %rdx, %r12
    cmpq    %r13, %r12
    jb      .Lt2_loop
  .Lt2_done:
    movq    %r12, TTor2State.pp(%r9)
    movq    %r14, TTor2State.op(%r9)
    movq    %r11, TTor2State.bb(%r9)
    movl    %r10d, TTor2State.bc(%r9)
  end ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'];
end;
{$ENDIF}

procedure TTorEngine.RunFast2(Resuming: Boolean);
var
  Co: TTorCoder;
  pp, mend, special, lim, bs, op, base: PByte;
  HT: PLongWord;
  hs, hm: LongWord;
  bb: QWord;
  bc: LongInt;
  SkipRead: Boolean;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
  st: TTor2State;
{$ELSE}
  q: PByte;
  v, h, len, dist, lcode, dcode, sx, n, L: LongWord;
{$ENDIF}
begin
  Co := C;
  bs := Buf;
  HT := TBaseMF(MF).HT;
  hs := TBaseMF(MF).HashShift;
  hm := TBaseMF(MF).HashMask;
  SkipRead := False;
  if Resuming then
  begin
    ReadPart2;
    if not (P < BufEnd) then
    begin
      FinishStream;
      Exit;
    end;
    SkipRead := True;
  end;
  pp := P;
  mend := MatchEnd;
  special := pp;
  while True do
  begin
    if pp >= special then
    begin
      special := FastSpecial(pp, SkipRead);
      if special = nil then Exit;
    end;
    lim := special;
    base := @Co.Out[0];
    op := base + Co.O;
    bb := Co.BitBuf;
    bc := Co.BitCount;
{$IF defined(CPUX86_64) and not defined(PARC_NOASM)}
    st.pp := pp; st.lim := lim; st.op := op; st.bs := bs; st.mend := mend; st.ht := HT;
    st.bb := bb; st.bc := bc; st.hs := hs; st.hm := hm;
    st.lcc := @Lc.Code[0]; st.lce := @Lc.Extra[0]; st.lcb := @Lc.Base[0];
    st.dcc := @Dc.Code[0]; st.dce := @Dc.Extra[0]; st.dcb := @Dc.Base[0];
    Tor2Span(st);
    pp := st.pp; op := st.op; bb := st.bb; bc := st.bc;
{$ELSE}
    repeat
      v := V32(pp);
      h := (Mul32(v, K1) shr hs) and hm;
      q := bs + HT[h];
      HT[h] := pp - bs;
      len := 3;
      if v = V32(q) then
      begin
        while (pp + len + 4 < mend) and (V32(pp + len) = V32(q + len)) do Inc(len, 4);
        while (pp + len < mend) and (pp[len] = q[len]) do Inc(len);
      end;
      // LZ77_BitCoder::encode: 9 bits por literal o por código de match, y los bits extra
      if len < 4 then
      begin
        sx := pp^;
        bb := bb or (QWord(sx) shl bc);
        Inc(bc, 9);
        if bc >= 64 then
        begin
          PQWord(op)^ := bb; Inc(op, 8); Dec(bc, 64);
          bb := QWord(sx) shr (9 - bc);
        end;
        Inc(pp);
      end
      else
      begin
        dist := LongWord(pp - q);
        L := len - 4;
        if L > 600 then lcode := 7 else lcode := Lc.Code[L];
        if dist < 512 then dcode := Dc.Code[dist]
        else if dist < 512 * 256 then dcode := Dc.Code[512 + (dist shr 8)]
        else dcode := Dc.Code[1024 + (dist shr 16)];
        sx := 256 + (lcode shl 5) + dcode;
        bb := bb or (QWord(sx) shl bc);
        Inc(bc, 9);
        if bc >= 64 then
        begin
          PQWord(op)^ := bb; Inc(op, 8); Dec(bc, 64);
          bb := QWord(sx) shr (9 - bc);
        end;
        n := Lc.Extra[lcode];
        if n <> 0 then
        begin
          sx := (L - Lc.Base[lcode]) and ((LongWord(1) shl n) - 1);
          bb := bb or (QWord(sx) shl bc);
          Inc(bc, n);
          if bc >= 64 then
          begin
            PQWord(op)^ := bb; Inc(op, 8); Dec(bc, 64);
            bb := QWord(sx) shr (n - LongWord(bc));
          end;
        end;
        n := Dc.Extra[dcode];
        if n <> 0 then
        begin
          sx := (dist - Dc.Base[dcode]) and ((LongWord(1) shl n) - 1);
          bb := bb or (QWord(sx) shl bc);
          Inc(bc, n);
          if bc >= 64 then
          begin
            PQWord(op)^ := bb; Inc(op, 8); Dec(bc, 64);
            bb := QWord(sx) shr (n - LongWord(bc));
          end;
        end;
        Inc(pp, len);
      end;
    until pp >= lim;
{$ENDIF}
    Co.O := op - base;
    Co.BitBuf := bb;
    Co.BitCount := bc;
  end;
end;

{$macro on}

{$IF not defined(CPUX86_64) or defined(PARC_NOASM)}
{ combo 3: MatchFinder2 + Huffman, greedy }
{$define TF_NAME := RunFast3}
{$define TF_MF2}
{$I parc_torrun.inc}
{$undef TF_MF2}
{$ENDIF}


{ combo 4: CachingMatchFinder<4> + Huffman, greedy }
{$define TF_NAME := RunFast4}
{$I parc_torrun.inc}

{ combo 5: LazyMatching<Hash3<CachingMatchFinder<4>,14,10,FALSE>> + aritmético }
{$define TF_NAME := RunFast5}
{$define TF_LAZY}
{$define TF_FIND := H3Find}
{$define TF_UPDATE := H3Update}
{$define TF_ARITH}
{$I parc_torrun.inc}
{$undef TF_ARITH}

{ combo 6: lo mismo con Huffman }
{$define TF_NAME := RunFast6}
{$I parc_torrun.inc}

{ combo 7: LazyMatching<Hash3<CombineMF<CycledCachingMatchFinder<5>,ExactMatchFinder<4>>,
  16,12,TRUE>>, con el codificador del método (aritmético o Huffman; c1/c2 van por Run) }
{$define TF_FIND := H7Find}
{$define TF_UPDATE := H7Update}
{$define TF_NOPF}
{$define TF_PFY}
{$define TF_NAME := RunFast7H}
{$I parc_torrun.inc}
{$define TF_NAME := RunFast7A}
{$define TF_ARITH}
{$I parc_torrun.inc}
{$undef TF_ARITH}
{$undef TF_NOPF}
{$undef TF_PFY}
{$undef TF_LAZY}

{$macro off}
