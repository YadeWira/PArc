{ ht4 (parc_lzmaenc): las rutinas de una forma de fila. Se incluye una vez por forma con las
  macros RF_CAP (entradas), RF_TA (bytes de etiquetas) y los nombres RF_* definidos. }

function RF_LOADTAGS(row: PByte): QWord; inline;
begin
  {$IF RF_TA = 8}Result := PQWord(row)^;{$ELSE}Result := PLongWord(row)^;{$ENDIF}
end;

{ Escribe pos como entrada nueva de la fila: la cabeza baja uno (sobre la más vieja), con la
  etiqueta de h; x = las etiquetas leídas. Un solo store para etiquetas y cabeza. }
procedure RF_PUSH(row: PByte; x: QWord; h, pos: LongWord); inline;
var
  head: LongWord;
begin
  head := LongWord(x shr (8 * RF_TA - 4)) and $F;
  if head = 0 then head := RF_CAP - 1 else Dec(head);
  PLongWord(row + RF_TA)[head] := pos;
  x := (x and not ((QWord($F) shl (4 * head)) or (QWord($F) shl (8 * RF_TA - 4))))
    or (QWord(h and $F) shl (4 * head)) or (QWord(head) shl (8 * RF_TA - 4));
  {$IF RF_TA = 8}PQWord(row)^ := x;{$ELSE}PLongWord(row)^ := LongWord(x);{$ENDIF}
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
  head := LongWord(x0 shr (8 * RF_TA - 4)) and $F;
  // nibbles iguales a la etiqueta: bit 4i en m (exacto, sin falsos positivos)
  x := x0 xor (QWord(h and $F) * QWord($1111111111111111));
  m := (((not (((x and kRf7) + kRf7) or x)) and kRf8) shr 3) and ((QWord(1) shl (4 * RF_CAP)) - 1);
  if m <> 0 then
  begin
    // la entrada más nueva (head) al nibble 0, después head + 1, ...
    if head <> 0 then
      m := ((m shr (4 * head)) or (m shl (4 * (RF_CAP - head)))) and ((QWord(1) shl (4 * RF_CAP)) - 1);
    n := p^.cutValue;
    repeat
      i := head + (LongWord(BsfQWord(m)) shr 2);
      if i >= RF_CAP then Dec(i, RF_CAP);
      delta := LongWord(pos - e[i]);
      if delta >= mmm then Break;
      c := cur - delta;
      // etiqueta igual pero otros 4 bytes (1 de 16): no cuenta como candidato
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

