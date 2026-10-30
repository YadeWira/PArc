# PArc — pending work and details

Updated: 2026-10-29 (block scheduling under the thread budget)  
Current release: **0.0.2** (`v0.0.2`, GitHub release published).  
Format: `.parc` only. License: GPL-2.0.

This file is the project backlog. It records decisions, measurements and acceptance criteria so
the next session does not need to rediscover them.

## P0 — large single-file speed: Tornado/REP

### Problem

`TILIN.tar` (1.876.746.240 bytes, a single file) is one solid block because a single file is not
split by `-s`. PArc `-m1` uses `rep:96mb + 4x4:tor:16mb`.

| | FreeArc `aX.exe` | PArc 0.0.2 |
|---|---:|---:|
| Size | 1.127.602.562 | 1.083.919.516 |
| Ratio | 60,08 % | 57,76 % |
| Time | **1,98 s** | 11,64 s |
| Speed | **949,6 MB/s** | 153,7 MB/s |

PArc is **3,9 % smaller and ~5,9× slower**. Full per-level table (0.0.2, before the `rep` fix
below; `-m2`/`-m3`/`-m5` are now 56,39 % / 56,26 % / 56,06 %):

| Level | Size | Ratio | Compression | Verification |
|---|---:|---:|---:|---:|
| `-m1` | 1.083.919.531 | 57,76 % | 16,93 s | 4,20 s |
| `-m2` | 1.145.794.183 | 61,05 % | 48,59 s | 11,44 s |
| `-m3` | 1.139.676.422 | 60,73 % | 69,90 s | 11,30 s |
| `-m4` | 1.052.137.161 | 56,06 % | 85,06 s | 11,04 s |
| `-m5` | 1.135.883.693 | 60,52 % | 81,36 s | 11,28 s |
| `-m6` | 854.615.335 | 45,54 % | 262,99 s | 78,67 s |
| `-m7` | 832.355.742 | 44,35 % | 311,13 s | 78,21 s |
| `-m8` | 759.218.643 | 40,45 % | 286,57 s | 70,58 s |
| `-m9` | 755.317.174 | 40,25 % | 291,27 s | 68,56 s |

All runs were 4 threads; each archive was verified with `t` and deleted afterwards.

### Profile (`-m1` on TILIN)

- **43,8 %** `TCachingMF.FindMatchLen`
- **7,6 %** `TRepEncStage.ProcessJob`
- **6,7 %** `THash3MF.FindMatchLen`
- **5,6 %** `TRepEncStage.HashJob`
- **4,7 %** `TLazyMF.FindMatchLen`
- **3,4 %** `TTorEngine.Run`
- **3,3 %** `TCachingMF.UpdateHash1`
- **3,0 %** `TTorCoder.Encode`

The bottleneck is the Pascal Tornado match finder and REP, not the container or I/O.

### Single-thread comparison (2026-10-21)

With one thread on both sides (`PARC_THREADS=1`, `Arc.exe -cfg- -mt1` under Wine, same machine),
the gap disappears: `-m1` is 40,1 s for PArc vs 40,7 s CPU for FreeArc, with 57,76 % vs 57,60 %.
So the ~5,9× gap above is about **how each tool parallelizes a single large file**, not raw
match-finder speed. FreeArc also picks different methods depending on `-mt` (with `-mt4` its
`-m2` is `rep:96mb+4x4:tor:16mb`; with `-mt1` it is smaller), so 1- and 4-thread comparisons do
not compare the same FreeArc methods.

