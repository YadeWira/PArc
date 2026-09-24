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
Las etapas de cifrado (`aes`, `blowfish`, `serpent`, `twofish` + parámetros de clave/IV)
aparecen dentro del `Method`. Si el footer o el directorio están cifrados (`-hp`), sin
contraseña no se puede listar. Pendiente de especificar (§9).

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
