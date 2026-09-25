# Formato de archivo FreeArc (`.arc`) — especificación para PArc

Estado: **v0.1 (2026-09-24)**, derivada de las fuentes de FreeArc 0.67
(`ArhiveStructure.hs`, `ArhiveDirectory.hs`, `ByteStream.hs`, `Compression.hs`,
`Unarc/ArcStructure.h`, `Compression/LZMA2/C_LZMA.cpp`) y **validada byte a byte**
contra dos archivos reales del corpus (`archive/freeArc/example.arc` y `data2.arc`)
con el prototipo `tools/arcls.py`.

Todo número multibyte es **little-endian**.

---

## 1. Vista general

Un archivo es una secuencia de **bloques**. Después de cada bloque de control (todos
menos los de datos) se escribe un **descriptor local** que permite ubicarlo leyendo
hacia atrás. El archivo se lee **desde el final**.

```
[SFX opcional]
HEADER_BLOCK        "ArC\x01" + versión (8 bytes, storing)
  descriptor
DATA_BLOCK 0        datos comprimidos de un bloque sólido (sin descriptor)
DATA_BLOCK 1 ...
DIR_BLOCK           directorio de los DATA_BLOCK anteriores (normalmente lzma)
  descriptor
[DATA_BLOCK... DIR_BLOCK+descriptor]*   (un archivo puede tener varios DIR_BLOCK)
[RECOVERY_BLOCK + descriptor]*          (opcional, -rr)
FOOTER_BLOCK        lista de bloques de control (normalmente lzma)
  descriptor        <- tiene que empezar dentro de los últimos 4096 bytes
```

Ejemplo real (`example.arc`, 255.358 bytes):

| bloque   | pos     | orig  | comp   | método                         |
|----------|---------|-------|--------|--------------------------------|
| HEADER   | 0       | 8     | 8      | `storing`                      |
| DATA     | 31      | —     | 244729 | `rep:244kb+tor:244kb:h1mb:c3`  |
| DIR      | 244760  | 81    | 88     | `lzma:1mb:normal:bt4:32`       |
| RECOVERY | 244989  | 8192  | 8192   | `storing`                      |
| RECOVERY | 253206  | 1995  | 1995   | `storing`                      |
| FOOTER   | 255226  | 95    | 94     | `lzma:1mb:normal:bt4:32`       |

## 2. Tipos primitivos

### 2.1 `VInt`: entero de longitud variable (1 a 9 bytes)
La cantidad de **bits 1 consecutivos en la parte baja del primer byte** indica cuántos
bytes extra siguen. El valor se guarda desplazado a la izquierda por (n+1) bits dentro
de una palabra little-endian de n+1 bytes.

| primer byte (bits bajos) | bytes totales | rango de valores | decodificación                      |
|--------------------------|---------------|------------------|-------------------------------------|
| `xxxxxxx0`               | 1             | < 2^7            | `LE(1) >> 1`                        |
| `xxxxxx01`               | 2             | < 2^14           | `LE(2) >> 2`                        |
| `xxxxx011`               | 3             | < 2^21           | `LE(3) >> 3`                        |
| `xxxx0111`               | 4             | < 2^28           | `LE(4) >> 4`                        |
| `xxx01111`               | 5             | < 2^35           | `LE(5) >> 5`                        |
| `xx011111`               | 6             | < 2^42           | `LE(6) >> 6`                        |
| `x0111111`               | 7             | < 2^49           | `LE(7) >> 7`                        |
| `01111111`               | 8             | < 2^56           | `LE(8) >> 8`                        |
| `11111111`               | 9             | < 2^64           | `LE(8)` de los bytes 1..8           |

El codificador **siempre** elige la forma más corta; al escribir, PArc tiene que hacer
lo mismo para producir archivos idénticos. Los valores negativos no existen.

Ejemplos: `0x10` → 8; `2d 1f` → 0x1f2d>>2 = 1995; `0x02` → 1.

