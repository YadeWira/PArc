# `.parc` format — specification v1 (draft, 2026-09-24)

`.parc` is PArc's native format. It takes FreeArc 0.67's container structure (blocks,
descriptors, VInts, footer, column-oriented directory and method strings) and adds its own
fields. The base container specification lives in the FreeArc-ex repo
(`docs/FORMATO-ARC.md`) and in the original FreeArc distribution.

PArc reads and writes only `.parc`; it neither produces nor accepts `.arc`.

## 1. Own signature

| | `.arc` | `.parc` |
|---|---|---|
| descriptor / HEADER signature | `41 72 43 01` ("ArC\x01") | `50 41 72 01` ("PAr\x01") |
| HEADER version | `00 00 06 07` (0.67) | `01 00 00 00` (format 1, U32 LE) |

**Why change the signature and not just the version:** FreeArc locates the footer by its
signature in the last 4096 bytes. With the same signature, an old FreeArc would try to read a
`.parc` and fail halfway, or worse, silently ignore what it does not understand (64-bit dates,
attributes). With a different signature it says "not a FreeArc archive", which is the correct
error.

The reader identifies the format by the footer descriptor signature. The HEADER version says
which extensions may appear: a version-N reader rejects a newer file with a clear error.

## 2. Directory: optional fields (implemented)

`.arc` defines an optional-field mechanism at the end of DIR_BLOCK (the base container), which
FreeArc 0.67 never used: it only writes `tag_end = 0`. `.parc` uses it like this:

```
repeat:
  VInt  tag          (0 = end)
  Bool  mandatory    (1 = a reader that does not know the tag must fail)
  VInt  len          (data bytes for this field)
  len bytes
```

A reader skips unknown non-mandatory tags and fails on mandatory ones. All per-file arrays use
the same order as the directory columns (N = number of files in the block).

