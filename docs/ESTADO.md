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
| Rendimiento vs FreeArc 0.67.1 | ✅ PArc gana en tamaño y velocidad en `-m1`…`-mx` sobre los corpus de prueba (ver abajo) |

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

Objetivo: que `-m1`…`-m9`/`-mx` produzcan archivos **más chicos y en menos tiempo** que
FreeArc 0.67.1 con sus presets internos (`arc.exe -cfg-`), sin comparar contenedores ni
compatibilidad.

Medición con `tests/bench_vs_freearc.sh` sobre siete corpus (5–44 MB): cabeceras C
(`/usr/include`), fuente Python, documentación HTML, binarios `.so`, mixto, el corpus
heterogéneo de pruebas y 3.000 archivos chicos (5 MB). En los siete, PArc gana en tamaño
en **todos** los niveles. Delta de tamaño total (PArc − FreeArc; negativo = PArc más chico):

| nivel | texto | binarios | mixto | 3.000 chicos |
|---|---|---|---|---|
| `-m1` | −13,1 % a −16,2 % | −10,2 % | −9,7 % | −17,8 % |
| `-m2` | −3,0 % a −6,1 % | −1,5 % | −1,6 % | −9,7 % |
| `-m3` | −2,2 % a −7,7 % | −1,2 % | −1,2 % | −4,6 % |
| `-m4` | −3,4 % a −8,0 % | −2,8 % | −2,3 % | −4,2 % |
| `-m5` | −0,6 % a −1,3 % | −0,9 % | −0,6 % | −0,5 % |
| `-m6`…`-mx` | −0,3 % a −0,7 % | −0,2 % | −0,3 % | −0,3 % |

Velocidad (tiempo de pared; el de FreeArc incluye el arranque de Wine). En el corpus mixto
de 44 MB:

| nivel | PArc | FreeArc | | nivel | PArc | FreeArc |
|---|---|---|---|---|---|---|
| `-m1` | 1,17 s | 2,03 s | | `-m6` | 9,40 s | 10,84 s |
| `-m2` | 1,96 s | 2,81 s | | `-m7` | 9,21 s | 10,75 s |
| `-m3` | 3,42 s | 4,16 s | | `-m8` | 9,30 s | 11,00 s |
| `-m4` | 4,93 s | 6,41 s | | `-m9` | 8,99 s | 10,81 s |
| `-m5` | 7,07 s | 8,74 s | | `-mx` | 8,95 s | 11,02 s |

En los siete corpus PArc también es más rápido en todos los niveles; las diferencias de
pocos por ciento están en el orden del ruido de una corrida. El margen de tamaño en `-m5` y
`-m6` sobre el corpus heterogéneo es chico (0,04–0,14 %), así que en datos muy distintos
puede quedar cerca.

Cambios que lo hacen posible (todos dentro de `.parc`; los códecs son los mismos):

- **Salida con buffer**: `TStreamSink` junta 64 KB antes de escribir. Los codecs emitían
  muchos pedazos chicos (sobre todo el range-coder de PPMd) y ~14 % del tiempo se iba en
  `write`. PPMd sobre 20 MB de texto pasó de 4,6 s a ~2,7–3,5 s (FreeArc: 2,86 s).
- **LZMA `fast`**: se portaron los agregados de FreeArc a `GetOptimumFast` (poda del match
  principal por longitud/distancia y aceptación relajada de rep-matches). Antes `-m3` perdía
  0,8 % en binarios; ahora gana.
- **Presets más fuertes y más rápidos** que los de FreeArc en el mismo nivel:
  `-m1` Tornado con ventana de 16 MB; `-m2` 64 MB; `-m3` LZMA `fast` con `mc8`; `-m4`/`-m5`
  binarios con `4x4:i0:lzma:8mb:max` (mejor y más rápido que `normal:32:mc8/mc32`);
  `-m5` PPMd 12/192 MB; GRZip con hash 2^20 (`-m2`/`-m3`) y 2^17 (`-m4`); y el grupo de
  texto de `-m6`+ con `dict:m800:s250:75%`, LZP al 90 % y PPMd 16/384 MB.
- **Directorio**: el mtime en ns se guarda como delta zigzag VInt (tag 7), sin perder
  precisión. Ahorra ~2 KB por cada 1.300 archivos.
- El registro de recuperación es sólo Reed-Solomon; el XOR de `.arc` ya no existe.

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