### 2.2 Otros tipos
| nombre   | codificación                                                              |
|----------|---------------------------------------------------------------------------|
| `U8`     | 1 byte                                                                    |
| `U32`    | 4 bytes LE                                                                |
| `CStr`   | bytes UTF-8 terminados en `0x00` (no puede contener NUL)                  |
| `Bool`   | 1 byte (0/1). **Las listas de Bool NO se empaquetan en bits**: 1 byte por elemento |
| `List<T>`| `VInt n` + n elementos `T`                                                |
| `CRC`    | `U32`: CRC-32 IEEE (poli 0xEDB88320, init 0xFFFFFFFF, xor final 0xFFFFFFFF) = `zlib.crc32` |
| `Time`   | `U32`: segundos Unix (UTC). `0` = 1970-01-01 (se usa con `-tsN`/sin fechas) |
| `Method` | `CStr` con las etapas unidas por `+`, ej. `rep:214mb+exe+delta+lzma:103mb`|

> Nota sobre `Time`: en Haskell es `CTime`, que en el build Win32 de referencia ocupa
> 4 bytes (el lector C++ de Unarc usa `read4`). Es un entero **con signo** de 32 bits,
> así que PArc debe leerlo como `Int32` y rechazar/saturar al escribir fechas
> > 2038-01-19 (o definir la extensión en `.parc`; ver §8).

## 3. Descriptor local de bloque

Va inmediatamente **después** de los datos del bloque que describe.

| campo       | tipo    | notas                                                       |
|-------------|---------|-------------------------------------------------------------|
| signature   | `U32`   | `41 72 43 01` = `"ArC\x01"`                                 |
| type        | `VInt`  | ver §3.1                                                    |
| method      | `CStr`  | compresor del bloque (`storing` si no está comprimido)      |
| origsize    | `VInt`  | tamaño descomprimido                                        |
| compsize    | `VInt`  | tamaño comprimido = bytes de datos antes de este descriptor |
| crc         | `CRC`   | CRC de los datos **descomprimidos**                         |
| descr_crc   | `CRC`   | CRC de todos los bytes anteriores del descriptor (signature..crc) |

Posición del bloque = `pos(descriptor) − compsize`.

Validaciones (Unarc): `descr_crc` correcto, firma correcta, `origsize>0`, `compsize>0`,
`compsize <= pos(descriptor)`.

### 3.1 Tipos de bloque (valores fijos, solo se agregan al final)
| valor | nombre           | descripción                                      |
|-------|------------------|--------------------------------------------------|
| 0     | `DESCR_BLOCK`    | (etiqueta interna de descriptor; no aparece en listas) |
| 1     | `HEADER_BLOCK`   | cabecera/firma del archivo                       |
| 2     | `DATA_BLOCK`     | bloque sólido de datos                           |
| 3     | `DIR_BLOCK`      | directorio                                       |
| 4     | `FOOTER_BLOCK`   | índice final                                     |
| 5     | `RECOVERY_BLOCK` | información de recuperación                      |
| 6+    | desconocido      | ignorarlo al leer                                |

## 4. HEADER_BLOCK

8 bytes, `storing`: `U32 "ArC\x01"` + `U32` versión. En FreeArc 0.67 la versión se
escribe como bytes `00 00 06 07` (`make4byte 0 0 6 7`) = "0.67". El archivo empieza
con `ArC\x01` salvo que tenga SFX delante.

Tamaño del SFX = posición del primer bloque de la lista del footer (= posición del HEADER).

## 5. Localizar y leer el FOOTER

1. Leer los últimos `min(4096, tamaño)` bytes.
2. Buscar la firma `ArC\x01` **desde el final hacia atrás**. Unarc toma la última
   ocurrencia; `arc.exe` además valida y, si el descriptor no es válido, sigue buscando
   hacia atrás (PArc hace lo segundo: es más robusto frente a firmas falsas).
3. Parsear el descriptor (§3); tiene que ser `type = FOOTER_BLOCK`.
4. Leer `compsize` bytes en `pos`, descomprimir con `method` y verificar tamaño + `crc`.