| tag | name | mandatory | data | use |
|---|---|---|---|---|
| 1 | `MTIME_NS` | 0 | N × Int64 LE | mtime in **nanoseconds** since 1970-01-01 UTC. Replaces the 32-bit `Time` column, which is still written truncated to the Int32 range |
| 2 | `WIN_ATTR` | 0 | N × U32 LE | Windows attributes (`FILE_ATTRIBUTE_*`) |
| 3 | `UNIX_MODE` | 0 | N × U32 LE | `st_mode` (permissions and type) |
| 4 | `CTIME_NS` | 0 | N × Int64 LE | reserved (creation) |
| 5 | `ATIME_NS` | 0 | N × Int64 LE | reserved (access) |
| 6 | `SYMLINK` | 0 | VInt K, then K times: VInt index, CStr target, U8 to_directory | symbolic links (and Windows junctions). The entry is a zero-size file with no data, placed in the directory block. Target in UTF-8 with `/`, as it was in the link (relative or absolute) |
| 7 | `MTIME_NS_DELTA` | 0 | N × VInt (zigzag) | like `MTIME_NS`, but each value is the signed delta from the previous file (the first one from 0). Zero precision loss; very small when many consecutive files share a date. An old reader that does not know this tag falls back to the `Time` column (seconds) |
| 8 | `MTIME_SUBSEC` | 0 | U8 k, U8 W, then N × W bytes (LE) | only the sub-second part of each mtime, in units of 10^k ns (k = 0…9; 2 for NTFS's 100 ns); W = 0…4 bytes per value (0: every file has whole seconds). The seconds come from the `Time` column, so mtime = Time × 10^9 + value × 10^k ns, again with zero loss. A value × 10^k ≥ 10^9 is a damaged archive; a field whose length is not 2 + W·N, or with k > 9 or W > 4, is ignored |

A reader that does not know `SYMLINK` extracts an empty file instead of the link. When
extracting, PArc creates links at the end and does not create ones that point outside the
destination (absolute, or with `..` escaping the root) unless `-snld` is given.

`MTIME_NS`/`MTIME_NS_DELTA` cover ±292 years around 1970, so they solve the 2038 problem of
the `Time` column (Int32) and keep NTFS (100 ns) and ext4 (1 ns) precision. PArc still reads
`MTIME_NS` from archives already created.

What PArc writes (after 0.0.2): one of `MTIME_NS_DELTA` or `MTIME_SUBSEC` per directory block,
whichever compresses smaller with the directory method (measured on the first 65,536 files).
`MTIME_SUBSEC` is only a candidate when every file's seconds fit in the `Time` column
(1901–2038); otherwise `MTIME_NS_DELTA` is written. With random nanoseconds (files copied on
ext4/NTFS) `MTIME_SUBSEC` makes the directory 6–10 % smaller; with runs of identical dates
(package installs) `MTIME_NS_DELTA` wins and the output is the same as before.

Compatibility: PArc 0.0.2 and earlier do not know tag 8 (it is not mandatory), so they list,
test and extract such archives normally, using the `Time` column: mtimes come out with
second precision. If 0.0.2 *updates* such an archive, the files it keeps lose their
sub-second part. Archives written with `MTIME_NS_DELTA` are unchanged for old readers.

`WIN_ATTR`/`UNIX_MODE` stay as fixed U32 columns: the directory compressor already reduces
them to almost nothing (removing `UNIX_MODE` entirely saved 47–124 bytes on 5,000–40,000
files), so a compact encoding is not worth a new tag.

## 3. Rest of the container (FreeArc base)

- **Blocks**: HEADER, DATA, DIR, FOOTER and RECOVERY, with the same type numbers.
- **Descriptors**: the same fields and the same CRC; only the signature changes.
- **Methods**: the same strings (`lzma:...`, `orep:...+...`, `4x4:...`); see §6 for the streams
  that are PArc's own (`ppmd`, `orep`).
- **Footer**: the same fields, including `locked`, `recovery` and `comment`. `locked` (one byte,
  0 or 1) is written as 1 by `-k`/`k`; PArc then refuses every command that would modify the
  archive.
- **Encryption**: its own scheme, not FreeArc's; see §3b.

## 3b. Encryption (scheme 1)

Encryption is the **last stage of a block's method string** (`lzma:...+xchacha20:...`). The stage
carries every public parameter the reader needs and **never the key**; the stage stored in the
archive is exactly the one the encoder used. Archives encrypted by PArc 0.0.3 and earlier
(FreeArc's `aes-256/ctr:...` scheme) are not readable any more (pre-1.0, no compatibility).

### Stage string

```
xchacha20:t<T>:m<M>:p<P>:s<salt>:c<check>:n<nonce>[:h]     XChaCha20-Poly1305 (default)
aes256gcm:t<T>:m<M>:p<P>:s<salt>:c<check>:n<nonce>[:h]     AES-256-GCM (-ae=aes)
```

| param | meaning |
|---|---|
| `t`, `m`, `p` | Argon2id passes, memory in KiB and lanes (decimal). Default `t3:m65536:p4` |
| `s` | Argon2 salt, 16 bytes, lowercase hex. Random per archive (see "Keys") |
| `c` | password check value, 8 bytes, hex |
| `n` | block nonce, 16 bytes, hex. Random for **every** block |
| `h` | (no value) the block is a control block: directory or footer (`-hp`) |

Every parameter except `h` is mandatory; an unknown or repeated parameter, wrong hex length, or a
cost outside `1 ≤ t ≤ 64`, `1 ≤ p ≤ 64`, `8·p ≤ m ≤ 4194304` (4 GiB) makes the block unreadable
(a hostile archive cannot ask for unbounded memory or time).

### Keys

```
master  = Argon2id(password, salt, t, m, p, tag length 32)          RFC 9106, version 0x13, no secret, no AD
K(label) = BLAKE2b-256(key = master, message = "PArc/1 " || label)  RFC 7693, keyed mode
check   = K("check")[0..7]
K_use   = K("data xchacha20") | K("data aes256gcm") | K("header xchacha20") | K("header aes256gcm")
```

The password is its UTF-8 bytes, as typed (no Unicode normalization). With a key file
(`-kf<file>`) the bytes given to Argon2id are

```
password || 0x00 || "PArc/1 keyfile:" || hex(BLAKE2b-256(contents of the key file))
```

(`hex` = 64 lowercase hexadecimal ASCII characters; unkeyed BLAKE2b with a 32-byte digest). With
`-kf` alone the password part is empty; with `-p`/`-hp` each of them is combined with the key
file the same way. A password typed on the command line cannot contain 0x00, so a key-file
password never equals a plain one. This changes only the password input: salt, costs, check value
and stage string are as above, and nothing in the archive says that a key file was used. A reader derives `master`
for each password it has (`-p`, `-hp`, prompts) and compares `check` (constant time): a mismatch is
reported as **wrong password** (exit code 5), not as damage; a matching check with a failing tag
is damage. `check` is 64 bits, so a wrong password passes it with probability 2^-64 and then fails
authentication. Keys are cached per (salt, t, m, p, check): Argon2 runs once per archive.

Default cost: `t = 3`, `m = 64 MiB`, `p = 4` is RFC 9106's second recommended option (for memory
constrained settings). The four lanes run in parallel (within the thread budget): ~0.12 s on a
2.6 GHz Xeon E5-2697A v4 with 4 threads (0.37 s with `PARC_THREADS=1`); the i386 build, without
native 64-bit arithmetic, takes ~0.3 s with 4 threads (1.0 s on one). The parameters
are stored per block, so they can be raised later without a format change; `-ae=chacha:t4:m256m`
chooses others.

When writing, PArc reuses the salt of a key already derived **with the same password and costs**
in the same run, i.e. the salt of the archive being updated; otherwise it draws a new one. All
blocks written in one go share one salt; each block draws its own 16-byte nonce `n`.

### Chunks

The plaintext of a block (the output of the previous stages) is cut into **64 KiB chunks**; the
last chunk has 0 to 65,536 bytes (an empty block is one empty final chunk). Each chunk is sealed as
an independent AEAD message with **empty associated data**, and stored as ciphertext followed by its
16-byte tag. `compsize` includes the tags: `n + 16·max(1, ⌈n / 65536⌉)` bytes.

| cipher | chunk key | chunk nonce |
|---|---|---|
| XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03) | `K_use` | 24 bytes: `n` (16) ‖ LE56(i) ‖ `last` |
| AES-256-GCM (NIST SP 800-38D, 96-bit nonce, 128-bit tag) | `BLAKE2b-256(key = K_use, message = n)` | 12 bytes: LE88(i) ‖ `last` |

`i` is the chunk index (0, 1, ...) and `last` is the byte 1 for the final chunk, 0 otherwise. A
reader knows a chunk is the final one because the block ends right after it (it reads one byte
ahead). This is the STREAM construction: dropping, reordering, duplicating, truncating (even at a
chunk boundary) or appending chunks, or flipping any bit, fails authentication. A chunk's plaintext
is released only after its tag verifies, so no unauthenticated byte ever reaches a decompressor.
For AES-GCM the per-block key keeps every (key, nonce) pair unique without random 96-bit nonces.

### What is bound to what

- Nothing depends on the block's absolute position, so blocks are **copied unchanged** when an
  archive is updated (`a`, `u`, `f`, `d` keep intact solid blocks), with their stage strings.
- The block nonce lives in the method string, which the directory stores: a block moved to
  another block's place (or replaced by another block of the same archive) decrypts with the wrong
  nonce and fails. With `-hp` the directory and footer are themselves authenticated (header key),
  so the whole archive structure is covered; the HEADER block (signature and version) and the
  descriptors stay in clear. The footer's descriptor necessarily exposes the footer's stage
  (salt, check, nonce, costs).
