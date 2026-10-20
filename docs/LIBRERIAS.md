# Códecs de FreeArc 0.67 portados a PArc

PArc no enlaza bibliotecas de terceros: los compresores y cifrados están portados a Pascal.
Este documento releva de dónde sale cada uno, contra qué se verificó y qué queda pendiente.

> Las rutas `Compression/...` son relativas a `reference/freearc-0.67/`. En el repo sólo se
> conserva `Compression/` (fuente de referencia y oráculo de los tests de códecs). El resto
> del árbol de FreeArc 0.67 está en el historial de git (commit `82ea8d9`) y en el proyecto
> [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

## Versiones de las que se portó

| Componente | En FreeArc 0.67 | Versión portada | Notas |
|---|---|---|---|
| LZMA SDK (`Compression/LZMA2/C`) | 2009-02 | 26.x | El stream LZMA y BCJ x86 no cambian; el encoder nuevo produce bytes válidos, no idénticos. `GetOptimumFast` conserva los agregados de FreeArc (poda por longitud/distancia y rep-matches relajados) |
| LZ4 (`Compression/LZ4`) | 2011-2012 | 1.10.0 | El formato de bloque es estable; la versión vieja tiene CVE-2014-4611 |
| LibTomCrypt (`_Encryption`) | 1.17 | 1.18.2 | AES/Blowfish/Serpent/Twofish/SHA dan la misma salida |
| PPMd (D. Shkarin, modificado por FreeArc) | var. H/I | sin upstream compatible | Se mantiene el port propio (incluido el layout de 32 bits en x64) |
| SREP | 3.93 beta (2013) | 3.93a beta (2014-10-11) | freeware de Bulat Ziganshin; formato v1–v4 |
| Tornado, REP, 4x4, Dict, LZP, Delta, MM/TTA, GRZip, DisPack | 0.67 | sin upstream mantenido | Se portaron desde `Compression/`; el stream lo define ese código |

## Estado en PArc

| Componente | Portado desde | Verificación |
|---|---|---|
| LZMA (descompresión) | especificación de referencia (LzmaSpec) | streams generados con Python y el SDK; `tests/run_lzma_tests.py` |
| LZMA (compresión) | LZMA SDK 26.03 + agregados de FreeArc en `fast` | streams válidos verificados con liblzma (`tests/run_lzma_tests.py`) y roundtrip en `.parc` |
| BCJ x86 (`exe`) | LZMA SDK 26.03 | contra `Bra86.c` compilado, con cortes de buffer (`tests/bcj.sh`) |
| LZ4 (descompresión) | semántica de LZ4 1.10 (`LZ4_decompress_safe`), sin CVE-2014-4611 | streams de referencia |
| LZ4 (compresión) | LZ4 1.10 (`LZ4_compress_default` y `LZ4_compress_HC` nivel 9) | byte a byte contra LZ4 1.10 en C; roundtrip en `.parc` |
| AES, Blowfish, Twofish, SHA-512, PBKDF2 | LibTomCrypt | `tests/crypto_vectors.sh`: 0 diferencias en miles de vectores al azar contra la 1.17 de FreeArc y contra la 1.18.2 oficial |
| Serpent | el agregado de FreeArc sobre LibTomCrypt 1.17 | ídem, contra la 1.17 |
| CTR / CFB | LibTomCrypt (contador little-endian) | ídem |
| PPMd, Tornado, REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip | FreeArc 0.67 | `tests/run_tornado_tests.sh`, `tests/ppmd`, `tests/mm_tta` y roundtrips en `.parc` |
| DisPack (`dispack070`) | `Compression/DisPack` (0.70) | `tests/dispack.sh`: filtro byte a byte contra el C y roundtrip en `.parc` |
| SREP (`srep`), decodificador | `Compression/SREP/srep.cpp` (3.93 beta) + 3.93a | `tests/srep.sh`: streams v1–v4 (texto, repetidos, azar, >8 MB), casos sintéticos de `BASE_LEN=0` y largos con vuelta de 32 bits; interoperabilidad opcional con 3.93a |
| SREP (`srep`), codificador | `Compression/SREP/srep.cpp` (formato v3) | `tests/srep.sh`: streams decodificados por el srep de referencia; LZ77 greedy (≥512, lazy matching, 4 candidatos por hash), `BASE_LEN=0` como 3.93a |

Detalle histórico: LibTomCrypt rechaza claves de Blowfish de menos de 8 bytes (y AES/Twofish
que no sean de 16/24/32); PArc ahora también las rechaza (`CipherKeySizeValid`).

## Fuera de PArc

Los compresores externos de FreeArc (`precomp`, `ecm`, `jpg`, `ppmonstr`, `durilca`, `ccm`,
`rzm`, etc.) no están portados: son programas aparte y quedan fuera del alcance de PArc, igual
que los contenedores `.zip`/`.7z`/`.rar`, que atiende FreeArc-ex.

El srep del repo no compila tal cual contra el `Common.h` actual; `tests/srep.sh` arma una
copia con dos ajustes mínimos para usarlo como referencia.