### 5.1 Contenido del FOOTER (descomprimido)
| campo            | tipo                | notas                                           |
|------------------|---------------------|-------------------------------------------------|
| blocks           | `List<BlockRef>`    | bloques de control, en orden de archivo (sin el propio footer) |
| locked           | `Bool`              | `-k`: archivo bloqueado contra cambios          |
| old_comment_len  | `VInt`              | comentario viejo (UCS-4): siguen `4·len` bytes; FreeArc escribe 0 |
| *— opcional (si no es EOF) —* |          |                                                 |
| recovery         | `CStr`              | configuración de `-rr`, ej. `"4%"`; `""` si no hay |
| *— opcional (si no es EOF) —* |          |                                                 |
| comment_len      | `VInt`              |                                                 |
| comment          | `comment_len` bytes | UTF-8, puede contener NUL                       |

`BlockRef` (`blockToTuple`):
| campo    | tipo   | notas                                                    |
|----------|--------|----------------------------------------------------------|
| type     | `VInt` |                                                          |
| method   | `CStr` |                                                          |
| rel_pos  | `VInt` | **posición absoluta = pos(FOOTER) − rel_pos**            |
| origsize | `VInt` |                                                          |
| compsize | `VInt` |                                                          |
| crc      | `CRC`  |                                                          |

## 6. DIR_BLOCK (descomprimido)

Todos los campos por archivo van **columna por columna** (struct-of-arrays), no fila
por fila. Los archivos aparecen en el orden en que están dentro de los bloques sólidos.

| # | campo          | tipo                      | notas                                    |
|---|----------------|---------------------------|------------------------------------------|
| 1 | nblocks        | `VInt`                    | cantidad de DATA_BLOCK que describe      |
| 2 | files_in_block | `nblocks × VInt`          | archivos por bloque sólido               |
| 3 | methods        | `nblocks × CStr`          | compresor de cada bloque                 |
| 4 | rel_offsets    | `nblocks × VInt`          | **pos absoluta = pos(DIR_BLOCK) − off**  |
| 5 | compsizes      | `nblocks × VInt`          | tamaño comprimido de cada bloque         |
| 6 | dirs           | `List<CStr>`              | nombres de directorio, separador `/`; `""` = raíz |
| — | N = Σ files_in_block |                     |                                          |
| 7 | names          | `N × CStr`                | nombre base (sin directorio)             |
| 8 | dir_index      | `N × VInt`                | índice en `dirs`                         |
| 9 | sizes          | `N × VInt`                | tamaño original                          |
|10 | times          | `N × Time`                | mtime                                    |
|11 | is_dir         | `N × Bool`                | entrada de directorio                    |
|12 | crcs           | `N × CRC`                 | CRC de los datos del archivo             |
|13 | tag_end        | `VInt` = 0                | fin de campos opcionales (hoy no hay ninguno) |

Datos derivados (no se guardan):
- Nombre completo = `dirs[dir_index]` + `/` + `name` (sin `/` si el dir es `""`).
- Offset de un archivo dentro de su bloque sólido = suma de los `sizes` anteriores en ese bloque.
- `origsize` de un DATA_BLOCK = suma de los `sizes` de sus archivos. Los DATA_BLOCK no
  tienen CRC propio ni descriptor.
- Los atributos de archivo **no se guardan** (`fiAttr = 0`).
- Al leer hay que **sanear** `dirs`: quitar componentes `..` y raíces absolutas
  (`remove_unsafe_dirs`) antes de extraer (protección contra path traversal).

Campos opcionales (reservado, sin implementar en 0.67): `VInt tag`, `Bool mandatory`,
`VInt len`, `len` bytes; se repite hasta `tag = 0`. Un lector tiene que fallar si un tag
`mandatory` es desconocido y saltear los demás.

## 7. Métodos de compresión

