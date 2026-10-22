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

{$macro on}

{ combo 3: MatchFinder2 + Huffman, greedy }
{$define TF_NAME := RunFast3}
{$define TF_MF2}
{$I parc_torrun.inc}
{$undef TF_MF2}

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
