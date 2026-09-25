{ Detección del tipo de datos de un bloque: '$compressed', '$text' o 'default'.

  Port exacto de detect_datatype() de FreeArc (Compression/MM/mmdet.cpp). FreeArc la
  llama sobre trozos de 64 KB del archivo y con el resultado elige el grupo de
  métodos ($compressed -> storing/rep, $text -> ppmd/dict, etc.).

  El algoritmo junta tres estadísticas en una sola pasada:
    - la frecuencia de cada byte (para el order-0 y los "caracteres normales");
    - matches LZ con una tabla hash de 16384 entradas indexada por el valor de 16 bits
      (little-endian) en la posición; solo cuentan los de distancia < 256, y de ellos
      cuántos repiten una de las últimas 4 distancias (repdist);
    - la longitud total de los matches (sumlen).

  Detalles del C que hay que reproducir al pie de la letra, porque mueven el umbral:
    - los últimos 10 bytes no se recorren (p < buf+bufsize-10), y con bufsize <= 10 no
      se recorre nada;
    - el bucle de 4 en 4 compara value32 ANTES de mirar el límite, por eso p puede
      pasarse del límite hasta 3 bytes; tras los bucles se cuenta además el byte en p
      (count[*p]++) sin tocar la tabla, y el p++ del for lo saltea;
    - sumlen solo suma si o-q < 256 con q ya avanzado (o-q puede ser negativo);
    - order0 usa log(bufsize/count[i]) con DIVISIÓN ENTERA, y el log() del runtime C;
    - las comparaciones finales se hacen en double. }
unit parc_filetype;

{$mode objfpc}{$H+}

interface

// Clasifica Buf[0..BufSize-1]. Con Buf = nil devuelve la lista de tipos que sabe
// reconocer: '$compressed $text' (como el C).
function DetectDatatype(Buf: PByte; BufSize: Integer): string;

implementation

uses
  SysUtils;

const
  TABLE_SIZE = 16384;
  K020: Double = 0.20;
  K090: Double = 0.90;
  K095: Double = 0.95;
  K010: Double = 0.10;

// log() de la biblioteca C, no Ln de FPC: Ln se calcula en x87 extendido y al
// redondear a double difiere en 1 ulp de log() de glibc en 247 de los enteros
// 1..2^20, lo que puede mover el umbral order0 > 0.95*bufsize. FreeArc llama al log()
// de su runtime C, así que usamos el mismo (libm en Unix, msvcrt en Windows).
{$IFDEF UNIX}
function c_log(x: Double): Double; cdecl; external 'm' name 'log';
{$ELSE}
function c_log(x: Double): Double; cdecl; external 'msvcrt.dll' name 'log';
{$ENDIF}

type
  TCounts = array[0..255] of Integer;

// value16/value32 de Common.h: lectura little-endian sin alinear.
function Value16(p: PByte): Word; inline;
begin
  Result := Word(p[0]) or (Word(p[1]) shl 8);
end;

function Value32(p: PByte): LongWord; inline;
begin
  Result := LongWord(p[0]) or (LongWord(p[1]) shl 8) or
            (LongWord(p[2]) shl 16) or (LongWord(p[3]) shl 24);
end;

function Hash(p: PByte): Integer; inline;
begin
  Result := Value16(p) mod TABLE_SIZE;
end;

// Orden descendente; como son enteros sueltos, el resultado no depende de la
// estabilidad del qsort del C.
procedure SortDesc(var c: TCounts);
var
  i, j, v: Integer;
begin
  for i := 1 to 255 do
  begin
    v := c[i];
    j := i - 1;
    while (j >= 0) and (c[j] < v) do
    begin
      c[j + 1] := c[j];
      Dec(j);
    end;
    c[j + 1] := v;
  end;
end;

function DetectDatatype(Buf: PByte; BufSize: Integer): string;
var
  count: TCounts;
  table: array of PByte;
  matches, repdists, sumlen, i, x, y, sums, total, normal_chars: Integer;
  dist: array[0..3] of Integer;
  p, q, o, lim: PByte;
  pq: PtrInt;
  order0, lg, ln2, term: Double;
begin
  if Buf = nil then
    Exit('$compressed $text');

  FillChar(count, SizeOf(count), 0);
  matches := 0; repdists := 0; sumlen := 0;
  FillChar(dist, SizeOf(dist), 0);

  if BufSize > 10 then
  begin
    SetLength(table, TABLE_SIZE);   // inicializada a nil, como calloc
    lim := Buf + (BufSize - 10);
    p := Buf;
    while p < lim do
    begin
      q := table[Hash(p)];
      if (q <> nil) and (Value16(p) = Value16(q)) then
      begin
        pq := p - q;
        if pq < 256 then
        begin
          Inc(matches);
          x := Integer(pq);
          for i := 0 to 3 do
          begin
            y := dist[i]; dist[i] := x; x := y;
            if x = pq then begin Inc(repdists); Break; end;
          end;
        end;
        // Saltear el match actualizando contadores y tabla
        o := p;
        while (Value32(p) = Value32(q)) and (p < lim) do
        begin
          Inc(count[p[0]]); table[Hash(p)]     := p;
          Inc(count[p[1]]); table[Hash(p + 1)] := p + 1;
          Inc(count[p[2]]); table[Hash(p + 2)] := p + 2;
          Inc(count[p[3]]); table[Hash(p + 3)] := p + 3;
          Inc(p, 4); Inc(q, 4);
        end;
        while (p^ = q^) and (p < lim) do
        begin
          Inc(count[p^]); table[Hash(p)] := p;
          Inc(p); Inc(q);
        end;
        Inc(count[p^]);
        if o - q < 256 then
          sumlen := sumlen + Integer(p - o);
      end
      else
      begin
        Inc(count[p^]);
        table[Hash(p)] := p;
      end;
      Inc(p);
    end;
    table := nil;
  end;

  // Compresión con modelo order-0 (bufsize/count[i] es división entera en el C)
  order0 := 0;
  ln2 := c_log(2.0);
  for i := 0 to 255 do
    if count[i] <> 0 then
    begin
      lg := c_log(Double(BufSize div count[i]));
      term := count[i] * lg;
      term := term / ln2;
      term := term / 8;
      order0 := order0 + term;
    end;

  // Cantidad de símbolos que ocupan el 90% del texto
  sums := 0; total := BufSize; normal_chars := 256;
  SortDesc(count);
  for i := 0 to 255 do
  begin
    if count[i] > BufSize * K020 then
    begin
      total := total - count[i];
      Continue;
    end;
    sums := sums + count[i];
    if sums > total * K090 then
    begin
      normal_chars := i;
      Break;
    end;
  end;

  if (order0 > K095 * BufSize) and (sumlen < K010 * BufSize) then
    Result := '$compressed'
  else if (17 <= normal_chars) and (normal_chars <= 80)
          and (repdists < K020 * matches)
          and (sumlen > K010 * BufSize) then
    Result := '$text'
  else
    Result := 'default';
end;

end.