| Level | PArc | FreeArc | Δ size | PArc comp. | FreeArc comp. | PArc `t` | FreeArc `t` |
|---|---:|---:|---:|---:|---:|---:|---:|
| `-m1` | 57,76 % | 57,60 % | +0,26 % | 40,1 s | 52,9 s (40,7 CPU) | 10,7 s | 19,5 s |
| `-m2` | 56,39 % | 56,39 % | −0,00 % | 157,5 s | 146,8 s | 35,8 s | 29,8 s |
| `-m3` | 56,26 % | 54,80 % | +2,68 % | 238,4 s | 401,5 s | 37,5 s | 99,7 s |
| `-m4` | 56,06 % | 54,51 % | +2,85 % | 436,5 s | 529,5 s | 41,6 s | 90,1 s |
| `-m5` | 56,06 % | 54,43 % | +3,00 % | 297,4 s | 894,9 s | 36,1 s | 103,9 s |
| `-m6` | 45,54 % | 45,54 % | −0,01 % | 796,2 s | 732,8 s | 85,8 s | 75,2 s |
| `-m7` | 44,35 % | 44,36 % | −0,03 % | 842,8 s | 747,5 s | 83,9 s | 73,4 s |
| `-m8` | 40,45 % | 40,46 % | −0,01 % | 654,4 s | 661,1 s | 78,5 s | 66,8 s |
| `-m9` | 40,25 % | 40,29 % | −0,10 % | 652,3 s | 671,5 s | 78,7 s | 67,0 s |

One run per level on a shared, loaded machine (load 15–35): times are noisy. PArc `-m2`/`-m3`/`-m5`
include the `rep` fix. Report: `/mnt/IA_LAB/agentes/PArc/bench_tilin_1thread.md`.

Open points from this run:

- `-m3`…`-m5` are 2,7–3,0 % larger than FreeArc on TILIN (FreeArc uses LZMA 96 MB there, PArc
  `4x4:lzma:8mb`), while compressing 1,2–3× and verifying 2,2–2,9× faster. Decide whether large
  blocks should get a bigger LZMA dictionary.
- `-m6`…`-m9` verification is 14–18 % slower than FreeArc (PPMd decode).
- `-m4` and `-m5` produce the same size on large binaries (same effective method).

### Experiments already tried

| Variant | Size | Time |
|---|---:|---:|
| `rep:96mb + 4x4:tor:16mb` (current) | 1.083.919.516 | 11,64 s |
| `rep:96mb + 4x4:tor:4` | 1.098.579.801 | 9,98 s |
| `4x4:tor:16mb` | 1.457.292.105 | 9,14 s |
| `4x4:tor:4` | 1.498.244.805 | 4,93 s |
| `4x4:lz4` | 1.597.855.697 | 4,20 s |
| `PARC_THREADS=16` | 1.083.919.516 | 10,9 s |
| `4x4` with 64-worker cap (temporary) | 1.083.919.516 | 11,9 s |

Also tried and reverted, with no measurable gain: swapping the hash position/key pair with a
single 64-bit move in `FindMatchLen`.

### Next options

0. First compare multi-thread behaviour: how FreeArc splits/parallelizes one large file at
   `-mt4` vs PArc's `4x4`; that is where the gap is.
1. Optimize/port the Tornado match finder and REP (C/asm or a much tighter Pascal path),
   preserving the stream; target is a large fraction of the current 43,8 % hotspot.
2. Add a multi-stream mode for a single large file (e.g. 16/32 independent LZ77 streams); measure
   the ratio cost. This would use more cores without changing the container.
3. Do not change `-m1` to `lz4`/`tor:4`: it loses ~22–27 points of ratio.

Acceptance: for TILIN, `-m1` should be materially faster without giving up the ~57,8 % ratio;
otherwise keep the current preset.

## P0 — PPMd7 port

7-Zip PPMd (`Ppmd7`, public domain) is 30–45 % faster than our FreeArc-compatible PPMd, but its
ratio alone is not better. Measurements on a 20 MB text file:

| Implementation | Size | Compress | Decompress |
|---|---:|---:|---:|
| PArc `ppmd:16:384m` | 2.176.051 | 2,89 s | 3,14 s |
| PArc `ppmd:18:1g` | 2.159.448 | 3,13 s | 3,49 s |
| PArc `dict+lzp+ppmd:16` | **2.103.674** | 3,64 s | 3,01 s |
| 7-Zip PPMd `o18:1g` | 2.162.416 | 2,25 s | 2,24 s |
| 7-Zip PPMd `o20:1g` | 2.152.065 | 2,40 s | 2,77 s |

Plan: port `Ppmd7.c`/`Ppmd7Enc.c`/`Ppmd7Dec.c` to Pascal, add a `ppmd7` method, keep our
`dict+lzp` preprocessing, and use it only if it passes the gate:

1. size <= current `dict+lzp+ppmd`;
2. compression faster;
3. decompression faster.

A direct replacement without preprocessing does not pass the ratio gate.

## Done — level monotonicity on TILIN

Cause: the PArc-specific `2$binary`/`3$binary`/`5$binary` (and `$obj`) overrides used bare `rep`
(64 MB window) instead of the level's `#rep` (`rep:96m`). On small corpora the window is clipped to
the block, so it did not show; on a 1,8 GB tar, matches 64–96 MB away were lost (dictionary 8 MB vs
96 MB LZMA only accounts for ~0,35 %). Fixed by using `2rep`/`3rep`/`5rep`.

TILIN now: `-m1` 57,76 %, `-m2` 56,39 %, `-m3` 56,26 %, `-m4` 56,06 %, `-m5` 56,06 %, then
45,54 % → 40,25 %. Linux suite passes; on a 151 MB binary corpus `-m2` is 3,3 % smaller, `-m3`
+744 bytes, `-m5` identical.

## Done — container I/O (branch perf/container-io)

- Planning (FindType, gerpn sort, Reorder, update merge) and BuildDirectory without O(n^2);
  Unix enumeration with readdir + one lstat. Archives byte-identical to 2f7f7f4.
- Parallel compression: no `.blkN` temp files (block in turn streams into the archive; the
  rest wait in a global budget, min(1 GB, RAM/4), `PARC_BUFMEM`); one thread writes directly.
- Parallel extraction: workers write the files directly (no `.dec` temps, no 2 GB cap).
- CRC-32 with PCLMULQDQ on x86-64 (CPUID dispatch, tables elsewhere).
- Directory tag 8 (`MTIME_SUBSEC`): 6–10 % smaller directories with random ns; 0.0.2 reads
  such archives with second-precision mtimes.

Open points:

- `d` without `-m` repacks the affected solid block with the default `-m4`; FreeArc reuses the
  block's old method (10 s vs 31 s CPU on 24 MB, but 35 % larger). Decide the policy.
- High-entropy files are not routed to storing at `-m1`/`-m5+` (FreeArc neither).
- Many-file FreeArc numbers are under Wine (file creation dominates); compare natively on win10.

## Done — block scheduling under the thread budget (branch perf3/sched)

See docs/ESTADO.md ("Block scheduling under the budget"): linear method grouping and parallel
file-type detection in planning, largest-first solid blocks, smaller/tapered 4x4 blocks for
fast inner methods when the data is short for the threads, bt4 always with its 3 threads.
Measured on the shared 64-core machine (load 10–35, pinned to idle cores, minimum of 2 runs;
FreeArc times are its internal ones under Wine), compress / `t` wall s, 3e8f8cb → now:

| set, level | N=2 | N=4 | N=8 | FreeArc `-mt4` |
|---|---|---|---|---|
| small `-m1` | 0.83 / 0.19 → 0.66 / 0.13 | 0.84 / 0.20 → 0.64 / 0.12 | 0.86 → 0.59 | 3.48 / 1.04 |
| small `-m2` | 2.65 → 1.48 | 2.61 → 1.07 | 2.72 → 1.06 | 6.56 / 1.77 |
| small `-m9` | 4.67 → 2.90 | 4.18 → 2.38 | 4.00 → 2.48 | 10.86 / 3.27 |
| exe `-m1` | 2.68 / 1.13 → 2.24 / 0.85 | 1.68 / 0.72 → 1.39 / 0.46 | 1.42 / 0.65 → 0.80 / 0.32 | 0.68 / 0.48 |
| exe `-m2` | 4.93 → 4.64 | 3.14 → 2.95 | 2.34 / 0.73 → 1.66 / 0.45 | 2.21 / 0.79 |
| document `-m1` | 1.87 → 1.73 | 1.22 / 0.52 → 1.26 / 0.45 | 1.18 / 0.49 → 0.87 / 0.26 | 0.93 / 0.38 |
| text `-m1` | 1.71 → 1.73 | 1.41 / 0.46 → 1.32 / 0.42 | 1.21 / 0.40 → 1.01 / 0.29 | 2.15 / 0.74 |
| text `-m2` | 5.50 → 5.54 | 4.02 → 3.99 | 3.29 → 2.31 | 3.84 / 1.26 |

`-m3`…`-m9` on these sets and the 512 MB slice (`-m1`, `-m2`, `-m5`, N=2/4/8) are within the
noise of the machine (±15 %). Sizes: `-m3`+ unchanged except block order (± a few bytes of
directory); `-m1`/`-m2` with the smaller 4x4 blocks: exe `-m1` −0.2 % (N=4), small `-m1`
+0.65 %, document `-m1` +0.3 % (N=4) / +0.7 % (N=8), document `-m3` N=8 +0.8 %. Archives are
identical across runs for the same N and differ between N (as before). Logs and scripts:
`/mnt/IA_LAB/agentes/PArc/impl3/sched/`.

These comparisons are **N=2/4/8 only**; "within the noise" above is against 3e8f8cb, not a
claim that `-m3`+ beats FreeArc on all three metrics at every N. At N=1 it does not (see the
first open point). The largest-first sort of the solid blocks was an insertion sort over the
records (quadratic: one block per file with `-s-`, 40,000 files of growing size took ~26 s of
planning); it is now a merge sort of indexes, archives byte-identical (`tests/block_order.sh`).

Open points:

- **N=1, document `-m3`: compression ~1.8× slower than FreeArc `-mt1`** (pre-existing, same at
  3e8f8cb). 2026-10-29, load ~4, 2 runs: PArc 37,313,130 B, `a` 12.97 / 13.36 s, `t` 1.86 /
  1.92 s; FreeArc 38,454,002 B, `a` 7.10 / 7.50 s real, `t` 2.93 / 2.75 s. Size and `t` win,
  `a` loses: 66 MB of the 101 MB go through `rep+exe+delta+4x4:lzma:8mb:normal` (bt4, one
  thread). Needs a 1-thread `-m3` preset (like `-m1`/`-m2`) or a faster lzma normal.
- `-s-` with thousands of small files, N=1: ~+20 % system time vs 3e8f8cb on the `small` set
  (`-s- -m1`: 12.3–13.0 s vs 10.5–10.7 s, CPU sys 8.3–8.8 vs 7.0 s). Not the block sort (fixed,
  above): with the largest-first order each block's `TRepEnc` hash (~1 MB) and `TTorCoder`
  (~256 KB) land on FPC heap OS chunks that are mmapped and unmapped again per block (4,090
  more mmap/munmap pairs of 1 MB + 256 KB than at 3e8f8cb). Reusing those per thread (as
  `TTorEncCache` does for 4x4) would remove it.
