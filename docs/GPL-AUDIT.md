# GPL audit: FreeArc-derived code outside the codecs (2026-11-23)

Purpose: list what is still derived from FreeArc 0.67 (Bulat Ziganshin, GPL) in the parts of
`src/` that are **not** codecs, so it can be rewritten before PArc moves to MIT. Sources used:
source comments ("como FreeArc", "port de", names of FreeArc `.hs`/`.cpp` files), `git log`, and
the structure of each unit. Line numbers are at commit `e4e76fd`.

Confidence: **high** = the code says it ports a named FreeArc function/file, or reproduces its
structure step by step; **medium** = same behaviour and same decomposition, written in Pascal
without the original at hand, or implemented from FreeArc's format description; **low** =
only the observable behaviour (CLI semantics, messages) is FreeArc's, the code is ours.

Only "high" and "medium" need a rewrite. Copying observable behaviour (option syntax, defaults,
which files go together) is fine; porting the code is not.

## 1. Inventory

| file:lines | what | origin | confidence | action |
|---|---|---|---|---|
| `src/parc_filelist.pas:1-1470` (whole unit) | file sort "gerpn", `reorder`, `find_type`, `splitFileTypes`/`check`/`bestType`/`chooseType`, `splitToSolidBlocks`, `splitBy`/`splitLenMin`/`splitLenMax`/`solidBlockLen`, `parseSolidOption`, `typeByCompressor`, `VeryFast?` | step-by-step port of `ArhiveFileList.hs`, `Cmdline.hs` (`parseSolidOption`, `find_type`, `clevel`), `Compression.hs` (`typeByCompressor`), `Utils.hs` (`match`, `merge`), `UTF8Z.hs` (`comparePS`) | high | **removed**: replaced by own `parc_solid.pas` (2026-11-23) |
| `src/parc.lpr:1118-1153` `GroupNewEntries` | calls the above | glue | low | rewritten over `parc_solid` |
| `src/parc.lpr:1160-1304` `PlanUpdate` | `join_lists` + merge by the gerpn key + `splitToSolidBlocks` keeping whole old blocks | port of the update path of `ArhiveFileList.hs`/`Utils.hs merge` | high | **rewritten** (own plan: copy whole blocks, rewrite broken ones in place, new files in new blocks) |
| `src/parc_encoders.pas:44-500` `T4x4EncStage`/`T4x4EncJob` | 4x4 encoder: per-block `[Int32 OutSize][U32 InSize]` records, version word 0, `order0_compression_ratio` skip, block size rule | port of `_4x4MTCompressor` (`Compression/4x4/C_4x4.cpp`) and its stream format | high | **removed**: own `parc_4x4.pas`, own stream (FORMATO-PARC §6.11) |
| `src/parc_encoders.pas:552-690` `Parse4x4`, `Balance4x4`, `Adaptive4x4Block`, `Has4x4BlockParam` | 4x4 parameters (`b`, `t`, `r`, inner method) | `parse_4x4` of `C_4x4.cpp` (parameter syntax) + own balancing | medium (syntax) / low (balancing is ours) | parameters kept (observable), code rewritten with the stage |
| `src/parc_methods.pas:210-400` `Inner4x4Method`, `T4x4Stage`, `T4x4Job` | 4x4 decoder | port of the `C_4x4.cpp` reader/format | high | **removed**: own `parc_4x4.pas`, own stream (FORMATO-PARC §6.11) |
| `src/parc_parallel.pas:21-25, 126-160, 794-941` `TParallelBlockStage` | ordered parallel block decoding | "como el MTCompressor de FreeArc" (idea: decode blocks in a pool, deliver in order); the pool, budget and job ring are our own code (git: 0bbbbbd, eb2f7d7, 45f1ddf, written for PArc) | low | comment reworded; nothing to port |
| `src/parc_parallel.pas:1-20, 160-790` budget, `TJobPool` | thread budget, pools | own (PArc) | none | — |
| `src/parc_encoders.pas:85-125, 689-1125` (non-4x4) | chain builder, memory estimates, `FitEncodeMem`, `LimitMethodToSize`, srep/bcj/orep stages | own code; *behaviour* of FreeArc's `SetDictionary`/`limit_compression_memory` (comments at :90, :101) | low | keep; reword comments |
| `src/parc_encoders.pas:961-1030` `TSrepEncStage` | 1-byte srep header (`1` = srep stream, `0` = stored) | FreeArc's SREP framing | medium | goes with the SREP codec rewrite (codec, out of this scope) |
| `src/parc_archive.pas:1-492` | reader of the container: end descriptor, FOOTER, DIR_BLOCK columns, signature `ArC\x01` | written from FreeArc's *format description* ("el formato base de FreeArc", FreeArc-ex doc §3/§5/§6); code is ours | medium (format), low (code) | own container format later (see §3) |
| `src/parc_writer.pas:114-150, 336-470` | local descriptor, DIR_BLOCK, FOOTER serialization; `enumDirectories` order (:380); "provisional footer first" like `ArcvProcessRead.hs` (:1235) | same format description; the directory-numbering and provisional-footer steps follow the `.hs` structure | medium | own container format later (see §3) |
| `src/parc_writer.pas:150-200` | recovery record = two storing `RECOVERY_BLOCK`s | layout of `ArcRecover.hs` | medium | with §3 |
| `src/parc_recovery.pas:198-240, 241-400` | writer "espejo de ArcRecover.hs:104-181", `parseNumber` (`Utils.hs`), `-rr` spec parsing "como ArcRecover.hs (writeRecoveryBlocks)" | port of the recovery-record writer structure; the RS math (`parc_rs`, `parc-rs1`) is ours | high (198-240 writer, 274-330 spec) / none (RS) | rewrite with own recovery layout (open) |
| `src/parc_bytes.pas:1-255` | VInt (shortest form, 0xFF+8 bytes from 2^56, `ByteStream.hs`), CStr, U32 readers/writers | FreeArc's primitive encoding (`ByteStream.hs`), code ours | medium (format) | own container format later (§3) |
| `src/parc_lzma.pas:1-10` | LZMA raw stream "como lzma_decompress2 de FreeArc" (end marker framing) | decoder from LzmaSpec (public domain); only the framing convention is FreeArc's | low | — |
| `src/parc.lpr:628-700` `CollectEntries.Walk` | directory walk order "como findFiles_FileInfo" | behaviour (order) | low | keep |
| `src/parc.lpr:1003-1022` `ResolveRecovery` | `-rr` defaults "como ArcRecover.hs" | behaviour | low | keep |
| `src/parc.lpr:1023-1110` `-s` default, `-mc` (`Cmdline.hs`, "implementación propia") | option semantics | behaviour | low | keep |
| `src/parc.lpr:1416-1560, 2064, 2226-2400` | CmdModify, password options "como Cmdline.hs" | behaviour | low | keep |
| `src/parc_select.pas:1-368` | -n/-x/-sm/-sl/-ta/-tb/-ap/@list "al estilo de FreeArc 0.67, Options.hs; implementación propia" | behaviour | low | keep |
| `src/parc_extract.pas:47-110` | wildcards "estilo FreeArc", `*.*` matches names without dot | behaviour | low | keep |
| `src/parc_console.pas:28-40` | output format (thousand separators, timing line) | behaviour | low | keep |
| `src/parc_volume.pas`, `parc_stream.pas`, `parc_outstream.pas`, `parc_progress.pas`, `parc_strmap.pas`, `parc_os.pas`, `parc_crc.pas`, `parc_rs.pas`, `parc_crypt.pas`, `parc_aes.pas`, `parc_chacha.pas`, `parc_blake2.pas` | — | own code / specs | none | — |

