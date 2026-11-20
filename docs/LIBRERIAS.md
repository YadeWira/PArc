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
| LZ4 (`Compression/LZ4`) | 2011-2012 | 1.11.1 (BSD-2) | Since 2026-11 the `lz4` stream is a standard LZ4 Frame (readable by the `lz4` tool), no longer FreeArc's framing. 1.11 adds the "position after the previous ip-1" candidate to the fast compressor (0.2-2% smaller, same speed); HC level 9 is unchanged |
| PPMd (D. Shkarin, modified by FreeArc) | var. H/I | LZMA SDK `Ppmd8` (var.I rev.1, public domain) | Since 2026-11 `ppmd` is a new port of the LZMA SDK's PPMd8 (no FreeArc code; streams are not compatible with the old ones). Bit-identical to the SDK's C; same ratio as FreeArc's var.I with restart |
| SREP | 3.93 beta (2013) | 3.93a beta (2014-10-11) | freeware by Bulat Ziganshin; v1–v4 format |
| REP, 4x4, Dict, LZP, Delta, MM/TTA, GRZip, DisPack | 0.67 | no maintained upstream | Ported from `Compression/`; that code defines the stream |
| Tornado | 0.67 | — | **Removed** after 0.0.5 (Pascal port of encoder and decoder, plus FreeArc's C++ encoder that `build.sh` compiled for `tor:10`/`tor:15`): replaced by the own `plz`. PArc no longer needs a C/C++ compiler; `tor` blocks of older archives no longer decode |
| Context mixing `cm` | lpaq1 (2007) | lpaq1 model | GPLv2; ported to Pascal and wrapped as a block codec. Used by `-mxx`; much slower than LZMA/PPMd |

## Status in PArc

| Component | Ported from | Verification |
|---|---|---|
| LZMA (decompression) | reference specification (LzmaSpec) | streams generated with Python and the SDK; `tests/run_lzma_tests.py` |
| LZMA (compression) | LZMA SDK 26.03 + FreeArc's `fast` additions | valid streams verified with liblzma (`tests/run_lzma_tests.py`) and round-trip in `.parc` |
| x86 BCJ (`exe`) | LZMA SDK 26.03 | against compiled `Bra86.c`, with buffer splits (`tests/bcj.sh`) |
| LZ4 (decompression) | LZ4 Frame spec + block semantics of `LZ4_decompress_safe` (own code); linked blocks, block/content checksums and content size are read | `tests/lz4frame.sh`: PArc ↔ `lz4` tool both ways, damaged and cut frames |
| LZ4 (compression) | LZ4 1.11.1 (`LZ4_compress_default` and `LZ4_compress_HC` level 9), BSD-2 notice kept in `parc_lz4enc.pas`; frame with independent blocks, no checksums | block bytes identical to LZ4 1.11.1 in C (`LZ4_LIB_DIR=... tests/lz4frame.sh`) |
| Encryption: BLAKE2b, Argon2id/d/i (`parc_blake2`), ChaCha20, HChaCha20, Poly1305, (X)ChaCha20-Poly1305 (`parc_chacha`), AES-256 and GCM (`parc_aes`), scheme (`parc_crypt`) | own code from RFC 7693, RFC 9106, RFC 8439, draft-irtf-cfrg-xchacha-03, FIPS 197, NIST SP 800-38D (nothing from FreeArc or LibTomCrypt); x86-64 assembler for AVX2 ChaCha20 (stitched with Poly1305), Poly1305 (64-bit MUL), AES-NI and PCLMULQDQ, with Pascal fallbacks giving the same output | `tests/crypto_vectors.sh`: official vectors, NIST CAVP AES-256-GCM (750 cases), thousands of random cases against python-cryptography/OpenSSL, PyNaCl/libsodium and `openssl kdf` (Argon2), each with the asm path, without AVX2/AES-NI and with `-dPARC_NOASM`; a `.parc` block decrypted by an independent Python implementation of the format |
| PPMd (`ppmd`) | LZMA SDK `Ppmd8.c`/`Ppmd8Enc.c`/`Ppmd8Dec.c` (Igor Pavlov, public domain, after D. Shkarin's PPMd var.I) | `tests/ppmd.sh`: round-trips (orders 2–64, 2 KB–32 MB, restart and cut-off, empty/tiny/random inputs), damaged streams, and streams byte-for-byte against the SDK in C when `$PPMD_SDK` is available; `tests/ppmd_asm.sh`: x86-64 assembler == Pascal |
| `plz` (own LZ codec; replaced Tornado in the presets) | own code (LZ77 with repeated offsets, canonical Huffman; nothing from Tornado or FreeArc) | `tests/plz.sh`: round trips at every level and window, streaming = memory = random write sizes, x86-64 assembler == `-dPARC_NOASM`, 2,000 damaged streams per run (clean error, never a crash or hang; also under valgrind); `tests/plz_cross.sh`: identical bytes on linux64, linux32, linuxarm64 (QEMU), win64 and win32 (Wine) |
| REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip | FreeArc 0.67 | `tests/mm_tta`, `tests/grzip.sh` and `.parc` round-trips; GRZip raises LZP to l64/h22 adaptively for BWT blocks >=4 MB |
| DisPack (`dispack070`) | `Compression/DisPack` (0.70) | `tests/dispack.sh`: filter byte-for-byte against C and `.parc` round-trip |
| SREP (`srep`), decoder | `Compression/SREP/srep.cpp` (3.93 beta) + 3.93a | `tests/srep.sh`: v1–v4 streams (text, repeats, random, >8 MB), synthetic `BASE_LEN=0` cases and lengths that wrap 32 bits; optional interoperability with 3.93a |
| SREP (`srep`), encoder | `Compression/SREP/srep.cpp` (v3 format) | `tests/srep.sh`: streams decoded by reference srep; greedy LZ77 (≥512, lazy matching, 4 hash candidates), `BASE_LEN=0` like 3.93a |
| BCJ2-style filter (`bcj2`) | own implementation (4 streams: main, CALL/JMP, Jcc, service bits) | `tests/bcj2.sh`: round-trip on synthetic x86 markers, random bytes and empty input. **Experimental**: not used by presets yet; compared with 7-Zip BCJ2 on binaries |
| Context mixing (`cm`) | lpaq1 by Matt Mahoney (GPLv2) | `tests/cm.sh`: round-trip of text/binary/empty data, `-mxx` ratio vs `-m9`, `-mx` fast path, damaged stream (code 2) and encrypted archives |

Until 0.0.3 PArc used FreeArc's encryption (LibTomCrypt AES/Blowfish/Serpent/Twofish in CTR/CFB
with PBKDF2-HMAC-SHA512 and keys in the method string). It was replaced by the scheme in
`docs/formato/FORMATO-PARC.md` §3b, written from the standards; old encrypted archives are no
longer readable.

## Out of scope

FreeArc external compressors (`precomp`, `ecm`, `jpg`, `ppmonstr`, `durilca`, `ccm`, `rzm`,
etc.) are not ported: they are separate programs and remain out of PArc's scope, as do the
`.zip`/`.7z`/`.rar` containers handled by FreeArc-ex.

The repository's srep does not compile as-is against the current `Common.h`; `tests/srep.sh`
builds a copy with two minimal adjustments to use it as a reference.