Un `Method` es una cadena de etapas separadas por `+`, aplicadas **de izquierda a
derecha al comprimir**; al descomprimir se aplican **de derecha a izquierda**. Cada
etapa es `nombre[:param]*`.

Mínimo necesario para **listar** (footer y directorio): `storing` y `lzma`.

### 7.1 `lzma` (bloques de control)
Stream **LZMA1 raw**: sin la cabecera de 5 bytes de `.lzma`, sin tamaño y sin marca de
fin (el decodificador para al llegar a `origsize`). Las propiedades salen del texto del
método:

| parámetro                       | efecto                   | default |
|---------------------------------|--------------------------|---------|
| `d<mem>` o `<mem>` con sufijo   | tamaño de diccionario    | 64mb    |
| `lc<n>` / `lp<n>` / `pb<n>`     | propiedades del literal/pos | 3/0/2 |
| número pelado (`32`)            | numFastBytes (solo compresor) |    |
| `bt4`, `hc4`, `normal`, `max`…  | solo compresor           |         |

`<mem>`: número + `b`/`k`/`kb`/`m`/`mb`/`g`/`gb`.

### 7.1b `lzma` en bloques de DATOS (streaming)
Distinto de los bloques de control: el tamaño de cada etapa intermedia no se conoce, así
que el stream **termina con marca de fin** (distancia 0xFFFFFFFF) y el decodificador usa un
**diccionario circular** de `d` bytes (del método; default 64mb). `lzma_decompress2` en
modo stream falla si la entrada se agota sin marca de fin.

### 7.1c `exe` (BCJ x86)
Filtro sin parámetros. Estado (`ip`, máscara) continuo entre buffers. **Rareza de FreeArc**
(`bcj_x86_de_compress`): un tramo de ≤5 bytes se entrega sin convertir. Como el compresor
recibe buffers llenos, eso solo pasa al final del stream, así que el decodificador **tiene
que llenar su buffer entero antes de convertir**. Si convierte lo primero que le da la etapa
anterior, a mitad del stream puede dejar sin convertir un tramo de ≤5 bytes y la salida queda
corrupta. Es un bug real que tuvo PArc; lo cubre `tests/regress.sh`.

### 7.1d `delta` (Bulat Ziganshin)
Secuencia de bloques hasta EOF, todos los enteros `U32` LE:
`DataSize`, `TableSize` (bytes, múltiplo de 4), `TSkip[TableSize]`, `TType[TableSize]`,
`TRows[TableSize]`, `Data[DataSize]`. Por cada tabla `i`: avanzar `skip`, decodificar
`type` (el bit más alto da el ancho N; los bits de abajo marcan columnas inmutables),
"desreordenar" (las columnas inmutables se guardaron juntas primero) y sumar a cada fila la
anterior, byte a byte en LSB primero, acarreando solo entre columnas mutables contiguas.
Parámetros (`b<mem>`, `x`): solo afectan al compresor.

### 7.2 Métodos vistos en datos reales
`rep`, `tor`, `dict`, `lzp`, `ppmd`, `exe`, `delta`, `lzma` (y, por el código,
`4x4`, `grzip`, `lz4`, `srep`, `precomp`, externos). Para extraer hacen falta todos;
para listar, ninguno.

### 7.3 Cifrado

Fuentes: `Encryption.hs` (derivación de clave y armado del método),
`Compression/_Encryption/C_Encryption.cpp` (`parse_ENCRYPTION`, `docrypt`) y los
cifrados de LibTomCrypt 1.18.2 embebidos en `Compression/_Encryption/`.

El cifrado **no es un método aparte: es una etapa más de la cadena**, unida con
`+` después del compresor. En un archivo real:

```
grzip:198kb:m1:l32:h15+aes-256/ctr:n1000:r0:i<32 hex>:s<64 hex>:c<4 hex>
```

#### 7.3.1 Gramática de la etapa

```
<cifrado>-<bits-clave>/<modo>[:f]:n<iteraciones>:r<rondas>
    [:k<clave-hex>] [:i<iv-hex>] [:s<salt-hex>] [:c<checkcode-hex>]
```

