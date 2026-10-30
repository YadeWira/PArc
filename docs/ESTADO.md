# PArc status (2026-10-20)

PArc is an archiver written in **Free Pascal** with its own format, **`.parc`**, for Windows 7+
(x86/x64) and Linux x64. It does not read or write `.arc` and has no GUI: support for `.arc`
and the other containers (`.zip`/`.7z`/`.rar`) lives in
[FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

## Layout

```
src/                     Pascal sources (+ parc_torglue.cpp/.patch: bridge to FreeArc's Tornado encoder)
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
- **LZMA `ht4`**: FreeArc's hash-table match finder (rows of `mc` positions with a hash tag in
  the high bits, no `son` array) is ported; 0.0.2 mapped `ht4` to `hc4`. `fast`/`normal` (the
  `ht4` profiles) compress the same as FreeArc and faster. The next position's hash row/head is
  prefetched in `ht4` and `bt4`. Streams are standard LZMA: 0.0.2 decodes them.
- **LZMA decoder fast path**: whole symbols are decoded without input checks while 20 or more
  input bytes remain (LzmaDec style); the literal and match symbols are x86-64 assembler with a
  Pascal fallback (i386, or `-dPARC_NOASM`). The stream tail and truncated/corrupt input take
  the old path, and `tests/test_lzma_diff` checks that both decoders give identical output and
  errors on valid, truncated and corrupted streams.
- **Tornado encoder**: every `tor:1`…`tor:16` combination runs a loop specialized for its
  match finder and coder (no virtual calls), with the same stream as FreeArc. On x86-64,
  `tor:1`…`tor:4` spans are assembler, `tor:5`/`tor:6` split match finding and arithmetic
  coding into two assembler passes, and the optimal parser (`tor:11`…`tor:16`) prefetches
  like FreeArc;
  `-dPARC_NOASM`/i386 use Pascal loops. `4x4:tor` reuses its engines between blocks, and the
  decoder has fast loops for `c1`/`c2` too. All `tor:` options (`l`, `p`, `s`, `x`, `u`, `t`,
  `ah`, `al`, `fb`) now reach the encoder (they used to be dropped from the stored method).
  512 MB of TILIN, one thread, compress CPU: `tor:1` 5.4 → 1.8 s (FreeArc 2.7), `tor:3`
  6.4 → 5.0 s (6.5), `tor:5` 18.4 → 14.4 s (23.4), `tor:6` 23.9 → 20.4 s (40.4).
- **FreeArc's own Tornado encoder (C++) where it is faster**: `build.sh` compiles
  `reference/freearc-0.67/Compression/Tornado` with g++ (linux64) or MinGW-w64 g++ (win64/win32,
  libgcc/libmingwex static; the `.exe` imports the same system DLLs as before) through `src/parc_torglue.cpp`
  (`extern "C"`, no exceptions across the boundary, `CHECK` → error code, out of memory →
  `EOutOfMemory`, per-call `compress_all_at_once` for 4x4 threads). A single-stream `tor` runs
  it in its own thread that hands the turn back and forth with the caller, so only one of the
  two is busy. Chosen per method by measurement (compress CPU, one thread, minimum of 3–6 runs
  on 128 MB of TILIN, the `text` and `exe` sets): the C++ wins at `tor:10` (combination 8:
  0.85–1.00× the Pascal time; its Pascal engine was removed) and in the optimal parser with
  CachingMatchFinder<6> and rows ≥ 64 (`tor:15`: 0.73–0.95×). Everywhere else the Pascal/asm
  engine is faster or equal (C++ 0.98–2.1× at `tor:1`…`9`, `11`…`14`, `16`; 1.04–2.2× in `4x4:tor:5/6/7/12`
  with 4 threads, where Pascal reuses its engines). `PARC_TORENC=c|pas` forces one of them.
  `src/parc_torglue.patch` caps the optimal parser's repdist match at bufend while reads are
  pending (FreeArc's encoder can write archives that fail `t`, see above) and leaves FreeArc's
  decoder out. `tests/run_tornado_tests.sh` checks that both encoders produce FreeArc's stream
  byte for byte (oracle `tor64`) and fuzzes the options through the C++ one.
  128 MB of TILIN, one thread, compress CPU (41af3bc → now, FreeArc `-mt1`): `tor:10`
  98.0 → 81.6 s (88.2), `tor:15` 70.7 → 32.9 s (34.7).
- **LZMA encoder (`normal`/`max`)**: the bt tree walk and the literal coder are x86-64
  assembler (Pascal fallback), the bt4/ht4 match finders prefetch two or three positions ahead
  (hash head, first tree node, its children), and the optimal parser drops two SDK 18+ speed
  shortcuts that cost ratio (it always prices the literal, tries the short rep like SDK 9.x) and
  refreshes prices every 32 matches. `normal` and `max` are now smaller than FreeArc's.
- **LZMA multi-thread match finder** (port of LzFindMt, `normal`/`max` only). bt4: same output
  as one thread. ht4 (the `normal` default): 2 threads, the BT thread walks the HT4 rows and
  the list of matches is the one of FreeArc's multi-thread finder (rows report every longer
  match from length 4, hash2/hash3 matches only when closer, skipped positions also search
  their row), which is smaller than the one-thread list: like FreeArc, ht4 output with 2+
  threads differs from 1 thread (that one is FreeArc `-mt1`'s). 512 MB TILIN slice,
  `lzma:8mb:normal`: 1 thread 257,005,522, 2+ threads 256,882,467 (FreeArc `-mt1`
  257,058,517, `-mt4` 256,920,905); `96mb`: 253,641,041 / 253,540,503 (FreeArc 253,723,647 /
  253,565,992). Threads: `TLzmaEncParams.NumThreads` = 1 (one thread), 2 (compressing thread
  + a BT thread that also hashes) or 3 (+ a separate hash thread, like the SDK; the hash
  thread is light); 0 = automatic: the per-thread grant `LzmaEncThreadGrant` if a caller set
  one, otherwise this block's share of the global thread budget (`ThreadShare`, at least 2),
  and one thread inside 4x4 or with a one-thread budget. The match-finder threads take tokens
  from the global budget while they work, so PARC_THREADS is never exceeded.
  `LzmaEncMaxThreads(P)` tells how many threads a stream can use (3 for bt4, 2 for ht4, else
  1) and `LzmaEncThreadsFor(P)` how many it would take now. `tests/lzma_threads.sh` checks
  the thread peak under `PARC_THREADS`.
- **4x4 skips fewer compressible blocks**: FreeArc does not even try a 4x4 block whose order-0
  entropy is >= 99 % (`r99`). PArc still skips it, unless some ~1 MB piece of it repeats
  (>= 4 % covered by repeats of 8+ bytes): a block that mixes random MBs with compressible ones,
  or random data repeated, is compressed. 512 MB TILIN slice: one 8 MB block, 8,388,608 ->
  8,196,086 bytes; `-m2`…`-m5` on the exe/document/video sets 0.5–2.5 % smaller (-m5 exe:
  ~18 % more CPU). JPEG/MP3 blocks barely repeat and are still skipped.
- **Automatic solid blocks**: without `-s`, 64 MB for `-m1`…`-m3` and 32 MB for `-m4`…`-m9`/`-mx`. On Silesia this improved compression time and ratio at every level; small archives still use one block. `-mxx` keeps a single block for ratio.
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
- **Extraction (`x`/`e`)** decodes independent blocks in parallel and each worker writes its
  files directly (no temp files, no 2 GB limit): random 2 GB 17–21 s -> 3.5–4 s, 2.2 GB of
  already-compressed files 19 s -> 6.2–6.6 s (FreeArc 8.8 s), 35k small files 3.2 s -> 1.5 s.
  `-mx` verifies/extracts in ~2.5 s on the mixed corpus.
- **Container I/O**: parallel compression writes each block once (the block in turn goes
  straight to the archive, the rest wait in a bounded memory budget); solid-block planning,
  the update merge and the directory index are no longer quadratic (35k files `-m1`: 20 s ->
  12 s with 1 thread, 11 s -> 4 s with 4); file enumeration does one `lstat` per entry on
  Unix; CRC-32 uses PCLMULQDQ on x86-64 (~18 GB/s, tables ~2 GB/s).
- **Global thread budget** (`parc_parallel`): `PARC_THREADS=N` (default: cores, at most 64)
  is the maximum number of threads *working* at the same time in the whole process. There are
  N tokens; the main thread starts with one, pool threads take one per job, the LZMA match
  finder threads hold one while they run. A thread that blocks on another thread (a job, a
  match-finder semaphore, LZMA input) gives its token back while it waits and gets it back
  with priority over new jobs; a job nobody has started yet is run inline by the thread that
  waits for it, so nested pools (blocks -> 4x4/grzip/REP hashing -> LZMA MT) cannot deadlock
  and degrade to fewer threads. Pools are sized from the caller's share (`ThreadShare`:
  the whole budget at the top, `N div workers` inside a block job) and 4x4/grzip grow while
  tokens are free (`TJobPool.CanGrow`), so tokens go to the inner pools of one huge block or
  to the block level when there are many blocks. Verify/extract/compress main threads only
  collect results and hold no token while they wait. `tests/thread_budget.py` samples
  `/proc/<pid>/task/*/stat`: p99 of threads in R <= N and CPU/wall <= N + 0.3.
  The preset alternatives `(a|b)` are picked by N too (like FreeArc's `-mtN`).
  LZMA joins the budget through `LzmaEncThreadsFor` (see the multi-thread match finder
  above): 4x4 jobs set `LzmaSingleThreadHere` (one thread per block), the MT threads take a
  token with `BudgetEnter`/`BudgetLeave` and the semaphore waits give it back with
  `BudgetWaitBegin`/`End` (also the 2-thread mode's inline hash, run by the BT thread).
- **Directory**: mtime in ns is stored losslessly as zigzag VInt deltas (tag 7) or, when it
  is smaller, as the sub-second part only on top of the `Time` column (tag 8): 6–10 % smaller
  directories with random nanoseconds.
- Recovery is Reed-Solomon only; the `.arc` XOR scheme is gone.

## Verified platforms (0.0.2)

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
bash tests/run_tornado_tests.sh tests/crypto_vectors.sh tests/crc.sh tests/extract_parallel.sh
bash tests/run_lzma_tests.py build/tests/test_lzma
# decodificador LZMA actual vs copia congelada de 0.0.2 (streams válidos, truncados y dañados)
fpc -O2 -Fusrc -Futests/lzma_ref -FUbuild/tests/units -FEbuild/tests tests/test_lzma_diff.lpr
build/tests/test_lzma_diff 2000
sudo bash tests/fixes.sh          # patterns, links, full disk, FAT32
python3 tests/fuzz.py build/linux64/parc 100 build/linux64/parc
python3 tests/thread_budget.py    # PARC_THREADS=N: <= N hilos trabajando (muestrea /proc)
# liberar/reusar un trabajo del pool apenas termina (ventana ampliada con -dPARC_RACE_TEST)
fpc -O2 -dPARC_RACE_TEST -Fusrc -FUbuild/tests/race -FEbuild/tests tests/test_jobfree.lpr
PARC_THREADS=4 build/tests/test_jobfree
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
