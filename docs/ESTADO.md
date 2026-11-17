# PArc status (2026-10-30)

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
| Performance vs FreeArc 0.67.1 | ✅ on TILIN.tar (2026-10-30) PArc wins size, compression and verify time at every `-m1`…`-m9` with 1 thread, and with 4 threads except `-m5` compression (a tie); remaining small losses per set are listed in TODO.md; `-mx` is fast to decode, `-mxx` is the CM maximum (see below) |

## What it does today

- `.parc` format: nanosecond timestamps, Windows attributes, Unix permissions and links,
  Reed-Solomon recovery (`-rr`), volumes (`-v`), authenticated encryption (`-p`/`-hp`:
  XChaCha20-Poly1305 or AES-256-GCM in 64 KiB chunks, Argon2id; own code, see
  [FORMATO-PARC.md §3b](formato/FORMATO-PARC.md)), stdin/stdout (`-si`, `-so`, `-`), long paths and cancellation without partial files.
- Existing self-extractors can be listed, tested and extracted; no new ones are created.
- Commands: `l`, `lb`, `t`, `x`, `e`, `a`, `u`, `f`, `d`, `r`, and FreeArc's `v`, `lt`, `create`,
  `m`, `mf`, `ch`, `rr<spec>`, `c`, `cw`, `j`, `k` (tests/cli_commands.sh). Not implemented: `s`
  (SFX) and `modify`.
- Methods: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor`, `plz`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070`, `srep` and `cm` (context mixing), alone or
  chained.
- `plz` (2026-11) is PArc's own LZ77 codec (no FreeArc code), meant to replace Tornado in the
  presets: see "plz" below for the design and the measurements against `tor`; stream format in
  `formato/FORMATO-PARC.md` §6.2.
- FreeArc built-in presets ported: `-m0`…`-m9`, `-mx`, `-mxx` and the `d/t/xt/xb/binary/rep` families.
- `ppmd` (2026-11) is PPMd var.I from the public-domain LZMA SDK (`Ppmd8`), ported to Pascal
  with x86-64 assembler for the symbol coder and `UpdateModel`; it replaced FreeArc's PPMd (a
  step towards relicensing). Same ratio as before plus an 8-byte stream header; `ppmd` blocks
  from earlier versions no longer decode. Stream format in `formato/FORMATO-PARC.md` §6.1.
- FreeArc 0.67 command-line options (own implementation, see [USO.md](USO.md)): `-mt<N>`,
  `-t`/`-tp`, `-y`, `-n<pattern>` and `@listfile`, `-ep`/`-ep1`/`-ap<dir>`, `-ag[FMT]`,
  `-sm`/`-sl`/`-ta`/`-tb`/`-tn`/`-to`, `--dirs`/`-ed`, `--nodates`, `-tk`/`-tl`, `-w<dir>`,
  `-lc`/`-ld`, `-kb`, `--sync`, `-mc-<alg>`, `--print-config` and `-kf<file>`
  (tests/cli_options.sh). Differences from FreeArc: `-x`/`-n` and the size/time filters also
  apply to `l`/`t`/`x`/`e`/`d`; `-ep3` (absolute paths) and `-mc+`/`-mca/b` are not supported;
  without `-kb` broken extracted files are deleted (before, they were kept); `-ld` refuses
  blocks (exit code 7) instead of FreeArc's reduction when compressing.

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
- **4x4 and nearly random blocks**: FreeArc does not even try a 4x4 block whose order-0
  entropy is >= 99 % (`r99`). PArc looks at each ~1 MB piece of such a block: runs of pieces
  that repeat (>= 4 % covered by repeats of 8+ bytes) are compressed as 4x4 blocks of their
  own and the random pieces are stored, so the inner method never walks the random MBs (the
  4x4 format already allows blocks of any size; old decoders read it). JPEG/MP3 barely repeat
  and stay stored whole, as in FreeArc. Before, one repeating piece made the whole block go
  through the inner method: TILIN.tar `-m4` with 4 threads took 78 s (FreeArc 58 s); now
  55–61 s at 1,042 MB (FreeArc 1,050 MB), and `-m1` 9.1 s -> 6.3 s.