| campo | significado | default |
|---|---|---|
| `cifrado` | `aes`, `blowfish`, `serpent`, `twofish` | `aes` (se elige con `--encryption=` / `-ae`; el perfil lo canoniza a `aes-256/ctr`) |
| `bits-clave` | tamaño de clave en **bits**, tras `-` | el máximo del cifrado (ver tabla) |
| `modo` | `ctr` (0) o `cfb` (1), tras `/` | `ctr` |
| `f` | la contraseña se convierte de Unicode a UTF-8 antes de derivar | ausente = los bytes de la contraseña tal cual |
| `n` | iteraciones de PBKDF2 | 1000 |
| `r` | rondas del cifrado | 0 (las del cifrado) |
| `k` | la clave en hex (**sólo aparece en cabeceras ya descifradas**) | — |
| `i` | IV en hex | — |
| `s` | salt en hex | — |
| `c` | check-code en hex (2 bytes) | — |

#### 7.3.2 Cifrados y tamaños

| cifrado | clave máx. (bits) | bloque / IV (bytes) |
|---|---|---|
| `aes` | 256 (128 y 192 válidos) | 16 |
| `blowfish` | 448 | 8 |
| `serpent` | 256 | 16 |
| `twofish` | 256 | 16 |

#### 7.3.3 Modos

- **CTR** con contador **little-endian** (`CTR_COUNTER_LITTLE_ENDIAN`): keystream =
  `E(IV)` e incrementos sucesivos.
- Excepción: `aes` + `ctr` con `r0` usa el AES-CTR optimizado de 7-Zip
  (`7zAES/Aes.c`), que es equivalente pero lleva el contador **desde IV-1** y hace
  *pre*incremento. Ojo: sólo procesa múltiplos de 16 bytes; `docrypt` se encarga
  de dejar el resto para el ciclo siguiente (por eso el último bloque se redondea
  **hacia arriba** y el resto se recorta al escribir).
- **CFB** del tamaño del bloque (16, o 8 con blowfish).
- El relleno no existe: la longitud de salida es la de entrada. Lo que queda
  fuera del bloque de cifrado se copia tal cual (`RemainderSize`).

#### 7.3.4 Derivación de clave (el punto central)

```
dk       = PBKDF2-HMAC-SHA512(password, salt, iteraciones, keySize + 2)
clave    = dk[0 .. keySize-1]
checkCode= dk[keySize .. keySize+1]          (2 bytes)
```

`Encryption.hs::deriveKey` parte el resultado de `pbkdf2Hmac` con
`splitAt keySize`, así que la clave y el check-code salen de **una sola**
derivación. El `salt` mide exactamente `keySize` bytes y el IV `ivSize`.

Con `-hp`, el **footer en claro** (y su copia de respaldo) lleva
`:s<salt>:c<check>:i<iv>`; el directorio/cabecera descifrados llevan además el
`:k<clave>`, para no volver a pedir la contraseña.

Comprobado sobre archivos reales de 0.67.1: con `--encryption=aes-128` el salt
tiene 16 bytes, con `aes-192` 24, con `aes-256` 32, con `blowfish` 56 (448 bits)
y su IV 8 bytes, y con serpent/twofish 32 y 16.

#### 7.3.5 Detección de contraseña incorrecta

`generateDecryption` reconstruye la clave con cada contraseña candidata y compara
el check-code derivado con el `:c` del archivo. Si no coincide, la contraseña es
incorrecta (y FreeArc pregunta de nuevo / aborta). **No** hay verificación de la
clave contra el texto cifrado: el check-code es lo único que distingue una
contraseña mala antes de intentar descifrar. Además soporta *keyfiles*: se
prueban las contraseñas concatenadas con el contenido de cada keyfile.

`f` (contraseñas Unicode): sin `:f`, los bytes de la contraseña se usan tal cual
(FreeArc histórico); con `:f`, se convierten de Unicode a UTF-8.

