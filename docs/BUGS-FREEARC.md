# Bugs y limitaciones de FreeArc 0.67, y qué hace PArc con cada uno

> Las rutas de FreeArc que aparecen en este documento (`Compression/...`, `Unarc/...`,
> `Arc.hs`, ...) son relativas a `reference/freearc-0.67/`. En el repo sólo se conserva
> `Compression/` (referencia de códecs y oráculo de los tests); el resto del fuente de
> FreeArc 0.67 (Haskell, `Unarc/`, `ArcShellExt/`, `Documentation/`) está en el historial
> de git (commit `82ea8d9`) y en la distribución original de FreeArc.

Inventario armado el 2026-10-08 a partir de cuatro fuentes:

- **código**: comentarios TODO/bug del código original de FreeArc (raíz del repo, `Compression/`, `Unarc/`);
- **docs**: `Documentation/History.txt` (su "To-do list" y las listas de errores abiertos; el changelog termina en 0.51) y los readme de cada compresor;
- **tracker**: el bug tracker oficial en Google Code Archive (`code.google.com/archive/p/freearc/issues/N`, citado como #N); encode.su no cargó (Cloudflare);
- **prueba**: reproducido a mano contra PArc (`build/linux64/parc`) en `/mnt/IA_LAB/agentes/PArc/bugs/`.

Severidad: **alta** = pérdida o corrupción de datos, o cuelgue; **media** = falla o limitación molesta; **baja** = detalle.

Estado en PArc: ✅ ya lo corrige · ⚠️ lo hereda · 🐞 bug propio de PArc · ➖ no aplica (función que PArc no tiene) · ❓ sin verificar.

## 1. Bugs propios de PArc encontrados en esta revisión — ✅ corregidos

Corregidos el 2026-10-08 como se propone abajo; verificados en Linux, Windows 10 (x64 y x86) y Windows 7 x86. Prueba: `tests/fixes.sh`. Sintaxis en `docs/USO.md` (máscaras, `-r`, `-snld`, código 6).

| # | problema | sev. | evidencia | propuesta |
|---|---|---|---|---|
| P1 | **Las máscaras no se expanden.** `parc a x.parc *.txt` en Windows falla ("no existe: *.txt"): `cmd.exe` no expande comodines y PArc tampoco. En Linux funciona solo porque lo expande el shell; `'*.txt'` entre comillas falla. FreeArc sí las expandía. | **alta** (en Windows) | prueba; `parc.lpr` no tiene expansión | expandir `*` y `?` en los argumentos de `a/u/f` (y en `-x`), con recursión como FreeArc |
| P2 | **Un archivo ilegible aborta toda la actualización** (`Permission denied`, archivo bloqueado por otro programa). No se pierde nada (el archivo viejo queda intacto), pero un backup entero falla por un solo archivo. FreeArc #389 tenía el problema opuesto: el archivo desaparecía del archivo comprimido. | media | prueba (exit 4) | avisar, conservar la versión vieja de ese archivo si existe, seguir con el resto y terminar con código 1 o 2 (como 7-Zip) |
| P3 | **Symlinks incoherentes.** Un enlace a archivo se guarda con el contenido del destino; un enlace a directorio queda como directorio vacío. El enlace en sí nunca se guarda. (FreeArc los seguía y podía entrar en bucle, #211/#162; PArc no entra en bucle.) | media | prueba | en `.parc`: guardar el enlace como enlace (Unix y junctions/symlinks de Windows); en `.arc`: no seguirlos y avisar |

### Corregidos el 2026-10-20 (fuzz de actualización)

| # | problema | sev. | evidencia | arreglo |
|---|---|---|---|---|
| P4 | **`d` con `-m` explícito no recompilaba.** `parc d x.arc f -m1` copiaba los bloques viejos; `arc.exe` los rehace todos con ese método (`is_COPYING_COMMAND` → `--recompress` en `Cmdline.hs:433`). | media | `tests/fuzz_update.py`; `tests/update_matrix.sh` caso `delm` | `MethodGiven` en `TModifyOptions`; `PlanUpdate` recibe `Recompress` |
| P5 | **Actualizar con otro `-s` partía los bloques viejos.** Con `a/u/f` y un criterio distinto del que armó el archivo, PArc rehacía todo bloque por bloque; `arc.exe` conserva los bloques viejos enteros (`computeLen`: `oldLen`/`oldPos`/`minLen`) cuando el criterio es explícito (`-s-`, `-s1f`, `-s100k`…). Con "todo junto" (sin `-s`, `-s` o `-s7z`) sí rehace un bloque por grupo. | media | `tests/fuzz_update.py` seed 1 it=10; `tests/update_matrix.sh` caso `solidkeep` | `SolidBlockLen`, `CritLenMin`/`CritLenMax` y la regla de `computeLen` en `SplitOneType` |
| P6 | **Método guardado no canónico.** `parc a x.arc … -m4x4` guardaba `4x4` en vez de `4x4:tor:3:<tamaño>` (FreeArc imprime el método interno y el `:b` con `ShowCompressionMethod`), y `-mtor:16` quedaba como `tor:9:…` porque `parc_canon` sólo conocía los presets 0–9 de Tornado. | baja (los archivos se leen igual) | `tests/canon_methods.sh`; `tests/fuzz_update.py` seed 2 it=3 | tablas de Tornado 0–16; 4x4 clasifica sus parámetros como `parse_4x4` y usa el interno por defecto `tor:3:1mb` |

`tests/fuzz_update.py --iters 40 --seed N` compara secuencias aleatorias de `a/u/f/d` contra
`arc.exe` (estructura, métodos, `arc.exe t` y árbol extraído). También encontró que
`rep+tor:16` hace caer al *codificador* de FreeArc (#392) mientras PArc lo comprime y `arc.exe`
lo lee bien.

## 2. Lo que FreeArc tiene mal y PArc ya corrige ✅

| problema de FreeArc | fuente | sev. | en PArc |
|---|---|---|---|
| Cancelar una actualización deja un archivo a medio hacer en lugar del original | docs :444 | alta | escribe a un temporal y lo renombra al final; verificado con Ctrl-C |
| Rutas de más de 260 caracteres: omite archivos sin avisar, y con `-d` los borra igual | tracker #97, #273; docs :408 | alta | prefijo `\\?\` con la longitud absoluta (`parc_os.pas`) |
| Rutas UNC | docs :929 | media | `FsPath` |
| LZ4 de 2012 con CVE-2014-4611 | código LZ4/lz4.c | alta | decodificador con los chequeos de LZ4 1.10 |
| GetHeadsHt4 no es seguro en 64 bits | LZMA2/readme:19 | alta | ht4 se mapea a hc4 |
| PPMd, GRZip, TTA y REP mal en 64 bits ("require 64-bit fix", "rep:3g doesn't work") | código fazip.cpp:15 | alta | PPMd emula el layout de 32 bits; REP rechaza > 2 GB−1; todo verificado en x64 |
| Fechas: > 2038 se recortan, < 1970 pasan a 2038, horario de verano corre una hora (#251, #317) | código FileInfo.hs:151, Common.cpp:528 | media | `.parc` guarda ns en Int64 UTC; en `.arc` Int32 con signo, sin la regla "negativo → 2038" |
| No guarda atributos de Windows ni permisos de Unix (#133, #233) | código ArhiveDirectory.hs:169 | media | `.parc` los guarda y restaura (en `.arc` no caben) |
| Tamaños de memoria de 32 bits: `-md`/`-lc` > 4 GB se truncan en silencio | código CompressionLib.hs:363 | media | `ParseMem` en 64 bits |
| Sin RNG del sistema en Windows (salt e IV de handles y cursor) | código Environment.cpp:666 | media | RtlGenRandom |
| Solo i386 en Linux, sin build de 64 bits (#211, AUR) | tracker | media | Linux x64 nativo |
| Crear un SFX borra el `.arc` original (#238) | tracker | media | `-sfx` crea `x.exe` y conserva el contenido; probado |
| SFX limitado a MAX_PATH | código Unarc/gui/gui.h:11 | media | `parcsfx` usa las mismas rutas largas que `parc` |
| Fragmentación de memoria y "can't allocate memory" en 32 bits (#72, #167, #359) | tracker | media | en x64 no aplica; en x86 sigue el límite de 2 GB del proceso |
| Al fallar el CRC el archivo extraído queda truncado | docs :385 | media | se escribe completo, se informa el error y sale con código 2; probado |
| `arc a a.log new.arc` (argumentos invertidos) borra `a.log` | docs :387 | alta | rechaza ("no es un archivo FreeArc") y no toca `a.log`; probado |
| `a .` / `a ..` crea entradas raras (#215) | tracker | media | rutas relativas limpias; probado |
| Nombres no UTF-8 en Linux abortan ("fromUTF: illegal UTF-8", #211) | tracker | alta | se archivan y se extraen igual; probado |
| Stack overflow con miles de archivos o archivos enormes (#253, #269) | tracker | alta | un archivo de 4,7 GB se comprime y extrae idéntico (21 s / 10 s con `-m1`); con millones de archivos, sin medir |
| Directorios vacíos | docs :664; tracker #105 | media | se guardan y se crean; probado |
| Actualizar recomprime bloques sólidos enteros aunque no cambien | prueba con arc.exe | baja | igual que arc.exe a propósito (paridad); se puede mejorar en `.parc` |

## 3. Heredado por compatibilidad con `.arc` ⚠️ — se puede corregir solo en `.parc`

Cifrado: ✅ corregido en `.parc` el 2026-10-08 (`:f`, `:m`, 200 000 iteraciones; `tests/parc_crypt.sh`). Recuperación: ✅ Reed-Solomon en `.parc` (`parc-rs1`, `tests/rs_recovery.sh`). El `.arc` sigue con los esquemas de FreeArc.

El `.parc` es formato propio: estas cosas se pueden arreglar ahí sin romper la lectura ni la escritura de `.arc`.

| problema | fuente | sev. | propuesta para `.parc` |
|---|---|---|---|
| **Clave e IV mal decodificados** (`buggy_char2int`: 'a'..'f' → 0..5; cada nibble toma 10 valores en vez de 16; AES-256 baja a ~212 bits) | código Common.cpp:292; Encryption.hs:40 lo dejaba para 0.75 | media | escribir siempre `:f` (decodificación correcta) en `.parc` |
| **PBKDF2 con 1000 iteraciones** (hoy también en `.parc`) | código C_Encryption.cpp:280; docs :958 | media | 200 000 o más en `.parc`, o calibrar a ~0,1 s como planeaba el autor |
| **Sin autenticación (MAC)**: solo CRC; check-code de 2 bytes (1 de 65 536 contraseñas malas "pasa" y da basura) | docs :453; código Encryption.hs:38 | media | AES-GCM o HMAC sobre datos y cabeceras en `.parc` |
| **Recuperación por XOR**: dos sectores dañados del mismo grupo son irrecuperables aunque el `-rr` alcance; el registro tiene que caber en RAM | código ArcRecover.hs:43, Options.hs:156 | media | Reed-Solomon en `.parc` (estaba en el plan 2.0 de FreeArc) |
| Contraseñas no ASCII sin `:f` | código Encryption.hs:85 | media | ✅ compatibles con arc.exe (`tests/crypt_write.sh`); con `:f` en `.parc` irían en UTF-8 |

## 4. Limitaciones y funciones que FreeArc nunca hizo

| función | fuente | ¿vale la pena en PArc? |
|---|---|---|
| Symlinks, junctions, dueño/grupo, ACL, streams NTFS | docs :961-965, :1154; tracker #290 | symlinks sí (ver P3); ACL y streams, quizá en `.parc` |
| Leer/escribir archivos por stdin/stdout | código Files.hs:565; tracker #149, #157 | ✅ hecho: `-si`, `-so` y `-` (2026-10-08) |
| Extraer salteando un bloque sólido roto; recuperar sectores no consecutivos | docs :970-973, :1075 | ✅ los demás bloques se extraen y se informa cada archivo perdido; dentro de un bloque 4x4, los trozos sanos se extraen (PA-Lab); Reed-Solomon en `.parc` |
| `-n`: extraer solo lo nuevo o modificado; renombrar dentro del archivo; backup incremental | docs :487, :514, :376 | baja prioridad |
| Archivos con millones de entradas (memoria) | docs :977; tracker #287 | ❓ medir |
| Deduplicar archivos idénticos | tracker #303 | quizá (rep ya lo hace en parte) |
| Volúmenes | docs :1030; plan 0.80 | ✅ hecho, solo `.parc` |
| Comprimir bloques sólidos en paralelo | docs :727 | ya hay 4x4 y el match finder MT de LZMA |
| Temporales > 4 GB en FAT32; extraer > 4 GB a FAT32 se cuelga (#168) | docs :513; tracker | ❓ PArc no usa temporales entre métodos; verificar el error de disco lleno |
| Máscaras con expresiones (`r[0-9]`) | código Utils.hs:1123 | baja |

## 5. No aplica a PArc ➖

Compresores externos (precomp, srep, pmm/ppmonstr) y sus fallas (#380, #321, #381, #358, docs :429); archivos 7z/zip/rar vía 7z.dll (#368, docs :550, :573); `tempfile` entre métodos (docs :368-370); unarc.dll y su callback (#353); integración con Explorer y asociaciones (#372, #278, #300).
Para la GUI, cuando llegue, conviene recordar dos de la GUI vieja: borrar una carpeta seguía los symlinks y borraba el destino (código Files.hs:416, **alta**), y lo editado al abrir un archivo desde la GUI se perdía (FileManager.hs:430).

## 6. Verificado el 2026-10-08 (pruebas de PA-Lab; arreglos de PArc)

| caso | resultado |
|---|---|
| Archivo de 4,7 GB | se comprime y extrae idéntico (21 s / 10 s con `-m1`) |
| Disco lleno al comprimir | error claro, código 4, no cuelga ni deja temporal |
| Disco lleno al extraer | **corregido**: antes quedaba el archivo truncado; ahora se borra y el error dice cuál (`¿disco lleno o sin permiso?`) |
| Archivo de más de 4 GB a FAT32 | no se cuelga (FreeArc sí, #168). **Corregido**: antes escribía 4 GB y fallaba; ahora se avisa antes, se saltea ese archivo y se extrae el resto (Linux y Windows) |
| 1 millón de archivos chicos | `a`, `l` y `x` sin errores; pico de memoria ~480 MB al comprimir, ~185 MB al listar y extraer |
| Carpeta protegida por UAC sin ser administrador | no concluyente: la única cuenta de la VM es administradora |

Pendiente: reportes de FreeArc sin patrón (#349 corrupción al cambiar varias veces el modo sólido, #257 `rep` solo, #392 `rep+tor:16`), candidatos para un fuzz de actualización.