- **Solid blocks like FreeArc**: without `-s` there is no size cap (only the cuts that `dict`/
  `grzip`/`lzp`/`tta`/`mm` need and the file groups). The old automatic cap (64 MB for
  `-m1`…`-m3`, 32 MB above) predates 4x4/LZMA threads inside a block and cut the repeats between
  files: document set `-m6` 43.8 -> 36.6 MB (FreeArc 36.6 MB), exe set `-m6`…`-m9` -1.9 %,
  `-m1` -1 to -15 %.
- **GRZip adaptive LZP**: BWT blocks of 4 MB or more use `l64/h22` (fewer, longer matches); small blocks keep the fast LZP parameters. The choice is stored in each block's mode, so old decoders remain compatible. This makes `-m4` 1.2–1.4% smaller on text and many small files.
- **Even 4x4 blocks** (`Balance4x4` in `parc_encoders`, applied with the dictionary limit):
  with 2+ threads, a 4x4 of LZMA without its own `:b` whose `J = ceil(S/B)` jobs are fewer
  than the threads and whose last block is nearly full (equal blocks at most 1/8 smaller)
  splits the solid block into J equal blocks (`4x4:b<kb>` in the stored method). REP shrinks
  the stream before 4x4: the document set's 66 MB binary block became 24+23 MB, two jobs on
  four threads (9.9 s at `-m4`); now 22+22+3, 5.3 s. With J >= N, or a small last block,
  nothing changes: smaller blocks only cost ratio there (executables +0.05..0.7 %).
