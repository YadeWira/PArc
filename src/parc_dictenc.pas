{ DICT (codificador): reemplazo de palabras frecuentes por códigos de 1 o 2 bytes. Port de
  Compression/Dict/dict.cpp (DictEncode, phase1..phase7) y C_Dict.cpp (dict_compress) de
  FreeArc 0.67 (Bulat Ziganshin). El formato y el decodificador están en parc_dict.
  Stream: bloques [Int32 LE][datos] de a BlockSize; tamaño negativo = bloque guardado
  (DictEncode falló o no llegó a MinCompression).
  Diferencias con el C (a propósito):
   - los qsort del C no son estables y sus comparadores devuelven 0 en empates: acá se ordena
     con merge sort ESTABLE (empate = orden original), así la salida no depende de la libc.
     El qsort de glibc (msort) también es estable, así que contra el C compilado en Linux la
     salida coincide byte a byte;
   - las entradas de menos de 6 bytes, un diccionario que queda vacío tras phase4 o una
     salida que no entra en el buffer del C (bufsize+200000) se guardan sin comprimir: en el
     C son lecturas/escrituras fuera del buffer (ver phase1 endbuf, phase6 hashsize=0).
  Como en el C, char_counts sobrevive de un bloque al siguiente (es global en dict.cpp y
  DictEncode no lo reinicia): acá es estado de la etapa. }
unit parc_dictenc;

{$mode objfpc}{$H+}
{$R-}{$Q-}
{$goto on}

interface

uses
  SysUtils, parc_outstream, parc_dict;

type
  TDictCharCounts = array[0..255] of LongInt;

  { Estadísticas por bloque (las mismas que imprime dict.cpp con -DDEBUG). }
  TDictEncStats = record
    Code: Integer;          // 0 = codificado; <>0 = DictEncode falló (bloque guardado)
    Collected: SizeInt;     // palabras juntadas en phase1
    Good: SizeInt;          // sobrevivientes de phase2
    WeakChars: SizeInt;     // avail_count de phase3
    Nodes: SizeInt;         // palabras de 1 byte pedidas por phase3
    Final: SizeInt;         // palabras con código tras phase4
    DictLen, DataLen: SizeInt;
    Ms: array[1..7] of QWord;  // tiempo de cada fase (ms)
  end;
  PDictEncStats = ^TDictEncStats;

  TDictEncStage = class(TOutStage)
  private
    FPar: TDictParams;
    FIn, FOut: array of Byte;
    FInLen: SizeInt;
    FCharCounts: TDictCharCounts;
    procedure VolcarBloque;
  protected
    procedure DoWrite(Buf: PByte; Count: SizeInt); override;
    procedure DoFinish; override;
  public
    { Estadísticas de cada bloque (para tests); nil = no se juntan. }
    OnStats: procedure(const S: TDictEncStats) of object;
    constructor Create(ATarget: TOutStage; const Params: TStringArray);
  end;

{ DictEncode (dict.cpp) sobre Buf[0..BufSize). Devuelve 0 y OutSize bytes en Out, o un código
  <>0 si no se puede codificar. OutLimit: si la salida llega a OutLimit bytes se abandona
  (devuelve 1): así el llamador corta apenas el bloque ya no puede alcanzar MinCompression. }
function DictEncode(Buf: PByte; BufSize: SizeInt; var CharCounts: TDictCharCounts;
  var Out: TBytes; out OutSize: SizeInt; const Par: TDictParams; OutLimit: SizeInt;
  Stats: PDictEncStats = nil): Integer;

implementation

uses
  Math, parc_methods, parc_progress;

const
  USE_DICT2 = 1;
  RESERVED_CHAR = Ord(' ');
  MAX_WORD_LEN = 254;
  WORD_STEP = 4;
  SCNT_MAX = 32767;        // SHRT_MAX: scnt_t = short (sin PPMD_VERSION)
  SR_FOUND = 0; SR_EMPTY = 1; SR_LONG = 2;

type
  { struct Word: el union hash/hash0 <-> count/chr/chr2 se conserva (phase2 pisa hash con
    count y phase4 escribe chr/chr2 sobre hash0). Ofs = ptr - buf. }
  TDWord = record
    Ofs, Len: LongWord;
    case Integer of
      0: (Hash, Hash0: LongWord);
      1: (Count: LongInt; Chr, Chr2: Byte);
  end;
  TDWordArray = array of TDWord;

  { struct stats de scan_hash }
  TScanSlot = record
    Count: SmallInt;
    Hash0: Word;
  end;
  PScanSlot = ^TScanSlot;

  { struct CodeWord (phase6): el texto no se copia, Ofs apunta al buffer de entrada. }
  TCodeWord = record
    Ofs: LongWord;
    Len, Chr, Chr2: Byte;
  end;

  TSortKind = (skCountDesc, skLex);

