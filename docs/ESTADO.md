# PArc status (2026-10-20)

PArc is an archiver written in **Free Pascal** with its own format, **`.parc`**, for Windows 7+
(x86/x64) and Linux x64. It does not read or write `.arc` and has no GUI: support for `.arc`
and the other containers (`.zip`/`.7z`/`.rar`) lives in
[FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

## Layout

```
src/                     Pascal sources
docs/                    manual (USO.md), format (formato/FORMATO-PARC.md), codecs
tests/                   tests, codec oracles and fuzzers
reference/freearc-0.67/  only Compression/: C codec sources and test oracle
```

The rest of the FreeArc 0.67 tree is in git history (commit `82ea8d9`) and in FreeArc-ex.

## Phases

| phase | status |
|---|---|
| FreeArc/PArc bugs | ✅ closed (the `.arc` parity fixes remain as history; see tag `entrega-arc`) |
| Ported codecs | ✅ closed (LZMA, LZ4, PPMd, Tornado, REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip, BCJ, DisPack, SREP) |
| `.arc` compatibility | ❌ dropped: rejected with a message pointing to FreeArc-ex |
| GUI | ❌ dropped |
| `.zip/.7z/.rar` containers | ➡ moved to FreeArc-ex (tag `entrega-arc`) |
| SFX (creation) | ❌ dropped: `parcsfx` is not built and `-sfx` does not exist; old SFX archives are read/extracted and updating them preserves their stub |
| Performance vs FreeArc 0.67.1 | ✅ PArc wins on size at `-m1`…`-mx`; faster through `-m9`; `-mx` is fast to decode, `-mxx` is the CM maximum (see below) |

## What it does today

- `.parc` format: nanosecond timestamps, Windows attributes, Unix permissions and links,
  Reed-Solomon recovery (`-rr`), volumes (`-v`), authenticated encryption (`-p`/`-hp`),
  stdin/stdout (`-si`, `-so`, `-`), long paths and cancellation without partial files.
- Existing self-extractors can be listed, tested and extracted; no new ones are created.
- Commands: `l`, `lb`, `t`, `x`, `e`, `a`, `u`, `f`, `d`, `r`.
- Methods: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070`, `srep` and `cm` (context mixing), alone or
  chained.
- FreeArc built-in presets ported: `-m0`…`-m9`, `-mx`, `-mxx` and the `d/t/xt/xb/binary/rep` families.

## Performance vs FreeArc 0.67.1

Goal: make `-m1`…`-m9`/`-mx` produce **smaller archives in less time** than FreeArc 0.67.1
with its built-in presets (`arc.exe -cfg-`), without comparing containers or compatibility.

Measured with `tests/bench_vs_freearc.sh` on four corpora (5–43 MB): text, binaries, mixed
and 3,000 small files. Both use 4 threads (`PARC_THREADS=4`, `-mt4`); time is the best of two
runs. PArc wins on size at **every** level on all four. Total-size delta (PArc − FreeArc;
negative = PArc smaller):

| level | text | binaries | mixed | 3,000 small files |
|---|---|---|---|---|
| `-m1` | −14.0% | −10.2% | −9.7% | −17.8% |
| `-m2` | −3.9% | −13.5% | −9.1% | −10.2% |
| `-m3` | −2.9% | −7.4% | −5.0% | −4.8% |
| `-m4` | −4.5% | −2.8% | −2.5% | −5.4% |
| `-m5` | −1.3% | −0.9% | −0.9% | −0.5% |
| `-m6`…`-m9` | −1.0% | −0.2% | −0.3% | −0.3% |
| `-mx` (fast decode) | −1.0% | −0.2% | −0.4% | −0.3% |
| `-mxx` (CM) | −16.1% | −8.2% | −8.2% | −7.5% |

Speed on the 44 MB mixed corpus (wall-clock; FreeArc includes Wine startup):

| level | PArc | FreeArc | | level | PArc | FreeArc |
|---|---|---|---|---|---|---|
| `-m1` | 0.99 s | 1.68 s | | `-m6` | 6.28 s | 10.28 s |
| `-m2` | 1.39 s | 2.44 s | | `-m7` | 6.06 s | 10.32 s |
| `-m3` | 2.93 s | 3.97 s | | `-m8` | 5.80 s | 10.29 s |
| `-m4` | 4.63 s | 6.21 s | | `-m9` | 5.93 s | 10.60 s |
| `-m5` | 4.03 s | 8.60 s | | `-mx` (fast) | 5.62 s | 10.48 s |

`-mx` replaces CM with PPMd/LZMA: it is still smaller than FreeArc `-mx` and decompresses
about 12× faster than the old CM path on the mixed corpus (31 s → 2.5 s). Decompression
of `-mxx` is 5–40× slower than `-mx` depending on the corpus, in exchange for 7.5–16.1%
smaller archives. Size margins at `-m5`/`-m6` are small (0.3–0.9%), so other data may end
up close.

What makes this possible (all inside `.parc`; the codecs are unchanged):

- **Buffered output**: `TStreamSink` accumulates 64 KB before writing. Codecs emitted many
  small pieces (especially PPMd's range coder) and ~14% of the time went into `write`. PPMd on
  20 MB of text dropped from 4.6 s to ~2.7–3.5 s (FreeArc: 2.86 s).
- **LZMA `fast`**: FreeArc's additions to `GetOptimumFast` were ported (main-match pruning by
  length/distance and relaxed rep-match acceptance). `-m3` used to lose 0.8% on binaries; now
  it wins.
- **GRZip adaptive LZP**: BWT blocks of 4 MB or more use `l64/h22` (fewer, longer matches); small blocks keep the fast LZP parameters. The choice is stored in each block's mode, so old decoders remain compatible. This makes `-m4` 1.2–1.4% smaller on text and many small files.
- **Stronger and faster presets** than FreeArc's at the same level:
  `-m1` Tornado with a 16 MB window; `-m2` 64 MB; `-m3` LZMA `fast` with `mc8`; `-m4`/`-m5`
  binaries with `4x4:i0:lzma:8mb:max` (better and faster than `normal:32:mc8/mc32`);
  `-m5` PPMd 12/192 MB; GRZip with a 2^20 hash (`-m2`/`-m3`) and 2^17 (`-m4`); and the text
  group for `-m6`+ with `dict:m800:s250:75%`, 90% LZP and PPMd 16/384 MB.
- **Context mixing (`cm`)**: lpaq1-style model ported to Pascal and used by `-mxx` on text and
  binaries (`-mxx` text: 1.81 MB vs 2.16 MB for FreeArc on the 20 MB corpus; binaries: 5.45 MB
  vs 5.93 MB). It stores incompressible blocks raw, and `-O3` plus hot-loop optimisations
  brought 20 MB text from ~31 s to ~22 s. Independent data blocks are compressed in
  parallel at every level (mixed corpus `-m9`: ~8.8 s -> ~6.3 s; `-m5`: ~7.1 s -> ~4.3 s;
  `-mxx`: ~46 s serial -> ~32 s). `-mx` uses PPMd/LZMA instead, so it compresses and
  decompresses much faster.
- **Verification (`t`)** verifies independent blocks in parallel: mixed corpus ~3.5 s ->
  ~2.5 s at `-m6`, and ~48.5 s -> ~32.6 s at `-mxx`.
- **Extraction (`x`/`e`)** decodes independent blocks in parallel to temp files, then writes
  sequentially: mixed corpus ~3.2 s -> ~2.4 s at `-m6`, and ~48.4 s -> ~33.2 s at `-mxx`.
  `-mx` verifies/extracts in ~2.5 s on the same corpus.
- **Directory**: mtime in ns is stored as zigzag VInt deltas (tag 7), losslessly. Saves ~2 KB
  per 1,300 files.
- Recovery is Reed-Solomon only; the `.arc` XOR scheme is gone.

## Verified platforms (0.0.1)

| platform | binary | tests |
|---|---|---|
| Linux x64 | `parc` | full suite: CLI, stdio, volumes, RS, encryption, DisPack, SREP, BCJ, Tornado, crypto vectors, fixes, LZMA and fuzz |
| Windows 10 x64 | win64 | `a/l/t/x`, `u/f/d`, `-p`, `-rr`, `-v`, UTF-8 names and an archive created on Linux |
| Windows 10 x64 (WOW64) | win32 | same basic tests and a cross-checked archive on Linux |
| Windows 7 SP1 x64 | win32 and win64 | create/test/extract, encryption and Linux ↔ Windows cross-check |
| Linux ↔ Windows | both | `.parc` round-trip compared byte by byte with `diff` |
| Windows (final presets) | win32/win64 | Wine 10.0 smoke: `-m2`, `-m3`, `-mx`, `-mxx`, create/test/extract and `diff` |

SREP with the 32-bit binary was verified under Wine and with an archive cross-checked on Linux
(the rest of the Windows tests ran in the real VMs).

## Tests

```sh
./build.sh linux64
bash tests/cli.sh
bash tests/stdio.sh tests/volumes.sh
bash tests/rs_recovery.sh tests/parc_crypt.sh tests/cm.sh tests/grzip.sh tests/bcj2.sh
bash tests/dispack.sh tests/srep.sh tests/bcj.sh
bash tests/run_tornado_tests.sh tests/crypto_vectors.sh
bash tests/run_lzma_tests.py build/tests/test_lzma
sudo bash tests/fixes.sh          # patterns, links, full disk, FAT32
python3 tests/fuzz.py build/linux64/parc 100 build/linux64/parc
```

## Known limitations

- `.arc` is neither read nor written (by design; use FreeArc-ex).
- SREP: reads v1–v4 and writes v3; method options are not interpreted when compressing
  (`-m0o`, `-m3f`, etc.) and the ratio is greedy (lazy matching, 4 candidates per hash).
- FreeArc external compressors (precomp, ECM, JPG, PPMonstr, Durilca, CCM, etc.): out of
  scope.
- `reference/` keeps only `Compression/`; the rest of the source is in git history.

## Possible next steps

1. SREP: honor compression options and write v4/Index-LZ (optional).
2. `.parc`-specific fuzzing (updates and damage) plus volume/encryption tests in the suite.
3. Ideas for format v2 (stronger per-file hash, ACLs/xattrs).
