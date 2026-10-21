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
| Performance vs FreeArc 0.67.1 | ✅ PArc wins on size at `-m1`…`-mx`; faster through `-m9`, while `-mx` trades speed for ratio (see below) |

## What it does today

- `.parc` format: nanosecond timestamps, Windows attributes, Unix permissions and links,
  Reed-Solomon recovery (`-rr`), volumes (`-v`), authenticated encryption (`-p`/`-hp`),
  stdin/stdout (`-si`, `-so`, `-`), long paths and cancellation without partial files.
- Existing self-extractors can be listed, tested and extracted; no new ones are created.
- Commands: `l`, `lb`, `t`, `x`, `e`, `a`, `u`, `f`, `d`, `r`.
- Methods: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070`, `srep` and `cm` (context mixing), alone or
  chained.
- FreeArc built-in presets ported: `-m0`…`-m9`, `-mx` and the `d/t/xt/xb/binary/rep` families.

## Performance vs FreeArc 0.67.1

Goal: make `-m1`…`-m9`/`-mx` produce **smaller archives in less time** than FreeArc 0.67.1
with its built-in presets (`arc.exe -cfg-`), without comparing containers or compatibility.

Measured with `tests/bench_vs_freearc.sh` on seven corpora (5–44 MB): C headers
(`/usr/include`), Python sources, HTML documentation, `.so` binaries, mixed, the heterogeneous
test corpus and 3,000 small files (5 MB). PArc wins on size at **every** level on all seven.
Total-size delta (PArc − FreeArc; negative = PArc smaller):

| level | text | binaries | mixed | 3,000 small files |
|---|---|---|---|---|
| `-m1` | −13.1% to −16.2% | −10.2% | −9.7% | −17.8% |
| `-m2` | −3.0% to −6.1% | −1.5% | −1.6% | −9.7% |
| `-m3` | −2.2% to −7.7% | −1.2% | −1.2% | −4.6% |
| `-m4` | −3.4% to −8.0% | −2.8% | −2.3% | −4.2% |
| `-m5` | −0.6% to −1.3% | −0.9% | −0.6% | −0.5% |
| `-m6`…`-m9` | −0.3% to −0.7% | −0.2% | −0.3% | −0.3% |
| `-mx` (CM) | −9.2% to −16.1% | −8.2% | −8.2% | −7.5% |

Speed (wall-clock time; FreeArc's includes Wine startup). On the 44 MB mixed corpus:

| level | PArc | FreeArc | | level | PArc | FreeArc |
|---|---|---|---|---|---|---|
| `-m1` | 1.10 s | 1.87 s | | `-m6` | 6.42 s | 10.96 s |
| `-m2` | 1.59 s | 2.74 s | | `-m7` | 6.50 s | 10.80 s |
| `-m3` | 2.68 s | 4.28 s | | `-m8` | 6.19 s | 10.73 s |
| `-m4` | 4.18 s | 6.34 s | | `-m9` | 6.28 s | 10.82 s |
| `-m5` | 4.32 s | 9.04 s | | `-mx` (CM) | 32.0 s | 10.5 s |

On all seven corpora PArc is also faster at every level up to `-m9`; differences of a few
percent are within single-run noise. `-mx` uses context mixing and is much slower (roughly
4–32 s vs 3–11 s for FreeArc `-mx` on the 5–44 MB corpora) in exchange for the large ratio
gain above. Size margins at `-m5` and `-m6` on the heterogeneous corpus are small (0.04–0.14%),
so very different data may end up close.

What makes this possible (all inside `.parc`; the codecs are unchanged):

- **Buffered output**: `TStreamSink` accumulates 64 KB before writing. Codecs emitted many
  small pieces (especially PPMd's range coder) and ~14% of the time went into `write`. PPMd on
  20 MB of text dropped from 4.6 s to ~2.7–3.5 s (FreeArc: 2.86 s).
- **LZMA `fast`**: FreeArc's additions to `GetOptimumFast` were ported (main-match pruning by
  length/distance and relaxed rep-match acceptance). `-m3` used to lose 0.8% on binaries; now
  it wins.
- **Stronger and faster presets** than FreeArc's at the same level:
  `-m1` Tornado with a 16 MB window; `-m2` 64 MB; `-m3` LZMA `fast` with `mc8`; `-m4`/`-m5`
  binaries with `4x4:i0:lzma:8mb:max` (better and faster than `normal:32:mc8/mc32`);
  `-m5` PPMd 12/192 MB; GRZip with a 2^20 hash (`-m2`/`-m3`) and 2^17 (`-m4`); and the text
  group for `-m6`+ with `dict:m800:s250:75%`, 90% LZP and PPMd 16/384 MB.
- **Context mixing (`cm`)**: lpaq1-style model ported to Pascal and used by `-mx` on text and
  binaries (`-mx` text: 1.81 MB vs 2.16 MB for FreeArc on the 20 MB corpus; binaries: 5.45 MB
  vs 5.93 MB). It stores incompressible blocks raw, and `-O3` plus hot-loop optimisations
  brought 20 MB text from ~31 s to ~22 s. Independent data blocks are compressed in
  parallel at every level (mixed corpus `-m9`: ~8.8 s -> ~6.3 s; `-m5`: ~7.1 s -> ~4.3 s;
  `-mx`: ~46 s serial -> ~32 s);
  `-mx` is still slower than `-m9`.
- **Verification (`t`)** also verifies independent blocks in parallel: mixed corpus ~3.5 s ->
  ~2.5 s at `-m6`, and ~48.5 s -> ~32.6 s at `-mx`.
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

SREP with the 32-bit binary was verified under Wine and with an archive cross-checked on Linux
(the rest of the Windows tests ran in the real VMs).

## Tests

```sh
./build.sh linux64
bash tests/cli.sh
bash tests/stdio.sh tests/volumes.sh
bash tests/rs_recovery.sh tests/parc_crypt.sh tests/cm.sh
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