{ char_class_table (la variante #if 1): 0 para 0..32 (control + espacio), 1 para el resto. }
function CharClass(c: LongWord): Boolean; inline;
begin
  Result := c > 32;
end;

{ MIN_VISITS_TO_HAVE_SON(len) }
function MinVisits(Len: SizeInt): Integer; inline;
begin
  if Len > 10 then Result := 2 else Result := 5;
end;

{ roundup_to_power_of(n,2) de Common.h }
function RoundUpPow2(n: QWord): QWord;
begin
  if n = 0 then Exit(0);
  Result := 1;
  while Result < n do Result := Result shl 1;
end;

{ update_hash / rehash }
function UpdateHash(h: LongWord; c: Byte): LongWord; inline;
begin
  Result := h * 137 + c + 219;
end;

function Rehash(h: LongWord; c: Byte): LongWord; inline;
begin
  Result := h + LongWord(c) * 256 + 317;
end;

{ common_prefix_length }
function CommonPrefix(Buf: PByte; const A, B: TDWord): LongWord;
var
  n: LongWord;
begin
  n := A.Len;
  if B.Len < n then n := B.Len;
  Result := 0;
  while (Result < n) and (Buf[A.Ofs + Result] = Buf[B.Ofs + Result]) do Inc(Result);
end;

{ count_desc_order / lexicographical_order: <0 si A va antes que B. }
function CmpWords(Buf: PByte; Kind: TSortKind; const A, B: TDWord): Integer;
var
  n, i: LongWord;
begin
  if Kind = skCountDesc then Exit(B.Count - A.Count);
  n := A.Len;
  if B.Len < n then n := B.Len;
  for i := 0 to SizeInt(n) - 1 do
    if Buf[A.Ofs + i] <> Buf[B.Ofs + i] then
      Exit(Integer(Buf[A.Ofs + i]) - Integer(Buf[B.Ofs + i]));
  Result := Integer(A.Len) - Integer(B.Len);
end;

{ Reemplazo ESTABLE del qsort: merge sort de W[Lo..Lo+N), empates en el orden original. }
procedure SortWords(Buf: PByte; var W: TDWordArray; Lo, N: SizeInt; Kind: TSortKind);
var
  Tmp: TDWordArray;

  procedure Sort(L, R: SizeInt);   // [L, R)
  var
    M, i, j, k: SizeInt;
    x: TDWord;
  begin
    if R - L <= 16 then
    begin
      for i := L + 1 to R - 1 do         // inserción: estable
      begin
        x := W[i];
        j := i - 1;
        while (j >= L) and (CmpWords(Buf, Kind, W[j], x) > 0) do
        begin
          W[j + 1] := W[j];
          Dec(j);
        end;
        W[j + 1] := x;
      end;
      Exit;
    end;
    M := L + (R - L) div 2;
    Sort(L, M);
    Sort(M, R);
    if CmpWords(Buf, Kind, W[M - 1], W[M]) <= 0 then Exit;   // ya en orden
    for i := L to M - 1 do Tmp[i] := W[i];
    i := L; j := M; k := L;
    while (i < M) and (j < R) do
    begin
      if CmpWords(Buf, Kind, W[j], Tmp[i]) < 0 then   // solo pasa el derecho si es menor
      begin
        W[k] := W[j]; Inc(j);
      end
      else
      begin
        W[k] := Tmp[i]; Inc(i);
      end;
      Inc(k);
    end;
    while i < M do
    begin
      W[k] := Tmp[i]; Inc(i); Inc(k);
    end;
  end;

begin
  if N < 2 then Exit;
  SetLength(Tmp, Lo + N);
  Sort(Lo, Lo + N);
end;

type
  { Estado de un DictEncode (en el C son globales). }
  TDictEnc = object
    Buf: PByte;
    BufSize: SizeInt;
    CC: ^TDictCharCounts;           // char_counts
    Par: TDictParams;
    W: TDWordArray;                 // FirstWord
    NWords: SizeInt;                // LastWord - FirstWord
    ScanHash: array of TScanSlot;
    Prefix: Byte;                   // PREFIX_FOR_WEAK_CHARS
    HashSize, HashMask: LongWord;
    HashBits: array of Word;
    CodeWords: array of TCodeWord;
    procedure AddWordM(Mask: LongWord; p0, len: SizeInt; hash, phash: LongWord);
    function Phase1: Integer;
    function Phase2: Integer;
    function Phase3(out Nodes: SizeInt; out Avail: SizeInt): Integer;
    function Phase4(Nodes: SizeInt): Integer;
    function Phase5(var Out: TBytes; out DictLen: SizeInt; OutLimit: SizeInt): Integer;
    function Phase6: Integer;
    function Phase7(var Out: TBytes; DictLen: SizeInt; out DataLen: SizeInt; OutLimit: SizeInt): Integer;
  end;

{ SEARCH_IN_HASH(hash,phash,c,...): modifica h (rehash) como la macro. }
function SearchSH(SH: PScanSlot; Mask: LongWord; var h: LongWord; phash: LongWord;
  ch: Byte): Integer; inline;
var
  k: Integer;
  v: Word;
begin
  k := 13;
  repeat
    v := SH[h and Mask].Hash0;
    if v = 0 then Exit(SR_EMPTY);
    if v = Word(phash) then Exit(SR_FOUND);
    Dec(k);
    if k = 0 then Exit(SR_LONG);
    h := Rehash(h, ch);
  until False;
end;

{ ADDWORD(hash,phash) + AddWord: palabra [p0, p0+len) }
procedure TDictEnc.AddWordM(Mask: LongWord; p0, len: SizeInt; hash, phash: LongWord);
var
  h, ph: LongWord;
begin
  if (NWords < Length(W)) and (len <= MAX_WORD_LEN) and (Word(hash) <> 0) then
  begin
    h := hash and Mask;
    ph := phash and Mask;
    Inc(ScanHash[ph].Count);            // short: da la vuelta como en el C
    ScanHash[h].Count := 1;
    ScanHash[h].Hash0 := Word(phash);
    W[NWords].Ofs := p0;
    W[NWords].Len := len;
    W[NWords].Hash := h;
    W[NWords].Hash0 := ph;
    Inc(NWords);
  end;
end;

{ phase1: lista de palabras (AddWord) y cuentas en scan_hash; de paso, frecuencia de bytes. }
function TDictEnc.Phase1: Integer;
var
  MaxWords, ScanSize, Mask: LongWord;
  i0: SizeInt;
  p, p0, EndBuf, maxi, i: SizeInt;
  c1, c: LongWord;
  cb: Byte;
  hash0, hash, hash1, h0, h1, h2, h3: LongWord;
  hh: Word;
  n, r, counter: Integer;
  SH: PScanSlot;
  Tick: LongWord;
label
  found2, lend, search_max, found_max, search_less, lfound;

begin
  // Máximo de palabras: 1/32 de la entrada; hash del doble
  Tick := 0;
  MaxWords := RoundUpPow2(Max(BufSize div 32, 32768));
  SetLength(W, MaxWords);
  NWords := 0;
  ScanSize := MaxWords * 2;
  Mask := ScanSize - 1;
  SetLength(ScanHash, ScanSize);   // en cero
  // Slots 0, 65536, ...: reservados (hash0=1), si no, sus hijos no se podrían buscar
  i0 := 0;
  while i0 < ScanSize do
  begin
    ScanHash[i0].Hash0 := 1;
    Inc(i0, 65536);
  end;
  SH := @ScanHash[0];

  p := 0;
  EndBuf := BufSize - WORD_STEP - 1;
  repeat
    p0 := p;
    c1 := Buf[p]; Inc(p); c := Buf[p];
    if CharClass(c1) <> CharClass(c) then goto lend;
    Inc(p);
    hash0 := (c1 shl 8) + c + 16;
    // SEARCH_IN_HASH(hash0, hash0, hash0, ...): hash, phash y c son la MISMA variable, así que
    // la comparación y el rehash usan el hash0 ya rehasheado (y c = byte bajo de hash0)
    n := 13;
    repeat
      hh := SH[hash0 and Mask].Hash0;
      if hh = 0 then Break;
      if hh = Word(hash0) then goto found2;
      Dec(n);
      if n = 0 then goto lend;
      hash0 := Rehash(hash0, Byte(hash0));
    until False;
    AddWordM(Mask, p0, p - p0, hash0, hash0);        // padre = sí misma (misma variable)
    goto lend;

  found2:
    repeat
      hash := hash0; hash1 := hash0;
      // Búsqueda especulativa: extender mientras la clase de carácter no cambie
      i := 0;
      while i < WORD_STEP do
      begin
        c1 := c; c := Buf[p + i];
        if CharClass(c1) <> CharClass(c) then goto search_max;
        hash1 := hash;
        hash := UpdateHash(hash, c);
        Inc(i);
      end;
      r := SearchSH(SH, Mask, hash, hash1, c1);          // c1: el penúltimo carácter, como en el C
      if r = SR_LONG then goto found_max;
      if r = SR_EMPTY then goto search_less;
      // next_cycle: está la palabra de largo máximo, seguir con otra más larga
      Inc(p, i);
      counter := SH[hash and Mask].Count;
      if counter >= MinVisits(p - p0) then
      begin
        hash0 := hash;
        Continue;
      end;
      if counter > 0 then
      begin
        SH[hash and Mask].Count := counter + 1;
        Break;
      end;
      AddWordM(Mask, p0, p - p0, hash, hash1);
      Break;

    search_max:   // largo i: después viene un carácter de otra clase
      if i > 0 then
      begin
        r := SearchSH(SH, Mask, hash, hash1, c1);
        if r = SR_EMPTY then goto search_less;
      end;
    found_max:    // la palabra está pero no se puede extender: solo sube su cuenta
      Inc(p, i);
      counter := SH[hash and Mask].Count;
      if counter <= 0 then
      begin
        AddWordM(Mask, p0, p - p0, hash, hash1);
        Break;
      end;
      if counter < SCNT_MAX - 1 then SH[hash and Mask].Count := counter + 1;
      Break;

    search_less:  // la más larga no está: buscar desde el principio la más larga que sí
      maxi := i;
      h0 := hash0; h3 := hash0;
      i := 1;
      while i < maxi do
      begin
        cb := Buf[p]; Inc(p);
        h1 := UpdateHash(h0, cb);
        h2 := h1;
        r := SearchSH(SH, Mask, h2, h0, cb);
        if r = SR_LONG then goto found_max;   // con el i y el p de este ciclo, como el C
        if r = SR_EMPTY then
        begin
          Dec(p);
          goto lfound;
        end;
        h0 := h1; h3 := h2;                    // next: (h0 sin rehash, como el C)
        Inc(i);
      end;
      h2 := hash;

    lfound:       // la de largo i está, la de i+1 no
      counter := SH[h3 and Mask].Count;
      if counter >= MinVisits(p - p0) then
      begin
        Inc(p);
        AddWordM(Mask, p0, p - p0, h2, h0);
      end
      else
        SH[h3 and Mask].Count := counter + 1;
      Break;
    until not (p < EndBuf);

  lend:
    while p0 < p do
    begin
      Inc(CC^[Buf[p0]]);
      Inc(p0);
    end;
    // Cancelación: phase1 de un bloque de 128 MB son segundos sin emitir nada
    Inc(Tick);
    if Tick and $FFFF = 0 then CheckCancel;
  until not (p < EndBuf);

  while p < BufSize do
  begin
    Inc(CC^[Buf[p]]);
    Inc(p);
  end;
  Result := 0;
end;

{ phase2: pasar cuentas de padres con un solo hijo al hijo, y de palabras malas al padre. }
function TDictEnc.Phase2: Integer;
var
  k, q, Good: SizeInt;
  len, hash, hash0: LongWord;
  cnt, cnt0, sumcnt: LongInt;
  NW: TDWordArray;

  function IsGood(cnt, cnt0: LongInt): Boolean; inline;   // GOOD_WORD
  begin
    if cnt > Par.MinLargeCnt then Exit(True);
    if cnt0 <> 0 then Result := (cnt > Par.MinMediumCnt) and (cnt > cnt0 * Par.MinRatio)
    else Result := cnt > Par.MinSmallCnt;
  end;

begin
  for k := 0 to NWords - 1 do
  begin
    len := W[k].Len; hash := W[k].Hash; hash0 := W[k].Hash0;
    cnt := ScanHash[hash].Count; cnt0 := ScanHash[hash0].Count;
    if (cnt0 = MinVisits(len - 1) + 1) or (cnt0 < 0) then
    begin
      ScanHash[hash0].Count := 0;
      sumcnt := Abs(cnt) + Abs(cnt0);
      if sumcnt > SCNT_MAX then sumcnt := SCNT_MAX;
      if cnt = MinVisits(len) + 1 then ScanHash[hash].Count := -sumcnt
      else ScanHash[hash].Count := sumcnt;
    end;
  end;

  q := NWords;
  for k := NWords - 1 downto 0 do
  begin
    hash := W[k].Hash; hash0 := W[k].Hash0;
    cnt := Abs(LongInt(ScanHash[hash].Count));
    cnt0 := Abs(LongInt(ScanHash[hash0].Count));
    if IsGood(cnt, cnt0) then
    begin
      W[k].Count := cnt;
      Dec(q);
      W[q] := W[k];
    end
    else
    begin
      sumcnt := cnt + cnt0;
      if sumcnt > SCNT_MAX then sumcnt := SCNT_MAX;
      ScanHash[hash0].Count := sumcnt;
    end;
  end;
  ScanHash := nil;

  // Las sobrevivientes pasan a un arreglo propio (libera el grande de phase1)
  Good := NWords - q;
  SetLength(NW, Good);
  for k := 0 to Good - 1 do NW[k] := W[q + k];
  W := NW;
  NWords := Good;
  if Good > 0 then Result := 0 else Result := -1;
end;

{ phase3: qué bytes (los menos frecuentes) pasan a codificar palabras. }
function TDictEnc.Phase3(out Nodes: SizeInt; out Avail: SizeInt): Integer;
var
  Chr: array[0..255] of Byte;
  Cnt: array[0..255] of LongInt;
  i, j, n, wc: SizeInt;
  xc: Byte;
  xn: LongInt;
begin
  Nodes := 0; Avail := 0;
  SortWords(Buf, W, 0, NWords, skCountDesc);
  // chars por frecuencia ascendente (char_count_asc_order), estable
  for i := 0 to 255 do
  begin
    Chr[i] := i;
    Cnt[i] := CC^[i];
  end;
  for i := 1 to 255 do
  begin
    xc := Chr[i]; xn := Cnt[i];
    j := i - 1;
    while (j >= 0) and (Cnt[j] - xn > 0) do
    begin
      Chr[j + 1] := Chr[j]; Cnt[j + 1] := Cnt[j];
      Dec(j);
    end;
    Chr[j + 1] := xc; Cnt[j + 1] := xn;
  end;

  n := 0;
  while (n < NWords) and (n <= 255) do
  begin
    if Cnt[n] >= W[n].Count then Break;
    CC^[Chr[n]] := 0;              // byte "libre" para codificar palabras
    Inc(n);
  end;
  if n <= Par.MinWeakChars then Exit(-1);   // pocos bytes libres: seguramente binario

  Dec(n);
  CC^[Chr[n]] := 1;                // el último liberado es el prefijo de los bytes robados
  Prefix := Chr[n];
  Avail := n;
  wc := NWords;
  if wc <= Avail then Nodes := Min(wc, Avail)
  else Nodes := Max(Avail - (wc + 259) div 256, 0);
  Result := 0;
end;

{ phase4: asignar códigos de 1 y 2 bytes. }
function TDictEnc.Phase4(Nodes: SizeInt): Integer;
var
  p, Two, Last: SizeInt;
  c, c2: Integer;
begin
  p := 0;
  Two := Nodes;
  SortWords(Buf, W, 0, Nodes, skLex);
  SortWords(Buf, W, Two, NWords - Nodes, skLex);

  c := 0;
  while (c <= 255) and (p < Two) do
  begin
    if (CC^[c] = 0) and (c <> RESERVED_CHAR) then
    begin
      W[p].Chr := c; W[p].Chr2 := RESERVED_CHAR; Inc(p);
    end;
    Inc(c);
  end;

  Last := NWords;
  while (c <= 255) and (p < Last) do
  begin
    if (CC^[c] = 0) and (c <> RESERVED_CHAR) then
    begin
      c2 := 0;
      while (c2 <= 255) and (p < Last) do
      begin
        if c2 <> RESERVED_CHAR then
        begin
          // GOOD_2BYTE_WORD: len>=4; las cortas se descartan (count=0)
          while (p < Last) and not (W[p].Len >= 4) do
          begin
            W[p].Count := 0; Inc(p);
          end;
          if p < Last then
          begin
            W[p].Chr := c; W[p].Chr2 := c2; Inc(p);
          end;
        end;
        Inc(c2);
      end;
    end;
    Inc(c);
  end;
  Last := p;

  // Los códigos de 1 byte que sobran van a las palabras desde TwoByteWords (como el C:
  // pisan códigos de 2 bytes ya dados y también le tocan a las de count=0)
  p := Two;
  while (c <= 255) and (p < Last) do
  begin
    if (CC^[c] = 0) and (c <> RESERVED_CHAR) then
    begin
      W[p].Chr := c; W[p].Chr2 := RESERVED_CHAR; Inc(p);
    end;
    Inc(c);
  end;

  // Quedarse con las que tienen código: por cuenta descendente, cortar en la primera en 0
  SortWords(Buf, W, 0, Last, skCountDesc);
  p := 0;
  while (p < Last) and (W[p].Count <> 0) do Inc(p);
  NWords := p;
  Result := 0;
end;

{ phase5: escribir el diccionario al principio de Out. }
function TDictEnc.Phase5(var Out: TBytes; out DictLen: SizeInt; OutLimit: SizeInt): Integer;
const
  NONE = -1; DICT2 = -2;
var
  D1: array[0..255] of SizeInt;
  D2: array of SizeInt;
  InUse: array[0..255] of Boolean;
  k, i, j, prev, d, n, op, Need: SizeInt;
  c: LongWord;
  WordSep: Integer;
begin
  DictLen := 0;
  SetLength(D2, 65536);
  for i := 0 to 255 do begin D1[i] := NONE; InUse[i] := False; end;
  for i := 0 to 65535 do D2[i] := NONE;
  for k := 0 to NWords - 1 do
    if W[k].Chr2 = RESERVED_CHAR then D1[W[k].Chr] := k
    else
    begin
      D2[W[k].Chr * 256 + W[k].Chr2] := k;
      D1[W[k].Chr] := DICT2;
      for c := 0 to W[k].Len - 1 do InUse[Buf[W[k].Ofs + c]] := True;
    end;
  WordSep := -1;
  for i := 255 downto 0 do
    if not InUse[i] then begin WordSep := i; Break; end;
  if WordSep < 0 then Exit(-1);   // todos los bytes aparecen en palabras de 2 bytes

  // Cota del diccionario para dimensionar Out
  Need := 256 + 2;
  for i := 0 to 255 do
    if D1[i] = DICT2 then Inc(Need, 2 * 256)
    else if D1[i] >= 0 then Inc(Need, W[D1[i]].Len);
  for k := 0 to NWords - 1 do Inc(Need, W[k].Len);
  Need := Max(Need, OutLimit + 2);
  if Length(Out) < Need then
  begin
    Out := nil;
    SetLength(Out, Need);
  end;

  op := 0;
  // 1. largos de las palabras de 1 byte (0 = libre, 1 = USE_DICT2)
  for i := 0 to 255 do
  begin
    if D1[i] = DICT2 then Out[op] := USE_DICT2
    else if D1[i] >= 0 then Out[op] := W[D1[i]].Len
    else Out[op] := 0;
    Inc(op);
  end;
  // 2. prefijo compartido con la palabra anterior de cada código de 2 bytes
  prev := NONE;
  for i := 0 to 255 do
    if D1[i] = DICT2 then
      for j := 0 to 255 do
      begin
        d := D2[i * 256 + j];
        n := 0;
        if (d >= 0) and (prev >= 0) then n := CommonPrefix(Buf, W[d], W[prev]);
        Out[op] := n; Inc(op);
        prev := d;                  // un código vacío corta la cadena (prev_word = NULL)
      end;
  // 3. texto de las palabras de 1 byte
  for i := 0 to 255 do
    if D1[i] >= 0 then
    begin
      Move(Buf[W[D1[i]].Ofs], Out[op], W[D1[i]].Len);
      Inc(op, W[D1[i]].Len);
    end;
  // 4. word_sep y el resto de cada palabra de 2 bytes, terminado en word_sep
  prev := NONE;
  Out[op] := WordSep; Inc(op);
  for i := 0 to 255 do
    if D1[i] = DICT2 then
      for j := 0 to 255 do
      begin
        d := D2[i * 256 + j];
        n := 0;
        if (d >= 0) and (prev >= 0) then n := CommonPrefix(Buf, W[d], W[prev]);
        if d >= 0 then
          while n < SizeInt(W[d].Len) do
          begin
            Out[op] := Buf[W[d].Ofs + n]; Inc(op); Inc(n);
          end;
        Out[op] := WordSep; Inc(op);
        prev := d;
      end;
  // 5. prefijo de los bytes que cedieron su código
  Out[op] := Prefix; Inc(op);
  DictLen := op;
  if op >= OutLimit then Exit(1);
  Result := 0;
end;

{ phase6: hash para encontrar la palabra más larga en cada posición (con los prefijos
  propagados por la cadena). }
function TDictEnc.Phase6: Integer;
var
  k, Longest: SizeInt;
  Unique: QWord;
  i: LongWord;
  hash, hash0, s: LongWord;
  c: Byte;
  n: Integer;
label
  NextWord;
begin
  SortWords(Buf, W, 0, NWords, skLex);
  Unique := 0;
  for k := 0 to NWords - 1 do
    if k = 0 then Inc(Unique, W[k].Len)
    else Inc(Unique, W[k].Len - CommonPrefix(Buf, W[k], W[k - 1]));
  HashSize := RoundUpPow2(Unique * 4);
  if HashSize = 0 then Exit(-1);   // diccionario vacío: en el C hashmask=0xFFFFFFFF (fuera del buffer)
  HashMask := HashSize - 1;
  SetLength(HashBits, HashSize);
  SetLength(CodeWords, HashSize);

  for k := 0 to NWords - 1 do
  begin
    hash := HashSize + Buf[W[k].Ofs];
    Longest := -1;
    for i := 1 to W[k].Len - 1 do
    begin
      c := Buf[W[k].Ofs + i];
      hash0 := hash;
      hash := UpdateHash(hash, c);
      n := 13;
      while (HashBits[hash and HashMask] <> 0) and (HashBits[hash and HashMask] <> Word(hash0)) do
      begin
        Dec(n);
        if n = 0 then goto NextWord;   // cadena demasiado larga: la palabra no entra
        hash := Rehash(hash, c);
      end;
      s := hash and HashMask;
      HashBits[s] := Word(hash0);
      if CodeWords[s].Len <> 0 then Longest := s
      else if Longest >= 0 then CodeWords[s] := CodeWords[Longest];
    end;
    s := hash and HashMask;
    CodeWords[s].Len := W[k].Len;
    CodeWords[s].Chr := W[k].Chr;
    CodeWords[s].Chr2 := W[k].Chr2;
    CodeWords[s].Ofs := W[k].Ofs;
  NextWord:
  end;
  Result := 0;
end;

{ phase7 + FindWord: codificar el texto. }
function TDictEnc.Phase7(var Out: TBytes; DictLen: SizeInt; out DataLen: SizeInt;
  OutLimit: SizeInt): Integer;
var
  p, p0, q, op, len: SizeInt;
  hash0, hash: LongWord;
  h: Word;
  c: Byte;
  n: Integer;
  found: Boolean;
  cw: ^TCodeWord;
  B, O: PByte;
  HB: PWord;
  CWs: ^TCodeWord;
  Cnt: ^TDictCharCounts;
  HS, HM: LongWord;
  k: SizeInt;
  Tick: LongWord;
begin
  Tick := 0;
  HB := @HashBits[0]; CWs := @CodeWords[0]; Cnt := CC; HS := HashSize; HM := HashMask;
  DataLen := 0;
  B := Buf;
  O := @Out[0];
  op := DictLen;
  p := 0;
  repeat
    // FindWord(p, endbuf)
    p0 := p;
    cw := nil;
    q := p0;
    hash0 := HS + B[q]; Inc(q);
    if q <> BufSize then
    begin
      repeat
        c := B[q]; Inc(q);
        hash := UpdateHash(hash0, c);
        n := 13;
        found := False;
        repeat
          h := HB[hash and HM];
          if h = 0 then Break;
          if h = Word(hash0) then begin found := True; Break; end;
          hash := Rehash(hash, c);
          Dec(n);
        until n = 0;
        if not found then Break;
        hash0 := hash;
      until not (q < BufSize);
      Dec(q);
      cw := @CWs[hash0 and HM];
      len := cw^.Len;
      // Como el C: el largo se compara con endbuf-p (p = fin del match, no p0)
      if (len = 0) or (len > BufSize - q) then cw := nil
      else
        for k := 0 to len - 1 do
          if B[p0 + k] <> B[SizeInt(cw^.Ofs) + k] then begin cw := nil; Break; end;
    end;

    if cw <> nil then
    begin
      O[op] := cw^.Chr; Inc(op);
      if cw^.Chr2 <> RESERVED_CHAR then begin O[op] := cw^.Chr2; Inc(op); end;
      Inc(p, cw^.Len);
    end
    else
    begin
      c := B[p]; Inc(p);
      if (Cnt^[c] = 0) or (c = Prefix) then
      begin
        O[op] := Prefix; Inc(op);   // byte que cedió su código: va con prefijo
      end;
      O[op] := c; Inc(op);
    end;
    if op >= OutLimit then Exit(1);  // ya no alcanza MinCompression (o no entra en el buffer del C)
    Inc(Tick);
    if Tick and $FFFF = 0 then CheckCancel;
  until not (p < BufSize);
  DataLen := op - DictLen;
  Result := 0;
end;

function DictEncode(Buf: PByte; BufSize: SizeInt; var CharCounts: TDictCharCounts;
  var Out: TBytes; out OutSize: SizeInt; const Par: TDictParams; OutLimit: SizeInt;
  Stats: PDictEncStats): Integer;
var
  E: TDictEnc;
  Nodes, Avail, DictLen, DataLen: SizeInt;
  S: TDictEncStats;
  t: QWord;

  procedure Lap(k: Integer);
  var t2: QWord;
  begin
    t2 := GetTickCount64;
    S.Ms[k] := t2 - t;
    t := t2;
    CheckCancel;
  end;

begin
  OutSize := 0;
  FillChar(S, SizeOf(S), 0);
  E.NWords := 0; E.Prefix := 0; E.HashSize := 0; E.HashMask := 0;
  E.Buf := Buf;
  E.BufSize := BufSize;
  E.CC := @CharCounts;
  E.Par := Par;
  try
    // Con menos de 6 bytes phase1 del C lee fuera del buffer (endbuf = buf+bufsize-5)
    if BufSize < 6 then Result := -1
    else
    begin
      t := GetTickCount64;
      Result := E.Phase1;
      S.Collected := E.NWords;
      Lap(1);
      if Result = 0 then begin Result := E.Phase2; S.Good := E.NWords; Lap(2); end;
      if Result = 0 then begin Result := E.Phase3(Nodes, Avail); S.WeakChars := Avail; S.Nodes := Nodes; Lap(3); end;
      if Result = 0 then begin Result := E.Phase4(Nodes); S.Final := E.NWords; Lap(4); end;
      if Result = 0 then begin Result := E.Phase5(Out, DictLen, OutLimit); S.DictLen := DictLen; Lap(5); end;
      if Result = 0 then begin Result := E.Phase6; Lap(6); end;
      if Result = 0 then
      begin
        E.W := nil;
        Result := E.Phase7(Out, DictLen, DataLen, OutLimit);
        S.DataLen := DataLen;
        Lap(7);
      end;
      if Result = 0 then OutSize := DictLen + DataLen;
    end;
  finally
    E.W := nil; E.ScanHash := nil; E.HashBits := nil; E.CodeWords := nil;
  end;
  S.Code := Result;
  if Stats <> nil then Stats^ := S;
end;

{ TDictEncStage }

constructor TDictEncStage.Create(ATarget: TOutStage; const Params: TStringArray);
begin
  FPar := ParseDictParams(Params);
  // El encabezado del bloque es un int32 (dict_compress: int WrSize = -InSize)
  if (FPar.BlockSize <= 0) or (FPar.BlockSize > High(LongInt) - 200000) then
    raise EUnsupportedMethod.Create('dict: tamaño de bloque inválido');
  SetLength(FIn, Min(FPar.BlockSize, SizeInt(1) shl 20));
  FInLen := 0;
  FillChar(FCharCounts, SizeOf(FCharCounts), 0);
  inherited Create(ATarget);
end;

{ dict_compress (C_Dict.cpp): un bloque; guardado si DictEncode falla o
  OutSize >= InSize*MinCompression/100 (con MinCompression>0). }
procedure TDictEncStage.VolcarBloque;
var
  OutSize, Limit: SizeInt;
  x: Double;
  r: Integer;
  St: TDictEncStats;
begin
  if FInLen <= 0 then Exit;
  // Límite de salida: el buffer del C (bufsize+200000) y, si hay MinCompression, el primer
  // tamaño que ya se rechazaría
  Limit := FInLen + 200001;
  if FPar.MinCompression > 0 then
  begin
    x := (Double(FInLen) * FPar.MinCompression) / 100;
    if x < Limit then
    begin
      Limit := Trunc(x);
      if Limit < x then Inc(Limit);   // ceil: OutSize >= x  <=>  OutSize >= ceil(x)
    end;
  end;
  r := DictEncode(@FIn[0], FInLen, FCharCounts, FOut, OutSize, FPar, Limit, @St);
  if Assigned(OnStats) then OnStats(St);
  if r <> 0 then
  begin
    EmitU32(LongWord(-LongInt(FInLen)));
    Emit(@FIn[0], FInLen);
  end
  else
  begin
    EmitU32(LongWord(OutSize));
    Emit(@FOut[0], OutSize);
  end;
  // El C libera todo por bloque: acá el de salida se suelta si es grande
  if Length(FOut) > (4 shl 20) then FOut := nil;
  FInLen := 0;
end;

procedure TDictEncStage.DoWrite(Buf: PByte; Count: SizeInt);
var
  n: SizeInt;
begin
  while Count > 0 do
  begin
    if FInLen = Length(FIn) then
      SetLength(FIn, Min(FPar.BlockSize, 2 * Length(FIn)));
    n := Length(FIn) - FInLen;
    if n > Count then n := Count;
    Move(Buf^, FIn[FInLen], n);
    Inc(FInLen, n);
    Inc(Buf, n);
    Dec(Count, n);
    if FInLen >= FPar.BlockSize then VolcarBloque;
  end;
end;

procedure TDictEncStage.DoFinish;
begin
  VolcarBloque;
end;

end.
