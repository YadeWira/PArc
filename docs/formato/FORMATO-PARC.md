# Formato `.parc` — especificación v1 (borrador, 2026-09-24)

`.parc` es el formato nativo de PArc. Toma la estructura de contenedor de FreeArc 0.67
(bloques, descriptores, VInt, footer, directorio en columnas y cadenas de métodos) y le
agrega campos propios. La especificación del contenedor base está en el repo de FreeArc-ex
(`docs/FORMATO-ARC.md`) y en la distribución original de FreeArc.

PArc escribe y lee únicamente `.parc`; no genera ni acepta `.arc`.

## 1. Firma propia

| | `.arc` | `.parc` |
|---|---|---|
| firma de descriptor / HEADER | `41 72 43 01` ("ArC\x01") | `50 41 72 01` ("PAr\x01") |
| versión en el HEADER | `00 00 06 07` (0.67) | `01 00 00 00` (formato 1, U32 LE) |

**Por qué cambia la firma y no solo la versión:** FreeArc busca el footer por la firma
en los últimos 4096 bytes. Con la misma firma, un FreeArc viejo intentaría leer un
`.parc` y fallaría a mitad de camino, o peor, ignoraría en silencio lo que no entiende
(fechas de 64 bits, atributos). Con otra firma dice "no es un archivo FreeArc", que es
el error correcto.

El lector distingue el formato por la firma del descriptor del footer. La versión del
HEADER dice qué extensiones pueden aparecer: un lector de versión N rechaza con un error
claro un archivo de versión mayor.

## 2. Directorio: campos opcionales (implementados)

`.arc` define un mecanismo de campos opcionales al final del DIR_BLOCK
(el contenedor base), que FreeArc 0.67 nunca usó: solo escribe `tag_end = 0`. `.parc`
lo usa así:

```
repetir:
  VInt  tag          (0 = fin)
  Bool  mandatory    (1 = un lector que no conoce el tag tiene que fallar)
  VInt  len          (bytes de datos de este campo)
  len bytes
```

Un lector saltea los tags desconocidos no obligatorios y falla con los obligatorios.
Todos los arrays por archivo van en el mismo orden que las columnas del directorio
(N = cantidad de archivos del bloque).

| tag | nombre | mandatory | datos | uso |
|---|---|---|---|---|
| 1 | `MTIME_NS` | 0 | N × Int64 LE | mtime en **nanosegundos** desde 1970-01-01 UTC. Reemplaza a la columna `Time` de 32 bits, que se sigue escribiendo recortada al rango de Int32 |
| 2 | `WIN_ATTR` | 0 | N × U32 LE | atributos de Windows (`FILE_ATTRIBUTE_*`) |
| 3 | `UNIX_MODE` | 0 | N × U32 LE | `st_mode` (permisos y tipo) |
| 4 | `CTIME_NS` | 0 | N × Int64 LE | reservado (creación) |
| 5 | `ATIME_NS` | 0 | N × Int64 LE | reservado (acceso) |
| 6 | `SYMLINK` | 0 | VInt K, y K veces: VInt índice, CStr destino, U8 a_directorio | enlaces simbólicos (y junctions de Windows). La entrada es un archivo de tamaño 0, sin datos, que va en el bloque de directorios. Destino en UTF-8 con `/`, tal como estaba en el enlace (relativo o absoluto) |
| 7 | `MTIME_NS_DELTA` | 0 | N × VInt (zigzag) | igual que `MTIME_NS` pero cada valor es el delta con signo respecto del archivo anterior (el primero, respecto de 0). Es el que escribe PArc: pierde cero precisión y, como los archivos de un bloque suelen tener fechas parecidas, ocupa menos. Un lector viejo que no conoce este tag se queda con la columna `Time` (segundos) |

Un lector que no conoce `SYMLINK` extrae un archivo vacío en lugar del enlace. Al extraer,
PArc crea los enlaces al final y no crea los que apuntan fuera del destino (absolutos o con
`..` que sube más allá de la raíz) salvo con `-snld`.

