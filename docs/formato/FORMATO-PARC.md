# Formato `.parc` — especificación v1 (borrador, 2026-09-24)

`.parc` es el formato nativo de PArc. Es **derivado** de `.arc` de FreeArc 0.67
(`FORMATO-ARC.md`, que es la base y define todo lo que acá no se redefine): los mismos
bloques, descriptores, VInt, footer, directorio en columnas y cadenas de métodos. Las
diferencias son pocas y a propósito.

Decisión del humano (2026-09-24): formato derivado con versión propia. PArc **lee** `.arc`
y `.parc`, y **escribe** `.parc` (y, con `-fmt=arc`, `.arc` compatible, ver §6).
FreeArc no tiene que poder leer `.parc`.

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
(`FORMATO-ARC.md` §6), que FreeArc 0.67 nunca usó: solo escribe `tag_end = 0`. `.parc`
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

Un lector que no conoce `SYMLINK` extrae un archivo vacío en lugar del enlace. Al extraer,
PArc crea los enlaces al final y no crea los que apuntan fuera del destino (absolutos o con
`..` que sube más allá de la raíz) salvo con `-snld`.

`MTIME_NS` cubre ±292 años alrededor de 1970, así que resuelve el problema de 2038 de la
columna `Time` (Int32) y guarda la precisión de NTFS (100 ns) y ext4 (1 ns).

## 3. Todo lo demás, igual que `.arc`

- **Bloques**: HEADER, DATA, DIR, FOOTER y RECOVERY, con los mismos números de tipo.
- **Descriptores**: los mismos campos y el mismo CRC; solo cambia la firma.
- **Métodos**: las mismas cadenas (`lzma:...`, `rep:...+...`, `4x4:...`). Los
  decodificadores de PArc son los mismos para los dos formatos.
- **Footer**: los mismos campos, incluidos `locked`, `recovery` y `comment`.
- **Cifrado**: el mismo (`FORMATO-ARC.md` §7.3).

## 4. Escritura: invariantes que tiene que cumplir PArc

- Los VInt se escriben siempre en la forma más corta (como FreeArc).
- `compsize` y `origsize` de los descriptores tienen que coincidir con lo escrito.
- El CRC de cada archivo es el de sus datos originales; el de cada bloque de control, el
  de sus datos sin comprimir.
- `rel_pos` del footer y `rel_offsets` del directorio son relativos a la posición del
  bloque que los contiene (`FORMATO-ARC.md` §5.1 y §6).
- Nombres en UTF-8 con `/` como separador, relativos, sin `..` ni raíz. En Windows, los
  `\` se convierten a `/`.
- El directorio se escribe **después** de los bloques de datos que describe. Un archivo
  puede tener varios DIR_BLOCK, y todos se listan en el footer.
- El descriptor del footer tiene que terminar dentro de los últimos 4096 bytes.

## 5. Pendiente

- Formato de RECOVERY_BLOCK (el mismo que en `.arc`, falta especificarlo, `FORMATO-ARC.md` §9).
- ¿Hash más fuerte que CRC-32 por archivo (p. ej. un tag `BLAKE2B`)? A decidir.
- Enlaces duros, ACL, atributos extendidos: tags futuros.

## 6. Modo compatible: escribir `.arc`

`parc a -fmt=arc` (o una salida con extensión `.arc`) escribe un `.arc` que FreeArc 0.67 y
Unarc pueden leer: firma `ArC\x01`, versión 0.67, sin campos opcionales (solo
`tag_end = 0`) y solo métodos que existen en FreeArc 0.67. Se pierde lo que `.arc` no
puede guardar (fechas de 64 bits, atributos), igual que con FreeArc.

Además de servir para interoperar, es la herramienta de validación del escritor: todo lo
que PArc escribe en modo `.arc` tiene que pasar `arc.exe t` y `unarc t`.
