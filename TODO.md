# PArc — pending work and details

Updated: 2026-10-21  
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

PArc is **3,9 % smaller and ~5,9× slower**. Full per-level table:

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

## P1 — level monotonicity on TILIN

On this archive, `-m2`, `-m3` and `-m5` are worse than `-m1`/`-m4`:

- `-m1`: 57,76 %; `-m2`: 61,05 %; `-m3`: 60,73 %; `-m4`: 56,06 %; `-m5`: 60,52 %.
- `-m6`…`-m9` then improve sharply (45,54 % → 40,25 %) at slow speeds.

Likely caused by the per-type methods chosen by those presets on a large tar. Investigate method
selection/grouping so levels are monotonic on large single files, without regressing the four
standard corpora. Candidate: use LZMA for large binary blocks at m2/m3/m5, or adjust the group
rules.

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
- [ ] Preset monotonicity for large single files.
- [ ] Exact BCJ2 (optional).