Codecs (outside this audit, listed for completeness): `parc_srep.pas` (SREP 3.93 port, high),
`parc_dict.pas`/`parc_dictenc.pas` (Dict port, high), `parc_lzmaenc.pas` FreeArc `fast`
additions (agent a), `parc_presets*`/`parc_canon`/`parc_filetype`/`parc_methods` helpers
(agent b; `parc_presets_data.inc` is FreeArc's `arc.ini`/`arc.groups` text).

## 2. Rewritten in this round (details and measurements in ESTADO.md)

- `parc_filelist.pas` → removed (done); replaced by `parc_solid.pas` (own design, documented in
  `ESTADO.md` "Solid planning"): same CLI semantics for `-s…`, `-ds`-like ordering by type and
  extension, own twin clustering, own content typing, own block splitting and update planning.
- `PlanUpdate` in `parc.lpr` → own plan over `parc_solid` (done).
- 4x4 → own stream format (`FORMATO-PARC.md` §6.11) and own encoder/decoder (`parc_4x4.pas`): done.

(See ESTADO.md for what landed and the measurements.)

## 3. When the last piece is gone

- **Container format** (`parc_archive`, `parc_writer`, `parc_bytes`, recovery layout) is still
  FreeArc's on-disk structure (descriptors, footer, DIR_BLOCK columns, VInt). Formats are not
  code and our implementation is ours, but for a clean MIT story the container should get its
  own layout (pre-1.0: no compatibility needed). Do this last, together with the recovery
  record layout.
- **`reference/freearc-0.67/`** (2.9 MB of FreeArc sources and notices): delete it from the tree
  once no file is derived from it any more (keep only a pointer to the git commit that had it,
  as with `82ea8d9`). While any GPL-derived file remains it must stay (it carries the notices).
- **`LICENSE`**: replace GPL-2.0 by MIT (copyright holder: PArc authors). Keep third-party
  notices next to their code: LZMA SDK (public domain, statement only), LZ4 (BSD-2, notice
  required), libsais / libbsc QLFC (Apache-2.0, `src/bwt/NOTICE`), OREP (MIT).
- **`README.md`** license table (`rep, 4x4, dict, mm, tta, srep` row, `cm` row) and the
  "License" paragraph; **`docs/LIBRERIAS.md`**: drop FreeArc as a source; **`docs/ESTADO.md`**
  "Ported codecs" row; source headers that say "port de"/"como FreeArc" (reword to describe the
  behaviour only).
- `parc_presets_data.inc` is FreeArc's `arc.ini`/`arc.groups` text: it must be regenerated
  from our own tables (agent b) before the switch.