`MTIME_NS`/`MTIME_NS_DELTA` cubren ±292 años alrededor de 1970, así que resuelven el problema
de 2038 de la columna `Time` (Int32) y guardan la precisión de NTFS (100 ns) y ext4 (1 ns).
PArc escribe `MTIME_NS_DELTA`; sigue leyendo `MTIME_NS` de los archivos ya creados.

## 3. Resto del contenedor (base de FreeArc)

- **Bloques**: HEADER, DATA, DIR, FOOTER y RECOVERY, con los mismos números de tipo.
- **Descriptores**: los mismos campos y el mismo CRC; solo cambia la firma.
- **Métodos**: las mismas cadenas (`lzma:...`, `rep:...+...`, `4x4:...`).
- **Footer**: los mismos campos, incluidos `locked`, `recovery` y `comment`.
- **Cifrado**: la misma cadena de método que el contenedor base, con dos parámetros más
  que PArc escribe siempre en `.parc` (un lector los acepta también en archivos viejos sin
  ellos):
  - `:f`: el hex de `:s`, `:c`, `:i` y la clave se decodifica bien y la contraseña va en
    UTF-8 (en FreeArc, `:f` existía pero no se usaba; sin él, el hex se decodifica con
    `buggy_decode16`);
  - `:m`: al final de los datos cifrados del bloque van 32 bytes de etiqueta:
    HMAC-SHA512(K_mac, IV ‖ cifrado) truncado, con K_mac = HMAC-SHA512(clave, "PArc-MAC-v1").
    `compsize` incluye la etiqueta.
  Por defecto `:n200000`. Todos los bloques de un archivo escrito de una vez comparten la sal
  (y la clave); cada uno lleva su IV al azar.

## 4. Escritura: invariantes que tiene que cumplir PArc

- Los VInt se escriben siempre en la forma más corta (como FreeArc).
- `compsize` y `origsize` de los descriptores tienen que coincidir con lo escrito.
- El CRC de cada archivo es el de sus datos originales; el de cada bloque de control, el
  de sus datos sin comprimir.
- `rel_pos` del footer y `rel_offsets` del directorio son relativos a la posición del
  bloque que los contiene.
- Nombres en UTF-8 con `/` como separador, relativos, sin `..` ni raíz. En Windows, los
  `\` se convierten a `/`.
- El directorio se escribe **después** de los bloques de datos que describe. Un archivo
  puede tener varios DIR_BLOCK, y todos se listan en el footer.
- El descriptor del footer tiene que terminar dentro de los últimos 4096 bytes.

## 5. Pendiente


## 5b. Registro de recuperación de `.parc`: Reed-Solomon (`parc-rs1`)

Dos RECOVERY_BLOCK (sectores primero, info+CRCs después), con:

- addinfo: versión `parc-rs1`, `arcsize`, `offset` y **dos** pares: `(sector_size,
  rec_sectors)` y `(m, S)`, con `rec_sectors = S × m`;
- los N sectores de la zona protegida (el último, con ceros hasta `sector_size`) se reparten
  en S = ⌈N / (255 − m)⌉ franjas: el sector i es el dato i div S de la franja i mod S;
- la paridad j de la franja s (código de borrado RS sobre GF(2^8), polinomio 0x11D, matriz de
  Cauchy escalada: `src/parc_rs.pas`) es el sector j·S + s del bloque de sectores;
- los CRCs son uno por sector de datos y uno por sector de paridad, y marcan
  qué sectores faltan. Una franja se repara con a lo sumo m sectores dañados.

m es la menor cantidad que da al menos los sectores de recuperación que pide `-rr` con el
cálculo de FreeArc.
- ¿Hash más fuerte que CRC-32 por archivo (p. ej. un tag `BLAKE2B`)? A decidir.
- Enlaces duros, ACL, atributos extendidos: tags futuros.