- With `-p` alone the directory is plaintext and not authenticated: names, sizes, dates and the
  compression part of each method can be read and changed. A changed method or block list makes
  decompression or the per-file CRC fail; it cannot reveal or forge encrypted data. An attacker can
  also replace the whole archive, or roll back the footer of an `-hp` archive to an older one.
- Data and control blocks use different keys, so a data block cannot stand in for a directory.

### Updating

Updating an encrypted archive needs the password of its data blocks: if `-p` is given and the
archive already has encrypted data blocks, the password is checked first against their stage; a
different password is rejected as a **wrong password** (exit 5) and the archive is left untouched,
so the data of an archive never mixes passwords. Blocks that are recompressed (`d` in a solid block,
`--recompress`) are encrypted again, with a new nonce, even when `-p` is not repeated. The directory
and footer are always rewritten, with the `-hp` password given for that run.

## 4. Writing: invariants PArc must satisfy

- VInts are always written in the shortest form (like FreeArc).
- Descriptor `compsize` and `origsize` must match what was written.
- Each file CRC is that of its original data; each control block CRC is that of its
  uncompressed data.
- The footer `rel_pos` and the directory `rel_offsets` are relative to the position of the
  containing block.
- Names are UTF-8 with `/` as separator, relative, without `..` or a root. On Windows, `\` is
  converted to `/`.
- The directory is written **after** the data blocks it describes. An archive may contain
  several DIR_BLOCKs, and all of them are listed in the footer.
- The footer descriptor must end within the last 4096 bytes.

## 5. Pending

## 5b. `.parc` recovery record: Reed-Solomon (`parc-rs1`)

Two RECOVERY_BLOCKs (sectors first, then info+CRCs), containing:

- addinfo: version `parc-rs1`, `arcsize`, `offset` and **two** pairs: `(sector_size,
  rec_sectors)` and `(m, S)`, with `rec_sectors = S × m`;
- the N sectors of the protected area (the last one zero-padded to `sector_size`) are split
  into S = ⌈N / (255 − m)⌉ stripes: sector i is data i div S of stripe i mod S;
- parity j of stripe s (RS erasure code over GF(2^8), polynomial 0x11D, scaled Cauchy matrix:
  `src/parc_rs.pas`) is sector j·S + s of the sector block;
- CRCs are one per data sector and one per parity sector, and mark which sectors are missing.
  A stripe is repaired with at most m damaged sectors.

m is the smallest number that provides at least the recovery sectors requested by `-rr` using
FreeArc's calculation.

- Stronger per-file hash than CRC-32 (e.g. a `BLAKE2B` tag)? To be decided.
- Hard links, ACLs, extended attributes: future tags.

## 6. Codec streams that differ from FreeArc

### 6.1 `ppmd` (since 2026-11)

The `ppmd` method is PPMd var.I rev.1 as implemented in the public-domain LZMA SDK by Igor Pavlov
(`Ppmd8.c`, based on Dmitry Shkarin's public-domain PPMd), translated to Pascal in
`src/parc_ppmd.pas` (with x86-64 assembler in `src/parc_ppmd8_x64.inc`). It replaced FreeArc's
modified PPMd; **`ppmd` blocks written before this change do not decode** (the header check
below rejects them).

Method string: `ppmd:<order>:<mem>[:r]`, also `o<order>`, `m<mem>`/`mem<mem>`, `r<N>`.
Defaults: order 10, 48 MB, restart. Order 2..64; memory 2 KB .. 4 GB − 36 bytes; `r`/`r1` =
cut-off, `r0` = restart. `c<mem>` (FreeArc's chunk) is accepted and ignored.

Stream:

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | `'P'` (0x50) |
| 1 | 1 | variant: `'I'` (0x49) |
| 2 | 1 | maximum order (2..64) |
| 3 | 1 | restore method when the model memory is full: 0 = restart, 1 = cut-off |
| 4 | 4 | model memory in bytes, little-endian |
| 8 | … | Subbotin carry-less range coder data (`Ppmd8Enc.c`), ending with PPMd's end marker (an escape from the order −1 context) followed by the 4-byte flush |

The stream is self-terminating: the decoder needs neither the original size nor a byte count.
The encoder is streaming (no block buffering).

The decoder requires the 8 header bytes to equal the parameters of the stored method string,
decodes until the end marker and then requires the range coder to finish exactly (`Code = 0`)
without having read past the end of the stream; anything else is a damaged block. Model memory
is allocated from the method string (the same limits as the encoder), never from untrusted
stream data.

Differences from the SDK, none of which changes the bytes of a stream the SDK can produce:
orders above 16 are allowed (the SDK limits them to 16 only for the zip format; the
`CreateSuccessors` stack array is sized for 64); and in cut-off mode, when a `CutOff` +
`ExpandTextArea` pass changes nothing while the memory is still above 3/4 (the SDK would loop
forever, e.g. with very small memories), the model is restarted instead.

### 6.2 `orep` (since 2026-11): replaces `rep`

`orep` is OREP, a one-pass streaming long-range matcher written for PArc (clean-room, MIT;
`src/orep/`, version and commit in `src/orep/VERSION`). It replaced FreeArc's REP (GPL):
**the method `rep` no longer exists**; a `rep` block of an archive written by PArc 0.0.5 or
earlier fails with "method rep (FreeArc REP) is no longer supported" (extract it with 0.0.5).

Method string: `orep[:<window>][:<min length>][:w<mem>][:l<n>][:a<n>][:s<n>][:c<n>][:r<n>][:b<mem>][:d<mem>]`

| parameter | meaning | default | range |
|---|---|---|---|
| `w<mem>` or a bare memory (`96mb`) | window: the largest match distance | 512mb | 1 byte .. 3840mb |
| `l<n>` or a bare integer | shortest match searched | 64 | 16 .. 65536 |
| `a<n>` | match lengths are multiples of `a`, and literals stay at their input position modulo `a` (lzma's `pb`/`lp` contexts); `a0` = chosen per stream block (1 for text, 4 otherwise) | 0 | 0 .. 4096, ≤ `l` |
| `s<n>` | anchor density: higher finds more short matches, slower, larger table | 4 | 1 .. 64 |
| `c<n>` | candidates tried per anchor: more finds longer matches, slower; 1 is the fastest | 4 | 1 .. 4 |
| `r<n>` | a match that only covers a run of one byte and is shorter than this is left to the next compressor (`plz` codes runs almost free) | 0 | 0 .. 65536 |
| `b<mem>` | stream block (slot) size | 4mb | a power of 2, 64kb .. 64mb |
| `d<mem>` | matches nearer than this are left to the next compressor | 0 | |

Memories as everywhere in PArc (`b/k/m/g` suffixes; a bare number is 2^N). The stored
(canonical) string always has the window, clipped to the solid block like any dictionary
(`orep:57mb`) and, with `-lc`, to what fits the memory limit; the other parameters only when
they differ from the defaults (`orep:96mb:l256`, `orep:2040mb:l512`).

Stream: OREP format version 4 (OREP 0.0.10; frozen upstream on 2026-11-21, so every later OREP
reads it; 0.0.10 does not read the version 3 streams of OREP 0.0.4 to 0.0.9, which only pre-release
branches wrote), specified in `src/orep/orep-format.md`: a 14–30-byte header (magic `OREP`,
version, log2 of the block size, then varints: window, alignment setting, minimum length, flags
(0); CRC-32C), blocks (output size, match count, column
size, the block's alignment, three varint columns: literal run, length − 16, distance − 1, zero
padding) followed by the block's literals
and the CRC-32C of the block's output, and an end marker with the total size. The stream does
not depend on the number of threads or on how the input is split into writes; the native core
(`orep_core.c`) and the Pascal reference (`-dOREP_NO_NATIVE`) give the same bytes on every
platform.

The decoder reads the window and block size from the stream header. It keeps a ring of
`ceil(window / block) × block + block` bytes as separate block-sized slots allocated when first
used (no copies when it grows), and refuses (as damaged) a
header that needs more memory than the method string declares (`OrepDecMemory` of the method's
window and block), so `-ld` (which reads the method string) bounds it. Every block is checked
(sizes, distances inside the decoded data, zero padding, CRC-32C); the end marker's total and
the absence of bytes after it too. PArc's stage reads the verified output in place (`OrepDecPeek`/`OrepDecSkip`) and reuses
decoders whose ring is at most 64 MB across blocks (`OrepDecReset`, up to 8 kept).

### 6.3 `plz` (since 2026-11)

`plz` is PArc's own LZ77 codec (`src/parc_plz.pas` decoder and format, `src/parc_plzenc.pas`
encoder), written to replace Tornado (`tor`), which came from FreeArc and was removed after
0.0.5 (`tor` blocks are no longer read). It is not derived from Tornado; it uses textbook techniques: LZ77 with four repeated offsets, length-limited canonical
Huffman codes rebuilt per block, literals in four interleaved streams.

Method string: `plz[:<level>][:<window>][:h<hash>]` plus tuning options that only the encoder
reads (`w<ways>`, `z<lazy>`, `n<nice>`, `i<insert>`, `k<skip>`, `x<hash bytes>`, `b<block>`,
`y<short table bits>`, `q<split mode>`, `u<extra lazy steps on binary blocks>`, `v<hash bytes on
binary blocks>`, `g<entries per direct-table slot>`, `m<lazy-match limit on text blocks>`,
`t<text-table bits>` (levels with hash rows: a direct table used instead of the rows on text
blocks; greedy levels: hash bits used on text blocks; 0 = off), `r<skip on near-random blocks>`,
`e<insertions inside a match on text blocks>` (1 = only the last two, n = the first and last n)).
The stored (canonical) string is `plz:<level>:<window>` followed by the options that differ from
the level's defaults; the window is limited to the block size (rounded up to 64 KB). The decoder
takes everything it needs from the stream.

Stream:

| Offset | Size | Value |
|---|---|---|
| 0 | 1 | version (1) |
| 1 | 4 | window W, U32 LE, 1 KB ≤ W ≤ 1 GB: no match reaches further back than W bytes |
| 5 | … | blocks, each starting with a type byte: 0 = end of stream; 1 = stored (`VInt n`, n bytes); 2 = repeated byte (`VInt n`, 1 byte); 3 = compressed (`VInt n`, `VInt c`, c bytes of content) |

`VInt` here is LEB128 (7 bits per byte, low group first, bit 7 = more), at most 5 bytes, value
< 2^31. Every block has 1 ≤ n ≤ 1 MiB original bytes. The stream ends at the end-of-stream byte;
the decoder needs no original size.

Compressed block content:

1. `VInt nSeq`, `VInt nLit` (literal bytes in the block, ≤ n).
2. Two mode bytes. First: bits 0-1 literals, 2-3 TOK, 4-5 LLX, 6-7 MLX; second: bits 0-1 OFS,
   bits 2-7 zero. Table modes: 0 = new table (described below), 1 = the table of the same
   alphabet from the last block that sent one, 2 = unused in this block. Literal mode: 0/1 =
   Huffman with a new/the previous table, 2 = no literals (nLit = 0), 3 = stored literals.
3. If any table is new: a bit stream with the descriptions of the new tables in the order
   LIT, TOK, LLX, MLX, OFS, padded to a byte.
4. Literals: stored (nLit bytes), or `VInt` section length followed by, for nLit ≥ 1024, four
   `VInt` stream lengths and four bit streams (stream k holds literals `[k·q, min((k+1)·q, nLit))`,
   q = ⌈nLit/4⌉), otherwise one `VInt` length and one stream.
5. The rest of the block is the sequence bit stream (absent when nSeq = 0).

Each sequence is: a TOK symbol (alphabet 128: `LLt·16 + MLt`), an OFS symbol, an LLX symbol if
LLt = 7, an MLX symbol if MLt = 15, then the extra bits of LLX, MLX and OFS in that order. The
literal length is LLt (< 7) or 7 + LLX value; the match length is 3 + MLt (< 15) or 18 + MLX
value. The decoder copies that many literals, then the match. After nSeq sequences the remaining
literals are appended; the block must then be exactly n bytes and every literal used.

- LLX/MLX values (alphabet 48): v < 8 is code v; otherwise b = ⌊log2 v⌋, code 8 + 2(b−3) + bit
  b−1 of v, followed by the low b−1 bits of v.
- OFS (alphabet 64): 0..3 = repeated offsets rep0..rep3 (the one used moves to the front);
  4 + slot = a new offset d+1, slot = d for d < 4, else 2b + bit b−1 of d (b = ⌊log2 d⌋),
  followed by the low b−1 bits of d; the new offset is pushed in front of the reps. The reps
  start as 1, 2, 3, 4 at the start of the stream and carry across blocks (stored and repeated
  blocks leave them unchanged).

Bits are read LSB first. Huffman codes are canonical (by length, then by symbol), at most 11
bits, stored bit-reversed so the first code bit is the lowest. A table with exactly one used
symbol codes it with 0 bits; otherwise the lengths must form a complete code (Kraft sum 1).

Table description: 8 bits (number of described symbols − 1, trailing ones are 0), 15 × 3 bits
lengths of the code-length (CL) code, then CL symbols with that code (lengths ≤ 7): 0..11 =
a code length, 12 = repeat the previous length 3–6 times (2 extra bits), 13 = 3–10 zeros
(3 bits), 14 = 11–138 zeros (7 bits).

Decoder checks: every count, length, offset (≤ W and ≤ bytes produced so far), table and bit
stream is bounded; each bit stream must end exactly at its last byte; anything else is a damaged
block (`EArcCorrupt`). Memory comes from W, never more than W + 1 MiB (allocated as the data
arrives), plus fixed buffers. Inside `4x4` each 4x4 block is a complete `plz` stream decoded
memory to memory, which must produce exactly the block's original size and end at its last byte.

### 6.4 `delta` (since 2026-11)

`delta` is PArc's own filter for tables of fixed-size records (`src/parc_delta.pas`, encoder
and decoder), written to replace FreeArc's `delta` (Bulat Ziganshin, GPL); it is not derived from
it. **`delta` blocks written before this change do not decode** (the version byte rejects them).
The output has the length of the input plus a small header per block: the encoder rewrites the
tables it finds in place (each field minus the same field of the previous record) and leaves
everything else as it is. How the tables are found is the encoder's business (see the comment at
the top of the unit); the decoder only follows the segment list.

Method string: `delta[:<block>][:x]`, also `b<block>`. Block 8 MB by default (1 B .. 1 GB; a
bare number without a suffix is 2^N as in every PArc memory parameter); `x` lets the encoder
look for records of up to 64 bytes (default 32). The decoder needs no parameter.

Stream: one byte, the version (1), then blocks until the end of the stream:

| Field | Value |
|---|---|
| `VInt Len` | bytes in the block, 1 ≤ Len ≤ 2^30 |
| `VInt NSeg` | number of segments, NSeg ≤ Len / 2 |
| NSeg × segment | `VInt Gap`, `U8 Stride`, `VInt Count`, `U8 Layout`, `VInt Mask` |
| padding | zero bytes until the stream position (from the version byte) is a multiple of 8 |
| data | Len bytes |

`VInt` is LEB128 (7 bits per byte, low group first, bit 7 = more), at most 64 bits. Segment i
starts Gap bytes after the end of segment i−1 (after the block start for the first one) and
covers Count × Stride bytes: Count ≥ 2 records of Stride bytes (1 ≤ Stride ≤ 64), entirely inside
the block. Layout bits 0-1 give the field width w = 1, 2 or 4 bytes (3 is invalid; Stride must
be a multiple of w), bit 2 = the fields are big endian (only with w > 1), bits 3-7 zero. Field f
of a record is bytes [f·w, (f+1)·w). Mask is non-zero and has no bits at or above Stride / w;
bit f set means that in every record but the first, field f holds (value − value of field f in
the previous record) mod 2^(8w), the values read with the given byte order. The decoder undoes the
segments in order, records first to last. The padding keeps the data at the alignment it had in
the input (LZ and context-mixing back ends use the position modulo 2, 4 or 8 as context).

Decoder checks: version, VInt ranges, every segment field and position, and the padding bytes;
anything else is a damaged block (`EArcCorrupt`). Memory: one block (at most Len bytes, the
buffer growing as the data arrives, so a damaged length cannot reserve 1 GB up front) plus the
segment list.

### 6.5 `lzp` (since 2026-11)

`lzp` is PArc's own long-repeat filter for the text presets (`src/parc_lzp.pas`), written to
replace FreeArc's `lzp` (Dmitry Shkarin's LZP as ported by Bulat Ziganshin, GPL); it is not
derived from it. **`lzp` blocks written before this change do not decode.**

Method string: `lzp[:<block>][:<min>][:h<bits>][:d<barrier>][:s<smallest>][:<N>%]`, also
`b<block>` and `l<min>`. Defaults: block 8 MB, minimum match 64, 18 hash bits, no barrier,
smallest match 32, N = 100. Limits applied by both sides (`Normalize`): block ≤ 1 GB, 8 ≤
minimum ≤ 65535, 8 ≤ smallest ≤ minimum, 10 ≤ bits ≤ 26, barrier ≤ 1 GB. `N%` is the encoder's:
a block whose coded size exceeds N % of the input is stored. The decoder allocates from the
method string (block, table), never from stream values.

Stream header: `U8 version` (1), `U8 context bytes` (4), `U8 hash bits`, `VInt minimum`,
`VInt smallest`, `VInt barrier`; all must equal the method string's values after the limits.
Then blocks until the end of the stream: `VInt Len` (1 ≤ Len ≤ block size), `U8 mode`. Mode 0:
Len stored bytes. Mode 1: `U8 escape`, `VInt NMain` (≤ Len), `VInt NLens`, NMain bytes of main
stream, NLens bytes of length stream. `VInt` is LEB128 (bit 7 = more).

Model (encoder and decoder keep it identically): positions are offsets in the block; the table
has 2^b buckets of two positions (b = the hash bits, but at most 1 + ⌈log2 Len⌉ and at least 10),
cleared at each block. Position i ≥ 8 has the context C = the 4 bytes before it (as a
little-endian 32-bit value) and the bucket ⌊(C · 0x9E3779B97F4A7C15 mod 2^64) / 2^(64−b)⌋; its
candidates are the bucket's first slot (the most recent position with that bucket) and second
slot (the one before), 0 = none; after reading them the bucket becomes (i, first). Positions below 8
have no candidates and do not touch the table.

Decoding, at output position i: take the next main byte m. If m ≠ escape, output m (i + 1). If
m = escape, read a length value v from the length stream (a sequence of bytes, each 255 adds 255,
the first byte < 255 ends it): v = 0 outputs the escape byte itself; otherwise the candidate is
the first slot if v is odd, the second if even (it must not be 0), the minimum is `smallest` if
the candidate is more than `barrier` bytes back and `minimum` otherwise, and the match length is
⌊(v − 1) / 2⌋ + minimum: copy that many bytes from the candidate position onwards (forwards, the
copy may overlap itself). The table is updated at every position where a main byte is read,
before the byte is interpreted; positions inside a match are not. The block must end exactly
when both streams are used up, at Len bytes; anything else (or a match past Len, or NLens
larger than NMain + 2⌊Len/255⌋ + 2) is a damaged block (`EArcCorrupt`).

### 6.6 `dispack` (since 2026-11): replaces FreeArc's DisPack

`dispack` is PArc's own filter for x86 and x86-64 machine code (`src/parc_dispack.pas` and the
walker `src/parc_dispack_walk.inc`, shared by encoder and decoder), written to replace FreeArc's
DisPack 0.70 (GPL); it is not derived from it. Method names `dispack`, `dispack070` (stored) and
the preset `exe2`. **`dispack070` blocks written before this change do not decode** (the version
byte rejects them).

Method string: `dispack070[:<block>][:x]`, also `b<block>`. Block 8 MB by default (1 B .. 1 GB; a
bare number is 2^N as in every PArc memory parameter); `x` is accepted and ignored. The decoder
uses the block size as the limit of `Len`.

Stream: `U8 version` (1), then blocks until the end of the stream:

| Field | Value |
|---|---|
| `VInt Len` | bytes in the block, 1 ≤ Len ≤ block size |
| `VInt NReg` | code regions, NReg ≤ Len / 16 + 1 |
| NReg × region | `VInt Gap`, `VInt RegLen` (≥ 1), `U8 Mode` (0 = 32-bit, 1 = 64-bit), `U32 Va` |
| 8 × `VInt StreamLen` | OP, D32, ADDR, I16, I32, CALL, JMP, RAW; each ≤ 2·Len + 64 |
| padding | zero bytes until the stream position (from the version byte) is a multiple of 4 |
| 8 streams | each followed by zero bytes up to a multiple of 4 |

`VInt` is LEB128 (bit 7 = more), `U32` little endian. Region i starts Gap bytes after the end of
region i−1 (after the block start for the first) and lies inside the block; the bytes before,
between and after the regions are taken in order from RAW. A region is rebuilt instruction by
instruction from the other streams; Va is the virtual address of its first byte (only its value
modulo 2^32 matters).

Instruction walk (the decoder rebuilds the bytes in this order and every choice depends only on
bytes already rebuilt). At the start of an instruction, OP byte `D6` is an escape: `D6 00` = the
byte D6; `D6 n` with 1 ≤ n ≤ 63 = n raw bytes from OP (n ≤ bytes left in the region); other n are
invalid. Otherwise, from OP: up to 14 prefixes (26 2E 36 3E 64 65 66 67 F0 F2 F3, and 40-4F in
64-bit mode; a 15th prefix byte is taken as the opcode), then the opcode: `0F xx`, `0F 38 xx` and
`0F 3A xx`; C4/C5/62 followed by a byte b: in 64-bit mode or when b ≥ C0, VEX (C5: b; C4: b and
one more byte, map = b & 1F) or EVEX (62: b and two more bytes, map = b & 7) and then the opcode
byte; in 32-bit mode with b < C0, b is the ModRM of LES/LDS/BOUND. ModRM and SIB come from OP.
Operand fields, by the opcode maps of the Intel/AMD manuals (the tables in the unit are the
normative list): 8-bit displacement → OP; 32-bit displacement with a base register (mod = 2) →
D32 as is; [disp32] without base (mod = 0 and r/m = 5 or SIB base = 5, 32-bit mode; SIB base = 5
in 64-bit mode) → ADDR; RIP-relative disp32 (64-bit mode, mod = 0, r/m = 5) → ADDR as disp +
address of the next instruction; 16-bit addressing (67 in 32-bit mode) → D32 (2 bytes) / OP;
imm8 and rel8 → OP; imm16 → I16; imm16/32 by operand size → I16 / I32; imm64 (B8+r with REX.W)
→ I32 (8 bytes); moffs → ADDR (32-bit address) or I32 / I16; E8 rel32 → CALL and E9 / 0F 80-8F
rel32 → JMP as rel + address of the next instruction (with 66 in 32-bit mode: I16). Values in
ADDR, CALL and JMP are 32-bit, most significant byte first, arithmetic modulo 2^32. An
instruction that would end past the region is invalid.

Decoder checks: version, VInt ranges, regions inside the block, Mode, padding bytes, escapes,
every instruction inside its region, every stream used exactly; anything else is a damaged
block (`EArcCorrupt`). Memory: the encoded block plus the decoded block.

### 6.7 `cm` (since 2026-11)

`cm` is PArc's own context-mixing compressor (`src/parc_cm.pas` + the model in
`src/cm/pcm_core.c`, freestanding C, MIT), written to replace the port of Matt Mahoney's lpaq1
(GPL); it is not derived from it (designed from published descriptions of bitwise context
mixing). **`cm` blocks written before this change do not decode** (the version byte rejects
them). Used by `-mxx` (`xx$text`, `xx$binary`, `xx$obj`).

Method string: `cm[:<level>]`, level 1..9 (default 6). The level sets the encoder's table sizes
and, at 8–9, the `full` option; both go in the stream header, the decoder needs no parameter.

| level | context table | history | match table | model memory |
|---|---|---|---|---|
| L | 64·2^(15+L) B | 2^(18+L) B | 4·2^(16+L) B | ≈ 2^(21+L) · 1.25 B (level 6: ≈ 168 MB) |

Inputs of at most 1 MB get smaller tables (context table ≥ 4 buckets per input byte rounded up
to a power of two, history and match table ≥ the input), so small blocks neither allocate nor
clear the full model.

Stream header: `U8 version` (1), `U8 htbits` (10..24: 2^htbits buckets of 64 bytes), `U8 wbits`
(16..27: history ring of 2^wbits bytes), `U8 mtbits` (12..25: match table of 2^mtbits
entries), `U8 flags` (bit 0: the size follows; bit 1: `full`; other bits 0), and if bit 0 is set `U32 size`
(little endian, ≤ 64 MiB, the exact number of bytes the stream decodes to). The encoder sets
bit 0 when the whole input fits in 64 MiB; the decoder then decodes everything at once and
frees the model before the stages above it allocate theirs (so a `dict+lzp+cm` chain never
holds the CM model and the LZP tables at the same time).

Then one binary arithmetic-coded stream (32-bit range, carry-less; probability of a 1 in 16
bits; after the last bit the encoder writes the 4 bytes of the low end of the range). It is a
sequence of blocks of at most 64 KiB:

| Field | Coding |
|---|---|
| end | 1 bit, p = 1/2: 1 = end of stream (nothing follows) |
| modelled | 1 bit, adaptive (p starts at 1/2, moves 1/16 towards each coded value) |
| text | only if modelled: 1 bit, adaptive like the previous one (its own probability) |
| full | 1 bit, p = 1/2: 1 = 65536 bytes; 0 = 16 bits of length follow (p = 1/2, MSB first, 1..65535) |
| data | the block's bytes, 8 bits each MSB first: predicted by the model if modelled, else p = 1/2 |

In a binary block the model uses the sparse context "bytes 2–3 back", and with `full` also
"bytes 3–4 back" (about 2% smaller binaries, 8% slower); in a text block it uses neither: they
help text little and cost about 4% each. The
encoder marks a block as text when at least half of its bytes are printable ASCII (0x20–0x7E,
tab, LF, CR) and fewer than 1/32 are zero (a heuristic; the decoder only reads the bit).
The encoder stores a block raw ("not modelled") when it has at least 4096 bytes and its order-0
entropy exceeds 7.92 bits per byte (already compressed data): it costs 8 bits per byte and keeps
such data at full speed in both directions. Raw bytes still enter the history, the contexts and
the match model; the mixers, state maps and secondary estimators only learn from modelled bits.

The model (identical in encoder and decoder; integer arithmetic only, so every platform gives
the same bytes; the SSE2 (x86, also 32-bit: `build.sh` compiles the core with `-msse2` there)
and NEON (aarch64) mixer code and the portable C code are bit-exact) is defined by
`pcm_core.c`. In short: for each bit, up to eleven contexts give a bit-history state (one byte, a
bounded (n0, n1, last bit) counter): order 0 and order 1 from direct tables, and orders 2, 3, 4
and 6, the current word, the previous and current word, bytes 2–3 back, the two bytes that last
followed the previous byte (indirect), and bytes 3–4 back from a hash table of 64-byte buckets
(four 16-byte slots: an 8-bit check and the 15 states of a nibble; the slot with the lowest
state count is replaced). Each state is mapped to a probability by an adaptive table per context
(rate 1/(n+1.5), n ≤ 1023). A match model (the last position with the same 6 preceding bytes,
verified backwards) adds the predicted bit with its length. Six mixers (16 inputs, 16-bit
weights, weight sets selected by the partial byte, the match state, the number of known
contexts and bit position, the byte 2 back, the byte 3 back and the classes of the last three
bytes) feed a second mixer (selected by the match state and the partial byte), followed by two
interpolated secondary estimators (order 1, and match byte or order-2 hash).

Decoder checks: version, header ranges, the flags byte, the known size (decoded bytes must
match it exactly) and a stream that ends early (more than 8 missing bytes); a damaged stream
gives either wrong data (caught by the block's CRC) or `EArcCorrupt`. Memory: the model (from
the header) plus 64 KiB, or plus the known size.

### 6.8 `bwt` (since 2026-11): replaces `grzip`

`bwt` is PArc's block-sorting compressor (`src/parc_bwt.pas` and the C core in `src/bwt/`),
written to replace FreeArc's GRZip (I. Grebnov, LGPL); it is not derived from it. It is LZP
(the model of §6.5), the Burrows–Wheeler transform (libsais, Apache-2.0) and QLFC coding (the
coders of libbsc 3.4.1, Apache-2.0, translated to C; at `m4` libbsc's order-5 sort transform
instead of the BWT). **`grzip` blocks of older archives no
longer decode** (exit code 3); a `grzip:...` method string given to the compressor is written
as `bwt:...`.

Method string: `bwt[:<block>][:m1..m4][:l|:l<N>|:<N>][:h<N>][:e0|:e1|:e2]`, also `b<block>`;
GRZip's `a`, `s`, `d`, `p`, `t<N>`, `i<N>` are accepted and ignored. Defaults: block 8 MB
(at most 1 GB), `m1`, LZP minimum 32 (8..65535; `l` alone = no LZP) and 18 hash bits (10..26).
The coder: `m1` adaptive, `m2` and `m3` static, `m4` fast, or `e0` fast, `e1` static, `e2` adaptive. The decoder takes the block size and the LZP hash bits from the method string.

Stream header: `U8 version` (1), `U8 LZP hash bits` (0 = no LZP), and `VInt LZP minimum` when
the bits are not 0; both must equal the method string's. Then blocks until the end of the
stream (`VInt` is LEB128):

| Field | Value |
|---|---|
| `VInt Len` | bytes the block decodes to, 1 ≤ Len ≤ block size |
| `U8 mode` | 0 = stored: Len bytes follow; 1 = coded |
| `U8 flags` | (coded) bits 0–1: coder (1 static, 2 adaptive, 3 fast; 0 invalid), bit 2: LZP applied (only if the header has LZP), bit 3: order-5 sort transform instead of the BWT, bits 4–7 zero |
| LZP fields | (bit 2) `U8 escape`, `VInt minimum` (8..65535), `VInt NMain` (≤ Len), `VInt NLens` (≤ NMain + 2⌊Len/255⌋ + 2) |
| `VInt Primary` | primary index of the BWT, or the sort transform's index + 1; 1 ≤ Primary ≤ M |
| `VInt CodedLen` | bytes of QLFC data, ≤ Len |
| data | CodedLen bytes |

M = NMain + NLens with LZP (1 ≤ M ≤ Len), else M = Len. Decoding a coded block: the QLFC data
give M bytes (their first 32 bits, coded, must say M), the inverse BWT of those with Primary
(libsais' convention: the index of the row of the original string, counted from 1; the
string is not terminated) — or with flag bit 3 the inverse of libbsc's order-5 sort transform
(the cyclic rotations sorted by their first 5 bytes, ties by position; the output is the byte
before each rotation; index = Primary − 1 is the row of the rotation at position 0, as
libbsc's `bsc_st5_encode` returns it; the exact order is `parc_st5_forward` in
`src/bwt/bwt_core.c`) — gives the BWT input, and with LZP that input is the main stream
(NMain bytes) followed by the lengths stream (NLens bytes), decoded as in §6.5 with this
block's minimum as both minimum and smallest length, no barrier, and b = min(the header's
hash bits, ⌈log2 Len⌉ − 3), at least 10, as the table bits (at most one bucket per 8 bytes of
the block), into Len bytes; without LZP it is the block.

QLFC (Grebnov's quantized local frequency coding, as coded by libbsc's `qlfc.cpp`): the BWT
output is cut into runs of equal bytes; for each run, the move-to-front rank of its byte
(the ranks are those of a list that starts with the alphabet in the order coded first) and
its length are coded with a binary range coder (32-bit range, 16-bit output words stored
little-endian) bit by bit — exponent then mantissa — under contexts of the byte, of the
recent ranks and lengths, and of a static model. The three coders differ only in how they
predict each bit: fast (one counter per context, fixed rates; 13-bit probabilities for
ranks, 11-bit for lengths), static (three counters averaged with fixed weights) and adaptive
(the three counters mixed by a 3-input mixer with an interpolated output map per context).
The exact model (states, rates, thresholds and tables) is the one in `src/bwt/qlfc.c` and
`qlfc_tables.h`, which define the format, as libbsc's sources define its own.

The encoder's choices (not needed to decode): `m4` uses the sort transform on blocks of 1 MB or more
(after the LZP), the BWT otherwise and at the other levels; blocks are cut where order-1 statistics change
(a solid block of many files becomes pieces of similar data, at least 64 KB); with `a` the
blocks are at most half the block size at `m2`..`m4` and 3/4 at `m1`, and the pieces of data
found to be mixed at most 1/4; the LZP is skipped on blocks with few long repeats (estimated
from content-defined samples); a block whose BWT output has fewer runs than 1/8 of its bytes is
coded with the adaptive coder unless `e` is given; a block shorter than 64 bytes, or whose coded form
is not smaller, is stored; at `m1`..`m3`, a block where the LZP removes more than half of
the data is filtered again with 4 times the minimum (recorded in the block).

Decoder checks: version, header parameters, every field range above, the QLFC data (a read
past CodedLen, a length or rank that does not fit, a decoded size other than M), the primary
index and the LZP decoding; anything else is a damaged block (`EArcCorrupt`). Memory per block
being decoded: the coded data, M bytes, 4(M + 1) bytes for the inverse BWT, then Len bytes
and the LZP table; blocks are decoded in parallel within `PARC_THREADS`.