#### 7.3.6 Detalle crítico: el hex de `:k` y `:i` se decodifica "mal" a propósito

`Compression/Common.h` define dos conversores de dígito:

```c
static inline int char2int(char c)       { return isdigit(c)? c-'0' : tolower(c)-'a'+10; }
static inline int buggy_char2int(char c) { return isdigit(c)? c-'0' : tolower(c)-'a';    }
```

es decir que el segundo **no suma 10** para las letras: con él `'a'..'f'` valen
0..5 en vez de 10..15.  Y `ENCRYPTION_METHOD::decompress`/`compress` hacen

```c
fixed? decode16 (key, key_bytes) : buggy_decode16 (key, key_bytes);
```

o sea que **la clave y el IV se decodifican con el conversor "buggy"** salvo que
el método traiga el flag `:f`.  Como el *codificador* usó exactamente el mismo
camino, la clave (y el IV) que realmente se usan para cifrar son esa
decodificación "mal decodificada" del hex correcto que escribe el Haskell con
`encode16`/`decode16` (`Utils.hs`).

El **salt** y el **check-code**, en cambio, los decodifica el Haskell con
`decode16` (hex normal): son los que entran a PBKDF2.

Consecuencia práctica: hay que implementar los dos decodificadores y elegir según
el flag `f`.  Si se usa el hex normal para la clave, la derivación y el check-code
dan bien (el salt está bien) pero el descifrado produce basura.

#### 7.3.7 Varios bloques, varios juegos de parámetros

Un archivo cifrado tiene **más de un bloque** (el de los directorios y el de los
datos) y **cada bloque lleva su propio IV, salt y check-code** en su propio
string de método.  Ejemplo real (dos filas de `arc.exe lt`):

```
*  31        0        0   storing+aes-256/ctr:n1000:r0:i<b13c8d..>:s<69d2fd..>:c<7357>
*  31  200,000  200,000   storing+aes-256/ctr:n1000:r0:i<eaf24a..>:s<2ad189..>:c<131e>
```

y cada uno se descifra con la clave derivada de *su* salt (misma contraseña).

#### 7.3.8 Lo que tiene que hacer PArc

1. Sacar `s`, `c`, `n`, `f` y el cifrado/modo de la etapa de cifrado del `Method`.
2. `PBKDF2-HMAC-SHA512(password, salt, n, keySize+2)` y comparar `dk[keySize..]`
   con el `c` del archivo: si no coincide → error claro de contraseña.
3. Si la cabecera está cifrada (`-hp`): leer `s`/`c`/`i` del footer en claro,
   derivar la clave y descifrar la cabecera/directorio; de ahí sale el `:k`.
4. Descifrar el bloque de datos con `cifrado` + `modo` + clave + IV, teniendo en
   cuenta el detalle de AES-CTR/7-Zip y el manejo del sobrante.

#### 7.4 RECOVERY_BLOCK (`-rr`)

Fuentes: `ArcRecover.hs` (escritura, verificación y reparación). En el C++ sólo
aparece la constante `RECOVERY_BLOCK` (`Unarc/FarPlugin.cpp:166`); la lógica real
está toda en el Haskell.

**Qué es.** Un registro de paridad que permite *reparar* el archivo, no sólo
detectar que está roto. Se escriben **dos** bloques de control `RECOVERY_BLOCK`
consecutivos, ambos con método `aNO_COMPRESSION`:

1. el bloque de **sectores de recuperación** (`rec_sectors_size` bytes), y
2. el bloque de **CRCs + info** (`crcs_size` bytes), que empieza con la info de
   control y sigue con los CRCs.

Se escriben en `rrPos` (el final de los datos) y `lt` los reporta como
"N recovery sectors (X bytes) present".

