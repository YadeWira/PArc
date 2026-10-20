# FreeArc 0.67 codecs ported to PArc

PArc does not link third-party libraries: compressors and ciphers are ported to Pascal. This
document records where each one comes from, what it was verified against, and what remains.

> Paths such as `Compression/...` are relative to `reference/freearc-0.67/`. The repository
> keeps only `Compression/` (reference sources and oracle for codec tests). The rest of the
> FreeArc 0.67 tree is in git history (commit `82ea8d9`) and in the
> [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex) project.

## Versions ported from

| Component | In FreeArc 0.67 | Ported version | Notes |
|---|---|---|---|
| LZMA SDK (`Compression/LZMA2/C`) | 2009-02 | 26.x | The LZMA stream and x86 BCJ do not change; the new encoder produces valid bytes, not identical ones. `GetOptimumFast` keeps FreeArc's additions (length/distance pruning and relaxed rep-matches) |
| LZ4 (`Compression/LZ4`) | 2011-2012 | 1.10.0 | The block format is stable; the old version has CVE-2014-4611 |
| LibTomCrypt (`_Encryption`) | 1.17 | 1.18.2 | AES/Blowfish/Serpent/Twofish/SHA produce the same output |
| PPMd (D. Shkarin, modified by FreeArc) | var. H/I | no compatible upstream | Kept as PArc's own port (including the 32-bit layout on x64) |
| SREP | 3.93 beta (2013) | 3.93a beta (2014-10-11) | freeware by Bulat Ziganshin; v1–v4 format |
| Tornado, REP, 4x4, Dict, LZP, Delta, MM/TTA, GRZip, DisPack | 0.67 | no maintained upstream | Ported from `Compression/`; that code defines the stream |

## Status in PArc

| Component | Ported from | Verification |
|---|---|---|
| LZMA (decompression) | reference specification (LzmaSpec) | streams generated with Python and the SDK; `tests/run_lzma_tests.py` |
| LZMA (compression) | LZMA SDK 26.03 + FreeArc's `fast` additions | valid streams verified with liblzma (`tests/run_lzma_tests.py`) and round-trip in `.parc` |
| x86 BCJ (`exe`) | LZMA SDK 26.03 | against compiled `Bra86.c`, with buffer splits (`tests/bcj.sh`) |
| LZ4 (decompression) | LZ4 1.10 semantics (`LZ4_decompress_safe`), without CVE-2014-4611 | reference streams |
| LZ4 (compression) | LZ4 1.10 (`LZ4_compress_default` and `LZ4_compress_HC` level 9) | byte-for-byte against LZ4 1.10 in C; round-trip in `.parc` |
| AES, Blowfish, Twofish, SHA-512, PBKDF2 | LibTomCrypt | `tests/crypto_vectors.sh`: 0 differences over thousands of random vectors against FreeArc's 1.17 and official 1.18.2 |
| Serpent | FreeArc's addition to LibTomCrypt 1.17 | same, against 1.17 |
| CTR / CFB | LibTomCrypt (little-endian counter) | same |
| PPMd, Tornado, REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip | FreeArc 0.67 | `tests/run_tornado_tests.sh`, `tests/ppmd`, `tests/mm_tta` and `.parc` round-trips |
| DisPack (`dispack070`) | `Compression/DisPack` (0.70) | `tests/dispack.sh`: filter byte-for-byte against C and `.parc` round-trip |
| SREP (`srep`), decoder | `Compression/SREP/srep.cpp` (3.93 beta) + 3.93a | `tests/srep.sh`: v1–v4 streams (text, repeats, random, >8 MB), synthetic `BASE_LEN=0` cases and lengths that wrap 32 bits; optional interoperability with 3.93a |
| SREP (`srep`), encoder | `Compression/SREP/srep.cpp` (v3 format) | `tests/srep.sh`: streams decoded by reference srep; greedy LZ77 (≥512, lazy matching, 4 hash candidates), `BASE_LEN=0` like 3.93a |

Historical note: LibTomCrypt rejects Blowfish keys shorter than 8 bytes (and AES/Twofish keys
that are not 16/24/32 bytes); PArc now rejects them too (`CipherKeySizeValid`).

## Out of scope

FreeArc external compressors (`precomp`, `ecm`, `jpg`, `ppmonstr`, `durilca`, `ccm`, `rzm`,
etc.) are not ported: they are separate programs and remain out of PArc's scope, as do the
`.zip`/`.7z`/`.rar` containers handled by FreeArc-ex.

The repository's srep does not compile as-is against the current `Common.h`; `tests/srep.sh`
builds a copy with two minimal adjustments to use it as a reference.
