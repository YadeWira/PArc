# Estado de PArc (2026-10-20)

PArc es un archivador en **Free Pascal** con formato propio **`.parc`**, para Windows 7+
(x86/x64) y Linux x64. No lee ni escribe `.arc` y no tiene GUI: el soporte de `.arc` y de los
contenedores (`.zip`/`.7z`/`.rar`) está en [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

## Layout

```
src/                     fuentes Pascal
docs/                    manual (USO.md), formato (formato/FORMATO-PARC.md), códecs
tests/                   pruebas, oráculos de códecs y fuzzers
reference/freearc-0.67/  sólo Compression/: fuente C de los códecs y oráculo de tests
```

El resto del árbol de FreeArc 0.67 está en el historial de git (commit `82ea8d9`) y en
FreeArc-ex.

## Fases

| fase | estado |
|---|---|
| Bugs de FreeArc/PArc | ✅ cerrada (los arreglos de paridad `.arc` quedaron como historia; ver tag `entrega-arc`) |
| Códecs portados | ✅ cerrada (LZMA, LZ4, PPMd, Tornado, REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip, BCJ, DisPack, SREP) |
| Compatibilidad `.arc` | ❌ descartada: se rechaza con un mensaje que apunta a FreeArc-ex |
| GUI | ❌ descartada |
| Contenedores `.zip/.7z/.rar` | ➡ movidos a FreeArc-ex (tag `entrega-arc`) |
| SFX (creación) | ❌ descartada: no se compila `parcsfx` ni existe `-sfx`; los SFX viejos se leen/extraen y al actualizarlos se conserva su módulo |
| Rendimiento vs FreeArc 0.67.1 | ✅ PArc gana en tamaño en `-m1`…`-mx` sobre los corpus de prueba (ver abajo) |

## Qué hace hoy

- Formato `.parc`: fechas en nanosegundos, atributos de Windows, permisos y enlaces de Unix,
  registro Reed-Solomon (`-rr`), volúmenes (`-v`), cifrado autenticado (`-p`/`-hp`),
  stdin/stdout (`-si`, `-so`, `-`), rutas largas y cancelación sin dejar parciales.
- Los autoextraíbles existentes se listan, verifican y extraen; ya no se crean.
- Comandos: `l`, `lb`, `t`, `x`, `e`, `a`, `u`, `f`, `d`, `r`.
- Métodos: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070` y `srep`, solos o en cadena.
- Presets internos de FreeArc portados: `-m0`…`-m9`, `-mx` y las familias `d/t/xt/xb/binary/rep`.

## Rendimiento vs FreeArc 0.67.1

Objetivo: que `-m1`…`-m9`/`-mx` produzcan archivos **más chicos** que FreeArc 0.67.1 con los
presets internos (`arc.exe -cfg-`), sin comparar contenedores ni compatibilidad.

Medición con `tests/bench_vs_freearc.sh` sobre seis corpus (12–44 MB): texto C (/usr/include),
fuente Python, documentación HTML, binarios `.so`, mixto y el corpus heterogéneo de pruebas.
En los seis, PArc gana en **todos** los niveles. Resumen del delta de tamaño total (PArc −
FreeArc; negativo = PArc más chico):

| nivel | texto | binarios | mixto |
|---|---|---|---|
| `-m1` | −13 % a −16 % | −10,2 % | −9,7 % |
| `-m2` | −2,4 % a −5,2 % | −1,5 % | −1,4 % |
| `-m3` | −1,8 % a −7,2 % | −0,3 % | −0,6 % |
| `-m4` | −2,4 % a −7,5 % | −1,0 % | −1,1 % |
| `-m5` | −0,5 % a −0,7 % | −0,2 % | −0,25 % |
| `-m6`…`-mx` | −0,3 % a −0,9 % | −0,24 % | −0,31 % |

Cambios que lo hacen posible (todos dentro de `.parc`; los códecs siguen siendo los mismos):

- **LZMA `fast`**: se portaron los agregados de FreeArc a `GetOptimumFast` (poda del match
  principal por longitud/distancia y aceptación relajada de rep-matches). Antes `-m3` perdía
  0,8 % en binarios; ahora gana.
- **Presets más fuertes** que los de FreeArc en el mismo nivel: `-m1` usa Tornado con ventana
  de 16 MB en vez de 8 MB; `-m2`, ventana de 64 MB; `-m4`, `fb=32`; `-m5`, PPMd 12/192 MB; y
  el grupo de texto de `-m6`+ usa `dict:m800:s250:75%`, LZP al 90 % y PPMd 16/384 MB.
- **Directorio**: el mtime en ns se guarda como delta zigzag VInt (tag 7), sin perder
  precisión. Ahorra ~2 KB por cada 1.300 archivos y deja el sobrecosto de metadatos de PArc
  (fechas ns + modo Unix, que FreeArc no guarda) en unos 2,5–7 KB por cada 1.000–2.500 archivos.
- El registro de recuperación es sólo Reed-Solomon; el XOR de `.arc` ya no existe.

Contrapartida: algunos niveles son más lentos que FreeArc (por ejemplo `-m1` ~1,5× y `-m5`
~1,4× en el corpus mixto), a cambio de archivos más chicos. Los tiempos están en el script
de benchmark.

## Pruebas

```sh
./build.sh linux64
bash tests/stdio.sh tests/volumes.sh
bash tests/rs_recovery.sh tests/parc_crypt.sh
bash tests/dispack.sh tests/srep.sh tests/bcj.sh
bash tests/run_tornado_tests.sh tests/crypto_vectors.sh
bash tests/run_lzma_tests.py build/tests/test_lzma
sudo bash tests/fixes.sh          # máscaras, enlaces, disco lleno, FAT32
python3 tests/fuzz.py build/linux64/parc 100 build/linux64/parc
```

## Limitaciones conocidas

- `.arc` no se lee ni se escribe (por diseño; usar FreeArc-ex).
- SREP: se lee v1–v4 y se escribe v3; no se interpretan las opciones del método al comprimir
  (`-m0o`, `-m3f`, etc.) y el ratio es greedy (lazy matching, 4 candidatos por hash).
- Compresores externos de FreeArc (precomp, ECM, JPG, PPMonstr, Durilca, CCM, etc.): fuera de
  alcance.
- `reference/` conserva sólo `Compression/`; el resto del fuente está en el historial.

## Próximos pasos posibles

1. SREP: respetar opciones al comprimir y escribir v4/Index-LZ (opcional).
2. Fuzz específico de `.parc` (actualizaciones y daño) y pruebas de volumen/cifrado en la suite.
3. Ideas de formato v2 (hash más fuerte por archivo, ACL/xattrs).