**Footer provisional** (`ArcvProcessRead.hs:85-93`). Antes de los RECOVERY_BLOCK se
escribe un FOOTER_BLOCK completo con la lista `header + directorio` y recovery `""`;
`rrPos` queda *después* de él, así que el registro también lo protege. Después de los
dos RECOVERY_BLOCK se escribe el footer definitivo (lista `header + directorio +
recovery`, sin el provisional, y el texto de `-rr`). Sin el provisional el archivo es
válido pero no idéntico al de FreeArc: `arcsize` y la paridad de la cola cambian.

**Gramática de `-rr`** (`ArcRecover.hs:104-112`, `parseNumber` de `Utils.hs`):
`N;SS` = cantidad N con sector SS; `N*SS` = exactamente N·SS bytes con sector SS
(los dos con `parseSize`: bytes, o `k`/`m`/`g`); si no, `parseNumber N 's'`: sin
sufijo o `s` = N·512, `b`/`k`/`m` = bytes, `%`/`p` = N·⌈arcsize/100⌉ (`divRoundUp`).
`-rr0.1%` y `-rr0.01%` se guardan como `0*4kb` y `0*64kb` (así lo hace arc.exe 0.67.1;
el fuente dice `0*4096`/`0*65536`). `-rr4096*8` (sector de 8 bytes) hace que FreeArc se
quede sin memoria; PArc lo rechaza. Verificado: con `-m0`, archivos idénticos byte a
byte a los de arc.exe para `1%`, `0.1%`, `0.01%`, `8*4096`, `10`, `4%`, `3%;4096`, `2`,
`1m` y `20000b`.

**Derivación de parámetros** (`ArcRecover.hs:104-135`). Con `arcsize` = bytes a
proteger y `wanted_rec_size` = lo pedido en `-rr`:

| cantidad | fórmula |
|---|---|
| `wanted_rec_size` | sufijo `b` = bytes, `s` (o ninguno) = n·512, `%`/`p` = n·⌈arcsize/100⌉ |
| `sector_size` | `2^floor(log2(40·arcsize div wanted_rec_size))`, mínimo 512; con `-rr0%` es 4096 |
| `arc_sectors` | `ceil(arcsize / sector_size)` |
| `crcs_size0` | `arc_sectors · 4` (un CRC de 4 bytes por sector) |
| `rec_size` | `max(wanted_rec_size, crcs_size0)` |
| `rec_sectors` | `ceil((rec_size − crcs_size0) / sector_size)` |
| `rec_sectors_size` | `rec_sectors · sector_size` |
| `crcs_size` | `crcs_size0 + rec_sectors · 4` |

(ojo con `40·arcsize div wanted_rec_size`: es división entera *antes* del logaritmo)

Validado contra archivos reales de `arc.exe` 0.67.1: con datos de 272.000 bytes y
`-rr4%` las fórmulas dan `sector_size = 512`, `rec_sectors = 7` y
`rec_sectors_size = 3584`, y `arc.exe lt` reporta exactamente "7 recovery sectors
(3584 bytes)"; con `-rr1%` dan `sector_size = 2048`, `rec_sectors = 1`, y reporta
"1 recovery sectors (2 kbytes)". La relación es inversa a lo que uno esperaría: más
porcentaje ⇒ sectores más chicos (4% → 512, 2% → 1024, 1% → 2048).

**Algoritmo de paridad.** Es un **XOR rotativo**, no Reed-Solomon:

- El archivo se recorre desde `init_pos` en trozos de a `sector_size` (el último
  puede ser más corto).
- Cada trozo se **XOR-ea** dentro de un sector de recuperación que rota:
  `i := (i+1) mod rec_sectors`, empezando en `i0 = (-arc_sectors) mod rec_sectors`.
  Ese `i0` es lo que hace que el reparto sea independiente de dónde arranque la
  protección, y **hay que respetarlo igual al verificar**.
- De cada trozo se calcula además su **CRC de 4 bytes**, y se guarda en orden.
- Al final se calcula el CRC de **cada sector de recuperación** y se agregan
  también, después de los CRCs de los datos.