- **Presets by thread count** (`src/parc_presets_data.inc`, lines marked `// PARC`): like
  FreeArc's `-mtN`, the `(a|b)` alternatives follow `PARC_THREADS`: one thread uses
  single-stream methods, 2+ threads the 4x4 ones. Binaries (FreeArc's method in brackets):
  `-m1` `rep+tor:4:h4m` [`tor:4`] / `rep+4x4:tor:3` [same]; `-m2` `rep+exe+delta+tor:6`
  [no delta] / `4x4:tor:5`; `-m3` `lzma:96m:fast:mc6:lc4` [`mc4`] /
  `4x4:lzma:16mb:normal:16:mc4:lc4` [`4x4:lzma:96mb:fast:mc4`, one block on 100 MB]; `-m4`
  `lzma:96m:normal:16:mc8:lc4` / `4x4:lzma:24mb:normal:20:mc6:lc5:pb1`; `-m5`
  `lzma:96m:normal:32:bt4:mc8:lc4` [ht4 `mc32`] / `4x4:lzma:24mb:normal:32:bt4:mc8:lc4`. Files
  of the `$compressed` group (by extension at `-m1`) are no longer stored at `-m1`: they go
  with the rest (with threads, 4x4 stores the random pieces).
  `-m6`…`-m9` keep FreeArc's methods, and `-mx` is `-m9` again, as in FreeArc (its own
  `x$text`/`x$binary` with PPMd 20/1 GB and a 64 MB REP window were larger: document set
  +0.05 %). Text: GRZip with adaptive blocks (`:a`, FreeArc's reads end up cutting its
  blocks too) at `-m2`/`-m3`/`-m4` with threads, `dict+lzp:32+grzip:m3:a` at `-m3`, PPMd
  8/192 MB at `-m4`, 13/192 MB at `-m5`, 12/192 MB (`4x4`) at `-m5` with threads, and
  `dict:m800:s250:75%`, 90% LZP and PPMd 18/512 MB for `-m6`+. `*.pak` left the
  `$compressed` group (FreeArc's `find_type` sends them to `$precomp`, i.e. compressed).
  Measurements and the remaining losses: TODO.md, "Presets retune".
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
- **Deterministic output**: the same binary, input and `PARC_THREADS` always write the same
  archive (`tests/determinism.sh`). Different N may differ only through the preset
  alternatives `(a|b||c)` (N=1, 2, ≥3), lzma ht4's 1-thread match list, and the 4x4 block size
  for fast inner methods (see block scheduling below); otherwise, with the same method string,
  every codec gives the same stream for any N.
- **Block scheduling under the budget** (branch perf3/sched):
  - Planning: grouping the sorted runs by method was quadratic (an insertion sort that split
    both method strings on every comparison: thousands of runs with many small files); now the
    few distinct methods are sorted and the runs bucketed. File-type detection (`GroupType`,
    which opens and samples files) runs per extension run in the thread pool. Same archives.
  - Solid blocks go into the archive **largest first** (LPT): the threads start with what takes
    longest and the run ends with small blocks; `t`/`x` submit blocks in archive order, so they
    get the same order. Only block order (and listing order) changes; not on updates that copy
    or re-read old blocks. The sort is a stable merge sort of indexes with one permutation of
    the groups (`SortGroupsBySize`, O(G log G): with `-s-` there is one group per file);
    `tests/block_order.sh` checks the order, its stability and the round trip.
  - `4x4` with a fast inner method (`tor`, `lz4`, `lzma:fast`) and no explicit `b<size>`:
    if everything being compressed (`Enc4x4TotalHint`) gives fewer than 3 blocks per thread,
    blocks shrink to that (whole MB, down to a quarter, at least 1 MB); and near the end of
    each solid block (less than two blocks of input left, from `Enc4x4BlockHint`) each new
    4x4 block is a quarter of what is left, down to a quarter block, so a solid block ends with
    several small pieces instead of one or two big ones. Both depend only on the data and on
    `PARC_THREADS` (and are off with 1 thread): **archive bytes depend on N** (they already did
    through the `(a|b)` presets and ht4) but are identical across runs with the same N.
  - LZMA `bt4` (same output with any number of threads) always uses its 3 threads when the
    budget has 3 or more, even if the block's share is smaller: the threads hold tokens only
    while they work, so the last block picks up the tokens the others leave.
  - Tried and dropped: a pipe stage that runs a decoder in its own thread (ppmd | lzp,
    lzma | delta+exe+rep): no gain, lzp and dict decode whole blocks (lzp reads its match
    lengths from the end of the block) and lzma's consumers are cheap; letting the 4x4 writer
    queue grow while its oldest block runs (instead of waiting for it): no measurable gain.
- **Directory**: mtime in ns is stored losslessly as zigzag VInt deltas (tag 7) or, when it
  is smaller, as the sub-second part only on top of the `Time` column (tag 8): 6–10 % smaller
  directories with random nanoseconds.
- Recovery is Reed-Solomon only; the `.arc` XOR scheme is gone.

## Compression memory limit (2026-11-17)

Before, PArc only limited dictionaries to the data size: win32 `a -m9` over TILIN (1.86 GB,
10k files) became `rep:1gb+exe+delta+lzma:192mb:bt4` (+ 4x4 and parallel blocks) and died with
"Out of memory". Now every block's chain is estimated (`EncodeMemEstimate`) and shrunk to fit
the compression limit (`FitEncodeMem`: largest consumer first, not below the next one), and
the blocks compressed in parallel are limited so that their sum fits. Limit: `-lc`, or 75 % of
the RAM; 32-bit also 2.25 GB and 9/16 of the address space (`-lc-` disables it).

**The 32-bit builds can therefore choose smaller dictionaries than x86-64 on huge inputs**
(`-m5` with 8 threads, `-m9`/`-mx` below): their archives can differ from x86-64 ones at
`-m5`…`-mx` on big data. The method only depends on (data, `PARC_THREADS`, limit, bitness):
linux32 and win32 give the same method (sizes differ by a few hundred bytes: Windows
attributes vs Unix modes). x86-64 with the same `-lc` can still choose differently, because the
32-bit lzma encoder is first capped at 2 GB (`-m9` on TILIN with `-lc2304m`: x86-64
`rep:597mb+lzma:112mb`, 785.5 MB; 32-bit `rep:965mb+lzma:104mb`, 753.0 MB).

TILIN.tar extracted (1,865,122,242 bytes), PArc win32 under Wine (4 GB large-address-aware),
linux32 native, linux64 without limit (`-lc-`) and FreeArc 0.67 32-bit (`Arc.exe -cfg- -mtN`,
under Wine). Size in bytes, real time in s, peak RSS (`/usr/bin/time %M`). Two runs at a time
on a 64-core Xeon (times are indicative); every PArc archive tested OK with linux64.

| N | level | PArc win32 | PArc linux32 | PArc linux64 `-lc-` | FreeArc 0.67 32-bit |
|---|---|---|---|---|---|
| 4 | `-m5` | 973,109,312 · 106 s · 1.48 GB | 973,108,868 · 99 s · 1.41 GB | 973,108,868 · 58 s · 1.49 GB | 980,442,171 · 64 s · 1.54 GB |
| 4 | `-m7` | 821,490,429 · 422 s · 1.44 GB | 821,489,910 · 466 s · 1.41 GB | 821,489,910 · 260 s · 1.67 GB | 821,606,890 · 348 s · 1.37 GB |
| 4 | `-m9` | 753,013,493 · 389 s · 2.42 GB | 753,012,979 · 383 s · 2.39 GB | 752,941,926 · 245 s · 6.26 GB | 753,215,338 · 345 s · 1.97 GB |
| 4 | `-mx` | 753,013,493 · 388 s · 2.42 GB | 753,012,979 · 385 s · 2.39 GB | 752,941,926 · 235 s · 6.26 GB | 753,215,338 · 350 s · 1.97 GB |
| 8 | `-m5` | 973,928,759 · 59 s · 1.72 GB | 973,928,232 · 52 s · 1.71 GB | 973,108,868 · 36 s · 2.37 GB | 980,442,171 · 60 s · 1.72 GB |
| 8 | `-m7` | 821,490,429 · 413 s · 1.44 GB | 821,489,910 · 420 s · 1.41 GB | 821,489,910 · 240 s · 1.67 GB | 821,606,890 · 331 s · 1.37 GB |
| 8 | `-m9` | 753,013,493 · 375 s · 2.42 GB | 753,012,979 · 366 s · 2.39 GB | 752,941,926 · 239 s · 6.26 GB | 753,215,338 · 340 s · 1.98 GB |
| 8 | `-mx` | 753,013,493 · 381 s · 2.42 GB | 753,012,979 · 359 s · 2.39 GB | 752,941,926 · 252 s · 6.26 GB | 753,215,338 · 349 s · 1.99 GB |

32-bit methods chosen: `-m5` N=4 as x86-64; N=8 `4x4:lzma:16mb` instead of 24mb; `-m9`/`-mx`
`rep:965mb+exe+delta+lzma:104mb` (x86-64: `rep:1787mb+…+lzma:254mb`). With a 1.5 GB limit
`-m9` was 834 MB (`rep:407mb+lzma:72mb`), with 2 GB 818 MB; 2.5 GB ran out of memory (before
rep stopped copying its window when growing). No run ran out of memory.

## plz: own LZ codec to replace Tornado (2026-11-17)

PArc is moving to the MIT license, so the FreeArc-derived code has to go; Tornado (`tor`, ~10k
lines plus FreeArc's C++ encoder) is the largest piece, and it is the engine of `-m1`…`-m4`
(alone, inside `4x4`, and for `$compressed` files). `plz` replaces it with PArc's own code,
written from public LZ77 literature without looking at Tornado's sources
(`src/parc_plz.pas`: format and decoder; `src/parc_plzenc.pas`: encoder;
`src/parc_plz_x64.inc`: one x86-64 loop; format in `formato/FORMATO-PARC.md` §6.2).

**Design.**

- *Match finder.* Levels 1–2: a direct-mapped table whose 8-byte entries hold the position and
  the first 4 data bytes, so a non-matching candidate never touches the window (5/6-byte hash,
  1 MB / 8 MB table); the scan over positions without matches is a small assembler loop
  (identical output with `-dPARC_NOASM`). Levels 3–7: hash rows of 4–64 entries in recency
  order, each with an 8-bit tag; tags, row head and positions share a cache-line-aligned record
  and are compared 8 at a time (SWAR) before any data is read; rows of the next position are
  prefetched. The four repeated offsets are tried first at every position; matches are
  extended backwards over pending literals.
- *Parser.* Greedy with skip acceleration in incompressible stretches (1–2, inserting two
  positions per match), lazy with one step (3–4) or two (5–7) using an estimated gain
  `4·length − log2(offset)` (repeated offsets almost free); long matches insert only their first
  and last positions (4 at level 3, 16 at 4–5).
- *Entropy coding.* The input is parsed in blocks of 256 KB; each one is then coded whole or cut
  (after a sequence) into pieces of 16–128 KB, choosing the cut that minimises an integer
  entropy estimate of the pieces, so tables follow data that changes (many small files of
  different kinds one after another) and stay big on uniform data. Each coded block has its own
  canonical Huffman tables (≤ 11 bits, rebuilt from its histograms) for literals and for four
  sequence alphabets: a
  128-symbol token joining the literal and match lengths, overflow codes for long lengths, and
  an offset alphabet with the 4 repeated offsets and 60 log-slots with a mantissa bit. A table is
  reused from the previous block, literals are stored raw, or the whole block is stored, whenever
  that is cheaper. Literals are coded in four interleaved bit streams (decoded in parallel),
  sequences in a fifth one; extra bits are raw.
- *Decoder.* Literals first (4 streams, 11-bit lookup tables, 5 symbols per refill), then the
  sequences with 16-byte copies; every count, length, offset and bit-stream end is checked
  (damaged input gives `EArcCorrupt`, never an out-of-bounds access or a hang: 2,000 mutated
  streams per `tests/plz.sh` run, clean under valgrind). Streaming uses a ring of W + 1 MB that
  grows with the data (W from the stream, ≤ 1 GB); inside `4x4` each block is decoded memory
  to memory.
- *Determinism.* Each block is parsed only with the data up to its end and everything is integer
  arithmetic, so the output is the same in streaming and memory mode, for any write sizes, with or
  without assembler and on every platform (`tests/plz_cross.sh`: linux64, linux32, linuxarm64
  under QEMU, win64 and win32 under Wine, 450 identical outputs), and does not depend on the
  thread count (the encoder is single-threaded; `4x4` gives the parallelism, as with `tor`).

**Levels** (`plz:<1..7>[:<window>][:h<hash>]`, default 3):

| level | window | finder | parser | aimed at | memory to compress (streaming) |
|---|---|---|---|---|---|
| 1 | 8 MB | direct table 1 MB, 5-byte hash | greedy | `tor:3:8mb` (4x4 `-m1`) | ~14 MB |
| 2 | 8 MB | direct table 8 MB, 6-byte hash | greedy | `tor:4:8mb:h4m` (`-m1` one thread) | ~21 MB |
| 3 | 16 MB | rows of 4 (8 MB), 5-byte hash | lazy 1 | `tor:5`, `tor:c3` (4x4 `-m2`, `$compressed`) | ~33 MB |
| 4 | 64 MB | rows of 8 (16 MB), 5-byte hash | lazy 1 | `tor:6` (`-m2` one thread) | ~113 MB |
| 5–7 | 64 MB | rows of 16/32/64 | lazy 2 | slower, smaller (e.g. `3xt`'s `tor:7`) | 130–200 MB |

Decompression needs the window plus ~2 MB.

<!-- PLZ-TABLES -->

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
bash tests/cli.sh tests/cli_options.sh tests/cli_commands.sh
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
bash tests/determinism.sh         # mismo N => mismo archivo (todos los niveles, N=1/2/4/8)
bash tests/ppmd.sh                # PPMd: ida y vuelta, streams dañados y bit a bit contra el LZMA SDK ($PPMD_SDK)
bash tests/ppmd_asm.sh            # PPMd: ensamblador == Pascal (-dPARC_NOASM)
bash tests/plz.sh                 # plz: niveles, ventanas, streaming == memoria, asm == Pascal, dañados
bash tests/plz_cross.sh           # plz: mismos bytes en linux64/linux32/linuxarm64 (QEMU)/win64/win32 (Wine)
# plz_bench: cualquier método en memoria por las cadenas (tamaño, CPU y pared)
fpc -O3 -Fusrc -Fobuild/linux64/units -Flbuild/linux64/units -FUbuild/tests/units -FEbuild/tests tests/plz_bench.lpr
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
