{ ht4 (parc_lzmaenc): las rutinas de una forma de fila. Se incluye una vez por forma con las
  macros RF_CAP (entradas), RF_TA (dónde empiezan las posiciones), RF_TW (bytes de la palabra
  de etiquetas: 4 u 8, un LongWord o un QWord desde el byte 0), RF_TB (bits por etiqueta, 4 u
  8), RF_HS/RF_HB (bit y ancho de la cabeza en esa palabra), RF_LG (log2 de RF_TB),
  RF_KONE/RF_KLO/RF_KHI (un 1 / los bits bajos / el alto de cada campo de RF_TB bits) y los
  nombres RF_*. RF_PB: bytes por posición (4, o 3 para entradas de hasta 16 MB:
  la posición módulo 2^24, solo si ninguna distancia llega a 2^24). }

function RF_LOADTAGS(row: PByte): QWord; inline;
begin
  {$IF RF_TW = 8}Result := PQWord(row)^;{$ELSE}Result := PLongWord(row)^;{$ENDIF}
end;

{ Escribe pos como entrada nueva de la fila: la cabeza baja uno (sobre la más vieja), con la
  etiqueta de h; x = las etiquetas leídas. Un solo store para etiquetas y cabeza. }
procedure RF_PUSH(row: PByte; x: QWord; h, pos: LongWord); inline;
var
  head: LongWord;
begin
  head := LongWord(x shr RF_HS) and ((1 shl RF_HB) - 1);
  if head = 0 then head := RF_CAP - 1 else Dec(head);
  x := (x and not ((QWord((1 shl RF_TB) - 1) shl (RF_TB * head)) or (QWord((1 shl RF_HB) - 1) shl RF_HS)))
    or (QWord(h and ((1 shl RF_TB) - 1)) shl (RF_TB * head)) or (QWord(head) shl RF_HS);
  // las etiquetas primero: la palabra puede incluir bytes de la primera posición (sin cambios
  // hasta acá), que se escribe después
  {$IF RF_TW = 8}PQWord(row)^ := x;{$ELSE}PLongWord(row)^ := LongWord(x);{$ENDIF}
  {$IF RF_PB = 3}
  PWord(row + RF_TA + 3 * head)^ := Word(pos);
  row[RF_TA + 3 * head + 2] := Byte(pos shr 16);
  {$ELSE}
  PLongWord(row + RF_TA)[head] := pos;
  {$ENDIF}
end;

{ Busca en la fila row (del hash h) los matches de cur (pos) más largos que maxLen, en orden
  de largo creciente, en d (pares largo, distancia - 1), e inserta pos en la fila. mmm: la
  distancia máxima + 1 (min(pos, ventana)). Devuelve el final de d. }
function RF_CORE(p: PMatchFinder; row: PByte; cur: PByte;
  pos, h, mmm, lenLimit, maxLen: LongWord; d: PLongWord): PLongWord; inline;
var
  c: PByte;
  e: PLongWord;
  x0, x, m: QWord;
  head, i, n, delta, len: LongWord;
begin
  e := PLongWord(row + RF_TA);
  x0 := RF_LOADTAGS(row);
  head := LongWord(x0 shr RF_HS) and ((1 shl RF_HB) - 1);
  // campos iguales a la etiqueta: bit RF_TB*i + RF_TB-1 en m (exacto, sin falsos positivos;
  // RF_KLO/RF_KHI: los bits bajos / el alto de cada campo)
  x := x0 xor (QWord(h and ((1 shl RF_TB) - 1)) * RF_KONE);
  m := ((not (((x and RF_KLO) + RF_KLO) or x)) and RF_KHI) and ((QWord(1) shl (RF_TB * RF_CAP)) - 1);
  m := m shr (RF_TB - 1);
  if m <> 0 then
  begin
    // la entrada más nueva (head) al nibble 0, después head + 1, ...
    if head <> 0 then
      m := ((m shr (RF_TB * head)) or (m shl (RF_TB * (RF_CAP - head)))) and ((QWord(1) shl (RF_TB * RF_CAP)) - 1);
    n := p^.cutValue;
    repeat
      {$IF RF_TB = 6}
      i := head + ((LongWord(BsfQWord(m)) * 11) shr 6);   // bsf div 6 (bsf < 64)
      {$ELSE}
      i := head + (LongWord(BsfQWord(m)) shr RF_LG);
      {$ENDIF}
      if i >= RF_CAP then Dec(i, RF_CAP);
      {$IF RF_PB = 3}
      // (leída desde el byte anterior: no pasa del final de la fila ni de la línea de caché)
      delta := LongWord(pos - (PLongWord(row + RF_TA - 1 + 3 * i)^ shr 8)) and $FFFFFF;
      if LongWord(delta - 1) >= LongWord(mmm - 1) then Break;
      {$ELSE}
      delta := LongWord(pos - e[i]);
      if delta >= mmm then Break;
      {$ENDIF}
      c := cur - delta;
      // etiqueta igual pero otros 4 bytes: no cuenta como candidato
      if PLongWord(c)^ = PLongWord(cur)^ then
      begin
        if c[maxLen] = cur[maxLen] then
        begin
          len := MatchLen(c, cur, 4, lenLimit);
          if len > maxLen then
          begin
            maxLen := len;
            d[0] := len;
            d[1] := delta - 1;
            Inc(d, 2);
            if len >= lenLimit then Break;
          end;
        end;
        Dec(n);
      end;
      m := m and (m - 1);
    until (m = 0) or (n = 0);
  end;
  RF_PUSH(row, x0, h, pos);
  Result := d;
