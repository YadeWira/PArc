# PArc status (2026-11-20)

PArc is an archiver written in **Free Pascal** with its own format, **`.parc`**, for Windows 7+
(x86/x64) and Linux x64. It does not read or write `.arc` and has no GUI: support for `.arc`
and the other containers (`.zip`/`.7z`/`.rar`) lives in
[FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

## Layout

```
src/                     Pascal sources (with inline assembler; C only in src/orep and src/cm)
src/orep/                OREP 0.0.10 (MIT, vendored unchanged): orep.pas + orep_core.c, the long-range matcher
src/cm/                  pcm_core.c: the model of PArc's own context-mixing codec `cm` (MIT, freestanding C)
docs/                    manual (USO.md), format (formato/FORMATO-PARC.md), codecs
tests/                   tests, codec oracles and fuzzers
reference/freearc-0.67/  only Compression/: C codec sources and test oracle
```

The rest of the FreeArc 0.67 tree is in git history (commit `82ea8d9`) and in FreeArc-ex.

## Phases

| phase | status |
|---|---|
| FreeArc/PArc bugs | ✅ closed (the `.arc` parity fixes remain as history; see tag `entrega-arc`) |
| Ported codecs | ✅ closed (LZMA, LZ4, PPMd, 4x4, Dict, LZP, Delta, MM, TTA, GRZip, BCJ, DisPack, SREP; Tornado was ported too and removed after 0.0.5, replaced by the own `plz`; REP replaced by OREP, MIT, 2026-11) |
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
- Methods: `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `orep`, `delta`, `plz`, `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070`, `srep` and `cm` (context mixing), alone or
  chained.
- `plz` (2026-11) is PArc's own LZ77 codec (no FreeArc code). Since 2026-11-20 it is the LZ of
  the presets (`-m1`/`-m2`, `$compressed` up to `-m4`, `3xt`) and Tornado (`tor`) is gone: see
  "plz" and "Tornado removed" below for the design and the measurements; stream format in
  `formato/FORMATO-PARC.md` §6.2.
- FreeArc built-in presets ported: `-m0`…`-m9`, `-mx`, `-mxx` and the `d/t/xt/xb/binary` families
  (the `rep` family is now `orep`: `-m5orep` = `orep:96m:l512`).
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
| `-mxx` (CM, lpaq1 port; the own `cm` of 2026-11-23 is smaller still, see below) | −16.1% | −8.2% | −8.2% | −7.5% |

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
- **Context mixing (`cm`)**: (since 2026-11-23 PArc's own CM, see "Own context mixing" below;
  what follows is the history of the lpaq1 port it replaced) lpaq1-style model ported to Pascal and used by `-mxx` on text and
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

## REP replaced by OREP (2026-11-18)

FreeArc's REP (GPL) is gone; the long-range stage is now `orep`: OREP 0.0.10 (MIT), written for
PArc by osrep and vendored unchanged in `src/orep/` (version and commit in `src/orep/VERSION`;
`build.sh` compiles its C core for every target). Syntax in [USO.md](USO.md), stream in
[FORMATO-PARC.md §6.2](formato/FORMATO-PARC.md). `rep` blocks of older archives no longer decode
(the error says so); `-mrep` fails with a hint; `-mc-rep`/`-mcr-` remove `orep`.

Presets: `-m1` `orep:96m:l256:c2:r512`, `-m2` `orep:96m:l256:r512`, `-m3`…`-m5` `orep:96m:l512`, `-m6`…`-m9`
`orep:<window>:l512` (256m/512m/1024m/2040m); `-mxx` `orep:64m:l512:a1`. How they were chosen
(TILIN, a 128 MB mix and the broad-sweep sets, every option run at the same time as REP):

- `-m1`/`-m2` with 4 threads, totals over 13 inputs: `l256` −0.025 %/−0.021 % size, +29 %/+8 %
  wall; `l256:c1` −0.011 %/−0.030 %, +22 %/+8 % (worst single input +0.08 %); `l128:c1`
  −0.21 %/−0.06 % but +59 %/+13 %. `-m1` takes `c1` (time), `-m2` keeps `l256` (`c1` saved no
  time there). With OREP 0.0.9 (`r<n>`: a match that only covers a run of one byte value and is
  shorter than n stays literals, which plz/4x4 code almost for free), osrep moved them to
  `c2:r512` and `r512`: TILIN.tar `-m1` with 4 threads REP 5.71 s, OREP 0.0.8 6.05 s, 0.0.9
  5.71 s, with less CPU and fewer bytes.
- In front of lzma, OREP's default `l64` (and `l32`) lost 0.1–0.4 % on TILIN; `l512` won
  everywhere. `-m6`…`-m9`: `l512:s8:a4` lost 0.04 % on `text` (forced alignment), `s16` saved
  0.003 % with four times the anchor table.

Threads (OREP 0.0.6 and later): with at least two tokens for the block, OREP searches with up to 4 threads
of its own (a coordinator and helpers) while the writing thread hands the previous block to the
next stage. Its threads never wait for a token: `OnWorkerTryBusy` takes a free one or the thread
that already has one does the work, `OnWorkerIdle` gives it back after at most 200 us of
spinning, and the writing thread gives its own back while it waits for the search
(`OnCallerWaitBegin/End`). So `PARC_THREADS` is never exceeded (`tests/thread_budget.py`), there
is no deadlock (nobody waits for a token while holding one; without the hooks OREP is only used
with one thread), and the output is the same with any number of threads. History: with 0.0.5
(blocking `OnWorkerBusy`, 2 ms spins holding the token, the caller waiting with its token) the
threads were slower than inline (tilin_512m `-m1` 4 threads: inline 2.3 s, k=2 3.0 s, k=3
3.4 s); with 0.0.6: REP 2.0 s, inline 2.3 s, threads 2.1 s; TILIN.tar `-m1`: REP 5.8 s, inline
7.3 s, threads 7.1 s; with 0.0.7 (segment pipeline, helper tokens once per block): tilin_512m
2.11 s, TILIN.tar 6.65 s; with 0.0.8 (verify fused into select): tilin_512m 1.99 s, TILIN.tar
5.96 s (REP 2.01–2.07 / 5.75–5.93 s). `PARC_OREP_THREADS=1` keeps it inline.

Decoding: the stage reads the verified output in place (`OrepDecPeek`/`OrepDecSkip`, straight
into the reader's buffer) and reuses decoders across blocks (`OrepDecReset`, up to 8 with rings
of at most 64 MB, after a clean end). The `orep` stage alone decodes tilin_512m in 0.39–0.45 s,
REP 0.41–0.44 s. Encoders are not reused: the canonical window is clipped to each solid block,
so parameters rarely match. OREP 0.0.7's CRC-32C uses SSE4.2 when `cpuid` says so and a table
otherwise (checked under `qemu -cpu core2duo`: same bytes on linux64 and linux32).

A 4x4 scheduling quirk exposed by OREP's smaller output (the last blocks of a solid block ran
one after another when there were fewer jobs than the queue: exe `-m4` with 4 threads 10 s
instead of 6) was fixed in `T4x4EncStage.SubmitBlock`.

Decompression changes that help REP as much as OREP: the 4x4 decoder's read-ahead is also
bounded by bytes (`TParallelBlockStage.ReadAheadBytes`, 16 MB per thread, up to 256 blocks;
4x4 keeps the 1 MB pieces that repeat as separate blocks, and 8 jobs in flight were only 8 MB of
work with 4 threads), and the extraction copy buffer is 128 KB instead of 1 MB (fits L2). The
first version of the read-ahead could overwrite the oldest queued block when the pool then grew
by a thread (a block delivered out of turn: `t` of document `-m3` with 4 threads failed 1 time
in 3); fixed, with `tests/test_blockorder.lpr`.

Measured with OREP 0.0.10 against `main` 40ffce5 (REP) on the broad-sweep sets (≈100 MB each),
`tilin_512m.tar` and `TILIN.tar` (1.8 GB; with one thread only `-m1`…`-m5`), every level. Six
independent streams, each pinned (`taskset`) to its own 4 cores of an otherwise idle part of
the machine; in each stream one configuration at a time, REP and OREP alternating: compression
best of 2, `t` best of 3 (REP archives also with `main` plus the two decompression changes of
this branch). `-mx` is `-m9`.

Size, OREP vs REP, % (T1; negative = OREP smaller):

| set | `-m1` | `-m2` | `-m3` | `-m4` | `-m5` | `-m6` | `-m7` | `-m8` | `-m9` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TILIN.tar | -0.010 | -0.009 | -0.012 | -0.012 | -0.010 | — | — | — | — |
| tilin_512m.tar | -0.009 | -0.026 | -0.010 | -0.006 | -0.034 | -0.012 | -0.040 | -0.097 | -0.094 |
| archive | -0.019 | -0.003 | -0.017 | -0.039 | -0.015 | -0.019 | -0.019 | -0.019 | -0.019 |
| audio | -0.017 | -0.001 | -0.025 | -0.011 | -0.008 | -0.011 | -0.004 | -0.004 | -0.004 |
| document | -0.026 | -0.017 | -0.040 | -0.020 | -0.011 | -0.017 | -0.018 | -0.018 | -0.018 |
| exe | -0.013 | -0.009 | -0.011 | -0.008 | -0.005 | -0.001 | +0.001 | -0.001 | -0.001 |
| font | -0.045 | -0.052 | -0.060 | -0.062 | -0.038 | -0.034 | -0.034 | -0.034 | -0.034 |
| image | -0.045 | — | -0.196 | -0.127 | -0.131 | -0.142 | -0.148 | -0.148 | -0.148 |
| large | -0.003 | +0.007 | -0.083 | -1.069 | -1.192 | -1.268 | -1.258 | -1.265 | -1.265 |
| small | +0.050 | +0.001 | -0.013 | -0.010 | -0.008 | -0.005 | -0.005 | -0.005 | -0.005 |
| text | -0.047 | +0.007 | -0.016 | -0.013 | +0.014 | +0.028 | +0.024 | +0.007 | +0.007 |
| video | -0.050 | -0.027 | -0.210 | -0.193 | -0.191 | -0.213 | -0.214 | -0.214 | -0.214 |

Size, OREP vs REP, % (T4; negative = OREP smaller):

| set | `-m1` | `-m2` | `-m3` | `-m4` | `-m5` | `-m6` | `-m7` | `-m8` | `-m9` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TILIN.tar | -0.018 | -0.036 | -0.004 | +0.015 | +0.012 | -0.015 | -0.041 | -0.027 | -0.151 |
| tilin_512m.tar | -0.008 | -0.014 | -0.013 | -0.017 | -0.016 | -0.012 | -0.040 | -0.097 | -0.094 |
| archive | -0.008 | +0.004 | -0.011 | +0.051 | -0.026 | -0.019 | -0.019 | -0.019 | -0.019 |
| audio | +0.000 | +0.005 | -0.013 | -0.011 | -0.005 | -0.011 | -0.004 | -0.004 | -0.004 |
| document | -0.025 | -0.006 | -0.073 | -0.015 | -0.008 | -0.017 | -0.018 | -0.018 | -0.018 |
| exe | -0.035 | -0.017 | -0.008 | -0.008 | -0.022 | -0.001 | +0.001 | -0.001 | -0.001 |
| font | -0.031 | -0.076 | -0.066 | -0.047 | -0.048 | -0.034 | -0.034 | -0.034 | -0.034 |
| image | -0.040 | -0.006 | -0.125 | -0.107 | -0.133 | -0.142 | -0.148 | -0.148 | -0.148 |
| large | -0.004 | +0.029 | -0.613 | -0.631 | -1.030 | -1.268 | -1.258 | -1.265 | -1.265 |
| small | +0.101 | +0.014 | -0.008 | -0.009 | -0.005 | -0.005 | -0.005 | -0.005 | -0.005 |
| text | -0.035 | +0.004 | -0.015 | -0.055 | -0.052 | +0.028 | +0.024 | +0.007 | +0.007 |
| video | -0.074 | -0.167 | -0.160 | -0.067 | -0.200 | -0.213 | -0.214 | -0.214 | -0.214 |

Compression wall time, OREP vs REP, % (T1; best of 2, REP and OREP alternating):

| set | `-m1` | `-m2` | `-m3` | `-m4` | `-m5` | `-m6` | `-m7` | `-m8` | `-m9` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TILIN.tar | -6 | -5 | -2 | +0 | +1 | — | — | — | — |
| tilin_512m.tar | -16 | -4 | -2 | -2 | -1 | -6 | -3 | +3 | +1 |
| archive | +14 | -4 | -5 | +0 | -1 | +0 | -1 | +9 | +5 |
| audio | -9 | -0 | -1 | +0 | -1 | -5 | -2 | +4 | +2 |
| document | +0 | +10 | -0 | -4 | +1 | +1 | +1 | -10 | -2 |
| exe | -21 | +5 | +3 | -0 | +1 | +0 | -5 | -2 | -2 |
| font | -4 | +1 | -4 | +1 | -0 | -2 | +2 | +2 | -1 |
| image | -2 | — | -0 | +4 | -2 | -2 | -1 | +3 | +1 |
| large | +4 | -2 | -2 | +0 | -0 | +2 | +2 | +9 | -2 |
| small | -1 | +0 | -0 | -1 | -1 | -2 | -1 | -1 | -6 |
| text | -4 | -0 | +1 | +2 | -4 | +1 | +6 | +0 | -0 |
| video | -11 | +1 | -0 | +1 | +3 | -1 | +1 | +1 | -3 |

Compression wall time, OREP vs REP, % (T4; best of 2, REP and OREP alternating):

| set | `-m1` | `-m2` | `-m3` | `-m4` | `-m5` | `-m6` | `-m7` | `-m8` | `-m9` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| TILIN.tar | -1 | -2 | +5 | +3 | +1 | +4 | +1 | +2 | -6 |
| tilin_512m.tar | -9 | -4 | +5 | +9 | +3 | +1 | +1 | -1 | -2 |
| archive | -12 | +8 | -23 | -32 | -5 | -2 | -1 | -5 | -1 |
| audio | -12 | +1 | -1 | -0 | -8 | -2 | -0 | -5 | -1 |
| document | -13 | -5 | -37 | -10 | -2 | +1 | -1 | +1 | -5 |
| exe | -9 | +4 | -9 | -3 | -6 | -2 | +0 | -2 | -2 |
| font | +5 | +18 | -1 | -1 | -1 | -1 | +0 | -1 | -2 |
| image | -9 | -2 | -1 | -6 | +0 | +1 | -3 | -1 | +20 |
| large | -11 | -17 | +0 | -5 | -0 | +10 | -1 | +8 | -2 |
| small | +2 | +1 | -4 | +3 | -1 | -1 | +4 | -0 | +0 |
| text | -9 | -1 | -7 | +0 | -28 | -2 | +2 | -4 | +1 |
| video | -18 | +10 | +2 | -4 | -16 | +0 | -4 | -1 | -2 |

Decompression (`t`) of the REP archives: `main` vs `main` with the two decompression changes (4x4 read-ahead by bytes, 128 KB copy buffer), wall seconds summed over all inputs (best of 3, alternating):

| T | level | main | main + changes | |
|---|---|---:|---:|---:|
| T1 | `-m1` | 10.8 s | 10.4 s | -3 % |
| T1 | `-m2` | 15.6 s | 15.3 s | -2 % |
| T1 | `-m3` | 84.4 s | 84.2 s | -0 % |
| T1 | `-m4` | 87.6 s | 87.6 s | -0 % |
| T1 | `-m5` | 95.7 s | 96.1 s | +0 % |
| T1 | `-m6` | 47.6 s | 47.5 s | -0 % |
| T1 | `-m7` | 48.5 s | 48.4 s | -0 % |
| T1 | `-m8` | 49.6 s | 49.5 s | -0 % |
| T1 | `-m9` | 49.0 s | 49.2 s | +0 % |
| T4 | `-m1` | 5.5 s | 5.1 s | -7 % |
| T4 | `-m2` | 7.5 s | 7.1 s | -5 % |
| T4 | `-m3` | 23.5 s | 22.3 s | -5 % |
| T4 | `-m4` | 25.0 s | 24.0 s | -4 % |
| T4 | `-m5` | 29.6 s | 29.7 s | +0 % |
| T4 | `-m6` | 79.6 s | 79.4 s | -0 % |
| T4 | `-m7` | 79.5 s | 79.1 s | -1 % |
| T4 | `-m8` | 77.1 s | 76.6 s | -1 % |
| T4 | `-m9` | 78.7 s | 80.3 s | +2 % |

Decompression (`t`) OREP vs REP with the same decompression changes (both on this branch's 4x4/copy code), wall seconds summed over all inputs (best of 3, alternating):

| T | level | REP (main + changes) | OREP | |
|---|---|---:|---:|---:|
| T1 | `-m1` | 10.4 s | 10.4 s | -0 % |
| T1 | `-m2` | 15.3 s | 15.2 s | -1 % |
| T1 | `-m3` | 84.2 s | 84.2 s | +0 % |
| T1 | `-m4` | 87.6 s | 87.8 s | +0 % |
| T1 | `-m5` | 96.1 s | 96.6 s | +1 % |
| T1 | `-m6` | 47.5 s | 47.9 s | +1 % |
| T1 | `-m7` | 48.4 s | 49.0 s | +1 % |
| T1 | `-m8` | 49.5 s | 50.0 s | +1 % |
| T1 | `-m9` | 49.2 s | 49.4 s | +1 % |
| T4 | `-m1` | 5.1 s | 5.2 s | +2 % |
| T4 | `-m2` | 7.1 s | 7.4 s | +4 % |
| T4 | `-m3` | 22.3 s | 22.4 s | +1 % |
| T4 | `-m4` | 24.0 s | 24.2 s | +1 % |
| T4 | `-m5` | 29.7 s | 28.6 s | -3 % |
| T4 | `-m6` | 79.4 s | 79.5 s | +0 % |
| T4 | `-m7` | 79.1 s | 79.6 s | +1 % |
| T4 | `-m8` | 76.6 s | 77.4 s | +1 % |
| T4 | `-m9` | 80.3 s | 78.6 s | -2 % |

Totals per level over all inputs (REP → OREP; size, compression wall and CPU, `t` wall, peak compression RSS of the largest input):

| T | level | size | comp wall | comp CPU | decomp wall | max RSS MB |
|---|---|---:|---|---|---|---|
| T1 | `-m1` | -0.014 % | 38 → 35 s (-7 %) | 37 → 35 s (-7 %) | 11 → 10 s (-4 %) | 229 → 174 |
| T1 | `-m2` | -0.011 % | 97 → 95 s (-3 %) | 96 → 94 s (-3 %) | 16 → 15 s (-3 %) | 364 → 377 |
| T1 | `-m3` | -0.029 % | 399 → 391 s (-2 %) | 399 → 391 s (-2 %) | 84 → 84 s (-0 %) | 363 → 371 |
| T1 | `-m4` | -0.064 % | 612 → 611 s (-0 %) | 607 → 609 s (+0 %) | 88 → 88 s (+0 %) | 330 → 353 |
| T1 | `-m5` | -0.069 % | 742 → 743 s (+0 %) | 738 → 741 s (+0 %) | 96 → 97 s (+1 %) | 1162 → 1186 |
| T1 | `-m6` | -0.155 % | 499 → 486 s (-3 %) | 499 → 484 s (-3 %) | 48 → 48 s (+1 %) | 674 → 682 |
| T1 | `-m7` | -0.163 % | 536 → 531 s (-1 %) | 535 → 530 s (-1 %) | 48 → 49 s (+1 %) | 1267 → 1269 |
| T1 | `-m8` | -0.184 % | 526 → 542 s (+3 %) | 526 → 540 s (+3 %) | 50 → 50 s (+1 %) | 1944 → 1941 |
| T1 | `-m9` | -0.183 % | 538 → 538 s (+0 %) | 537 → 537 s (+0 %) | 49 → 49 s (+1 %) | 3269 → 3268 |
| T4 | `-m1` | -0.019 % | 14 → 13 s (-7 %) | 41 → 39 s (-4 %) | 5 → 5 s (-6 %) | 338 → 376 |
| T4 | `-m2` | -0.028 % | 25 → 25 s (-1 %) | 82 → 81 s (-1 %) | 8 → 7 s (-2 %) | 515 → 525 |
| T4 | `-m3` | -0.040 % | 124 → 123 s (-1 %) | 377 → 389 s (+3 %) | 23 → 22 s (-4 %) | 461 → 494 |
| T4 | `-m4` | -0.024 % | 158 → 157 s (-1 %) | 450 → 460 s (+2 %) | 25 → 24 s (-3 %) | 612 → 627 |
| T4 | `-m5` | -0.049 % | 213 → 207 s (-3 %) | 657 → 662 s (+1 %) | 30 → 29 s (-3 %) | 1521 → 1544 |
| T4 | `-m6` | -0.078 % | 524 → 539 s (+3 %) | 1007 → 1028 s (+2 %) | 80 → 79 s (-0 %) | 739 → 753 |
| T4 | `-m7` | -0.097 % | 559 → 559 s (+0 %) | 1076 → 1075 s (-0 %) | 80 → 80 s (+0 %) | 1364 → 1385 |
| T4 | `-m8` | -0.103 % | 557 → 560 s (+1 %) | 1069 → 1075 s (+1 %) | 77 → 77 s (+0 %) | 2613 → 2635 |
| T4 | `-m9` | -0.166 % | 572 → 555 s (-3 %) | 1068 → 1051 s (-2 %) | 79 → 79 s (-0 %) | 4850 → 4816 |

Result (OREP 0.0.10): OREP wins or ties on size everywhere in total (−0.011…−0.184 % per
level; `large` −1.0…−1.3 % from `-m4`); the worst single inputs are +0.10 % (`small` `-m1`, 4
threads) and +0.05 % (`archive` `-m4`, 4 threads). Compression time per level is −7…+3 % (T1)
and −7…+3 % (T4); single cells of the ≈100 MB sets move ±10–30 % between runs, so only totals
count. Decompression with the same 4x4/copy code is −3…+4 % per level; the one consistent loss
is `TILIN.tar` `-m1`/`-m2` with 4 threads (2.06 → 2.18 s, 2.95 → 3.10 s, +5…6 %; the `orep`
stage alone decodes as fast as REP's, so the difference is in plz decoding a different stream).
Peak RSS is within ±60 MB of REP's. `image` `-m2` with one thread is missing: `t` fails with
CRC errors with REP and OREP alike (a `main` bug in `mm+plz`, e.g. `-mmm+plz:2` on
`image/bmp/cool.bmp`; `-mmm+lzma` and `-mplz:2` alone are fine).

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
`src/parc_plz_x64.inc`: one x86-64 loop; format in `formato/FORMATO-PARC.md` §6.3).

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
| 1 | 8 MB | direct table 1 MB, 6-byte hash (+ 4-byte table 2^16 on binary blocks) | greedy | `tor:3:8mb` (4x4 `-m1`) | ~14 MB |
| 2 | 8 MB | direct table 8 MB, 6-byte hash (+ 4-byte 2^12) | greedy | `tor:4:8mb:h4m` (`-m1` one thread) | ~21 MB |
| 3 | 16 MB | rows of 4 (8 MB), 5-byte hash (+ 4-byte 2^12) | lazy 1 | `tor:5`, `tor:c3` (4x4 `-m2`, `$compressed`) | ~33 MB |
| 4 | 64 MB | rows of 8 (16 MB), 5-byte hash (+ 4-byte 2^16) | lazy 1 | `tor:6` (`-m2` one thread) | ~113 MB |
| 5–7 | 64 MB | rows of 16/32/64 | lazy 2 | slower, smaller (e.g. `3xt`'s `tor:7`) | 130–200 MB |

Decompression needs the window plus ~2 MB.

**Second round (2026-11-18): every cell against `tor`.** The owner asked for `plz` to beat
`tor` in size, compression time and decompression time on every set at every preset use before
the switch. Encoder changes (the stream format and the decoder are unchanged):

- *Short-match table.* Binary formats (fonts, images, audio, video) repeat 4-byte stretches that
  the 5/6-byte hashes miss. Each 256 KB block is classified by a cheap deterministic sample (more
  than 1/8 of bytes outside 9..13 and 32..126 = binary); in binary blocks a second direct table
  hashed on 4 bytes (`y<bits>`: 2^16 entries at levels 1 and 4, 2^12 at 2 and 3) is probed and
  updated besides the main one, and the longer (or equally long and closer) candidate wins. Text
  blocks skip it. Level 1 now hashes 6 bytes like level 2.
- *Assembler.* The whole greedy loop of levels 1–2 (scan, both tables, match length, backward
  extension, literal copy, sequence, reps, insertions) and the per-position evaluation of the
  lazy parser on direct tables are x86-64 assembler, byte-identical to the Pascal path
  (`-dPARC_NOASM`, checked by `tests/plz.sh` and `tests/plz_cross.sh`).
- *Cheaper entropy stage.* Sequences are stored raw (length, length, rep index or distance) and
  coded in one pass per block; the histograms built to decide block cuts are reused when
  writing; a new Huffman table is only built when reusing the previous one or storing literals
  raw is not already cheaper than an entropy estimate.
- *Memory.* Hash tables shrink with small windows (≈ 2 entries per window byte), and the
  streaming buffer keeps one window ahead (one copy per input byte instead of two).

Measured again (2026-11-18, same chains with `rep` in front as the presets, best of 2 runs,
`nice -n10`, each run pinned to the idlest physical cores of the shared 64-core machine;
bold = `plz` worse). Logs: `/mnt/IA_LAB/agentes/PArc/lz-new/logs/final2/`.

| data | cell | tor size | plz size | Δ size | comp CPU tor/plz | comp wall tor/plz | dec CPU tor/plz | dec wall tor/plz |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| tilin512 | T1 -m1 (`plz:2`) | 284,628,505 | 280,958,631 | -1.29 % | 7.38 / 5.55 | 7.40 / 5.56 | 4.02 / 1.83 | 4.03 / 1.84 |
| tilin512 | T1 -m2 (`plz:4`) | 270,565,702 | 265,138,547 | -2.01 % | 23.06 / 17.58 | 23.09 / 17.59 | 5.93 / 2.40 | 5.94 / 2.41 |
| tilin512 | T4 -m1 (`plz:1`) | 289,006,803 | 283,942,785 | -1.75 % | 7.49 / 6.38 | 2.26 / 1.94 | 4.99 / 2.18 | 1.45 / 0.69 |
| tilin512 | T4 -m2 (`plz:3`) | 274,584,657 | 269,163,817 | -1.97 % | 18.24 / 17.12 | 5.03 / 4.82 | 7.09 / 2.62 | 1.98 / 1.03 |
| tilin512 | T4 -m4 $compressed (`plz:3`) | 276,647,421 | 270,844,074 | -2.10 % | 16.07 / 15.98 | 4.74 / 4.72 | 4.84 / 2.22 | 1.43 / 0.72 |
| TILIN | T1 -m1 (`plz:2`) | 1,078,738,066 | 1,070,935,651 | -0.72 % | 22.92 / 14.95 | 22.94 / 14.95 | 13.74 / 4.13 | 13.77 / 4.14 |
| TILIN | T1 -m2 (`plz:4`) | 1,055,483,194 | 1,044,817,684 | -1.01 % | 69.99 / 50.53 | 70.12 / 51.14 | 20.64 / 5.38 | 20.68 / 5.38 |
| TILIN | T4 -m1 (`plz:1`) | 1,091,769,634 | 1,086,040,274 | -0.52 % | 19.78 / 17.07 | 5.84 / 4.81 | 9.35 / 5.33 | 3.30 / 2.27 |
| TILIN | T4 -m2 (`plz:3`) | 1,071,314,861 | 1,065,244,516 | -0.57 % | **36.67 / 36.74** | **10.23 / 10.47** | 13.68 / 6.51 | 4.76 / 3.35 |
| TILIN | T4 -m4 $compressed (`plz:3`) | 1,072,970,322 | 1,066,257,446 | -0.63 % | 38.21 / 35.19 | 10.25 / 9.52 | 10.51 / 5.67 | 3.56 / 2.35 |
| text | T1 -m1 (`plz:2`) | 32,081,028 | 31,132,657 | -2.96 % | 1.22 / 1.22 | 1.23 / 1.22 | 0.52 / 0.39 | 0.53 / 0.40 |
| text | T1 -m2 (`plz:4`) | 29,429,591 | 28,187,532 | -4.22 % | **3.64 / 4.86** | **3.65 / 4.93** | 0.86 / 0.60 | 0.86 / 0.60 |
| text | T4 -m1 (`plz:1`) | 32,211,864 | 31,048,863 | -3.61 % | **1.56 / 1.66** | **0.63 / 0.69** | 0.74 / 0.52 | 0.24 / 0.22 |
| text | T4 -m2 (`plz:3`) | 30,061,663 | 28,640,003 | -4.73 % | **2.85 / 3.91** | **1.00 / 1.33** | 0.98 / 0.62 | 0.38 / 0.32 |
| text | T4 -m4 $compressed (`plz:3`) | 30,277,365 | 28,709,005 | -5.18 % | **2.45 / 3.70** | **0.86 / 1.29** | 0.69 / 0.52 | 0.23 / 0.22 |
| exe | T1 -m1 (`plz:2`) | 80,573,341 | 79,859,654 | -0.89 % | 1.70 / 1.11 | 1.71 / 1.12 | 0.99 / 0.33 | 1.00 / 0.33 |
| exe | T1 -m2 (`plz:4`) | 79,057,427 | 78,089,151 | -1.22 % | 5.51 / 4.08 | 5.51 / 4.08 | 1.66 / 0.54 | 1.66 / 0.55 |
| exe | T4 -m1 (`plz:1`) | 81,460,328 | 80,797,862 | -0.81 % | 1.70 / 1.36 | 0.57 / 0.52 | 0.92 / 0.42 | 0.31 / 0.21 |
| exe | T4 -m2 (`plz:3`) | 79,479,124 | 79,128,399 | -0.44 % | 3.14 / 3.08 | 1.08 / 1.03 | 1.25 / 0.53 | 0.49 / 0.28 |
| exe | T4 -m4 $compressed (`plz:3`) | 79,917,714 | 79,477,905 | -0.55 % | **3.08 / 3.25** | **1.02 / 1.07** | 0.85 / 0.44 | 0.36 / 0.21 |
| small | T1 -m1 (`plz:2`) | 4,690,757 | 4,556,561 | -2.86 % | **0.56 / 0.57** | **0.56 / 0.58** | 0.14 / 0.11 | 0.14 / 0.12 |
| small | T1 -m2 (`plz:4`) | 4,299,569 | 4,230,099 | -1.62 % | **0.93 / 1.07** | **0.94 / 1.07** | 0.18 / 0.13 | 0.18 / 0.14 |
| small | T4 -m1 (`plz:1`) | 4,727,630 | 4,649,454 | -1.65 % | 0.71 / 0.66 | 0.48 / 0.47 | 0.19 / 0.14 | 0.10 / 0.09 |
| small | T4 -m2 (`plz:3`) | 4,396,415 | 4,334,506 | -1.41 % | **0.91 / 1.05** | **0.55 / 0.67** | 0.21 / 0.14 | 0.12 / 0.10 |
| small | T4 -m4 $compressed (`plz:3`) | 4,413,401 | 4,332,622 | -1.83 % | **0.85 / 1.11** | **0.53 / 0.68** | 0.18 / 0.13 | 0.11 / 0.09 |
| document | T1 -m1 (`plz:2`) | 41,794,289 | 40,992,605 | -1.92 % | **1.22 / 1.38** | **1.22 / 1.38** | 0.63 / 0.36 | 0.63 / 0.37 |
| document | T1 -m2 (`plz:4`) | 39,949,183 | 38,982,101 | -2.42 % | **3.83 / 4.09** | **3.84 / 4.13** | 1.01 / 0.52 | 1.02 / 0.52 |
| document | T4 -m1 (`plz:1`) | 42,624,097 | 41,534,157 | -2.56 % | 1.49 / 1.45 | 0.55 / 0.54 | 0.80 / 0.45 | 0.25 / 0.20 |
| document | T4 -m2 (`plz:3`) | 40,562,832 | 39,819,202 | -1.83 % | **3.17 / 3.40** | **1.06 / 1.20** | 1.13 / 0.51 | 0.39 / 0.26 |
| document | T4 -m4 $compressed (`plz:3`) | 40,668,877 | 39,665,698 | -2.47 % | **2.83 / 3.38** | **1.06 / 1.11** | 0.82 / 0.43 | 0.29 / 0.19 |
| large | T1 -m1 (`plz:2`) | 79,570,422 | 78,486,251 | -1.36 % | 2.04 / 1.53 | 2.05 / 1.54 | 1.13 / 0.59 | 1.13 / 0.59 |
| large | T1 -m2 (`plz:4`) | 75,655,717 | 74,144,171 | -2.00 % | 7.56 / 7.18 | 7.57 / 7.19 | 1.86 / 0.85 | 1.86 / 0.85 |
| large | T4 -m1 (`plz:1`) | 80,096,432 | 78,656,993 | -1.80 % | 2.30 / 1.80 | 0.75 / 0.68 | 1.41 / 0.74 | 0.47 / 0.26 |
| large | T4 -m2 (`plz:3`) | 76,716,241 | 76,678,508 | -0.05 % | 5.29 / 4.18 | 1.68 / 1.41 | 2.03 / 0.84 | 0.59 / 0.40 |
| large | T4 -m4 $compressed (`plz:3`) | 76,828,425 | 76,710,910 | -0.15 % | 5.09 / 4.18 | 1.56 / 1.34 | 1.40 / 0.74 | 0.45 / 0.27 |
| archive | T1 -m1 (`plz:2`) | 67,646,429 | 66,793,769 | -1.26 % | 1.75 / 1.28 | 1.76 / 1.28 | 0.95 / 0.38 | 0.96 / 0.39 |
| archive | T1 -m2 (`plz:4`) | 65,912,043 | 65,193,266 | -1.09 % | 5.03 / 3.99 | 5.03 / 3.99 | 1.47 / 0.57 | 1.47 / 0.58 |
| archive | T4 -m1 (`plz:1`) | 68,341,150 | 67,306,699 | -1.51 % | 1.86 / 1.46 | 0.65 / 0.50 | 1.03 / 0.51 | 0.41 / 0.20 |
| archive | T4 -m2 (`plz:3`) | 66,314,139 | 65,807,208 | -0.76 % | 3.62 / 3.35 | 1.31 / 1.08 | 1.44 / 0.56 | 0.51 / 0.27 |
| archive | T4 -m4 $compressed (`plz:3`) | 66,531,275 | 65,724,543 | -1.21 % | 3.87 / 3.33 | 1.23 / 1.11 | 1.07 / 0.52 | 0.38 / 0.23 |
| image | T1 -m1 (`plz:2`) | 58,746,853 | 58,492,680 | -0.43 % | 1.68 / 1.34 | 1.68 / 1.35 | 0.89 / 0.40 | 0.89 / 0.41 |
| image | T1 -m2 (`plz:4`) | 56,861,907 | 56,128,471 | -1.29 % | **5.28 / 5.36** | **5.29 / 5.36** | 1.34 / 0.61 | 1.35 / 0.62 |
| image | T4 -m1 (`plz:1`) | 59,545,860 | 58,890,014 | -1.10 % | 1.79 / 1.56 | 0.63 / 0.56 | 1.10 / 0.56 | 0.35 / 0.23 |
| image | T4 -m2 (`plz:3`) | 57,422,990 | 57,391,953 | -0.05 % | **3.99 / 4.19** | **1.23 / 1.33** | 1.34 / 0.61 | 0.42 / 0.26 |
| image | T4 -m4 $compressed (`plz:3`) | 57,249,674 | 56,924,299 | -0.57 % | 3.80 / 3.75 | 1.27 / 1.26 | 1.12 / 0.55 | 0.36 / 0.20 |
| audio | T1 -m1 (`plz:2`) | 83,827,418 | 83,791,609 | -0.04 % | 1.92 / 1.26 | 1.93 / 1.26 | 1.03 / 0.39 | 1.03 / 0.40 |
| audio | T1 -m2 (`plz:4`) | 82,524,997 | 81,757,047 | -0.93 % | 6.16 / 4.84 | 6.17 / 4.85 | 1.69 / 0.64 | 1.69 / 0.64 |
| audio | T4 -m1 (`plz:1`) | 84,173,578 | 83,928,132 | -0.29 % | 2.08 / 1.50 | 0.69 / 0.60 | 1.12 / 0.55 | 0.35 / 0.23 |
| audio | T4 -m2 (`plz:3`) | 82,868,979 | 83,044,680 | **+0.21 %** | 4.71 / 3.94 | 1.46 / 1.43 | 1.73 / 0.62 | 0.54 / 0.30 |
| audio | T4 -m4 $compressed (`plz:3`) | 83,042,167 | 83,032,508 | -0.01 % | 4.98 / 3.85 | 1.54 / 1.45 | 1.21 / 0.53 | 0.34 / 0.21 |
| video | T1 -m1 (`plz:2`) | 64,745,387 | 64,409,731 | -0.52 % | 1.79 / 1.55 | 1.79 / 1.56 | 0.95 / 0.44 | 0.96 / 0.45 |
| video | T1 -m2 (`plz:4`) | 62,640,174 | 61,788,517 | -1.36 % | **5.01 / 6.10** | **5.03 / 6.11** | 1.33 / 0.62 | 1.34 / 0.63 |
| video | T4 -m1 (`plz:1`) | 66,763,444 | 65,451,648 | -1.96 % | 1.87 / 1.76 | **0.62 / 0.66** | 1.16 / 0.62 | 0.35 / 0.23 |
| video | T4 -m2 (`plz:3`) | 63,257,329 | 62,837,475 | -0.66 % | **4.40 / 5.20** | **1.34 / 1.64** | 1.60 / 0.68 | 0.46 / 0.27 |
| video | T4 -m4 $compressed (`plz:3`) | 63,609,571 | 63,056,869 | -0.87 % | **4.26 / 5.27** | **1.20 / 1.56** | 1.13 / 0.60 | 0.35 / 0.19 |
| font | T1 -m1 (`plz:2`) | 7,672,347 | 7,577,104 | -1.24 % | 0.32 / 0.32 | 0.33 / 0.32 | 0.13 / 0.09 | 0.14 / 0.10 |
| font | T1 -m2 (`plz:4`) | 6,929,099 | 6,717,691 | -3.05 % | **0.75 / 0.91** | **0.76 / 0.92** | 0.19 / 0.11 | 0.19 / 0.12 |
| font | T4 -m1 (`plz:1`) | 7,745,276 | 7,672,837 | -0.94 % | **0.44 / 0.45** | **0.19 / 0.20** | 0.21 / 0.13 | 0.08 / 0.06 |
| font | T4 -m2 (`plz:3`) | 7,253,698 | 7,085,828 | -2.31 % | **0.86 / 1.05** | **0.34 / 0.39** | 0.27 / 0.14 | 0.11 / 0.07 |
| font | T4 -m4 $compressed (`plz:3`) | 7,289,331 | 7,082,817 | -2.83 % | **0.78 / 1.00** | **0.29 / 0.37** | 0.21 / 0.12 | 0.10 / 0.06 |


Result: **decompression wins every cell** (CPU and wall, typically 2–5× faster); **size wins
every cell but one** (`audio`, `-m2` 4 threads: +0.21 %); **compression time still loses 24 of
60 cells**, almost all at the lazy levels on text-like and small-file data: `plz:3` against
`tor:5`/`tor:c3` inside `4x4` (text ×1.37–1.51, small ×1.15–1.31, font ×1.22–1.28, video
×1.18–1.24, document ×1.07–1.19, image ×1.05, exe `$compressed` ×1.06, TILIN `-m2` ×1.00–1.02
wall) and `plz:4` against `tor:6` with one thread (text ×1.34, font/video ×1.21, small ×1.15,
document ×1.07, image ×1.02); greedy levels lose only on text 4 threads (×1.06–1.10), font 4
threads (×1.02–1.05), video wall (×1.06) and small/document 1 thread (×1.02–1.13). Where
`plz` is slower it is also 0.6–5 % smaller. The lazy parser is memory-latency bound on these
data (hash-row and candidate loads); the per-position evaluation in assembler gained only ~5 %.
Timing noise on the shared machine was ±10–50 % between runs even pinned, so cells within
~5 % are not significant.

**Third round (2026-11-18): compression time.** Same goal (every cell against `tor`); this round
went after the 24 compression-time cells and the `audio` size cell. Encoder changes only (the
stream format and the decoder are unchanged):

- *Engine cache in `4x4`.* The cache that hands each `4x4` block an engine with its tables
  already allocated never matched at the row levels (its short-table check still assumed only
  the one-way levels had one), so every block of `plz:3`/`plz:4` inside `4x4` allocated and
  zeroed fresh tables (8–16 MB) and ran on cold memory. Fixed; on top of that a table is only
  cleared between streams if the previous stream wrote it (a text-only block never touches the
  rows, a binary one never touches the text table). This alone took most of the `4x4` binary
  cells (video, image, font, small) from ×1.0–1.2 to ×0.75–0.97.
- *Text table at the row levels.* Text blocks (the round-2 classifier) of levels 3–4 no longer
  use the 4/8-way rows: they use a direct table of 2-entry buckets (6-byte hash; 2^18 buckets
  at level 3, 2^20 at level 4, scaled with the window like the rows) with the one-way lazy
  evaluation, and insert only part of each match (level 3: the first and last 3 positions,
  level 4: the last 2). Binary blocks keep the rows. Options `t<bits>`, `g<entries>`,
  `e<insertions>`.
- *Greedy levels.* On text blocks levels 1–2 hash into only 2^14 / 2^17 entries of their table
  (fresher and cache-resident: smaller output too), and they only try block splits on binary
  blocks (`q2`), where the split pays for its estimate. Level 4's short table is 2^12.
- *Assembler and parser.* The prefetch of the entry 8 positions ahead moved into
  `PlzEval1`/`PlzEvalRows`; the lazy parser calls them directly (no Pascal wrapper per
  position) and copies the rep offsets once per match instead of once per position.
- `v<n>` (shorter hash on binary blocks, off by default) now skips near-random blocks.
- Memory-to-memory (`4x4`) the window shrinks to the block (power of 2, ≥ 64 KB), so small
  blocks get small tables; `tests/plz.sh` checks that this equals streaming with that window.

Measured again (2026-11-18, all 60 cells): each cell is 3 interleaved rounds (`tor` then `plz`,
each run pinned with `taskset` to the idlest physical cores of the shared 64-core machine,
`nice -n10`), best of 3 per side; CPU = user + system (the decision criterion), wall shown too;
bold = `plz` worse. Logs: `/mnt/IA_LAB/agentes/PArc/lz-new/logs/final3/`.

| data | cell | tor size | plz size | Δ size | comp CPU tor/plz | comp wall tor/plz | dec CPU tor/plz | dec wall tor/plz |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| tilin512 | T1 -m1 (`plz:2`) | 284,628,505 | 281,361,777 | -1.15 % | 7.33 / 5.20 | 7.40 / 5.22 | 4.10 / 1.82 | 4.10 / 1.82 |
| tilin512 | T1 -m2 (`plz:4`) | 270,565,702 | 266,290,682 | -1.58 % | 23.02 / 16.77 | 23.03 / 16.78 | 5.79 / 2.23 | 5.80 / 2.23 |
| tilin512 | T4 -m1 (`plz:1`) | 289,006,803 | 285,199,896 | -1.32 % | 7.00 / 6.04 | 2.10 / 1.91 | 4.56 / 2.10 | 1.33 / 0.69 |
| tilin512 | T4 -m2 (`plz:3`) | 274,584,657 | 269,518,058 | -1.85 % | 17.53 / 13.65 | 4.87 / 3.95 | 6.71 / 2.55 | 1.90 / 0.97 |
| tilin512 | T4 -m4 $compressed (`plz:3`) | 276,647,421 | 271,192,397 | -1.97 % | 18.05 / 13.20 | 5.13 / 3.93 | 4.42 / 2.15 | 1.29 / 0.68 |
| TILIN | T1 -m1 (`plz:2`) | 1,078,738,066 | 1,071,462,943 | -0.67 % | 22.25 / 13.47 | 22.26 / 13.48 | 12.85 / 3.74 | 12.85 / 3.75 |
| TILIN | T1 -m2 (`plz:4`) | 1,055,483,194 | 1,046,650,199 | -0.84 % | 68.92 / 36.99 | 69.29 / 37.30 | 20.08 / 5.43 | 20.09 / 5.43 |
| TILIN | T4 -m1 (`plz:1`) | 1,091,769,634 | 1,087,588,940 | -0.38 % | 18.62 / 17.40 | 5.22 / 5.03 | 9.22 / 5.05 | 3.12 / 2.14 |
| TILIN | T4 -m2 (`plz:3`) | 1,071,314,861 | 1,065,878,213 | -0.51 % | 33.71 / 27.62 | 9.67 / 7.60 | 12.50 / 6.18 | 4.41 / 3.03 |
| TILIN | T4 -m4 $compressed (`plz:3`) | 1,072,970,322 | 1,066,969,400 | -0.56 % | 35.84 / 25.86 | 9.80 / 7.15 | 9.77 / 5.33 | 3.38 / 2.21 |
| text | T1 -m1 (`plz:2`) | 32,081,028 | 31,342,044 | -2.30 % | 1.19 / 1.14 | 1.20 / 1.16 | 0.53 / 0.35 | 0.54 / 0.36 |
| text | T1 -m2 (`plz:4`) | 29,429,591 | 28,750,178 | -2.31 % | 3.31 / 3.17 | 3.32 / 3.18 | 0.76 / 0.55 | 0.76 / 0.56 |
| text | T4 -m1 (`plz:1`) | 32,211,864 | 31,403,873 | -2.51 % | 1.51 / 1.35 | 0.62 / 0.57 | 0.72 / 0.45 | 0.24 / 0.19 |
| text | T4 -m2 (`plz:3`) | 30,061,663 | 28,583,701 | -4.92 % | **2.74 / 2.76** | 0.97 / 0.95 | 0.96 / 0.57 | 0.35 / 0.26 |
| text | T4 -m4 $compressed (`plz:3`) | 30,277,365 | 28,671,662 | -5.30 % | **2.46 / 2.61** | **0.89 / 0.95** | 0.62 / 0.46 | 0.23 / 0.20 |
| exe | T1 -m1 (`plz:2`) | 80,573,341 | 79,859,654 | -0.89 % | 1.65 / 1.28 | 1.66 / 1.28 | 0.94 / 0.33 | 0.95 / 0.34 |
| exe | T1 -m2 (`plz:4`) | 79,057,427 | 78,126,172 | -1.18 % | 5.88 / 3.50 | 5.89 / 3.51 | 1.55 / 0.50 | 1.56 / 0.51 |
| exe | T4 -m1 (`plz:1`) | 81,460,328 | 80,800,220 | -0.81 % | 1.66 / 1.38 | 0.56 / 0.52 | 0.86 / 0.41 | 0.28 / 0.20 |
| exe | T4 -m2 (`plz:3`) | 79,479,124 | 79,139,051 | -0.43 % | 3.16 / 2.36 | 1.10 / 0.83 | 1.11 / 0.50 | 0.45 / 0.27 |
| exe | T4 -m4 $compressed (`plz:3`) | 79,917,714 | 79,491,377 | -0.53 % | 2.91 / 2.38 | 0.98 / 0.84 | 0.80 / 0.43 | 0.33 / 0.20 |
| small | T1 -m1 (`plz:2`) | 4,690,757 | 4,567,954 | -2.62 % | 0.52 / 0.52 | 0.53 / 0.52 | 0.12 / 0.10 | 0.12 / 0.11 |
| small | T1 -m2 (`plz:4`) | 4,299,569 | 4,277,000 | -0.52 % | **0.78 / 0.82** | **0.79 / 0.83** | 0.17 / 0.12 | 0.18 / 0.13 |
| small | T4 -m1 (`plz:1`) | 4,727,630 | 4,671,896 | -1.18 % | 0.67 / 0.63 | 0.46 / 0.46 | 0.17 / 0.14 | 0.10 / 0.09 |
| small | T4 -m2 (`plz:3`) | 4,396,415 | 4,367,284 | -0.66 % | 0.90 / 0.86 | **0.58 / 0.61** | 0.21 / 0.14 | 0.12 / 0.10 |
| small | T4 -m4 $compressed (`plz:3`) | 4,413,401 | 4,366,223 | -1.07 % | 0.90 / 0.87 | **0.56 / 0.57** | 0.16 / 0.13 | 0.11 / 0.09 |
| document | T1 -m1 (`plz:2`) | 41,794,289 | 41,066,767 | -1.74 % | 1.30 / 1.08 | 1.31 / 1.09 | 0.62 / 0.30 | 0.62 / 0.32 |
| document | T1 -m2 (`plz:4`) | 39,949,183 | 39,096,238 | -2.14 % | 3.57 / 3.08 | 3.58 / 3.09 | 0.92 / 0.47 | 0.92 / 0.48 |
| document | T4 -m1 (`plz:1`) | 42,624,097 | 41,624,430 | -2.35 % | 1.43 / 1.37 | 0.56 / 0.52 | 0.76 / 0.44 | 0.25 / 0.19 |
| document | T4 -m2 (`plz:3`) | 40,562,832 | 39,825,904 | -1.82 % | 3.08 / 2.83 | 1.01 / 1.01 | 1.06 / 0.48 | 0.34 / 0.25 |
| document | T4 -m4 $compressed (`plz:3`) | 40,668,877 | 39,677,170 | -2.44 % | 2.69 / 2.54 | 0.90 / 0.88 | 0.79 / 0.44 | 0.27 / 0.20 |
| large | T1 -m1 (`plz:2`) | 79,570,422 | 78,645,219 | -1.16 % | 2.05 / 1.40 | 2.07 / 1.41 | 1.11 / 0.52 | 1.11 / 0.52 |
| large | T1 -m2 (`plz:4`) | 75,655,717 | 74,522,634 | -1.50 % | 7.50 / 4.82 | 7.51 / 4.83 | 1.74 / 0.88 | 1.75 / 0.89 |
| large | T4 -m1 (`plz:1`) | 80,096,432 | 79,073,471 | -1.28 % | 2.23 / 1.65 | 0.71 / 0.58 | 1.35 / 0.68 | 0.43 / 0.27 |
| large | T4 -m2 (`plz:3`) | 76,716,241 | 76,594,564 | -0.16 % | 5.36 / 3.28 | 1.66 / 1.09 | 1.94 / 0.79 | 0.57 / 0.34 |
| large | T4 -m4 $compressed (`plz:3`) | 76,828,425 | 76,624,711 | -0.27 % | 5.09 / 3.22 | 1.58 / 1.02 | 1.35 / 0.70 | 0.38 / 0.26 |
| archive | T1 -m1 (`plz:2`) | 67,646,429 | 66,818,361 | -1.22 % | 1.61 / 1.09 | 1.62 / 1.10 | 0.86 / 0.37 | 0.87 / 0.37 |
| archive | T1 -m2 (`plz:4`) | 65,912,043 | 65,317,774 | -0.90 % | 5.10 / 3.29 | 5.11 / 3.30 | 1.39 / 0.55 | 1.39 / 0.55 |
| archive | T4 -m1 (`plz:1`) | 68,341,150 | 67,341,675 | -1.46 % | 1.77 / 1.46 | 0.60 / 0.49 | 1.02 / 0.50 | 0.37 / 0.21 |
| archive | T4 -m2 (`plz:3`) | 66,314,139 | 65,825,846 | -0.74 % | 3.81 / 2.64 | 1.23 / 0.83 | 1.40 / 0.57 | 0.50 / 0.30 |
| archive | T4 -m4 $compressed (`plz:3`) | 66,531,275 | 65,761,537 | -1.16 % | 3.62 / 2.97 | 1.19 / 0.98 | 1.04 / 0.51 | 0.35 / 0.20 |
| image | T1 -m1 (`plz:2`) | 58,746,853 | 58,492,680 | -0.43 % | 1.55 / 1.23 | 1.56 / 1.24 | 0.80 / 0.38 | 0.80 / 0.39 |
| image | T1 -m2 (`plz:4`) | 56,861,907 | 56,353,441 | -0.89 % | 4.99 / 3.76 | 5.05 / 3.91 | 1.22 / 0.59 | 1.23 / 0.59 |
| image | T4 -m1 (`plz:1`) | 59,545,860 | 58,890,108 | -1.10 % | 1.70 / 1.53 | 0.61 / 0.53 | 0.96 / 0.52 | 0.32 / 0.19 |
| image | T4 -m2 (`plz:3`) | 57,422,990 | 57,392,168 | -0.05 % | 3.97 / 2.97 | 1.27 / 0.99 | 1.35 / 0.57 | 0.44 / 0.25 |
| image | T4 -m4 $compressed (`plz:3`) | 57,249,674 | 56,924,478 | -0.57 % | 3.98 / 3.13 | 1.32 / 1.00 | 0.99 / 0.55 | 0.32 / 0.21 |
| audio | T1 -m1 (`plz:2`) | 83,827,418 | 83,791,609 | -0.04 % | 1.97 / 1.16 | 2.02 / 1.16 | 1.05 / 0.37 | 1.05 / 0.38 |
| audio | T1 -m2 (`plz:4`) | 82,524,997 | 81,816,431 | -0.86 % | 6.56 / 4.15 | 6.73 / 4.16 | 1.68 / 0.59 | 1.69 / 0.60 |
| audio | T4 -m1 (`plz:1`) | 84,173,578 | 83,929,774 | -0.29 % | 2.10 / 1.50 | 0.72 / 0.54 | 1.09 / 0.55 | 0.35 / 0.21 |
| audio | T4 -m2 (`plz:3`) | 82,868,979 | 83,051,399 | **+0.22 %** | 4.52 / 2.89 | 1.37 / 1.07 | 1.65 / 0.63 | 0.48 / 0.28 |
| audio | T4 -m4 $compressed (`plz:3`) | 83,042,167 | 83,039,775 | -0.00 % | 4.62 / 2.76 | 1.41 / 1.02 | 1.13 / 0.53 | 0.36 / 0.20 |
| video | T1 -m1 (`plz:2`) | 64,745,387 | 64,409,731 | -0.52 % | 1.74 / 1.44 | 1.75 / 1.44 | 0.93 / 0.40 | 0.93 / 0.40 |
| video | T1 -m2 (`plz:4`) | 62,640,174 | 62,072,646 | -0.91 % | 5.83 / 4.67 | 5.83 / 4.68 | 1.37 / 0.65 | 1.38 / 0.65 |
| video | T4 -m1 (`plz:1`) | 66,763,444 | 65,453,930 | -1.96 % | 1.83 / 1.81 | **0.58 / 0.61** | 1.12 / 0.58 | 0.32 / 0.20 |
| video | T4 -m2 (`plz:3`) | 63,257,329 | 62,837,815 | -0.66 % | 4.15 / 4.14 | 1.27 / 1.22 | 1.63 / 0.64 | 0.48 / 0.25 |
| video | T4 -m4 $compressed (`plz:3`) | 63,609,571 | 63,070,779 | -0.85 % | 4.78 / 4.20 | 1.39 / 1.32 | 1.17 / 0.62 | 0.33 / 0.20 |
| font | T1 -m1 (`plz:2`) | 7,672,347 | 7,591,492 | -1.05 % | 0.32 / 0.29 | 0.33 / 0.29 | 0.14 / 0.09 | 0.14 / 0.10 |
| font | T1 -m2 (`plz:4`) | 6,929,099 | 6,736,068 | -2.79 % | 0.79 / 0.76 | 0.79 / 0.76 | 0.20 / 0.11 | 0.20 / 0.12 |
| font | T4 -m1 (`plz:1`) | 7,745,276 | 7,712,329 | -0.43 % | **0.44 / 0.45** | 0.19 / 0.19 | 0.21 / 0.13 | 0.09 / 0.06 |
| font | T4 -m2 (`plz:3`) | 7,253,698 | 7,112,475 | -1.95 % | 0.85 / 0.77 | 0.33 / 0.33 | 0.24 / 0.15 | 0.10 / 0.08 |
| font | T4 -m4 $compressed (`plz:3`) | 7,289,331 | 7,115,927 | -2.38 % | 0.75 / 0.73 | **0.28 / 0.30** | 0.19 / 0.13 | 0.07 / 0.06 |

Result: **decompression wins every cell** (CPU, 1.2–3.7× faster). **Size wins 59 of 60**:
`audio` `-m2` 4 threads is still +0.22 % (`-m4 $compressed` on the same data is −0.00 %).
**Compression CPU wins 56 of 60** (was 36): the remaining losses are `text` inside `4x4`
(`plz:3` against `tor:c3` ×1.06, against `tor:5` ×1.01; both 5 % smaller), `small` `-m2` one
thread (`plz:4` ×1.05) and `font` `-m1` 4 threads (`plz:1` ×1.02); the last two won in the
previous runs of this round (×0.95–0.97), so they are within the noise (±5 % on this shared
machine even pinned and interleaved). A few 4-thread cells lose on wall time only, within the
same noise.

What is left and why:

- *`audio` size.* Per file, `plz` loses on 16-bit PCM of low amplitude: on `example.wav` (16-bit
  stereo, samples near zero) `tor:3` is 5 % smaller than even `plz:7`, and its 16-bit symbol
  entropy is 15 % below its byte entropy; the sizes say `tor` gets 2-byte structure that `plz`
  cannot express (minimum match 3, one literal table per block). `v4` (4-byte hash on binary
  blocks) closes it to +0.00…+0.02 % but costs ×1.05–1.2 time on video/image/document, so it
  stays off. A real fix needs a format change (2-byte rep matches or literal contexts).
- *`text` inside `4x4`.* With one thread `plz:3` already beats `tor:c3` on the same chain
  (1.80 s against 1.96 s of CPU); with 4 threads `plz` grows more (+0.6 s against +0.3 s). The
  profile is the same at 1 and 4 threads (half the time in the evaluation loads of the text
  table and the window), so the extra cost is memory contention between the 4 workers, not
  code; a 2^17 table (`t17`) did not change it.

**Tornado removed (2026-11-20).** The presets switched to the round-3 cells (`1binary = plz:2`,
`2binary = plz:4`, `ex1binary = xplz:1`, `ex2binary = xplz:3`, `4$compressed = 4rep + eplz:3`,
`4x$compressed = eplz:3:8m`, `bmpfastest = mm:d1 + 1binary`, `3xt = dict:64m:80% + plz:5:96m`;
`xplz = 4x4:plz`, `eplz = (|x)plz`) and Tornado was deleted: encoder (Pascal and FreeArc's C++
with its bridge), decoder, `reference/.../Tornado`, the C++ steps of `build.sh` and the tor
tests (~16,900 lines). The build needs only FPC; Linux binaries link libc/libm, the `.exe`
only Windows system DLLs. `tor`/`xtor`/`etor` given with `-m` fail (exit 3, hint to use
`plz`); `tor` blocks of older archives fail with "extract this archive with PArc 0.0.5".

Sanity check of the whole presets, old `main` (8ab0ae4, `tor`) against the new build, with the
groups (`$compressed`, `$text`...) as in real use. Data: `mix` = the `small`, `font`, `document`
and `exe` sets (256 MB, 7,201 files) and `TILIN.tar`. Levels whose method changed, measured one
at a time on a quiet machine (load ~5), old/new interleaved, best of 3 (mix) or 2 (TILIN),
pinned to idle physical cores; CPU = user + system. Logs:
`/mnt/IA_LAB/agentes/PArc/notor/logs/bench2.csv`.

| data | cell | old size | new size | Δ | comp wall old/new | comp CPU old/new | dec wall old/new | dec CPU old/new |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| mix | T1 -m1 | 141,666,657 | 139,924,545 | -1.23 % | 4.12 / 3.31 | 4.12 / 3.28 | 2.02 / 0.82 | 2.02 / 0.81 |
| mix | T1 -m2 | 130,671,916 | 128,831,831 | -1.41 % | 8.94 / 8.13 | 8.88 / 7.97 | 3.03 / 1.63 | 3.01 / 1.62 |
| mix | T1 -m3 | 126,845,173 | 126,577,194 | -0.21 % | 18.52 / 18.34 | 18.48 / 18.29 | 5.25 / 4.68 | 5.23 / 4.67 |
| mix | T1 -m4 | 124,822,486 | 124,579,537 | -0.19 % | 31.05 / 30.30 | 31.02 / 30.22 | 5.40 / 4.49 | 5.38 / 4.49 |
| mix | T4 -m1 | 143,240,238 | 141,452,892 | -1.25 % | 1.36 / 1.22 | 3.78 / 3.32 | 0.58 / 0.42 | 1.82 / 0.99 |
| mix | T4 -m2 | 132,297,063 | 130,761,945 | -1.16 % | 2.63 / 2.56 | 7.86 / 7.30 | 0.83 / 0.55 | 2.74 / 1.81 |
| mix | T4 -m3 | 126,471,835 | 126,434,015 | -0.03 % | 7.94 / 8.02 | 25.67 / 25.80 | 1.43 / 1.39 | 4.44 / 4.34 |
| mix | T4 -m4 | 125,937,969 | **125,956,437** | **+0.01 %** | 10.59 / 10.72 | 29.13 / 29.17 | 1.77 / 1.79 | 5.03 / 4.87 |
| TILIN | T1 -m1 | 1,078,738,066 | 1,071,462,943 | -0.67 % | 22.13 / 13.77 | 22.09 / 13.49 | 13.23 / 3.81 | 13.20 / 3.80 |
| TILIN | T1 -m2 | 1,055,483,194 | 1,046,650,199 | -0.84 % | 69.37 / 37.60 | 69.21 / 37.53 | 21.05 / 5.29 | 21.01 / 5.27 |
| TILIN | T4 -m1 | 1,091,769,634 | 1,087,588,940 | -0.38 % | 5.55 / 5.05 | 19.49 / 16.65 | 3.32 / 2.28 | 9.58 / 5.29 |
| TILIN | T4 -m2 | 1,071,314,861 | 1,065,878,213 | -0.51 % | 10.07 / 8.10 | 36.00 / 28.42 | 4.43 / 3.14 | 13.27 / 6.24 |

`-m3`/`-m4` change only on `$compressed` files (`document` has some): the sizes there move by
±0.2 % and the times are within noise (mix T4 `-m4` is +18 KB, +0.01 %, from `4x4:plz:3`
against `4x4:tor:c3` on those files). `-m5`…`-m9` (and TILIN `-m3`…`-m9`, a single `.tar`
with no `$compressed` file) use exactly the same methods as before (`--print-config` differs
only in the lines above) and gave byte-identical sizes in a first, parallel run (mix T1/T4
`-m1`…`-m9`, TILIN T4 `-m1`…`-m9`; its times were too noisy to report: load ~30).

**Measurements** (2026-11-17, one `parc` binary containing both codecs; a 64-core Xeon
E5-2697A v4 shared with other jobs, `nice -n10`, best of 2 runs; CPU = user + system of the
process, so the 4-thread rows show total work; decompression = `parc t`). Data:
`tilin_512m.tar` (first 512 MB of TILIN), `TILIN.tar` (1.876 GB), and the broad-sweep sets
(directories of 17–150 MB). Methods are the chains the presets use today for `-m1`/`-m2` with
`PARC_THREADS=1` (`tor:4:8mb:h4m`, `tor:6`) and ≥ 2 (`4x4:tor:3:8mb`, `4x4:tor:5`) and the
`$compressed` chain of `-m4` (`4x4:tor:c3`), each against its `plz` level. Logs and CSV:
`/mnt/IA_LAB/agentes/PArc/lz-new/logs/final/`.

**Codec alone** (`tests/plz_bench.lpr`: the stage in memory, one thread, best of 2; CPU = process CPU; sizes in MB)

| file | tor | size | comp CPU | dec CPU | plz | size | Δ | comp CPU | dec CPU |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|
| tilin_512m.tar | `tor:3:8mb` | 299.40 | 4.756 | 3.878 | `plz:1` | 288.83 | -3.53 % | 4.385 | 1.639 |
| tilin_512m.tar | `tor:4:8mb:h4m` | 290.26 | 6.556 | 4.171 | `plz:2` | 284.87 | -1.85 % | 4.695 | 1.753 |
| tilin_512m.tar | `tor:5` | 278.61 | 12.042 | 5.411 | `plz:3` | 272.70 | -2.12 % | 11.574 | 1.805 |
| tilin_512m.tar | `tor:c3` | 278.80 | 12.952 | 3.966 | `plz:3` | 272.70 | -2.19 % | 11.574 | 1.805 |
| tilin_512m.tar | `tor:6` | 273.77 | 19.330 | 5.592 | `plz:4` | 269.94 | -1.40 % | 11.808 | 1.643 |
| tilin_512m.tar | `tor:7:96m:h64m` | 269.16 | 53.103 | 5.025 | `plz:5:96m` | 267.52 | -0.61 % | 16.224 | 1.595 |
| set_exe.tar | `tor:3:8mb` | 84.94 | 1.205 | 0.936 | `plz:1` | 83.02 | -2.26 % | 0.807 | 0.275 |
| set_exe.tar | `tor:4:8mb:h4m` | 83.10 | 1.410 | 0.951 | `plz:2` | 82.22 | -1.06 % | 0.854 | 0.272 |
| set_exe.tar | `tor:5` | 81.89 | 3.021 | 1.390 | `plz:3` | 80.92 | -1.18 % | 1.872 | 0.290 |
| set_exe.tar | `tor:c3` | 81.92 | 3.058 | 0.915 | `plz:3` | 80.92 | -1.22 % | 1.872 | 0.290 |
| set_exe.tar | `tor:6` | 81.32 | 4.095 | 1.463 | `plz:4` | 80.11 | -1.49 % | 2.186 | 0.359 |
| set_exe.tar | `tor:7:96m:h64m` | 80.86 | 12.821 | 1.368 | `plz:5:96m` | 78.68 | -2.69 % | 2.858 | 0.370 |
| set_text.tar | `tor:3:8mb` | 32.45 | 0.659 | 0.476 | `plz:1` | 32.09 | -1.10 % | 0.877 | 0.314 |
| set_text.tar | `tor:4:8mb:h4m` | 32.25 | 0.785 | 0.454 | `plz:2` | 31.26 | -3.09 % | 0.885 | 0.296 |
| set_text.tar | `tor:5` | 30.13 | 1.603 | 0.601 | `plz:3` | 28.74 | -4.63 % | 2.382 | 0.307 |
| set_text.tar | `tor:c3` | 30.32 | 1.601 | 0.449 | `plz:3` | 28.74 | -5.21 % | 2.382 | 0.307 |
| set_text.tar | `tor:6` | 29.62 | 2.157 | 0.629 | `plz:4` | 28.41 | -4.11 % | 2.893 | 0.406 |
| set_text.tar | `tor:7:96m:h64m` | 28.62 | 6.117 | 0.554 | `plz:5:96m` | 27.82 | -2.81 % | 4.303 | 0.383 |
| set_document.tar | `tor:3:8mb` | 52.00 | 0.892 | 0.653 | `plz:1` | 49.57 | -4.68 % | 0.792 | 0.274 |
| set_document.tar | `tor:4:8mb:h4m` | 49.79 | 1.061 | 0.622 | `plz:2` | 49.00 | -1.59 % | 0.853 | 0.269 |
| set_document.tar | `tor:5` | 48.28 | 2.204 | 0.884 | `plz:3` | 47.28 | -2.07 % | 1.939 | 0.279 |
| set_document.tar | `tor:c3` | 48.48 | 2.069 | 0.590 | `plz:3` | 47.28 | -2.47 % | 1.939 | 0.279 |
| set_document.tar | `tor:6` | 47.90 | 2.740 | 0.912 | `plz:4` | 47.06 | -1.77 % | 2.544 | 0.390 |
| set_document.tar | `tor:7:96m:h64m` | 47.32 | 8.177 | 0.854 | `plz:5:96m` | 46.82 | -1.05 % | 2.879 | 0.340 |
| set_small.tar | `tor:3:8mb` | 4.82 | 0.133 | 0.073 | `plz:1` | 4.75 | -1.44 % | 0.165 | 0.068 |
| set_small.tar | `tor:4:8mb:h4m` | 4.76 | 0.180 | 0.083 | `plz:2` | 4.71 | -0.96 % | 0.192 | 0.075 |
| set_small.tar | `tor:5` | 4.43 | 0.306 | 0.105 | `plz:3` | 4.37 | -1.40 % | 0.390 | 0.073 |
| set_small.tar | `tor:c3` | 4.45 | 0.307 | 0.083 | `plz:3` | 4.37 | -1.77 % | 0.390 | 0.073 |
| set_small.tar | `tor:6` | 4.38 | 0.388 | 0.099 | `plz:4` | 4.33 | -1.19 % | 0.482 | 0.076 |
| set_small.tar | `tor:7:96m:h64m` | 4.29 | 0.990 | 0.101 | `plz:5:96m` | 4.28 | -0.09 % | 0.715 | 0.087 |
| set_large.tar | `tor:3:8mb` | 80.91 | 1.264 | 0.970 | `plz:1` | 79.99 | -1.15 % | 1.153 | 0.445 |
| set_large.tar | `tor:4:8mb:h4m` | 80.17 | 1.730 | 0.981 | `plz:2` | 78.60 | -1.96 % | 1.184 | 0.401 |
| set_large.tar | `tor:5` | 76.93 | 3.513 | 1.398 | `plz:3` | 76.61 | -0.42 % | 2.700 | 0.421 |
| set_large.tar | `tor:c3` | 76.97 | 3.911 | 1.072 | `plz:3` | 76.61 | -0.47 % | 2.700 | 0.421 |
| set_large.tar | `tor:6` | 76.16 | 4.962 | 1.406 | `plz:4` | 76.15 | -0.01 % | 3.320 | 0.526 |
| set_large.tar | `tor:7:96m:h64m` | 74.60 | 13.826 | 1.402 | `plz:5:96m` | 75.60 | +1.34 % | 5.277 | 0.530 |
| set_archive.tar | `tor:3:8mb` | 68.71 | 1.173 | 0.810 | `plz:1` | 67.52 | -1.73 % | 0.734 | 0.291 |
| set_archive.tar | `tor:4:8mb:h4m` | 67.74 | 1.223 | 0.767 | `plz:2` | 67.13 | -0.90 % | 0.805 | 0.288 |
| set_archive.tar | `tor:5` | 66.33 | 2.698 | 1.165 | `plz:3` | 65.80 | -0.79 % | 1.773 | 0.305 |
| set_archive.tar | `tor:c3` | 66.61 | 2.649 | 0.780 | `plz:3` | 65.80 | -1.21 % | 1.773 | 0.305 |
| set_archive.tar | `tor:6` | 66.15 | 3.282 | 1.182 | `plz:4` | 65.64 | -0.76 % | 2.208 | 0.394 |
| set_archive.tar | `tor:7:96m:h64m` | 65.78 | 10.823 | 1.171 | `plz:5:96m` | 65.53 | -0.38 % | 2.809 | 0.381 |
| set_image.tar | `tor:3:8mb` | 61.64 | 0.960 | 0.751 | `plz:1` | 59.28 | -3.84 % | 0.765 | 0.315 |
| set_image.tar | `tor:4:8mb:h4m` | 58.91 | 1.165 | 0.708 | `plz:2` | 59.12 | +0.35 % | 0.850 | 0.304 |
| set_image.tar | `tor:5` | 57.04 | 2.664 | 1.042 | `plz:3` | 57.08 | +0.07 % | 2.189 | 0.330 |
| set_image.tar | `tor:c3` | 57.33 | 2.587 | 0.724 | `plz:3` | 57.08 | -0.42 % | 2.189 | 0.330 |
| set_image.tar | `tor:6` | 56.84 | 3.178 | 1.049 | `plz:4` | 56.84 | +0.00 % | 2.862 | 0.438 |
| set_image.tar | `tor:7:96m:h64m` | 56.27 | 10.257 | 1.085 | `plz:5:96m` | 56.70 | +0.76 % | 3.615 | 0.422 |
| set_audio.tar | `tor:3:8mb` | 84.15 | 1.384 | 0.959 | `plz:1` | 83.97 | -0.21 % | 0.778 | 0.322 |
| set_audio.tar | `tor:4:8mb:h4m` | 83.88 | 1.716 | 0.974 | `plz:2` | 83.95 | +0.09 % | 0.909 | 0.330 |
| set_audio.tar | `tor:5` | 82.86 | 3.610 | 1.435 | `plz:3` | 82.89 | +0.04 % | 2.144 | 0.353 |
| set_audio.tar | `tor:c3` | 83.03 | 4.146 | 1.132 | `plz:3` | 82.89 | -0.17 % | 2.144 | 0.353 |
| set_audio.tar | `tor:6` | 82.74 | 4.789 | 1.572 | `plz:4` | 82.77 | +0.04 % | 2.535 | 0.415 |
| set_audio.tar | `tor:7:96m:h64m` | 82.39 | 13.032 | 1.417 | `plz:5:96m` | 82.64 | +0.30 % | 3.334 | 0.428 |
| set_font.tar | `tor:3:8mb` | 7.89 | 0.187 | 0.109 | `plz:1` | 7.93 | +0.56 % | 0.179 | 0.072 |
| set_font.tar | `tor:4:8mb:h4m` | 7.72 | 0.243 | 0.119 | `plz:2` | 7.80 | +0.97 % | 0.218 | 0.081 |
| set_font.tar | `tor:5` | 7.25 | 0.504 | 0.170 | `plz:3` | 7.29 | +0.54 % | 0.530 | 0.082 |
| set_font.tar | `tor:c3` | 7.31 | 0.410 | 0.111 | `plz:3` | 7.29 | -0.37 % | 0.530 | 0.082 |
| set_font.tar | `tor:6` | 7.17 | 0.664 | 0.168 | `plz:4` | 7.25 | +1.13 % | 0.634 | 0.093 |
| set_font.tar | `tor:7:96m:h64m` | 7.03 | 1.542 | 0.165 | `plz:5:96m` | 7.22 | +2.74 % | 0.865 | 0.089 |

Totals over the files:

| tor | size | comp CPU | dec CPU | plz | size | Δ | comp CPU | dec CPU |
|---|---:|---:|---:|---|---:|---:|---:|---:|
| `tor:3:8mb` | 776.91 | 12.61 | 9.61 | `plz:1` | 756.95 | -2.57 % | 10.64 | 4.01 |
| `tor:4:8mb:h4m` | 758.58 | 16.07 | 9.83 | `plz:2` | 748.66 | -1.31 % | 11.45 | 4.07 |
| `tor:5` | 733.75 | 32.16 | 13.60 | `plz:3` | 723.68 | -1.37 % | 27.49 | 4.24 |
| `tor:c3` | 735.21 | 33.69 | 9.82 | `plz:3` | 723.68 | -1.57 % | 27.49 | 4.24 |
| `tor:6` | 726.06 | 45.58 | 14.07 | `plz:4` | 718.51 | -1.04 % | 31.47 | 4.74 |
| `tor:7:96m:h64m` | 716.31 | 130.69 | 13.14 | `plz:5:96m` | 712.80 | -0.49 % | 42.88 | 4.62 |

**tilin_512m.tar through parc (best of 2 runs, nice -n10)**

| data | thr | tor method | size MB | comp wall/CPU s | dec wall/CPU s | plz method | size MB | Δ size | comp wall/CPU s | dec wall/CPU s |
|---|---:|---|---:|---:|---:|---|---:|---:|---:|---:|
| tilin512 | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 284.63 | 6.91 / 6.75 | 4.04 / 4.04 | `rep:96m:256:c256+plz:2` | 282.24 | -0.84 % | 5.05 / 5.04 | 1.66 / 1.66 |
| tilin512 | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 270.57 | 19.52 / 19.52 | 5.77 / 5.77 | `rep:96m:256:c256+exe+delta+plz:4` | 265.84 | -1.75 % | 14.79 / 14.76 | 2.20 / 2.20 |
| tilin512 | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 289.01 | 1.97 / 7.36 | 1.17 / 4.52 | `rep:96m:256:c256+4x4:plz:1` | 285.73 | -1.13 % | 1.78 / 6.58 | 0.68 / 2.21 |
| tilin512 | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 274.58 | 4.14 / 15.46 | 1.74 / 6.60 | `rep:96m:256:c256+exe+4x4:plz:3` | 270.30 | -1.56 % | 3.57 / 12.69 | 1.00 / 2.53 |
| tilin512 | 4 | `rep:96m+4x4:tor:c3` | 276.65 | 3.98 / 14.73 | 1.25 / 4.54 | `rep:96m+4x4:plz:3` | 272.00 | -1.68 % | 3.34 / 11.96 | 0.65 / 2.15 |
| tilin512 | 1 | `tor:4:8mb:h4m` | 290.26 | 5.34 / 5.33 | 3.60 / 3.58 | `plz:2` | 284.87 | -1.85 % | 3.73 / 3.70 | 1.50 / 1.50 |
| tilin512 | 1 | `tor:6` | 273.77 | 14.89 / 14.85 | 5.10 / 5.07 | `plz:4` | 269.94 | -1.40 % | 10.28 / 10.28 | 1.59 / 1.58 |
| tilin512 | 4 | `4x4:tor:3:8mb` | 299.07 | 1.60 / 6.14 | 1.20 / 4.65 | `4x4:plz:1` | 292.86 | -2.08 % | 1.22 / 4.61 | 0.56 / 2.18 |
| tilin512 | 4 | `4x4:tor:5` | 280.53 | 3.76 / 13.90 | 1.63 / 6.17 | `4x4:plz:3` | 275.44 | -1.82 % | 3.07 / 10.76 | 0.55 / 2.05 |

**TILIN.tar through parc**

| data | thr | tor method | size MB | comp wall/CPU s | dec wall/CPU s | plz method | size MB | Δ size | comp wall/CPU s | dec wall/CPU s |
|---|---:|---|---:|---:|---:|---|---:|---:|---:|---:|
| TILIN | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 1,078.74 | 20.76 / 20.75 | 12.51 / 12.50 | `rep:96m:256:c256+plz:2` | 1,073.91 | -0.45 % | 13.18 / 13.18 | 3.62 / 3.61 |
| TILIN | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 1,055.48 | 57.15 / 57.11 | 21.39 / 21.14 | `rep:96m:256:c256+exe+delta+plz:4` | 1,046.57 | -0.84 % | 37.62 / 37.62 | 5.26 / 5.25 |
| TILIN | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 1,091.77 | 5.66 / 21.73 | 3.08 / 9.64 | `rep:96m:256:c256+4x4:plz:1` | 1,089.33 | -0.22 % | 4.87 / 18.45 | 2.06 / 5.03 |
| TILIN | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 1,071.31 | 8.73 / 32.72 | 4.34 / 13.39 | `rep:96m:256:c256+exe+4x4:plz:3` | 1,067.24 | -0.38 % | 8.24 / 31.11 | 3.02 / 6.23 |
| TILIN | 4 | `rep:96m+4x4:tor:c3` | 1,072.97 | 9.38 / 35.78 | 3.42 / 10.89 | `rep:96m+4x4:plz:3` | 1,068.44 | -0.42 % | 7.82 / 30.10 | 2.18 / 5.32 |
| TILIN | 1 | `tor:4:8mb:h4m` | 1,384.77 | 22.26 / 21.64 | 14.25 / 14.25 | `plz:2` | 1,310.80 | -5.34 % | 10.66 / 10.36 | 3.95 / 3.95 |
| TILIN | 1 | `tor:6` | 1,257.31 | 55.28 / 55.04 | 20.98 / 20.99 | `plz:4` | 1,223.63 | -2.68 % | 28.40 / 28.39 | 3.97 / 3.97 |
| TILIN | 4 | `4x4:tor:3:8mb` | 1,493.71 | 5.28 / 20.61 | 4.10 / 13.33 | `4x4:plz:1` | 1,456.85 | -2.47 % | 3.99 / 15.49 | 2.05 / 5.70 |
| TILIN | 4 | `4x4:tor:5` | 1,419.31 | 10.60 / 40.46 | 5.54 / 17.73 | `4x4:plz:3` | 1,411.97 | -0.52 % | 7.68 / 29.18 | 2.10 / 5.76 |

**Sets through parc (preset chains)**

| data | thr | tor method | size MB | comp wall/CPU s | dec wall/CPU s | plz method | size MB | Δ size | comp wall/CPU s | dec wall/CPU s |
|---|---:|---|---:|---:|---:|---|---:|---:|---:|---:|
| text | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 32.08 | 1.19 / 1.17 | 0.55 / 0.54 | `rep:96m:256:c256+plz:2` | 31.15 | -2.89 % | 1.32 / 1.31 | 0.41 / 0.38 |
| text | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 29.43 | 3.16 / 3.16 | 0.80 / 0.76 | `rep:96m:256:c256+exe+delta+plz:4` | 28.18 | -4.24 % | 4.09 / 4.08 | 0.57 / 0.56 |
| text | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 32.21 | 0.58 / 1.53 | 0.23 / 0.74 | `rep:96m:256:c256+4x4:plz:1` | 31.90 | -0.96 % | 0.60 / 1.60 | 0.21 / 0.55 |
| text | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 30.06 | 0.87 / 2.48 | 0.32 / 0.93 | `rep:96m:256:c256+exe+4x4:plz:3` | 28.67 | -4.63 % | 1.07 / 3.21 | 0.27 / 0.60 |
| text | 4 | `rep:96m+4x4:tor:c3` | 30.28 | 0.78 / 2.26 | 0.21 / 0.60 | `rep:96m+4x4:plz:3` | 28.73 | -5.11 % | 1.04 / 3.05 | 0.20 / 0.49 |
| exe | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 80.57 | 1.55 / 1.55 | 1.00 / 0.98 | `rep:96m:256:c256+plz:2` | 80.13 | -0.55 % | 1.03 / 1.02 | 0.32 / 0.31 |
| exe | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 79.06 | 4.14 / 4.14 | 1.50 / 1.50 | `rep:96m:256:c256+exe+delta+plz:4` | 78.23 | -1.04 % | 2.69 / 2.68 | 0.49 / 0.48 |
| exe | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 81.46 | 0.52 / 1.70 | 0.29 / 0.89 | `rep:96m:256:c256+4x4:plz:1` | 80.94 | -0.64 % | 0.50 / 1.46 | 0.20 / 0.42 |
| exe | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 79.48 | 1.03 / 3.11 | 0.46 / 1.26 | `rep:96m:256:c256+exe+4x4:plz:3` | 79.25 | -0.29 % | 0.81 / 2.44 | 0.27 / 0.54 |
| exe | 4 | `rep:96m+4x4:tor:c3` | 79.92 | 1.00 / 2.80 | 0.32 / 0.82 | `rep:96m+4x4:plz:3` | 79.61 | -0.39 % | 0.72 / 2.35 | 0.19 / 0.48 |
| small | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 4.69 | 0.53 / 0.52 | 0.14 / 0.13 | `rep:96m:256:c256+plz:2` | 4.66 | -0.60 % | 0.52 / 0.51 | 0.14 / 0.12 |
| small | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 4.30 | 0.75 / 0.75 | 0.19 / 0.18 | `rep:96m:256:c256+exe+delta+plz:4` | 4.26 | -0.87 % | 0.83 / 0.83 | 0.15 / 0.15 |
| small | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 4.73 | 0.44 / 0.65 | 0.10 / 0.19 | `rep:96m:256:c256+4x4:plz:1` | 4.70 | -0.63 % | 0.44 / 0.63 | 0.10 / 0.15 |
| small | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 4.40 | 0.59 / 0.97 | 0.12 / 0.21 | `rep:96m:256:c256+exe+4x4:plz:3` | 4.37 | -0.61 % | 0.58 / 0.96 | 0.11 / 0.19 |
| small | 4 | `rep:96m+4x4:tor:c3` | 4.41 | 0.52 / 0.84 | 0.10 / 0.17 | `rep:96m+4x4:plz:3` | 4.37 | -1.03 % | 0.58 / 0.91 | 0.10 / 0.15 |
| document | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 41.79 | 1.21 / 1.17 | 0.67 / 0.67 | `rep:96m:256:c256+plz:2` | 41.14 | -1.57 % | 1.06 / 1.05 | 0.33 / 0.31 |
| document | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 39.95 | 3.01 / 3.00 | 0.99 / 0.99 | `rep:96m:256:c256+exe+delta+plz:4` | 39.11 | -2.11 % | 3.12 / 3.11 | 0.48 / 0.47 |
| document | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 42.62 | 0.49 / 1.43 | 0.25 / 0.80 | `rep:96m:256:c256+4x4:plz:1` | 41.83 | -1.86 % | 0.49 / 1.47 | 0.20 / 0.46 |
| document | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 40.56 | 0.92 / 2.93 | 0.35 / 1.10 | `rep:96m:256:c256+exe+4x4:plz:3` | 39.89 | -1.66 % | 0.88 / 2.76 | 0.24 / 0.51 |
| document | 4 | `rep:96m+4x4:tor:c3` | 40.67 | 0.87 / 2.53 | 0.27 / 0.82 | `rep:96m+4x4:plz:3` | 39.74 | -2.29 % | 0.82 / 2.54 | 0.18 / 0.46 |
| large | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 79.57 | 1.84 / 1.83 | 0.99 / 0.99 | `rep:96m:256:c256+plz:2` | 78.50 | -1.34 % | 1.39 / 1.38 | 0.46 / 0.46 |
| large | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 75.66 | 6.26 / 6.25 | 1.58 / 1.58 | `rep:96m:256:c256+exe+delta+plz:4` | 74.14 | -2.01 % | 5.07 / 5.06 | 0.75 / 0.75 |
| large | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 80.10 | 0.71 / 2.30 | 0.39 / 1.36 | `rep:96m:256:c256+4x4:plz:1` | 79.74 | -0.45 % | 0.63 / 1.93 | 0.25 / 0.76 |
| large | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 76.72 | 1.55 / 5.13 | 0.56 / 1.93 | `rep:96m:256:c256+exe+4x4:plz:3` | 76.65 | -0.08 % | 1.15 / 3.51 | 0.33 / 0.83 |
| large | 4 | `rep:96m+4x4:tor:c3` | 76.83 | 1.34 / 4.43 | 0.40 / 1.39 | `rep:96m+4x4:plz:3` | 76.69 | -0.18 % | 1.09 / 3.39 | 0.24 / 0.71 |
| archive | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 67.65 | 1.68 / 1.67 | 0.88 / 0.87 | `rep:96m:256:c256+plz:2` | 67.13 | -0.76 % | 1.13 / 1.12 | 0.35 / 0.33 |
| archive | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 65.91 | 4.14 / 4.13 | 1.35 / 1.34 | `rep:96m:256:c256+exe+delta+plz:4` | 65.36 | -0.83 % | 2.96 / 2.96 | 0.51 / 0.51 |
| archive | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 68.34 | 0.59 / 1.87 | 0.36 / 0.99 | `rep:96m:256:c256+4x4:plz:1` | 67.68 | -0.97 % | 0.47 / 1.43 | 0.20 / 0.50 |
| archive | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 66.31 | 1.08 / 3.53 | 0.53 / 1.47 | `rep:96m:256:c256+exe+4x4:plz:3` | 65.93 | -0.58 % | 0.82 / 2.62 | 0.25 / 0.58 |
| archive | 4 | `rep:96m+4x4:tor:c3` | 66.53 | 1.10 / 3.54 | 0.36 / 1.11 | `rep:96m+4x4:plz:3` | 65.84 | -1.03 % | 0.86 / 2.62 | 0.20 / 0.53 |
| image | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 58.75 | 1.51 / 1.50 | 0.83 / 0.82 | `rep:96m:256:c256+plz:2` | 59.02 | +0.47 % | 1.14 / 1.13 | 0.39 / 0.39 |
| image | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 56.86 | 4.49 / 4.48 | 1.23 / 1.23 | `rep:96m:256:c256+exe+delta+plz:4` | 56.44 | -0.75 % | 3.80 / 3.80 | 0.57 / 0.56 |
| image | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 59.55 | 0.58 / 1.84 | 0.31 / 1.01 | `rep:96m:256:c256+4x4:plz:1` | 59.60 | +0.09 % | 0.50 / 1.41 | 0.22 / 0.55 |
| image | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 57.42 | 1.12 / 3.61 | 0.40 / 1.36 | `rep:96m:256:c256+exe+4x4:plz:3` | 57.50 | +0.14 % | 0.97 / 3.04 | 0.28 / 0.60 |
| image | 4 | `rep:96m+4x4:tor:c3` | 57.25 | 1.11 / 3.54 | 0.34 / 1.07 | `rep:96m+4x4:plz:3` | 57.06 | -0.33 % | 0.90 / 3.03 | 0.19 / 0.55 |
| audio | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 83.83 | 2.02 / 2.01 | 1.17 / 1.16 | `rep:96m:256:c256+plz:2` | 83.96 | +0.15 % | 1.21 / 1.19 | 0.38 / 0.38 |
| audio | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 82.52 | 5.51 / 5.50 | 1.66 / 1.65 | `rep:96m:256:c256+exe+delta+plz:4` | 81.78 | -0.90 % | 3.85 / 3.85 | 0.61 / 0.61 |
| audio | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 84.17 | 0.66 / 2.07 | 0.35 / 1.17 | `rep:96m:256:c256+4x4:plz:1` | 84.18 | +0.01 % | 0.52 / 1.53 | 0.20 / 0.54 |
| audio | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 82.87 | 1.29 / 4.29 | 0.45 / 1.60 | `rep:96m:256:c256+exe+4x4:plz:3` | 83.04 | +0.20 % | 0.98 / 2.78 | 0.27 / 0.62 |
| audio | 4 | `rep:96m+4x4:tor:c3` | 83.04 | 1.13 / 4.01 | 0.34 / 1.22 | `rep:96m+4x4:plz:3` | 83.02 | -0.03 % | 1.01 / 2.80 | 0.20 / 0.55 |
| video | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 64.75 | 1.66 / 1.61 | 0.88 / 0.86 | `rep:96m:256:c256+plz:2` | 64.85 | +0.17 % | 1.35 / 1.35 | 0.43 / 0.43 |
| video | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 62.64 | 4.82 / 4.78 | 1.40 / 1.40 | `rep:96m:256:c256+exe+delta+plz:4` | 62.22 | -0.66 % | 4.65 / 4.65 | 0.64 / 0.60 |
| video | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 66.76 | 0.56 / 1.84 | 0.33 / 1.14 | `rep:96m:256:c256+4x4:plz:1` | 66.38 | -0.58 % | 0.50 / 1.50 | 0.18 / 0.59 |
| video | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 63.26 | 1.13 / 3.99 | 0.47 / 1.59 | `rep:96m:256:c256+exe+4x4:plz:3` | 63.04 | -0.34 % | 1.19 / 3.92 | 0.24 / 0.64 |
| video | 4 | `rep:96m+4x4:tor:c3` | 63.61 | 1.09 / 3.76 | 0.30 / 1.08 | `rep:96m+4x4:plz:3` | 63.26 | -0.54 % | 1.13 / 3.81 | 0.18 / 0.59 |
| font | 1 | `rep:96m:256:c256+tor:4:8mb:h4m` | 7.67 | 0.33 / 0.32 | 0.15 / 0.14 | `rep:96m:256:c256+plz:2` | 7.76 | +1.19 % | 0.31 / 0.30 | 0.11 / 0.11 |
| font | 1 | `rep:96m:256:c256+exe+delta+tor:6` | 6.93 | 0.77 / 0.76 | 0.21 / 0.21 | `rep:96m:256:c256+exe+delta+plz:4` | 6.75 | -2.53 % | 0.77 / 0.74 | 0.11 / 0.10 |
| font | 4 | `rep:96m:256:c256+4x4:tor:3:8mb` | 7.75 | 0.19 / 0.45 | 0.07 / 0.20 | `rep:96m:256:c256+4x4:plz:1` | 7.87 | +1.61 % | 0.17 / 0.40 | 0.05 / 0.14 |
| font | 4 | `rep:96m:256:c256+exe+4x4:tor:5` | 7.25 | 0.30 / 0.73 | 0.10 / 0.24 | `rep:96m:256:c256+exe+4x4:plz:3` | 7.30 | +0.58 % | 0.30 / 0.81 | 0.06 / 0.12 |
| font | 4 | `rep:96m+4x4:tor:c3` | 7.29 | 0.27 / 0.72 | 0.10 / 0.21 | `rep:96m+4x4:plz:3` | 7.30 | +0.10 % | 0.31 / 0.79 | 0.06 / 0.12 |

**Whole presets -m1..-m4** (`tor` = today's presets; `plz` = proposed mapping)

| data | thr | level | tor size MB | comp wall/CPU | dec wall/CPU | plz size MB | Δ | comp wall/CPU | dec wall/CPU |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|
| tilin512 | 1 | -m1 | 284.63 | 6.48 / 6.45 | 3.99 / 3.99 | 282.24 | -0.84 % | 5.03 / 5.03 | 1.62 / 1.62 |
| tilin512 | 1 | -m2 | 270.57 | 18.67 / 18.66 | 5.59 / 5.58 | 265.84 | -1.75 % | 14.85 / 14.60 | 2.19 / 2.19 |
| tilin512 | 4 | -m1 | 289.01 | 1.94 / 7.22 | 1.24 / 4.77 | 285.73 | -1.13 % | 1.76 / 6.46 | 0.66 / 2.15 |
| tilin512 | 4 | -m2 | 274.58 | 4.20 / 15.31 | 1.79 / 6.69 | 270.30 | -1.56 % | 3.62 / 12.77 | 0.94 / 2.54 |
| TILIN | 1 | -m1 | 1,078.74 | 20.14 / 20.14 | 12.33 / 12.33 | 1,073.91 | -0.45 % | 13.22 / 13.22 | 3.66 / 3.63 |
| TILIN | 1 | -m2 | 1,055.48 | 59.66 / 59.47 | 20.33 / 20.29 | 1,046.57 | -0.84 % | 37.81 / 37.79 | 5.32 / 5.32 |
| TILIN | 4 | -m1 | 1,091.77 | 5.54 / 21.16 | 3.10 / 9.73 | 1,089.33 | -0.22 % | 5.30 / 20.17 | 2.09 / 5.08 |
| TILIN | 4 | -m2 | 1,071.31 | 8.96 / 33.44 | 4.33 / 13.14 | 1,067.24 | -0.38 % | 8.21 / 30.19 | 2.90 / 5.89 |
| text | 1 | -m1 | 32.08 | 1.21 / 1.20 | 0.56 / 0.55 | 31.15 | -2.89 % | 1.33 / 1.33 | 0.41 / 0.40 |
| text | 1 | -m2 | 28.84 | 3.94 / 3.94 | 1.58 / 1.53 | 27.78 | -3.67 % | 4.63 / 4.60 | 1.40 / 1.39 |
| text | 1 | -m3 | 27.39 | 7.52 / 7.52 | 2.77 / 2.76 | 27.42 | +0.09 % | 7.56 / 7.53 | 3.32 / 3.23 |
| text | 1 | -m4 | 25.56 | 14.51 / 14.35 | 3.21 / 3.13 | 25.60 | +0.15 % | 14.32 / 14.31 | 2.93 / 2.93 |
| text | 4 | -m1 | 32.21 | 0.58 / 1.51 | 0.24 / 0.75 | 31.90 | -0.96 % | 0.62 / 1.69 | 0.22 / 0.58 |
| text | 4 | -m2 | 29.37 | 1.19 / 3.78 | 0.57 / 1.94 | 28.20 | -3.98 % | 1.29 / 4.38 | 0.50 / 1.61 |
| text | 4 | -m3 | 25.96 | 5.83 / 14.58 | 0.77 / 2.52 | 25.96 | +0.00 % | 5.44 / 14.12 | 0.82 / 2.57 |
| text | 4 | -m4 | 25.57 | 7.90 / 15.95 | 0.97 / 3.23 | 25.57 | -0.00 % | 8.24 / 15.80 | 0.99 / 3.14 |
| exe | 1 | -m1 | 80.57 | 1.62 / 1.57 | 1.05 / 0.98 | 80.13 | -0.55 % | 1.05 / 1.03 | 0.31 / 0.30 |
| exe | 1 | -m2 | 79.00 | 3.02 / 3.02 | 1.25 / 1.25 | 78.26 | -0.94 % | 2.34 / 2.33 | 0.42 / 0.42 |
| exe | 1 | -m3 | 77.59 | 7.04 / 7.04 | 2.10 / 2.07 | 77.40 | -0.26 % | 5.96 / 5.95 | 1.72 / 1.70 |
| exe | 1 | -m4 | 77.12 | 10.38 / 10.37 | 1.95 / 1.95 | 76.93 | -0.26 % | 9.79 / 9.79 | 1.71 / 1.71 |
| exe | 4 | -m1 | 81.46 | 0.52 / 1.70 | 0.26 / 0.83 | 80.94 | -0.64 % | 0.47 / 1.43 | 0.19 / 0.42 |
| exe | 4 | -m2 | 79.54 | 0.91 / 2.56 | 0.29 / 0.91 | 79.38 | -0.19 % | 0.95 / 2.51 | 0.19 / 0.48 |
| exe | 4 | -m3 | 77.82 | 3.56 / 9.16 | 0.99 / 1.83 | 77.82 | +0.00 % | 3.58 / 9.28 | 0.98 / 1.82 |
| exe | 4 | -m4 | 77.40 | 5.72 / 10.10 | 0.87 / 1.80 | 77.41 | +0.02 % | 5.26 / 9.97 | 0.94 / 1.92 |
| small | 1 | -m1 | 4.69 | 0.50 / 0.48 | 0.14 / 0.12 | 4.66 | -0.60 % | 0.49 / 0.48 | 0.12 / 0.11 |
| small | 1 | -m2 | 4.35 | 1.40 / 1.39 | 0.43 / 0.43 | 4.33 | -0.42 % | 1.65 / 1.65 | 0.39 / 0.39 |
| small | 1 | -m3 | 4.06 | 1.99 / 1.95 | 0.77 / 0.76 | 4.06 | -0.01 % | 1.97 / 1.97 | 0.83 / 0.83 |
| small | 1 | -m4 | 3.88 | 2.53 / 2.51 | 0.76 / 0.74 | 3.88 | +0.02 % | 2.53 / 2.51 | 0.75 / 0.73 |
| small | 4 | -m1 | 4.73 | 0.45 / 0.62 | 0.08 / 0.17 | 4.70 | -0.63 % | 0.46 / 0.61 | 0.07 / 0.12 |
| small | 4 | -m2 | 4.41 | 0.74 / 1.84 | 0.21 / 0.59 | 4.41 | -0.03 % | 0.77 / 1.83 | 0.19 / 0.55 |
| small | 4 | -m3 | 4.03 | 1.74 / 2.93 | 0.23 / 0.64 | 4.03 | -0.00 % | 1.69 / 2.88 | 0.23 / 0.63 |
| small | 4 | -m4 | 3.98 | 1.80 / 3.11 | 0.31 / 0.94 | 3.98 | +0.00 % | 1.73 / 3.07 | 0.32 / 0.96 |
| document | 1 | -m1 | 41.79 | 1.22 / 1.19 | 0.60 / 0.59 | 41.14 | -1.57 % | 1.07 / 1.07 | 0.34 / 0.33 |
| document | 1 | -m2 | 39.94 | 2.85 / 2.82 | 1.08 / 1.06 | 39.24 | -1.74 % | 3.07 / 3.06 | 0.72 / 0.71 |
| document | 1 | -m3 | 38.29 | 5.35 / 5.34 | 1.80 / 1.80 | 38.26 | -0.08 % | 5.26 / 5.26 | 1.64 / 1.63 |
| document | 1 | -m4 | 37.26 | 10.63 / 10.63 | 1.87 / 1.86 | 37.25 | -0.03 % | 10.28 / 10.27 | 1.70 / 1.69 |
| document | 4 | -m1 | 42.62 | 0.49 / 1.48 | 0.24 / 0.76 | 41.83 | -1.86 % | 0.50 / 1.38 | 0.20 / 0.46 |
| document | 4 | -m2 | 40.79 | 1.00 / 2.86 | 0.33 / 1.10 | 40.11 | -1.66 % | 1.10 / 3.07 | 0.27 / 0.83 |
| document | 4 | -m3 | 38.01 | 5.49 / 9.80 | 0.69 / 1.64 | 38.00 | -0.03 % | 5.40 / 9.79 | 0.74 / 1.61 |
| document | 4 | -m4 | 37.68 | 5.08 / 10.79 | 0.62 / 1.95 | 37.67 | -0.01 % | 5.01 / 10.79 | 0.62 / 1.86 |
| large | 1 | -m1 | 79.57 | 1.90 / 1.90 | 1.00 / 1.00 | 78.50 | -1.34 % | 1.37 / 1.37 | 0.46 / 0.46 |
| large | 1 | -m2 | 75.66 | 6.35 / 6.34 | 1.73 / 1.73 | 74.14 | -2.01 % | 5.38 / 5.37 | 0.83 / 0.82 |
| large | 1 | -m3 | 72.17 | 15.88 / 15.87 | 3.53 / 3.48 | 72.17 | +0.00 % | 15.89 / 15.88 | 3.44 / 3.43 |
| large | 1 | -m4 | 69.01 | 28.46 / 28.46 | 3.64 / 3.55 | 69.01 | +0.00 % | 28.19 / 28.18 | 3.87 / 3.76 |
| large | 4 | -m1 | 80.10 | 0.67 / 2.25 | 0.40 / 1.36 | 79.74 | -0.45 % | 0.59 / 1.77 | 0.25 / 0.73 |
| large | 4 | -m2 | 76.72 | 1.54 / 4.98 | 0.55 / 1.89 | 76.65 | -0.08 % | 1.20 / 3.71 | 0.35 / 0.84 |
| large | 4 | -m3 | 69.69 | 6.86 / 24.85 | 1.34 / 4.18 | 69.69 | +0.00 % | 6.96 / 25.16 | 1.29 / 4.14 |
| large | 4 | -m4 | 68.83 | 8.85 / 27.17 | 1.36 / 3.95 | 68.83 | +0.00 % | 9.76 / 27.74 | 1.38 / 3.96 |
| archive | 1 | -m1 | 67.65 | 1.68 / 1.66 | 0.87 / 0.83 | 67.13 | -0.76 % | 1.08 / 1.08 | 0.37 / 0.36 |
| archive | 1 | -m2 | 65.87 | 3.78 / 3.78 | 1.24 / 1.23 | 65.38 | -0.74 % | 3.16 / 3.15 | 0.59 / 0.59 |
| archive | 1 | -m3 | 64.00 | 8.02 / 8.01 | 2.51 / 2.49 | 63.91 | -0.14 % | 7.70 / 7.70 | 2.06 / 2.05 |
| archive | 1 | -m4 | 63.08 | 13.63 / 13.62 | 2.25 / 2.24 | 63.02 | -0.09 % | 12.43 / 12.42 | 2.03 / 2.03 |
| archive | 4 | -m1 | 68.34 | 0.57 / 1.78 | 0.37 / 1.01 | 67.68 | -0.97 % | 0.49 / 1.45 | 0.22 / 0.51 |
| archive | 4 | -m2 | 66.35 | 1.19 / 3.77 | 0.47 / 1.28 | 66.00 | -0.52 % | 1.03 / 3.37 | 0.24 / 0.76 |
| archive | 4 | -m3 | 63.40 | 4.81 / 11.67 | 1.07 / 2.35 | 63.40 | -0.00 % | 4.38 / 11.17 | 1.03 / 2.29 |
| archive | 4 | -m4 | 63.21 | 6.39 / 12.09 | 1.26 / 2.36 | 63.21 | -0.00 % | 6.55 / 12.06 | 1.10 / 2.34 |
| image | 1 | -m1 | 58.75 | 1.48 / 1.48 | 0.86 / 0.81 | 59.02 | +0.47 % | 1.16 / 1.15 | 0.38 / 0.36 |
| image | 1 | -m2 | 56.47 | 4.26 / 4.26 | 1.14 / 1.12 | 56.01 | -0.82 % | 4.41 / 4.40 | 0.72 / 0.72 |
| image | 1 | -m3 | 52.73 | 9.88 / 9.87 | 3.18 / 3.18 | 52.66 | -0.13 % | 9.53 / 9.53 | 2.97 / 2.97 |
| image | 1 | -m4 | 51.16 | 17.79 / 17.78 | 4.24 / 4.24 | 51.08 | -0.15 % | 17.17 / 17.15 | 4.17 / 4.18 |
| image | 4 | -m1 | 59.55 | 0.55 / 1.69 | 0.32 / 1.01 | 59.60 | +0.09 % | 0.50 / 1.47 | 0.18 / 0.52 |
| image | 4 | -m2 | 55.34 | 1.41 / 5.28 | 0.67 / 2.64 | 55.44 | +0.19 % | 1.36 / 5.14 | 0.56 / 2.16 |
| image | 4 | -m3 | 51.33 | 7.82 / 17.72 | 1.23 / 4.78 | 51.33 | +0.00 % | 7.67 / 17.38 | 1.20 / 4.77 |
| image | 4 | -m4 | 51.25 | 11.57 / 18.12 | 1.21 / 4.79 | 51.25 | +0.00 % | 11.83 / 18.30 | 1.21 / 4.72 |
| audio | 1 | -m1 | 83.83 | 1.85 / 1.85 | 1.10 / 1.07 | 83.96 | +0.15 % | 1.10 / 1.10 | 0.39 / 0.38 |
| audio | 1 | -m2 | 78.61 | 3.65 / 3.65 | 2.03 / 1.97 | 78.31 | -0.38 % | 3.02 / 3.01 | 1.24 / 1.24 |
| audio | 1 | -m3 | 77.12 | 6.27 / 6.27 | 3.94 / 3.94 | 76.91 | -0.27 % | 6.11 / 6.10 | 3.40 / 3.40 |
| audio | 1 | -m4 | 76.38 | 9.59 / 9.59 | 3.77 / 3.68 | 76.11 | -0.35 % | 8.48 / 8.48 | 3.31 / 3.31 |
| audio | 4 | -m1 | 84.17 | 0.67 / 2.13 | 0.37 / 1.15 | 84.18 | +0.01 % | 0.48 / 1.43 | 0.21 / 0.54 |
| audio | 4 | -m2 | 78.75 | 1.07 / 3.86 | 0.49 / 1.93 | 78.79 | +0.05 % | 0.88 / 3.22 | 0.38 / 1.48 |
| audio | 4 | -m3 | 76.36 | 5.61 / 8.74 | 0.98 / 3.83 | 76.35 | -0.01 % | 5.74 / 8.71 | 0.94 / 3.73 |
| audio | 4 | -m4 | 76.35 | 6.02 / 9.81 | 0.98 / 3.79 | 76.32 | -0.05 % | 5.62 / 9.43 | 0.98 / 3.77 |
| video | 1 | -m1 | 64.75 | 1.65 / 1.61 | 0.94 / 0.90 | 64.85 | +0.17 % | 1.39 / 1.37 | 0.42 / 0.41 |
| video | 1 | -m2 | 62.67 | 4.65 / 4.65 | 1.33 / 1.32 | 62.27 | -0.62 % | 4.83 / 4.71 | 0.67 / 0.66 |
| video | 1 | -m3 | 59.47 | 11.51 / 11.48 | 2.60 / 2.58 | 59.45 | -0.03 % | 12.37 / 12.08 | 2.53 / 2.53 |
| video | 1 | -m4 | 57.47 | 20.34 / 20.34 | 2.67 / 2.67 | 57.46 | -0.02 % | 20.41 / 20.40 | 2.52 / 2.51 |
| video | 4 | -m1 | 66.76 | 0.57 / 1.87 | 0.31 / 1.13 | 66.38 | -0.58 % | 0.49 / 1.51 | 0.19 / 0.60 |
| video | 4 | -m2 | 63.35 | 1.23 / 4.13 | 0.47 / 1.60 | 63.17 | -0.28 % | 1.21 / 4.10 | 0.24 / 0.71 |
| video | 4 | -m3 | 57.81 | 6.55 / 17.77 | 1.36 / 2.83 | 57.80 | -0.03 % | 6.50 / 17.51 | 1.16 / 2.83 |
| video | 4 | -m4 | 57.49 | 6.90 / 18.70 | 1.61 / 2.92 | 57.49 | +0.00 % | 6.99 / 18.90 | 1.57 / 2.76 |
| font | 1 | -m1 | 7.67 | 0.33 / 0.33 | 0.14 / 0.12 | 7.76 | +1.19 % | 0.30 / 0.28 | 0.09 / 0.08 |
| font | 1 | -m2 | 6.91 | 0.79 / 0.78 | 0.26 / 0.26 | 6.75 | -2.32 % | 0.92 / 0.89 | 0.18 / 0.18 |
| font | 1 | -m3 | 6.44 | 1.38 / 1.37 | 0.47 / 0.47 | 6.44 | -0.02 % | 1.40 / 1.35 | 0.42 / 0.41 |
| font | 1 | -m4 | 6.17 | 3.26 / 3.24 | 0.44 / 0.41 | 6.17 | -0.02 % | 2.85 / 2.84 | 0.45 / 0.45 |
| font | 4 | -m1 | 7.75 | 0.19 / 0.45 | 0.07 / 0.21 | 7.87 | +1.61 % | 0.17 / 0.39 | 0.05 / 0.14 |
| font | 4 | -m2 | 7.26 | 0.35 / 0.96 | 0.10 / 0.35 | 7.24 | -0.26 % | 0.40 / 1.10 | 0.08 / 0.24 |
| font | 4 | -m3 | 6.23 | 2.62 / 2.95 | 0.33 / 0.44 | 6.22 | -0.16 % | 2.50 / 2.81 | 0.37 / 0.48 |
| font | 4 | -m4 | 6.16 | 2.72 / 3.07 | 0.35 / 0.53 | 6.16 | +0.01 % | 2.77 / 3.11 | 0.31 / 0.48 |

**FreeArc 0.67 (Wine, private prefix), reference**

| data | level | threads | size MB | comp wall/CPU s | dec wall/CPU s |
|---|---|---|---:|---:|---:|
| tilin512 | `arc -m1` | mt1 | 285.44 | 14.28 / 14.77 | 5.86 / 5.84 |
| tilin512 | `arc -m1` | mt4 | 289.39 | 7.42 / 14.28 | 1.84 / 7.15 |
| tilin512 | `arc -m2` | mt1 | 271.55 | 45.52 / 46.38 | 8.56 / 8.49 |
| tilin512 | `arc -m2` | mt4 | 274.72 | 11.02 / 32.53 | 2.71 / 9.91 |
| tilin512 | `arc -m3` | mt1 | 258.90 | 91.13 / 91.63 | 21.92 / 21.89 |
| tilin512 | `arc -m3` | mt4 | 259.22 | 34.50 / 91.06 | 8.60 / 22.42 |
| tilin512 | `arc -m4` | mt1 | 253.47 | 131.54 / 131.88 | 21.65 / 21.60 |
| tilin512 | `arc -m4` | mt4 | 253.60 | 29.17 / 148.22 | 9.23 / 23.08 |
| TILIN | `arc -m1` | mt1 | 1,081.10 | 36.73 / 41.61 | 19.08 / 19.06 |
| TILIN | `arc -m1` | mt4 | 1,103.12 | 9.34 / 28.03 | 4.47 / 11.55 |
| TILIN | `arc -m2` | mt1 | 1,058.24 | 118.14 / 122.19 | 27.73 / 27.72 |
| TILIN | `arc -m2` | mt4 | 1,083.68 | 19.50 / 54.13 | 6.08 / 15.88 |
| TILIN | `arc -m3` | mt1 | 1,028.40 | 327.86 / 328.15 | 84.25 / 84.18 |
| TILIN | `arc -m3` | mt4 | 1,058.92 | 64.70 / 185.43 | 16.48 / 47.29 |
| TILIN | `arc -m4` | mt1 | 1,023.01 | 417.97 / 422.87 | 82.88 / 82.90 |
| TILIN | `arc -m4` | mt4 | 1,050.24 | 63.76 / 291.14 | 16.80 / 48.04 |

**Summary.** Against every `tor` use of the presets, on TILIN, tilin_512m and the
text/exe/small/document/large/archive/video sets, `plz` is smaller (−0.1 % to −5 %), uses less
compression CPU and decompresses in about half the time (one third to one fifth of the CPU
inside `4x4`). Where parity is **not** reached:

- **Size**, chains with `rep` in front: `font` (+1.2 % `-m1` 1 thread, +1.6 % `-m1` 4 threads,
  +0.6 % `-m2` 4 threads), `image` (+0.5 % `-m1` 1 thread, +0.1/+0.2 % 4 threads), `audio`
  (+0.15 % `-m1` 1 thread, +0.0–0.2 % 4 threads), `video` (+0.17 % `-m1` 1 thread). These are
  binary formats with short (3–4 byte) repeats where the 5/6-byte hashes of levels 1–3 miss
  matches (4-byte hashing fixes font but costs 20–35 % time on TILIN). In the presets `.wav`
  and `.bmp` go to `tta`/`mm` anyway.
- **Compression time**: level 1 is 10–33 % slower than `tor:3` on text (`set_text` codec
  alone 0.88 s vs 0.66 s; `-m1` on the text set 1.33 vs 1.20 s CPU), level 3 is ~50 % slower
  than `tor:5` on pure text (2.38 vs 1.60 s; the presets send text to grzip at that level), and
  `-m2` with one thread is 5–20 % slower than `tor:6` on the small/text/document/image/video
  sets (e.g. small 1.65 vs 1.39 s) while 25–40 % faster on TILIN and exe. Everything else is
  faster.

**Proposed preset mapping** (not applied; the `plz-presets` columns above use it):
`1binary = plz:2`, `2binary = plz:4`, `ex1binary = xplz:1` (`4x4:plz:1`, 8 MB blocks),
`ex2binary = xplz:3` (16 MB blocks), `4$compressed = 4rep + eplz:3`, `4x$compressed = eplz:3:8m`,
`bmpfastest = mm:d1 + plz:2`, `3xt = dict:64m:80% + plz:5:96m`, with `xplz = 4x4:plz` and
`eplz = (|x)plz`.


## Own filters replacing FreeArc's `delta` and `lzp` (2026-11-21/22)

Same method as `plz`: each filter is rewritten from the published idea of the algorithm, using
PArc's current code only for the interface (parameters, place in the chain, presets, memory
estimate, tests), then benchmarked against the old one until it is at least as good in size and
speed in every preset that uses it. `dict` stays FreeArc's for now: the own one (separate branch) is still behind it on
natural-language text. Work area and logs:
`/mnt/IA_LAB/agentes/PArc/filters/` (corpus copies in `data/`, scripts in `scripts/`, CSVs in
`logs/`; `base/parc_old` and `base/bench_old` are 40ffce5).

**`delta`** (done: `src/parc_delta.pas`, stream in `formato/FORMATO-PARC.md` §6.4; the old
`parc_deltaenc.pas` and the decoder in `parc_filters.pas` are gone). Per 8 MB block, in 512-byte
windows: a one-pass repeat-distance histogram (x86-64 assembler, Pascal fallback with the same
result) finds windows whose bytes repeat at a fixed distance (or change slowly byte to byte); the
stride is confirmed by the window's difference cost against unrelated control strides; the run
grows record by record while a moving average of the record cost stays below the midpoint of the
two levels, and runs of the same stride are joined across short gaps. For each run a field layout
is chosen on a sample (1/2/4-byte fields, both byte orders, every alignment, per-field on/off) by
order-0 column entropy in integer fixed point, counting raw bytes equal to the one a record back
as cheap repeats (that is what made it stop hurting LZ back ends on bitmaps with repeated
patterns). Output is aligned like the input (header padded to 8 bytes: plz and lzma use the
position modulo 2/4/8, and a 5-byte shift cost plz up to 6 % on some files). Decoding keeps the
running sums in registers for up to four differenced fields.

**`lzp`** (done: `src/parc_lzp.pas` rewritten, stream in `formato/FORMATO-PARC.md` §6.5). Bloom's
LZP on a 4-byte context with **two candidates per bucket** (the most recent and the one before;
the longer match beyond its minimum wins, one bit of the length says which). That was the step
that made it beat the old filter on documents in front of grzip (one candidate: +0.05 %; two:
−0.14 %); contexts of 5–6 bytes lost up to 0.7 % there. The escape is the block's least frequent
byte; lengths go to a separate stream after the literals. `d<barrier>`/`s<smallest>`: a repeat
that starts more than `d` back may be as short as `s` (close repeats are left to PPMd, which
predicts them well: the other way round cost 1 % with `ppmd:13`). Speed: the encoder computes
and prefetches table slots 8 positions ahead and rejects a candidate on its first 8 bytes; the
decoder writes literals 8 at a time with their 8 table slots computed together.


**`delta` in the presets** (binary pipelines; old = 40ffce5, new = own delta, both with REP; best of 2
runs, T1 on 2 and T4 on 4 of cores 0–15; `/mnt/IA_LAB/agentes/PArc/filters/logs/final_all.csv`). `-m2`
at T4 does not use delta. After the OREP merge the same comparison (main 78de427 vs the branch)
gave −0.02…−0.78 % in every binary cell (`logs/final_merged.csv`).

| set | preset | T | old size | new size | Δ | comp wall old/new | dec wall old/new |
|---|---|---|---:|---:|---:|---:|---:|
| TILIN | -m3 | 1 | 1,022,570,069 | 1,022,421,520 | -0.01 % | 237.49 / 233.07 | 44.74 / 46.80 |
| TILIN | -m5 | 1 | 1,006,574,156 | 1,006,338,179 | -0.02 % | 362.95 / 348.61 | 47.78 / 42.01 |
| TILIN | -m3 | 4 | 1,044,078,773 | 1,043,621,470 | -0.04 % | 42.48 / 43.99 | 9.65 / 9.59 |
| TILIN | -m5 | 4 | 1,037,925,682 | 1,037,439,496 | -0.05 % | 69.87 / 65.03 | 9.37 / 9.61 |
| exe | -m2 | 1 | 52,308,428 | 52,119,058 | -0.36 % | 3.06 / 2.85 | 0.46 / 0.47 |
| exe | -m3 | 1 | 51,123,480 | 51,092,421 | -0.06 % | 8.15 / 7.39 | 1.88 / 1.80 |
| exe | -m5 | 1 | 50,185,871 | 50,160,462 | -0.05 % | 19.23 / 20.17 | 2.54 / 2.54 |
| exe | -m9 | 1 | 50,096,051 | 50,052,547 | -0.09 % | 21.86 / 21.71 | 2.48 / 2.36 |
| exe | -m2 | 4 | 53,624,421 | 53,624,421 | +0.00 % | 0.85 / 0.83 | 0.22 / 0.20 |
| exe | -m3 | 4 | 51,558,814 | 51,512,785 | -0.09 % | 4.26 / 4.06 | 1.03 / 0.98 |
| exe | -m5 | 4 | 51,090,694 | 51,053,921 | -0.07 % | 11.52 / 11.43 | 1.51 / 1.48 |
| exe | -m9 | 4 | 50,096,051 | 50,052,547 | -0.09 % | 13.67 / 13.73 | 2.39 / 2.37 |
| table | -m2 | 1 | 152,512,559 | 150,370,428 | -1.40 % | 13.22 / 12.68 | Command / 3.49 |
| table | -m3 | 1 | 127,876,558 | 127,480,406 | -0.31 % | 41.44 / 40.28 | 19.76 / 19.83 |
| table | -m5 | 1 | 122,043,571 | 121,814,956 | -0.19 % | 70.00 / 68.45 | 33.48 / 33.68 |
| table | -m9 | 1 | 122,289,320 | 121,995,336 | -0.24 % | 75.24 / 82.20 | 33.71 / 32.75 |
| table | -m2 | 4 | 143,003,447 | 143,003,447 | +0.00 % | 6.38 / 6.33 | 4.22 / 4.08 |
| table | -m3 | 4 | 131,146,349 | 130,173,754 | -0.74 % | 16.28 / 15.62 | 8.54 / 8.45 |
| table | -m5 | 4 | 132,471,118 | 131,325,733 | -0.86 % | 18.85 / 19.29 | 9.19 / 8.34 |
| table | -m9 | 4 | 122,289,320 | 121,995,336 | -0.24 % | 28.50 / 29.69 | 9.25 / 9.25 |
| document | -m2 | 1 | 35,518,465 | 35,465,212 | -0.15 % | 2.75 / 2.88 | 1.00 / 1.01 |
| document | -m3 | 1 | 35,030,204 | 35,015,420 | -0.04 % | 5.14 / 5.28 | 2.39 / 2.35 |
| document | -m5 | 1 | 33,611,454 | 33,601,378 | -0.03 % | 14.55 / 15.45 | 3.23 / 3.78 |
| document | -m9 | 1 | 33,443,280 | 33,424,992 | -0.05 % | 19.98 / 19.42 | 3.49 / 3.48 |
| document | -m2 | 4 | 36,084,754 | 36,084,754 | +0.00 % | 0.99 / 1.01 | 0.51 / 0.53 |
| document | -m3 | 4 | 35,052,506 | 35,032,773 | -0.06 % | 3.03 / 3.07 | 0.55 / 0.55 |
| document | -m5 | 4 | 33,620,367 | 33,614,224 | -0.02 % | 6.33 / 6.28 | 1.81 / 2.08 |
| document | -m9 | 4 | 33,443,280 | 33,424,992 | -0.05 % | 11.28 / 10.93 | 2.30 / 2.16 |
| TILIN | -m3 | 1 | 1,022,444,338 | 1,022,287,502 | -0.02 % | 258.01 / 236.77 | 46.88 / 46.84 |
| TILIN | -m5 | 1 | 1,006,474,857 | 1,006,182,353 | -0.03 % | 397.17 / 368.87 | 48.42 / 48.30 |
| TILIN | -m3 | 4 | 1,044,040,024 | 1,043,543,307 | -0.05 % | 55.26 / 41.14 | 9.32 / 8.28 |
| TILIN | -m5 | 4 | 1,038,051,990 | 1,037,628,647 | -0.04 % | 78.08 / 62.02 | 8.34 / 8.35 |
| exe | -m3 | 1 | 51,107,676 | 51,070,356 | -0.07 % | 8.06 / 8.15 | 1.89 / 1.89 |
| exe | -m9 | 1 | 50,085,686 | 50,028,045 | -0.12 % | 20.15 / 20.29 | 2.41 / 2.41 |
| exe | -m3 | 4 | 51,538,484 | 51,489,178 | -0.10 % | 3.87 / 3.84 | 1.11 / 1.17 |
| exe | -m9 | 4 | 50,085,686 | 50,028,045 | -0.12 % | 14.21 / 13.94 | 2.46 / 2.47 |
| table | -m3 | 1 | 127,796,882 | 127,315,615 | -0.38 % | 44.59 / 41.31 | 21.30 / 21.59 |
| table | -m9 | 1 | 122,252,199 | 121,885,049 | -0.30 % | 80.91 / 81.63 | 39.11 / 34.86 |
| table | -m3 | 4 | 131,124,694 | 130,096,945 | -0.78 % | 16.09 / 16.13 | 9.79 / 9.33 |
| table | -m9 | 4 | 122,252,199 | 121,885,049 | -0.30 % | 29.02 / 29.76 | 9.26 / 9.50 |
| document | -m3 | 1 | 35,026,170 | 35,012,675 | -0.04 % | 5.32 / 5.57 | 2.49 / 2.41 |
| document | -m9 | 1 | 33,438,412 | 33,419,913 | -0.06 % | 19.84 / 28.30 | 3.52 / 3.78 |
| document | -m3 | 4 | 35,065,468 | 35,048,515 | -0.05 % | 3.13 / 3.13 | 0.60 / 0.62 |
| document | -m9 | 4 | 33,438,412 | 33,419,913 | -0.06 % | 11.00 / 11.01 | 2.32 / 2.35 |
| table | `delta` | 276,596,408 | 275,804,424 | -0.29 % | 5.601 / 4.741 | 0.438 / 0.501 |
| exe | `delta` | 90,177,852 | 90,096,736 | -0.09 % | 0.823 / 0.739 | 0.116 / 0.115 |
| document | `delta` | 70,580,428 | 70,518,152 | -0.09 % | 0.603 / 0.634 | 0.088 / 0.088 |
| table | `delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1` | 129,076,876 | 126,805,049 | -1.76 % | 109.930 / 110.539 | 7.814 / 7.406 |
| exe | `delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1` | 50,310,989 | 50,293,975 | -0.03 % | 21.177 / 21.390 | 2.314 / 2.333 |
| document | `delta+lzma:96m:normal:32:bt4:mc8:lc4:pb1` | 33,690,036 | 33,667,331 | -0.07 % | 17.822 / 17.172 | 1.628 / 1.664 |
| table | `delta+plz:4` | 160,749,548 | 149,530,401 | -6.98 % | 15.206 / 14.189 | 1.422 / 1.529 |
| exe | `delta+plz:4` | 54,222,235 | 54,052,898 | -0.31 % | 3.130 / 2.934 | 0.358 / 0.374 |
| document | `lzp:64m:32:h20:92%` | 50,929,712 | 50,627,665 | -0.59 % | 1.366 / 1.183 | 0.449 / 0.426 |
| document | `lzp:80m:105:d1m:s32:h22:92%` | 55,881,983 | 55,941,537 | +0.11 % | 2.600 / 2.071 | 1.226 / 0.794 |

**`lzp`**: with the presets' dict in front, the text chains are smaller than with the old lzp in
every case measured (3t grzip −0.14…−0.25 %, 4t ppmd:8 −0.07 %, 5t ppmd:13 −0.02 %, #t −0.03 %); `lzp`
alone encodes 5–25 % faster and decodes faster with h22/h23, 5–20 % slower with h20 on text
(0.47 vs 0.40 s for 93 MB), which is lost in the chains' seconds of PPMd/BWT.

Found on the way: `parc a -m2 -mt1` corrupted some images (mm + plz short reads), fixed in dc7aca9.

## Own context mixing `cm` replacing the lpaq1 port (2026-11-23)

`cm` (used by `-mxx`: `xx$text = dict+lzp+cm`, `xx$binary`/`xx$obj = orep+exe+delta+cm`) was a
Pascal port of lpaq1 (GPL). It is now PArc's own model (`src/parc_cm.pas` + `src/cm/pcm_core.c`,
MIT, freestanding C built by `build.sh` like OREP's core), designed from the published
descriptions of bitwise context mixing; no lpaq/paq/FreeArc code was read. Old `cm` blocks no
longer decode (new stream with a version byte, [FORMATO-PARC.md §6.6](formato/FORMATO-PARC.md)).

Model, per bit: bit-history states (bounded (n0, n1, last bit) counters, one byte) for order 0
and 1 (direct tables) and orders 2, 3, 4, 6, word, word bigram, an indirect context (the two
bytes that last followed the previous byte) and sparse contexts (bytes 2–3 back; with
`cm:8`/`cm:9` also bytes 3–4 back) in a hash table of 64-byte buckets of four nibble slots;
adaptive state maps; a match model; six mixers of 16 inputs (16-bit weights; SSE2 on x86,
including the 32-bit builds with `-msse2`, NEON on aarch64, bit-exact portable C otherwise)
selected by the partial byte, match state, order × bit position, byte 2 back, byte 3 back and
byte classes; a second-layer mixer and two interpolated APMs. Blocks of 64 KB: near-random ones
(order-0 entropy > 7.92 bits/byte) are coded raw, text-like ones (≥ 50% printable, < 1/32
zeros) skip the sparse contexts. Streams up to 64 MB carry their size: the decoder decodes them
at once and frees the model before `lzp`/`dict` allocate theirs (like the old port, which always
decoded everything at once), so a chain never holds both. Memory per stream: level 6 ≈ 170 MB
(old: ≈ 200 MB plus 4× the data when compressing); blocks under 1 MB get smaller tables.

Measured on silesia files and corpus sets (`/mnt/IA_LAB/agentes/PArc/cm/data`: silesia
`dickens`, `xml`, `ooffice`, `sao`, `x-ray`, `reymont`, `osdb`, `mr`, the first 8–12 MB of
`samba`, `mozilla`, `webster`, `nci`; `exe.tar` = 16 Windows executables/DLLs of the corpus,
`mix.tar` = 82 files of every category), main (a93a44b, old) against this branch (new), Linux
x86-64, one core per job (cores 40–51 of a shared 64-thread Xeon E5-2697A v4; the machine was
loaded by other jobs, so times vary by ±5%; each figure is the best of two runs of old and new
alternating on the same core). Times are wall clock of `parc a` and `parc t`; memory is peak
RSS. Sizes include the archive.

`-mcm` alone, `PARC_THREADS=1`:

| data | old size | new size | size | comp old → new (s) | dec old → new (s) | mem comp old → new (MB) | mem dec old → new (MB) |
|---|---|---|---|---|---|---|---|
| dickens | 2193807 | 2177921 | -0.72% | 15.51 → 14.02 | 16.13 → 14.62 | 219 → 188 | 211 → 181 |
| exe.tar | 3572147 | 3338387 | -6.54% | 20.80 → 19.02 | 21.86 → 18.47 | 219 → 189 | 214 → 184 |
| mix.tar | 2532113 | 2435826 | -3.80% | 12.91 → 10.89 | 13.55 → 11.34 | 219 → 181 | 209 → 180 |
| moz12 | 5054473 | 5014123 | -0.80% | 22.03 → 14.92 | 23.75 → 15.20 | 223 → 188 | 215 → 183 |
| mr | 2207247 | 2183547 | -1.07% | 14.46 → 12.93 | 15.36 → 12.76 | 219 → 188 | 210 → 182 |
| nci6 | 298551 | 283548 | -5.03% | 7.04 → 6.16 | 7.32 → 6.34 | 204 → 181 | 204 → 178 |
| ooffice | 2257024 | 2099016 | -7.00% | 11.59 → 10.19 | 11.88 → 10.74 | 211 → 181 | 206 → 178 |
| osdb | 2335130 | 2264231 | -3.04% | 17.08 → 16.88 | 19.00 → 16.82 | 219 → 189 | 210 → 181 |
| reymont | 1047348 | 980171 | -6.41% | 9.34 → 8.27 | 9.51 → 8.50 | 214 → 181 | 206 → 178 |
| samba8 | 1993040 | 1973197 | -1.00% | 12.91 → 11.85 | 13.60 → 11.76 | 215 → 181 | 208 → 179 |
| sao | 4434518 | 4392730 | -0.94% | 15.59 → 14.33 | 16.42 → 14.71 | 223 → 180 | 209 → 179 |
| web8 | 1245098 | 1230933 | -1.14% | 11.17 → 10.26 | 11.80 → 10.59 | 215 → 181 | 207 → 180 |
| xml | 340471 | 322936 | -5.15% | 6.83 → 6.29 | 7.14 → 6.55 | 204 → 181 | 203 → 177 |
| x-ray | 3731554 | 3689429 | -1.13% | 14.96 → 13.20 | 15.43 → 13.63 | 219 → 188 | 210 → 180 |
| **total** | 33242521 | 32385995 | -2.58% | 192.22 → 169.21 | 202.75 → 172.03 | | |

`-mxx`, `PARC_THREADS=1`:

| data | old size | new size | size | comp old → new (s) | dec old → new (s) | mem comp old → new (MB) | mem dec old → new (MB) |
|---|---|---|---|---|---|---|---|
| dickens | 2161026 | 2146879 | -0.65% | 12.90 → 10.70 | 12.53 → 11.18 | 303 → 265 | 207 → 178 |
| exe.tar | 3445583 | 3248073 | -5.73% | 19.63 → 18.00 | 21.13 → 19.80 | 230 → 198 | 214 → 184 |
| mix.tar | 2525369 | 2453164 | -2.86% | 12.27 → 9.82 | 12.43 → 9.99 | 228 → 189 | 209 → 180 |
| moz12 | 4983787 | 4952018 | -0.64% | 20.17 → 14.38 | 21.17 → 14.12 | 234 → 198 | 216 → 184 |
| ooffice | 1905377 | 1784763 | -6.33% | 11.04 → 9.50 | 11.11 → 9.86 | 222 → 188 | 207 → 179 |
| osdb | 2338294 | 2268209 | -3.00% | 17.79 → 16.41 | 17.74 → 16.51 | 230 → 198 | 211 → 183 |
| reymont | 992136 | 955124 | -3.73% | 5.74 → 5.36 | 5.78 → 5.21 | 281 → 252 | 202 → 175 |
| samba8 | 1995155 | 1969468 | -1.29% | 12.11 → 10.19 | 12.19 → 11.01 | 224 → 190 | 209 → 180 |
| web8 | 1242542 | 1220390 | -1.78% | 8.40 → 8.13 | 8.54 → 7.27 | 290 → 258 | 204 → 176 |
| xml | 327866 | 314416 | -4.10% | 4.14 → 3.60 | 4.24 → 3.53 | 283 → 257 | 200 → 175 |
| **total** | 21917135 | 21312504 | -2.76% | 124.19 → 106.09 | 126.86 → 108.48 | | |

`PARC_THREADS=4` (`textdir` = dickens + xml + reymont + 8 MB of webster; `exe`, `mix` = the
folders of the tars above), `-mxx` and `-mcm`:

| data | old size | new size | size | comp old → new (s) | dec old → new (s) | mem comp old → new (MB) | mem dec old → new (MB) |
|---|---|---|---|---|---|---|---|
| exe | 3441037 | 3244252 | -5.72% | 20.37 → 19.81 | 21.01 → 20.31 | 231 → 198 | 214 → 184 |
| mix | 2526017 | 2442935 | -3.29% | 9.14 → 8.22 | 9.19 → 8.99 | 439 → 358 | 403 → 322 |
| textdir | 4773051 | 4642601 | -2.73% | 32.00 → 27.94 | 32.50 → 30.13 | 368 → 316 | 220 → 187 |
| **total** | 10740105 | 10329788 | -3.82% | 61.51 → 55.97 | 62.70 → 59.43 | | |

| data | old size | new size | size | comp old → new (s) | dec old → new (s) | mem comp old → new (MB) | mem dec old → new (MB) |
|---|---|---|---|---|---|---|---|
| exe | 3569331 | 3331427 | -6.67% | 20.83 → 18.62 | 21.67 → 19.72 | 224 → 188 | 214 → 183 |
| mix | 2527167 | 2434571 | -3.66% | 17.62 → 14.38 | 16.81 → 14.10 | 214 → 188 | 208 → 179 |
| textdir | 4805925 | 4682119 | -2.58% | 42.53 → 42.39 | 45.88 → 41.65 | 238 → 205 | 232 → 201 |
| **total** | 10902423 | 10448117 | -4.17% | 80.98 → 75.39 | 84.36 → 75.47 | | |

`-mcm`, `PARC_THREADS=1`, the linux32 builds (old: FPC i386 code; new: the SSE2 mixer, same bytes
as linux64):

| data | old size | new size | size | comp old → new (s) | dec old → new (s) | mem comp old → new (MB) | mem dec old → new (MB) |
|---|---|---|---|---|---|---|---|
| dickens | 2193807 | 2177921 | -0.72% | 30.57 → 19.07 | 28.71 → 19.88 | 216 → 188 | 210 → 181 |
| exe.tar | 3572147 | 3338387 | -6.54% | 39.72 → 27.16 | 39.63 → 28.07 | 217 → 188 | 213 → 183 |
| mix.tar | 2532113 | 2435826 | -3.80% | 32.05 → 21.84 | 32.84 → 21.82 | 217 → 179 | 208 → 179 |
| ooffice | 2257024 | 2099016 | -7.00% | 27.75 → 20.35 | 29.25 → 20.59 | 208 → 180 | 206 → 177 |
| web8 | 1245098 | 1230933 | -1.14% | 21.17 → 16.51 | 22.25 → 15.61 | 213 → 179 | 206 → 179 |
| xml | 340471 | 322936 | -5.15% | 11.85 → 8.19 | 12.18 → 8.53 | 204 → 180 | 202 → 176 |
| **total** | 12140660 | 11605019 | -4.41% | 163.11 → 113.12 | 164.86 → 114.50 | | |

The model is compute-bound (about 1,100 instructions per bit; a 1 MB table runs as fast as the
128 MB one), so speed comes from SSE2/NEON mixers, unrolled loops and leaving out contexts
where they do not pay (sparse ones in text blocks). `cm:8`/`cm:9` (second sparse context in
binary blocks) are about 2% smaller on binaries and 8% slower; level 6 is the default.
Tests: `tests/cm.sh` (stage round trips, write sizes, SSE2 == C, 900 damaged streams, PArc
round trips, `PARC_THREADS=1` == 4), `tests/cm_cross.sh` (same bytes on linux64 SSE2 and C,
linux32, linuxarm64 NEON, win64, win32).

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
bash tests/orep.sh                # OREP: etapas, parámetros, 1..8 hilos, C == Pascal (-dOREP_NO_NATIVE), dañados
bash tests/plz.sh                 # plz: niveles, ventanas, streaming == memoria, asm == Pascal, dañados
bash tests/plz_cross.sh           # plz: mismos bytes en linux64/linux32/linuxarm64 (QEMU)/win64/win32 (Wine)
bash tests/delta.sh               # delta: tablas sintéticas de cada formato, trozos al azar, asm == Pascal, dañados
bash tests/lzp.sh                 # lzp: parámetros de los presets y extremos, trozos al azar, dañados
bash tests/filters_cross.sh       # delta/lzp: mismos bytes en linux64/linux32/linuxarm64/win64/win32
bash tests/cm_cross.sh            # cm: mismos bytes en linux64 (SSE2 y C)/linux32/linuxarm64 (NEON)/win64/win32
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
