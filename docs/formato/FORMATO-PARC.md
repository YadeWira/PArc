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
- **Methods**: the same strings (`lzma:...`, `rep:...+...`, `4x4:...`).
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

### 6.2 `plz` (since 2026-11)

`plz` is PArc's own LZ77 codec (`src/parc_plz.pas` decoder and format, `src/parc_plzenc.pas`
encoder), written to replace Tornado (`tor`), which comes from FreeArc. It is not derived from
Tornado; it uses textbook techniques: LZ77 with four repeated offsets, length-limited canonical
Huffman codes rebuilt per block, literals in four interleaved streams.

Method string: `plz[:<level>][:<window>][:h<hash>]` plus tuning options that only the encoder
reads (`w<ways>`, `z<lazy>`, `n<nice>`, `i<insert>`, `k<skip>`, `x<hash bytes>`, `b<block>`).
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