end;

{ ht4: el mismo "mixing" hash2/hash3 de Hc4GetMatches (SDK) y después la fila. }
function RF_GETMATCHES(p: PMatchFinder; distances: PLongWord): PLongWord;
var
  h, h2, h3, d2, d3, pos, mmm, maxLen, lenLimit, temp: LongWord;
  cur, row: PByte;
  hash: PLongWord;
begin
  lenLimit := p^.lenLimit;
  if lenLimit < 4 then begin MfMovePos(p); Exit(distances); end;
  cur := p^.buffer;
  pos := p^.pos;
  if lenLimit >= 4 + kRfPf then RfPrefetch(p, cur, pos);
  h := RfCurHash(p, cur, pos);
  row := RfRow(p, h);
  temp := p^.crc[cur[0]] xor cur[1];
  h2 := temp and (kHash2Size - 1);
  temp := temp xor (LongWord(cur[2]) shl 8);
  h3 := temp and (kHash3Size - 1);
  hash := p^.hash;
  d2 := LongWord(pos - hash[h2]);
  d3 := LongWord(pos - hash[kFix3HashSize + h3]);
  hash[h2] := pos;
  hash[kFix3HashSize + h3] := pos;
  mmm := p^.cyclicBufferSize;
  if pos < mmm then mmm := pos;
  maxLen := 3;
  repeat
    if (d2 < mmm) and ((cur - d2)^ = cur^) then
    begin
      distances[0] := 2;
      distances[1] := d2 - 1;
      Inc(distances, 2);
      if (cur - d2)[2] = cur[2] then
      else if (d3 < mmm) and ((cur - d3)^ = cur^) then
      begin
        d2 := d3;
        distances[1] := d3 - 1;
        Inc(distances, 2);
      end
      else
        Break;
    end
    else if (d3 < mmm) and ((cur - d3)^ = cur^) then
    begin
      d2 := d3;
      distances[1] := d3 - 1;
      Inc(distances, 2);
    end
    else
      Break;
    maxLen := UpdateMaxLen(cur, d2, maxLen, lenLimit);
    distances[-2] := maxLen;
    if maxLen = lenLimit then
    begin
      RF_PUSH(row, RF_LOADTAGS(row), h, pos);
      MfMovePos(p);
      Exit(distances);
    end;
    Break;
  until True;
  distances := RF_CORE(p, row, cur, pos, h, mmm, lenLimit, maxLen, distances);
  MfMovePos(p);
  Result := distances;
end;

procedure RF_SKIP(p: PMatchFinder; num: LongWord);
var
  cur, row: PByte;
  hash: PLongWord;
  pos, num2, rem, temp, h: LongWord;
begin
  repeat
    if p^.lenLimit < 4 + kRfPf then
    begin
      // cola del stream (sin prefetch, que lee más adelante)
      if p^.lenLimit >= 4 then
      begin
        cur := p^.buffer;
        temp := p^.crc[cur[0]] xor cur[1];
        p^.hash[temp and (kHash2Size - 1)] := p^.pos;
        temp := temp xor (LongWord(cur[2]) shl 8);
        p^.hash[kFix3HashSize + (temp and (kHash3Size - 1))] := p^.pos;
        h := RfCurHash(p, cur, p^.pos);
        row := RfRow(p, h);
        RF_PUSH(row, RF_LOADTAGS(row), h, p^.pos);
      end;
      MfMovePos(p);
      Dec(num);
      Continue;
    end;
    pos := p^.pos;
    num2 := num;
    rem := LongWord(p^.posLimit - pos);
    if num2 >= rem then num2 := rem;
    Dec(num, num2);
    p^.cyclicBufferPos := p^.cyclicBufferPos + num2;
    cur := p^.buffer;
    hash := p^.hash;
    repeat
      RfPrefetch(p, cur, pos);
      temp := p^.crc[cur[0]] xor cur[1];
      hash[temp and (kHash2Size - 1)] := pos;
      temp := temp xor (LongWord(cur[2]) shl 8);
      hash[kFix3HashSize + (temp and (kHash3Size - 1))] := pos;
      h := RfCurHash(p, cur, pos);
      row := RfRow(p, h);
      RF_PUSH(row, RF_LOADTAGS(row), h, pos);
      Inc(cur);
      pos := LongWord(pos + 1);
      Dec(num2);
    until num2 = 0;
    p^.buffer := cur;
    p^.pos := pos;
    if pos = p^.posLimit then MfCheckLimits(p);
  until num = 0;
end;

