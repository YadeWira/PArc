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

## Qué hace hoy

- Formato `.parc`: fechas en nanosegundos, atributos de Windows, permisos y enlaces de Unix,
  registro Reed-Solomon (`-rr`), volúmenes (`-v`), cifrado autenticado (`-p`/`-hp`), SFX
  (`-sfx`), stdin/stdout (`-si`, `-so`, `-`), rutas largas y cancelación sin dejar parciales.
- Comandos: `l`, `lb`, `t`, `x`, `e`, `a`, `u`, `f`, `d`, `r`.
- Métodos: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070` y `srep`, solos o en cadena.
- Presets internos de FreeArc portados: `-m0`…`-m9`, `-mx` y las familias `d/t/xt/xb/binary/rep`.

## Pruebas

```sh
./build.sh linux64
bash tests/stdio.sh tests/volumes.sh tests/sfx.sh
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
