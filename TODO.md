# PArc — pending work and details

Updated: 2026-10-21 (single-thread TILIN run, `rep` fix)  
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
- (perf3/presets) The three points above are fixed: see "Presets retune" below.

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

## Done — presets retune (branch perf3/presets)

Goal: beat FreeArc 0.67.1 on size, compression time and decompression time at `-m1`…`-m9`/`-mx`
with `PARC_THREADS=1` vs `-mt1` and `PARC_THREADS=4` vs `-mt4`. What changed (details in
docs/ESTADO.md, "Presets by thread count"):

- No automatic solid-block cap (document set `-m6` 43.8 -> 36.6 MB).
- One-thread presets use FreeArc's single-stream families with a cheap edge (`tor:4:h4m`, delta
  at `-m2`, LZMA `fast` `mc6:lc4`, `normal:16:mc8:lc4`, bt4 `normal:32:mc8` at `-m5`); the 4x4
  presets for 2+ threads use 16–24 MB blocks (FreeArc's 96 MB blocks leave one job on 100 MB).
  `-m4` and `-m5` are now different methods at every thread count.
- 4x4 compresses only the repeating 1 MB pieces of a nearly random block and stores the rest.
- GRZip with adaptive blocks (`:a`) on text; PPMd 8/192 at `-m4`, 13/192 at `-m5`.
- `*.pak` is no longer `$compressed`; `-m1` compresses the `$compressed` group; `-mx` is `-m9`
  again (as in FreeArc).

TILIN.tar (1,876,746,240 bytes, one file). PArc = final presets; FreeArc 0.67.1 under Wine with
its internal times. Minimum of 2+ runs each (PArc and FreeArc interleaved by level; shared
machine, load 10–45). Compress (`a`) and verify (`t`) wall/CPU in seconds:

**N=1 (PARC_THREADS=1 vs FreeArc -mt1)**

| level | PArc size | FA size | Δ size | PArc a wall/CPU s | FA a wall/CPU s | PArc t wall/CPU s | FA t wall/CPU s | runs P/F | loses |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| -m1 | 1,078,738,049 | 1,081,103,174 | -0.22 % | 32.2 / 32.2 | 46.5 / 50.6 | 15.2 / 15.2 | 23.1 / 22.6 | 2/2 | - |
| -m2 | 1,055,483,179 | 1,058,239,640 | -0.26 % | 92.2 / 92.2 | 206.1 / 209.8 | 23.4 / 23.4 | 30.4 / 29.8 | 2/2 | - |
| -m3 | 1,022,570,069 | 1,028,395,199 | -0.57 % | 247.3 / 247.3 | 345.7 / 351.3 | 47.3 / 47.3 | 86.4 / 85.5 | 2/2 | - |
| -m4 | 1,021,791,037 | 1,023,010,425 | -0.12 % | 358.3 / 358.2 | 447.7 / 453.7 | 49.2 / 49.2 | 84.8 / 83.9 | 2/2 | - |
| -m5 | 1,007,585,616 | 1,021,542,174 | -1.37 % | 420.6 / 420.5 | 582.9 / 589.0 | 49.9 / 49.9 | 87.5 / 86.8 | 2/2 | - |
| -m6 | 854,659,630 | 854,741,998 | -0.01 % | 423.9 / 423.5 | 736.0 / 741.1 | 45.4 / 45.4 | 74.7 / 73.9 | 2/2 | - |
| -m7 | 832,483,473 | 832,609,515 | -0.02 % | 490.4 / 489.3 | 836.2 / 842.2 | 41.6 / 41.6 | 72.6 / 71.8 | 2/2 | - |
| -m8 | 759,142,603 | 759,326,184 | -0.02 % | 473.0 / 472.9 | 719.0 / 718.9 | 40.7 / 40.7 | 63.8 / 62.8 | 2/2 | - |
| -m9 | 755,066,875 | 756,097,042 | -0.14 % | 440.5 / 440.2 | 783.6 / 783.7 | 40.4 / 40.4 | 68.2 / 66.7 | 2/2 | - |

**N=4 (PARC_THREADS=4 vs FreeArc -mt4)**

| level | PArc size | FA size | Δ size | PArc a wall/CPU s | FA a wall/CPU s | PArc t wall/CPU s | FA t wall/CPU s | runs P/F | loses |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| -m1 | 1,091,769,617 | 1,103,120,152 | -1.03 % | 5.7 / 22.0 | 6.6 / 22.3 | 3.3 / 10.3 | 3.9 / 9.8 | 2/4 | - |
| -m2 | 1,071,314,845 | 1,083,677,529 | -1.14 % | 12.2 / 45.3 | 17.4 / 60.3 | 5.1 / 15.0 | 6.0 / 15.1 | 2/2 | - |
| -m3 | 1,044,078,773 | 1,058,918,491 | -1.40 % | 40.3 / 150.7 | 70.5 / 211.0 | 9.3 / 30.5 | 17.2 / 47.8 | 2/3 | - |
| -m4 | 1,041,822,059 | 1,050,244,855 | -0.80 % | 47.8 / 179.9 | 51.3 / 280.9 | 8.9 / 30.2 | 17.2 / 47.3 | 2/4 | - |
| -m5 | 1,037,925,682 | 1,046,548,284 | -0.82 % | 58.0 / 217.0 | 57.9 / 376.5 | 8.9 / 30.3 | 16.6 / 46.8 | 4/4 | compress |
| -m6 | 854,659,630 | 854,856,052 | -0.02 % | 265.5 / 520.8 | 331.9 / 627.6 | 44.4 / 44.5 | 71.8 / 71.0 | 2/2 | - |
| -m7 | 832,483,473 | 832,579,383 | -0.01 % | 268.1 / 529.6 | 337.9 / 618.5 | 42.4 / 42.4 | 69.1 / 68.2 | 2/2 | - |
| -m8 | 759,142,603 | 759,690,384 | -0.07 % | 236.9 / 458.6 | 319.8 / 564.6 | 37.7 / 37.8 | 64.7 / 63.5 | 2/2 | - |
| -m9 | 755,066,875 | 755,862,632 | -0.11 % | 222.5 / 433.7 | 325.3 / 576.4 | 33.7 / 33.7 | 65.4 / 64.2 | 3/3 | - |

Sets of `diag/broad-sweep/sets` (~100 MB each; `small` = 7,896 files, 11 MB), the pure-text
Silesia trio `sil` (22 MB) and the 512 MB TILIN slice; same method, `S`/`A`/`T` = PArc
loses on size / compression / verification time in that cell (`r` runs below 2 are single
interleaved runs). Full table: `logs/final_sets_table.txt` in the workstream scratch.

| set | N | Δ size vs FreeArc (m1…mx) | cells where PArc loses |
|---|---|---|---|
| archive | 1 | -0.24 … -0.02 % | - |
| archive | 4 | -1.29 … +0.04 % | m4:S m5:S |
| document | 1 | -0.44 … -0.05 % | - |
| document | 4 | -2.88 … +0.07 % | m1:S |
| exe | 1 | -2.04 … -0.00 % | - |
| exe | 4 | -2.14 … +0.13 % | m3:S m5:S |
| image | 1 | -0.23 … +0.21 % | m2:S |
| image | 4 | -2.56 … -0.01 % | - |
| sil | 1 | -1.06 … -0.03 % | m3:T m8:A |
| sil | 4 | -1.05 … -0.01 % | m3:T m4:T |
| slice | 1 | -0.70 … -0.04 % | - |
| slice | 4 | -1.68 … -0.04 % | m4:A m5:A |
| small | 1 | -0.07 … +0.81 % | m2:S m3:S m4:S m5:S m6:S m7:S m8:S m9:S mx:S |
| small | 4 | -1.59 … +0.62 % | m1:S m2:S m4:S m5:S m6:S m7:S m8:S m9:S mx:S |
| text | 1 | -0.49 … -0.03 % | - |
| text | 4 | -6.43 … -0.01 % | - |

Why the remaining cells lose:

- `small` (many tiny files): the directory keeps nanosecond mtimes (random sub-second parts, ~3.4
  bytes per file after compression) and Unix modes: 127 KB vs FreeArc's 102 KB for 7,896 files,
  i.e. +0.5 % of the archive. The data blocks are smaller than FreeArc's; the ns mtimes are a
  user decision.
- `exe` and `archive` `-m3`…`-m5` with 4 threads (+0.02…+0.13 %): FreeArc's `4x4:lzma:96mb`
  is one block (one job, its LZMA match finder threaded) on these 60 MB binary blocks, i.e. a
  96 MB dictionary; PArc's 16–24 MB 4x4 blocks run in parallel (2–3x faster) but lose that much
  ratio on executables. Bigger blocks lose the time on TILIN/slice. Letting a 4x4 job use the
  threaded match finder when tokens are free would fix it (scheduler work).
- `image` `-m2` 1 thread (+0.21 %): `delta` before `tor:6` hurts these images; it wins on exe,
  slice and TILIN.
- `document` `-m1` 4 threads (+0.07 %): same method as FreeArc (`rep+4x4:tor:3`); PArc's split
  of random blocks gains less than its container/directory costs here.
- TILIN `-m5` with 4 threads: 58.0 s vs 57.9 s (minimum of 4 runs each; medians 59.7 vs 60.3
  s), a tie: FreeArc keeps 5.8 cores busy at `-mt4` (376 s CPU), PArc the 4 of its budget
  (217 s CPU). Slice `-m4`/`-m5` with 4 threads: PArc won both interleaved pairs at `-m4`
  (28.3/25.8 vs 32.3/29.3 s) and one of two at `-m5` (40.5/34.7 vs 39.8/36.5 s); the table's
  FreeArc minimum comes from earlier, less loaded runs.
- The `sil` time cells (2.68 vs 2.74 s and the like) are within the run-to-run noise of the
  loaded machine; the same methods win at the neighbouring levels.


### Review fixes (perf3/presets)

Four review findings on the retune, checked against FreeArc on the ~100 MB sets (PArc
`PARC_THREADS=N` vs `-mtN`, FreeArc internal times, 2 interleaved runs, load 2–7):

- `-m5` with 1 thread, audio set: `bt4:mc8` lost by 23 KB (76,475,171 vs 76,451,963). Now
  `lzma:96m:normal:32:bt4:mc8:lc4:pb1`: 76,381,929 (lc4 alone lost 0.9 KB on fonts, pb1 wins it
  back), no slower; all ten sets win at `-m5` N=1 except `small` (directory, as before).
- `-m4` with 4 threads, large set: `4x4:lzma:24mb:normal:20:mc6:lc4` lost by 23 KB (and archive
  by 22 KB). Now `…:mc6:lc5:pb1`: large 68,828,040 vs 69,129,232 (-0.44 %), archive
  63,853,651 vs 63,864,061, same speed (TILIN 41.0 s vs 46.3 s for FreeArc, 1,040,813,664 vs
  1,050,244,855). Stronger match finding (bt4, mc8..mc12, fb24..fb32) also fixed large but made
  the TILIN slice 4–15 % slower; `mc12` took TILIN to 46.1–46.4 s vs FreeArc's 45.2–46.9 s.
- `-m4` with 4 threads, document set 9.6 s vs FreeArc 10.3 s: REP shrinks its 66 MB binary block
  to ~47 MB and 24 MB 4x4 blocks leave two jobs for four threads. New `Balance4x4`
  (parc_encoders): with J = ceil(S/B) < N jobs and a nearly full last block, J equal blocks
  (`4x4:b<kb>`): 5.2 s. Not applied with J >= N or a small last block (equal blocks there cost
  0.03–0.7 % on exe/archive/document at `-m4`/`-m5`).
- Audio -m4 vs -m3 with 4 threads (76.49 vs 76.43 MB) and -m5 vs -m4 with 1 thread: kept.
  These levels win on the other sets and on TILIN, and FreeArc is not monotonic there either
  (audio `-mt1`: `-m4` 76,432,228 < `-m5` 76,451,963).
- Rejected: matching base 3e8f8cb on image/archive/audio/document `-m3`/`-m4` N=4 (its
  `4x4:lzma:8mb:max` took 78 s on TILIN `-m4` N=4 vs FreeArc's 46–51 s). The losses vs
  FreeArc that remain are the ones listed above (`small`; exe/archive `-m3`/`-m5` N=4).

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
- Solid blocks without `-s` have no size cap, like FreeArc (the 64/32 MB automatic cap was
  removed in perf3/presets: it cut repeats between files and the threads now work inside each
  block).

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