**Verificación** (`scanArchive`). Se leen los dos bloques, se recorre el archivo
igual que al escribir (mismo XOR rotativo y mismos CRCs) y todo sector cuyo CRC no
coincida es un sector dañado. Además de los sectores malos, el XOR acumulado de los
sectores *buenos* de cada grupo es lo que después permite reconstruir.

**Reparación.** Para cada sector dañado: si en su grupo de rotación (`i` fijo) hay
un **único** sector dañado, se reconstruye como el XOR del sector de recuperación
con todos los sectores buenos de ese grupo. O sea que **cada grupo tolera un sector
dañado**, y el total tolera hasta `rec_sectors` daños siempre que no caigan dos en el
mismo grupo. El resultado se escribe en `fixed.<nombre>` (nunca se toca el original).

**Info de control.** El bloque de CRCs arranca con la info:

- una **versión como string terminada en NUL**: `"0.36"` cuando hay sectores de
  recuperación y `"0.39"` cuando `rec_sectors = 0` (o sea, sólo CRCs, `-rr0%`);
  la lectura acepta ambas;
- `arcsize` del área protegida;
- el offset que permite recalcular `init_pos = pos_del_bloque − offset`;
- la lista de pares `(sector_size, rec_sectors)`.

**Serialización, confirmada contra un `.arc` real.** Los tipos son los de §2
(`String` = `CStr`, `Integer` = `VInt`, tupla = campos concatenados, lista = `VInt n`
+ elementos), así que el bloque arranca exactamente con:

    CStr "0.36" · VInt arcsize · VInt offset · VInt 1 · VInt sector_size · VInt rec_sectors

y detrás vienen los CRCs. **Ojo con una diferencia que es fácil pasar por alto**: los
CRC (tanto los de cada sector de datos como los de cada sector de recuperación) son
`U32` de 4 bytes **LE**, no `VInt`; en el Haskell son `Storable` (líneas 159 y 166),
no se serializan como los `Integer` del addinfo.

Decodificado de un `.arc` real de `arc.exe` con `-rr4%` (datos de prueba de 272.000
bytes): `"0.36"`, `arcsize = 104535`, `offset = 108144`, lista de 1 par, y el par
`(sector_size = 512, rec_sectors = 7)`. Esos dos valores son exactamente lo que
predicen las fórmulas de arriba para 4%, así que la derivación de parámetros y el
layout quedan confirmados juntos: el `offset` da `init_pos = pos_del_bloque − offset =
0`, o sea la protección arranca en el comienzo del archivo.

## 8. `.parc` — decisiones abiertas

La extensión nativa de PArc es `.parc`.

**Decidido (2026-09-24): `.parc` es un formato DERIVADO con versión propia.** Mantiene
la estructura base de este documento (bloques, descriptores, VInt, footer, directorio
en columnas), pero lleva firma/versión propia en el HEADER y extensiones. Consecuencias:
- PArc **lee** `.arc` de FreeArc 0.67 (obligatorio) y **lee/escribe** `.parc`.
- FreeArc/Unarc **no** tienen que poder leer `.parc`.
- Candidatas a extensión (a especificar en `FORMATO-PARC.md`): `Time` de 64 bits,
  atributos de archivo, campos opcionales del directorio (§6) realmente implementados,
  versión en el HEADER.
- A definir: si PArc también puede *escribir* `.arc` compatible (modo `--arc`).

## 9. Pendiente de especificar
- [ ] RECOVERY_BLOCK (`ArcRecover.hs`): formato de los sectores de recuperación.
- [ ] Cifrado de los datos y de las cabeceras (`Encryption.hs`, `-hp`).
- [ ] Archivos multivolumen, si los hay.
- [ ] Escaneo de archivos rotos (`findBlocksInBrokenArchive`): búsqueda de descriptores hacia atrás en ventanas de 8 MB.
- [ ] Orden y agrupación en bloques sólidos al **escribir** (`ArhiveFileList.hs`).
- [ ] Verificar con archivos generados: vacío, UTF-8, `-m0`, directorios vacíos, SFX.