- `-m1`/`-m2` on binaries/documents at N≥2 are still behind FreeArc in compression time:
  scheduling is no longer the limit (exe `-m1` N=4 uses ~3.4 of 4 cores), the preset is.
  FreeArc `-mt4` uses `rep:96mb+4x4:tor:3:8mb` at `-m1` (exe: 1.8 s CPU) where PArc uses
  `rep+4x4:tor:16mb` (tor level 5, ~4 s CPU). Pick the `-m1`/`-m2` methods by thread count
  (user decision). N=4, explicit `-m<method> -s64m`, size / compress wall / `t` wall:
  exe `4x4:tor:16mb` 81.02 MB 1.53 s 0.53 s, `tor:4:16mb` 82.29 MB 1.08 s 0.47 s,
  `tor:3:16mb` 83.05 MB 0.71 s 0.34 s (FreeArc 83.24 MB 0.68 s 0.48 s); text `tor:16mb`
  30.07 MB 1.16 s, `tor:3:16mb` 32.27 MB 0.75 s (FreeArc 32.29 MB 2.15 s). Document `-m1` is
  11 % larger than FreeArc's whatever the tor level (see below).
- `t`/`x` of text at `-m5`+ end on one thread: lzp decodes whole blocks (its match lengths are
  read from the block's end) at ~10–20 MB/s, after ppmd. Only a faster LZP decoder helps.
- document set: `-m9` is 19 % larger than `-m5` (43.8 MB vs 36.7 MB; FreeArc `-m9` 36.6 MB),
  the solid blocks are split differently; and `-m1` is 11 % larger than FreeArc's `-m1`
  (47.5 MB vs 42.6 MB). Grouping/preset issues, not scheduling.
- The front end is still serial for the rest of planning (directory scan, sort) and for
  `-m1` (no type detection there).
- The 4x4 tail split estimates what is left from the solid block's input size; with `rep`
  in front (most presets) 4x4 receives less and the split rarely happens (the 512 MB slice is
  unchanged). Scaling by what the writer has fed so far works and is deterministic, but cost
  0.3–0.9 % at `-m2` for no measurable time gain, so it was not kept.

## Done — LZMA encoder speed/ratio (branch perf2/lzma2)

512 MB TILIN slice, 1 thread, compress CPU s (FreeArc 0.67 `-mt1`), size:

| method | 41af3bc | now | FreeArc | size now vs FreeArc |
|---|---:|---:|---:|---:|
| `lzma:8mb:max` | 246–249 | 189–196 | 279–281 | −0.04 % |
| `lzma:8mb:normal` | 119 | 110 | 134 | −0.02 % |
| `lzma:8mb:fast` | 68 | 56 | 76 | same stream |
| `lzma:96mb:max` | 289–307 | 229–250 | 353–376 | −0.06 % |
| `lzma:96mb:normal` | 152 | 149–152 | 154–161 | −0.03 % (speed: only 1–8 % ahead) |

Decoding is ~13–15 s vs FreeArc's ~20.5 s.

128 MB of the slice (offset 128 MB), 2 interleaved runs, compress wall s (CPU s), size; 4 threads
= `PARC_THREADS=4` vs FreeArc `-mt4`:

| method | threads | 41af3bc | now | FreeArc | size now / FreeArc |
|---|---:|---:|---:|---:|---:|
| `lzma:8mb:max` | 1 | 48.1 | 30.8–30.9 | 60.2–60.6 | 113,772,538 / 113,782,760 |
| `lzma:8mb:max` | 4 | 23.5 (47.6) | 19.5–20.4 (36–38) | 26.9–27.9 (49–51) | same / 113,782,801 |
| `lzma:96mb:max` | 1 | 60.8–75.8 | 37.3–68.3 | 90.7–93.7 | 113,931,550 / 113,959,261 |
| `lzma:96mb:max` | 4 | 28.6–30.6 | 26.1–27.2 (44–46) | 32.5–33.4 (59–62) | same / 113,959,455 |
| `lzma:8mb:normal` | 1 | 27.3–28.4 | 22.7–25.1 | 29.6–29.8 | 113,835,386 / 113,844,818 |
| `lzma:8mb:normal` | 4 | 24.8–27.1 | 17.1–17.3 (28–29) | 25.4–25.5 (38) | 113,835,322 / 113,840,155 |
| `lzma:96mb:normal` | 1 | 42.7–48.6 | 38.5–44.2 | 44.7–49.5 | 113,940,940 / 113,949,646 |
| `lzma:96mb:normal` | 4 | 39.6–46.6 | 20.0–21.9 (prefetch 8) | 26.7–27.2 (45) | 113,935,194 / 113,941,108 |
| `lzma:8mb:fast` | 1 | 21.4–22.5 | 18.1–19.6 | 27.3–28.8 | same stream (+17 B) |
| `4x4:lzma:8mb:max` | 4 | 9.8–10.0 | 7.3 (27) | 7.7–7.8 (46) | 113,790,367 / 113,838,111 |
| `4x4:lzma:8mb:normal` | 4 | 6.8–7.5 | 6.1–6.7 (23–25) | 7.2 (38) | 113,849,098 / 113,869,118 |
| `4x4:lzma:8mb:fast` | 4 | 5.8–6.2 | 4.9–5.2 | 7.9–8.4 | same stream (+17 B) |

The 1-thread `lzma:8mb:max` gain (48.1 → 30.8 s, −36 %) is specific to this nearly
incompressible 128 MB sample. Other 64 MB pieces of TILIN, same interleaved setup: offset 460 MB
of TILIN.tar 16.1–16.6 → 13.1–13.3 s (−19 %); first 64 MB of the slice 20.5–21.5 → 18.7–19.4 s;
last 64 MB 20.6–21.3 → 18.4–18.7 s (−11 %) and there the output is 1,211 bytes larger than
41af3bc's (25,870,691 vs 25,869,480). Expect 10–20 % on ordinary data.

Test (decode) 5.3–5.9 s vs FreeArc 8.6–9.8 s. Whole 512 MB slice at 4 threads: `lzma:8mb:normal`
256,882,734 in 81–93 s vs FreeArc 256,921,155 in 105–169 s (machine loaded);
`4x4:lzma:8mb:normal` 261,132,045 vs 261,261,944; `4x4:lzma:8mb:max` 257,218,019 vs 257,986,572.

Notes and open points:

- Thread grant: `WriteArchive` sets `LzmaEncThreadGrant` (whole budget for a lone block,
  `budget div blocks in flight` in parallel); in a rep+lzma chain lzma takes the threads it can
  use first and REP hashes in background only with what is left (docs/ESTADO.md). bt4 uses up
  to 3 threads, ht4 `:normal` 2. Before, REP always took 2 off the grant, so at
  `PARC_THREADS=2`/`3` `-m6..-m9`/`-mx` ran lzma on one thread: 60 MB of the slice with `-m7`
  took 11.6–14.8 s vs 7.5–7.8 s now (41af3bc 8.0–9.9 s, FreeArc `-mt2/3` 11.2–11.5 s).
- REP with hashing threads was nondeterministic and lost ratio: `ResetForReuse` left the job's
  finished flag set, so from the second use of each hashing task the search did not wait for
  it (also in 41af3bc). `-mrep:58mb` on 60 MB: 28.97–29.03 MB in some runs vs 28.57 MB inline;
  4× larger on very repetitive input. Fixed; output is now the same for any thread count.
- ht4 `:normal` output with 1 thread (FreeArc `-mt1`'s list) differs from 2+ threads (FreeArc's
  multi-thread list, smaller), like FreeArc. Single 8 MB blocks with ht4 vary ±1.5 % either way
  vs FreeArc (slice @472 MB: +1.4 % with 1 thread); totals are smaller.
- `:fast` streams are identical to FreeArc's; whole-archive size then depends on the container
  (+15–20 bytes on one-file archives).
- 32 bits: big dictionaries are shrunk to what can be reserved (`lzma:1gb:normal` → 960mb under
  Wine, 2 threads, OK). Several big blocks compressed in parallel each probe on their own.
- `-m3` output on the exe set used to vary by a few hundred bytes between runs (also in
  41af3bc): it was the REP hashing race above. Now 77,813,396 every run.
- `-m5` on the exe set is still 1.7 % larger than FreeArc's (78.29 MB vs 76.96 MB; preset
  choice `4x4:i0:lzma:8mb:max` vs FreeArc's `lzma:96m:normal:mc32`), though 2.5× faster.

## P1 — BCJ2 exact

A BCJ2-style filter is present as experimental `-mbcj2`/`-mexe2`, with round-trip tests, but it is
**not used by presets**. Our simplified 4-stream filter currently loses to PArc's BCJ+delta path.
The exact 7-Zip BCJ2 comparison was:

| | Size | Compress | Decompress |
|---|---:|---:|---:|
| 7-Zip LZMA+BCJ2 | 5.814.910 | 3,56 s | 0,284 s |
| PArc `-m6` | 5.917.742 | 5,84 s | 0,700 s |

Next: port the exact BCJ2 encoder/decoder (public domain) or improve stream framing/settings;
only use in presets if it improves size and speed.

## P1 — real Windows test for 0.0.2

0.0.1 was tested on real Windows 10 and Windows 7 (x64 and x86). 0.0.2 only changes the version
and CLI timing output, and its Windows binaries were smoke-tested under Wine. Before a future
release, repeat the real Windows 10/7 matrix for the current build.

## P2 — CLI and docs

Done in 0.0.2:

- `parc`, `parc help`, `parc help <command>`, `--version`/`-V`;
- structured `l` listing with summary;
- creation/test/extract time, ratio and speed.

Still to consider:

- `parc help options` or a dedicated `parc options` page;
- machine-readable output (JSON/CSV) for scripting;
- tests for the new help/version output in `tests/cli.sh` are in place; keep them in sync with
  the version string.

## P2 — docs and repository

- `reference/freearc-0.67/Compression/` stays in the repo (3,2 MB): not used to build PArc, but
  used by test oracles and preserves FreeArc provenance. Keep unless intentionally moving to a
  separate reference repository and updating tests to fetch it.
- `TILIN.tar` is a local 1,8 GB test file and is ignored by `.gitignore`; it must not be committed.
- Benchmark reports live in `/mnt/IA_LAB/agentes/PArc/`:
  - `bench_silesia_0.0.1.md`
  - `bench_tilin_levels.md`
  - `bench_tilin.md`
  - `bench_bcj2_comparison.md`
  - `bench_grzip_adaptive.md`

## Decisions / non-goals

- Keep GPL-2.0. MIT is not possible without replacing all GPL-derived FreeArc/lpaq1 code.
- `.arc`, `.zip`, `.7z`, `.rar` are out of scope; use FreeArc-ex for those containers.
- No GUI and no SFX creation; existing SFX archives are read and preserved on update.
- bsc/libbsc is Apache-2.0 (incompatible with GPLv2); bzip3 is LGPL-3+ (incompatible).
- Brotli is MIT but loses to PPMd/GRZip in the relevant speed/ratio ranges.
- `-mxx` is the absolute-ratio CM mode and is intentionally slow; `-mx` is the fast-decode
  maximum.
- Automatic solid blocks without `-s`: 64 MB for `-m1`…`-m3`, 32 MB for `-m4`…`-m9`/`-mx`;
  `-mxx` keeps one block.

## Release checklist

- [x] Linux full suite.
- [x] Windows 10/7 x64/x86 for 0.0.1.
- [x] Linux ↔ Windows archive round-trips for 0.0.1.
- [x] CLI/help/version/list tests.
- [x] Silesia benchmark.
- [x] 0.0.1 and 0.0.2 GitHub releases; asset hashes verified after download.
- [ ] Real Windows 10/7 re-test for 0.0.2.
- [ ] Tornado/REP speed work.
- [ ] Ppmd7 port.
- [x] Preset monotonicity for large single files.
- [ ] Exact BCJ2 (optional).
