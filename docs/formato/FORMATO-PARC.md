# `.parc` format — specification, container version 2 (2026-11-26)

`.parc` is PArc's native format. Since container version 2 (PArc after 0.0.5) the container —
how blocks, the directory, the archive properties and the recovery record are laid out and
found — is PArc's own design; it no longer follows FreeArc's (descriptors, footer, `DIR_BLOCK`
columns, FreeArc's VInt). Method strings (`lzma:...`, `orep:...+...`) and the codec streams of
§6 are unchanged. There is no backward compatibility (pre-1.0): archives written by PArc 0.0.5
and earlier are rejected with the error *old PArc format* (§2.5), and PArc never reads or writes
FreeArc `.arc` files.

## 1. Overview

### 1.1 Layout

```
[SFX stub]                 optional, anything; not part of the archive (§2.5)
head                       16 bytes (§2.1)
data blocks                back to back, no per-block header (§2.2)
index                      header + payload: the directory and the archive properties (§2.3, §3)
end locator                24 bytes (§2.4)
[recovery record]          optional (§5); protects everything from the head to the locator
```

Every position stored in the archive is counted **from the start of the head** ("archive
position"), never from the start of the file: a stub can be prepended (or removed) without
touching the archive, and a multi-volume archive (`-v`, `name.parc.001`, `.002`...) is the same
byte stream cut into pieces.

### 1.2 Primitives

| name | encoding |
|---|---|
| `U8`, `U16`, `U32`, `U64` | unsigned, little-endian, fixed size |
| `Uv` | unsigned LEB128: 7 bits per byte, least significant group first, bit 7 set on every byte but the last; at most 10 bytes (values < 2^64). Writers use the shortest form; readers reject a longer one (a last byte 0x00 after the first) and anything above 2^64−1 |
| `Sv` | signed: zigzag (`v ≥ 0 → 2v`, `v < 0 → −2v − 1`) then `Uv` |
| `UBE(w)` | unsigned in exactly `w` bytes (0…8), **big-endian**: used for fixed-width columns, which a general-purpose compressor models better than varints |
| `Str` | `Uv` length + that many bytes (UTF-8 for text) |
| `ZStr` | bytes up to a 0x00 byte. Only in path columns (file and directory names cannot contain NUL); NUL-terminated names compress ~6 % better than length-prefixed ones in the index |

### 1.3 Checksums

CRC-32 is the IEEE / zlib polynomial (reflected 0xEDB88320, init and final xor 0xFFFFFFFF),
`src/parc_crc.pas`. Every control structure carries one: the head, the index header (its own
bytes, the stored payload and the decoded payload), the end locator, and the recovery record's
descriptors and stripe tables (§5). Data blocks have no checksum of their own; each file has
the CRC-32 of its contents in the index, and encrypted blocks are authenticated (§3b).

## 2. Container structures

### 2.1 Head (16 bytes, archive position 0)

| offset | field |
|---|---|
| 0 | magic `50 41 72 63 0D 0A 1A 0A` ("PArc\r\n\x1a\n": the CR LF / EOF / LF bytes reveal a text-mode transfer) |
| 8 | `U16` container version = 2 |
| 10 | `U16` flags = 0 (a reader rejects other values) |
| 12 | `U32` CRC-32 of bytes 0…11 |

A version above the reader's is rejected ("container version N: this PArc understands up to M").
The index does not depend on the head: a damaged head is reported as a warning, the archive is
still read.

### 2.2 Data blocks

A data block is the output of its method string's encoder chain (compression stages, then the
cipher stage with `-p`, §3b) over the concatenation of its files, in index order. Blocks have no
header: the index lists, per block, its method, its number of files and its stored size, and
the blocks of a *run* are stored back to back from the run's start. A written archive has one
run that starts right after the head; appending in place adds one per append (§3a). A block may
be empty (0 stored bytes).

Entries without data — directories and symbolic links — are not in any block (§3, `ARCHIVE`).

### 2.3 Index header

The index is a header followed by its payload; the header is never compressed or encrypted.

| field | |
|---|---|
| `U32` | magic "PAix" (`50 41 69 78`) |
| `Uv` | archive position of this header (lets a reader that found the header by scanning compute where the archive starts) |
| `Uv` | stored payload length |
| `Uv` | decoded payload length |
| `Str` | method of the payload: `lzma:1mb:normal:bt4:32` by default, `storing` when compressing does not make it smaller, plus the cipher stage `+xchacha20:…:h` / `+aes256gcm:…:h` with `-hp` |
| `U32` | CRC-32 of the stored payload |
| `U32` | CRC-32 of the decoded payload |
| `U32` | CRC-32 of the header from the magic up to here |

The stored payload follows immediately.

### 2.4 End locator (24 bytes)

| offset | field |
|---|---|
| 0 | `U64` archive position of the index header |
| 8 | `U64` archive length: from the head to the end of this locator |
| 16 | `U32` CRC-32 of bytes 0…15 and 20…23 |
| 20 | magic "PAel" (`50 41 65 6C`) |

### 2.5 Finding the index

1. If the file ends with a valid recovery descriptor (§5.1: magic "PArr" at its end, its CRC,
   version 1), the record occupies the last `record length` bytes and the locator ends where the
   record starts; otherwise the locator is the last 24 bytes of the file.
2. Locator valid (magic, CRC, `index position < archive length ≤ bytes before it`): the archive
   starts at `end of locator − archive length` (anything before is the SFX stub) and the index
   header is at `start + index position`; its own position field must match.
3. Otherwise (damaged or cut tail): if the file starts with `PAr\x01`, or its last 4096 bytes
   contain `PAr\x01\x08` (the footer descriptor of the old container), it is an archive of PArc
   0.0.5 or earlier: error *old PArc format*. If not, the file is scanned **backwards** for "PAix";
   the first candidate whose header CRC and stored-payload CRC match is the index, and the
   archive starts at `candidate − its position field`. The archive is then read normally, with
   the warning *the end of the archive is damaged (index found by scanning)*, and `parc r`
   is suggested when there is a recovery record.
4. Nothing found: *not a .parc archive, or its end is damaged*. A volume set whose last volume is
   missing says which volumes were read.

## 3. Index payload

The decoded payload is a sequence of sections ended by the byte 0:

```
repeat:  U8 id (0 = end) · Uv length · length bytes
```

A section must be parsed to exactly its length. Unknown ids with bit 7 set (`0x80…0xFF`) are
skipped; any other unknown id makes the archive unreadable (*unknown mandatory section: written
by a newer PArc?*). `ARCHIVE` must come first; a section appears at most once; nothing may
follow the end byte.

**Entry order.** `N` entries: first the `Z` entries without data (directories and links), then
the files of data block 0, of block 1, ... in the order they are stored in their block. A file's
offset inside its decoded block is the sum of the sizes of the files before it in that block.

| id | name | content |
|---|---|---|
| 1 | `ARCHIVE` | `Uv` flags (bit 0: locked — `-k`/`k`; PArc refuses to modify the archive; other bits must be 0) · `Uv N` · `Uv Z` · `Uv B` (data blocks) |
| 2 | `BLOCKS` | `Uv R` runs, R × (`Uv` start position, `Uv` block count) — the counts add up to B · `Uv M` methods, M × `Str` method string · B × `Uv` method index · B × `Uv` file count (they add up to N − Z) · B × `Uv` stored size. Required when B > 0 |
| 3 | `NAMES` | `Uv D` directories, D × (`Uv` bytes shared with the previous directory name, `ZStr` rest) in order of first use · N × `ZStr` base name · N × `Sv` directory index, as a difference from the previous entry's (the first from 0). The path is `directory/base` (just `base` for the empty directory name). Required when N > 0 |
| 4 | `KINDS` | Z × `U8`: 0 empty file, 1 directory, 2 symbolic link, 3 symbolic link to a directory (Windows: created as a directory link). Required when Z > 0 |
| 5 | `SIZES` | `U8 w` · (N − Z) × `UBE(w)` file size (entries without data have size 0). Required when N > Z |
| 6 | `CRCS` | `U32` CRC-32 of the contents of every file in a block whose size is not 0 (an empty file's CRC is 0 and is not stored). After `SIZES`. Required when N > Z |
| 7 | `MTIME` | `Sv` base second · `U8 w` · N × `UBE(w)` second − base · `U8 k` (0…9) · `U8 ws` (0…4) · N × `UBE(ws)` sub-second part in units of 10^k ns. mtime = (base + second) · 10^9 + part · 10^k ns since 1970-01-01 UTC, the second being the floor. A part · 10^k ≥ 10^9 is damage. Required when N > 0 |
| 8 | `UNIXMODE` | N × `Uv` `st_mode` (type and permissions). Only when every entry has one |
| 9 | `WINATTR` | N × `Uv` Windows attributes (`FILE_ATTRIBUTE_*`). Only when every entry has them |
| 10 | `LINKS` | for every entry of kind 2 or 3, in order: `Str` link target (UTF-8, `/`, as it was in the link) |
| 0x81 | `COMMENT` | the archive comment, raw bytes (UTF-8 by convention, may contain NUL) |
| 0x82 | `RECOVERY` | the `-rr` specification used (kept when the archive is updated without `-rr`) |

Paths are UTF-8 with `/`, relative, without `.`/`..` components or a root; a reader sanitizes
them again before extracting. The writer picks the encodings that compress best with the
index's method: fixed-width big-endian columns for sizes and seconds (measured on 10,000 files:
sizes 1.5 % and seconds 15 % smaller than LEB128 deltas after lzma), front-coded directory names
and delta-coded directory indexes.

Why the order and the separate kinds: entries without data need no size, CRC or block; files
need no kind. Directory and file times share one column so that runs of equal dates compress to
almost nothing.

### 3a. Updating and appending

**Appending in place.** When an update only adds files and keeps every file and every block of
the archive (`a`/`u`/`f` with new names only, no recompression, no password change), the archive
is a single file without a recovery record, and it was read without warnings, PArc writes after
the current end of the file: the new data blocks, a new index whose `BLOCKS` has two (or more)
runs — the old blocks where they are, the new ones after the old locator — and a new locator.
The old blocks are not read or rewritten; the old index and locator stay as dead bytes between
the runs. If anything fails (or is cancelled) the file is cut back to its old size, which is the
old archive byte for byte; if the process is killed, the file ends in garbage and readers find
the old index by scanning (§2.5) with a warning, and the next update rewrites it clean. Any
other update, or one with `PARC_NO_APPEND` set in the environment, rewrites the archive.

**Rewriting.** PArc writes a temporary file and replaces the archive at the end. Blocks whose
files all stay are **copied as stored bytes** (never decompressed or recompressed; encrypted
blocks keep their cipher stage and nonce); blocks that lose files are repacked. The index, the
locator and the recovery record are rebuilt, in one run with no dead bytes (`ch` compacts an
archive that was appended to).

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
| `h` | (no value) the stage encrypts the index (`-hp`) |

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
- The block nonce lives in the method string, which the index stores: a block moved to
  another block's place (or replaced by another block of the same archive) decrypts with the wrong
  nonce and fails. With `-hp` the index payload is itself authenticated (header key), so the whole
  archive structure is covered; the head, the index header, the end locator and the recovery
  record stay in clear. The index header necessarily exposes the index's stage (salt, check,
  nonce, costs) and the sizes of the stored and decoded index.
- With `-p` alone the directory is plaintext and not authenticated: names, sizes, dates and the
  compression part of each method can be read and changed. A changed method or block list makes
  decompression or the per-file CRC fail; it cannot reveal or forge encrypted data. An attacker can
  also replace the whole archive, or put back an older index of an `-hp` archive.
- Data blocks and the index use different keys, so a data block cannot stand in for an index.

### Updating

Updating an encrypted archive needs the password of its data blocks: if `-p` is given and the
archive already has encrypted data blocks, the password is checked first against their stage; a
different password is rejected as a **wrong password** (exit 5) and the archive is left untouched,
so the data of an archive never mixes passwords. Blocks that are recompressed (`d` in a solid block,
`--recompress`) are encrypted again, with a new nonce, even when `-p` is not repeated. The index
is always rewritten, with the `-hp` password given for that run.

## 4. Writing: invariants PArc must satisfy

- `Uv` in the shortest form; every length and count matches what follows.
- Data blocks of a run are contiguous and in index order; the index follows the last data block
  of the last run (an appended archive has the old index and locator before the last run), the
  end locator follows the index, and the recovery record (if any) follows the locator and ends
  the file.
- Each file CRC is that of its original data; the index header's CRCs are those of the stored
  and the decoded payload.
- Names are UTF-8 with `/` as separator, relative, without `..` or a root. On Windows, `\` is
  converted to `/`.
- The same input and options give the same bytes on every platform (except the random salt and
  nonces of encrypted archives): `tests/container_cross.sh`.

## 5. Recovery record (`parc-rr1`)

Own layout around the Reed-Solomon erasure code of `src/parc_rs.pas` (GF(2^8), polynomial 0x11D,
scaled Cauchy matrix: any m missing sectors of a stripe are rebuilt). It protects the archive
from the head to the end of the locator (*protected length* L), and itself.

### 5.1 Layout

```
descriptor                48 bytes
stripe table              S × U32 + U32
checks                    (N + S·m) × W bytes
parity sectors            S·m × sector size
stripe table (copy)       S × U32 + U32
descriptor (copy)         48 bytes
```

**Descriptor** (identical at both ends):

| offset | field |
|---|---|
| 0 | `U64` protected length L |
| 8 | `U64` record length (all of the above) |
| 16 | `U64` stripes S |
| 24 | `U32` sector size (≥ 512) |
| 28 | `U16` m: parity sectors per stripe (0 = checks only: detects, does not repair) |
| 30 | `U8` W: bytes per check (2 when m > 0, 4 when m = 0) |
| 31 | `U8` record version = 1 |
| 32 | 8 zero bytes |
| 40 | `U32` CRC-32 of bytes 0…39 and 44…47 |
| 44 | magic "PArr" (`50 41 72 72`) |

**Sectors and stripes.** The protected area is cut into N = ⌈L / sector size⌉ sectors (the last
one shorter, zero-padded for the parity). Sector i belongs to stripe i mod S at position i div S;
S = ⌈N / (255 − m)⌉, so a stripe has at most 255 − m data sectors and m parity sectors. Parity j
of stripe s is parity sector j·S + s, and its value is `Σ coef(j, p) · data(p)` over the stripe's
positions p (`RsCoef` in `parc_rs`). Interleaving spreads a contiguous damage of up to S·m
sectors over all stripes with at most m in each.

**Checks.** One per data sector, then one per parity sector: the low W bytes (little-endian) of
the sector's CRC-32 (of its real length). A check that does not match marks the sector as
missing. A damaged check only marks a good sector as missing (it is rebuilt to the same bytes).

**Stripe table.** The CRC-32 of each stripe's data sectors concatenated in position order (real
lengths), then the CRC-32 of the S values. After rebuilding a stripe the reader compares it
with this CRC; if it differs and the stripe has a spare parity, each other sector is tried as
the one whose damage the 16-bit check missed (probability 2^-16 per damaged sector). Two copies
(the first valid one is used; with both damaged, rebuilt stripes are not verified).

### 5.2 Finding and repairing

The record is found by the descriptor at the end of the file, or, if that one is damaged, by
scanning backwards for the first descriptor (magic + CRC). The archive starts at `record start
− L` (an SFX stub before it is neither protected nor needed). `parc r`:

1. reads both stripe tables, the checks and the parity;
2. reads the protected area once, comparing each sector with its check and computing each
   stripe's CRC;
3. rebuilds every stripe with damaged sectors (data or parity) or with a CRC mismatch, if it
   has at most m damaged sectors, and verifies it;
4. writes `fixed.<name>` (a copy; the original is never modified) with the rebuilt sectors and
   the record rewritten as it must be (descriptors, tables, checks, parity), so a repaired
   archive is byte-identical to the original. A volume set is repaired into one file.

Exit 0 if everything was repaired (or nothing was damaged), 2 if some stripe had more than m
damaged sectors (they are listed; a partial copy is still written if something was repaired),
1 if there is no record. A record with m = 0 reports the damaged sectors and exits 2.

### 5.3 Sizing (`-rr`)

Syntax in `docs/USO.md`. Every form except `<count>*<sector>` gives a **budget** for the whole
record: `N%` of L, `N b/k/m/g` bytes, or `N`/`Ns` = N sectors of 512 bytes (of the given size with
`;<sector>`). Then:

- sector size: given (`;<size>`), or the smallest power of two from 512 bytes whose checks take
  at most 1/8 of the budget (2·N ≤ budget / 8) and with N ≤ 2^25;
- m: the largest (1…254) whose record fits the budget; at least 1 (a budget below about
  0.4 % of L plus the checks gives a slightly bigger record than asked);
- `<count>*<sector>`: that sector size and the smallest m with S·m ≥ count; `0*<sector>` is a
  record of checks only (`-rr0.1%` = `0*4kb`, `-rr0.01%` = `0*64kb`).

With the default `-rr` (4 %, 2 % or 1 % by size) on a 10 MB archive: 1 % → 40 parity sectors of
2048 bytes (20 stripes, m = 2: any 2 sectors per stripe, or one contiguous damage of 80 KB);
5 % → 891 sectors of 512 bytes (81 stripes, m = 11). Compared with the record of PArc 0.0.5
(same RS code, FreeArc's two-block layout and 32-bit CRCs), the same parity costs 9.9 KB (1 %)
and 40 KB (5 %) less, because checks are 16-bit and verified per stripe.

## 5c. Pending

- Stronger per-file hash than CRC-32 (e.g. a BLAKE2b section)? To be decided.
- Hard links, ACLs, extended attributes: future optional sections.
- Reclaiming the dead bytes of appended archives without a full rewrite.

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
from content-defined samples); a block whose BWT output has few runs is coded
with the adaptive coder: fewer than 1/8 of its bytes instead of the fast coder (not with `e0`),
fewer than 30 % instead of the static one (also with `e1`); a block shorter than 64 bytes, or whose coded form
is not smaller, is stored; at `m1`..`m3`, a block where the LZP removes more than half of
the data is filtered again with 4 times the minimum (recorded in the block).

Decoder checks: version, header parameters, every field range above, the QLFC data (a read
past CodedLen, a length or rank that does not fit, a decoded size other than M), the primary
index and the LZP decoding; anything else is a damaged block (`EArcCorrupt`). Memory per block
being decoded: the coded data, M bytes, 4(M + 1) bytes for the inverse BWT, then Len bytes
and the LZP table; blocks are decoded in parallel within `PARC_THREADS`.

### 6.9 `tta` (since 2026-11)

`tta` is PArc's own lossless audio codec (`src/parc_tta.pas`, hot loops in C in
`src/tta/mmtta_core.c`), written to replace FreeArc's port of TTA (GPL); nothing is derived
from either. **`tta` blocks written before this change do not decode** (the version byte
rejects them). The method keeps its name and parameters: `tta[:m<level>][:s][:f][:c<n>][:w<bits>]
[:o<offset>][:r<n>][:<chan>*<bits>[f]]`. Level 1..9 (default 3) selects the predictor
configuration written in the stream; `m0` or `r1` store. Without `c`/`w`/`f` the encoder takes the
format from a WAV/RIFX/AIFF/AIFC header in the first MB (unless `s`), else from sample
statistics (1, 2, 4 or 6 channels of 8/16/24-bit samples, either byte order); if nothing fits,
the stream is stored. The decoder needs no parameter.

Stream:

| Field | Value |
|---|---|
| `U8 version` | 1 |
| `U8 mode` | 0 = stored: the rest of the stream is the data; 1 = coded |
| `U8 channels, U8 bits, U8 flags, U8 level` | 1..255 channels; bits 8/16/24/32; flags bit 0 big endian, bit 1 unsigned 8-bit, bit 2 IEEE float (bits = 32); level is informative |
| configuration | `U8 NF` (0..3), NF × (`U16 order` LE, multiple of 16 in 16..1024, `U8 shift` 1..24), `U8 A1, A2, A3, S2Shift, S2Step, MS, R1, R2` (R1 ≤ 7, R2 ≤ 1) |
| chunks | until type 0 |

Chunks: `U8 type`. Type 1, coded frame: `VInt frames` (1 ≤ frames ≤ 2^17 / channels), `VInt rcLen`
(≥ 5), `VInt rawLen`, rcLen bytes of range coder output, rawLen bytes of raw bits. Type 2, raw:
`VInt len` (1..2^20) bytes copied to the output (container header, trailing data, an incomplete
sample frame, a frame that did not compress). Type 0: end; nothing may follow. `VInt` is LEB128.

Samples are read as integers (8-bit unsigned minus 128; floats as their bit pattern, negative
ones xor 0x7FFFFFFF so the order is that of the values). Per sample frame, for stereo with MS = 1
first (L, R) → (M, S) = (R + (S >> 1), L − R) mod 2^32; then per channel in order, with all
arithmetic mod 2^32 and arithmetic right shifts:

1. d = x − ((31 · x_prev) >> 5) (x_prev of this channel, 0 at the start, 64-bit product).
2. Short stage (unless R1 bit 1): p = (Σ w_i·u_i + w_4·o_0 + w_5·o_1 + 2^(S2Shift−1)) >> S2Shift
   in 64 bits, u_0..3 = this channel's last four inputs d, o_0/o_1 = the previous channel's last
   input and the one before (channel NC−1 for channel 0; zeros for mono); out = d − p; then
   w_i += S2Step · sign(out) · sign(input_i) and the inputs shift.
3. LMS filters j = 0..NF−1 on 16-bit history h (inputs >> max(0, bits − 16), saturated) with
   16-bit coefficients c (all wrapping): first c_i += sign(err_prev) · a_i over the window of the
   previous sample (a = the steps stored with the history: ±A1 if |h| > 3·avg, ±A2 if 3|h| > 4·avg,
   ±A3 otherwise, 0 for h = 0; avg += (|h| − avg) / 16, truncating), then
   p = ((Σ c_i·h_i mod 2^32) << sh + 2^(shift−1)) >> shift, out = in − p; err_prev = out.
4. The residual e, zigzag-mapped to u = (e << 1) xor (e >> 31), is coded with the channel's
   models: from mean (initially 256; mean += min(u, 2^23) − mean >> 4), t = mean + 16,
   L = ⌊log2 t⌋, context 2L + bit L−1 of t (at most 63), k0 = min(L − 3, 32). The bit length b of u
   as s = clamp(b − k0 + 3, 0, 7) in a 3-level binary tree (nodes 1..7 of the context); s = 7 then
   bits "b > j" for j = k0+4.. (slots 8..18), s = 0 bits "b < j" for j = k0−3 down to 1 (slots
   19..31), each run ending at its first 0. Then, for b ≥ 2: with R1 bit 2 all b−1 bits below the
   leading one raw; else the first one modeled (context b), and for b ≥ 3 with R1 bit 0 the rest
   raw, else the second one modeled (context b and the first) and the rest raw.
   Binary decisions: a 32-bit range coder with carry (LZMA style: 5 flush bytes, the first byte
   0), 16-bit probabilities of a 0 starting at 32768, p += (t − p) >> 7 with t = 65408 after a 0 and
   127 after a 1. Raw bits go low bits first into the raw stream, 32 at a time.

5. With R2 bit 0 (no level uses it yet) a final short stage as in 2, on this channel's own
   last four residuals only, is applied to the residual before coding.

The decoder inverts the stages in reverse order. Models persist across frames; each frame's
range coder and raw stream are separate and must be used up exactly. Decoder checks: version,
mode, format, configuration ranges, frame and chunk sizes, b ≤ 32, both streams consumed exactly;
anything else is a damaged block (`EArcCorrupt`). Memory: the state (about 37 KB per channel
plus 9 KB per LMS filter), a frame of samples (2^17 values) and its coded bytes.

### 6.10 `mm` (since 2026-11)

`mm` is PArc's own decorrelation filter for multimedia data in front of a general compressor
(`src/parc_mm.pas`, loops in `src/tta/mmtta_core.c`), replacing FreeArc's `mm` (GPL; nothing is
derived from it). **`mm` blocks written before this change do not decode.** Method string as
before: `mm[:d<n>][:s][:f][:c<n>][:w<bits>][:o<offset>][:<chan>*<bits>[f]]` (`r` other than 0
is rejected). The output has the input's length plus the header below.

| Field | Value |
|---|---|
| `U8 version` | 1 |
| `U8 mode` | 0 = stored (the rest is the data); 1 = filtered |
| `U8 channels, U8 bytes, U8 flags, U8 predictor, U8 cross` | 1..16; 1..4; bit 0 big endian, bit 1 unsigned; 0..5; 0/1 |
| `VInt width, VInt rowBytes` | pixels per row and bytes per row (0, 0 = no rows) |
| `VInt header, VInt dataLen + 1` | bytes copied before the data; data bytes (0 = to the end) |
| padding | zero bytes to a multiple of 8 from the stream start (keeps the data's alignment) |

Then the header bytes as they are, the data region filtered, the rest as it is. The data region
is cut to a multiple of the unit (a row, or a sample frame of channels × bytes); an incomplete
unit at its end passes as it is. Each sample (read with its width, byte order and signedness)
becomes (sample − prediction) mod 2^(8·bytes). Without rows (predictor 0/1): the last sample of
the channel, or 2·last − the one before (0 at the start, carried through the whole stream). With
rows: of each row, the first width × channels × bytes bytes are samples, the rest passes as it
is; a = left, b = up, c = up-left (original values); the first row predicts a (0 at its start),
the first column b; else predictor 0 = a, 2 = b, 3 = a + b − c, 4 = the LOCO-I median (min(a, b)
if c ≥ max(a, b), max(a, b) if c ≤ min(a, b), else a + b − c), 5 = ⌊(a + b) / 2⌋. Cross = 1: with 2
channels the second residual minus the first, with 3 or more channels 0 and 2 minus channel 1.
The encoder (none of this is in the stream) takes the layout from a container header (WAV/AIFF;
BMP or bare DIB, TGA, binary PGM/PPM, uncompressed TIFF), the parameters, or sample statistics
(then also the frame phase and, for 8-bit pixels, a row length found as the byte distance at which
the data repeats best), the predictor and cross with the smallest residual cost on up to 128 KB
(64 KB with `d1`/`d2`), and stores (mode 0) when a fast LZ estimate on that sample is not smaller
filtered than raw (synthetic and palette images often compress better as they are). Packed
16-bit pixels (RGB555/565) and colour-mapped TGA are stored.

### 6.11 `lzma` encoder (since 2026-11): no FreeArc code

The `lzma` **stream does not change**: LZMA1 raw with the end marker, properties taken from the
method string, exactly as before (blocks written by any PArc decode, and the new streams decode
with liblzma). What changed is the encoder (`src/parc_lzmaenc.pas`, `src/parc_lzmarf.inc`): it is
the public-domain LZMA SDK 26.03 plus PArc's own code; the parts that came from FreeArc 0.67
(the `ht4` hash-table finder and its multi-thread match list, the default-cycles formula, the
`:fast` parser additions and the method-string parser) were removed without reading them and
replaced. Method string, parsed in order, case-insensitive (`*...` is ignored):

| Parameter | Meaning |
|---|---|
| `<n>` (digits only) | fast bytes (5..273) |
| `<size>`, `d<size>` | dictionary (`96m`, `1gb`, `64kb`, `512b`; digits without a suffix after `d` = 2^n) |
| `fb<n>`, `mc<n>`, `lc<n>` (0..8), `lp<n>` (0..4), `pb<n>` (0..4), `a<n>` | fast bytes, cycles, literal/position contexts, algorithm (0 = fast parser, ≥ 1 = optimal) |
| `bt2`, `bt3`, `bt4`, `hc4`, `ht4`, `mf=<finder>` | match finder |
| `fastest` / `fast` / `normal` / `max` / `ultra` | a0 fb5 mc1 / a0 fb32 / a1 fb32 / a1 fb128 / a1 fb128 mc128; `ht4` (`bt4` for max/ultra) if no finder was given yet |
| `h<size>` | memory for the `ht4` rows (default: 3/4 of the dictionary or of the input; all of it for the 24-bit row shapes and dictionaries up to 32 MB) |

`mc` = 0 picks 16 + fb/2 for `bt2`/`bt3`/`bt4`, half of that for `hc4` (the SDK's
`LzmaEncProps_Normalize`) and 4 + fb/8 for `ht4`. In `ht4`, `mc` is the number of candidates whose
4 bytes match that are verified per position (at most the row's capacity).

`ht4` (own design): a 64-bit multiplicative hash of 4 bytes picks a row of 16, 32 or 64 bytes
(cache-line aligned); the row is a ring of the most recent positions that fell into it, each
with a tag of 4, 6 or 8 other hash bits; the tags of a row are compared all at once inside one
64-bit word (SWAR), rotated so the newest comes first, and only the candidates with the right
tag read the window; the search stops at the first one out of the window. Row shapes: 32 bytes
with 7 tags of 4 bits and 32-bit positions; 64 bytes with 14; 32 bytes with 6 tags of 8 bits
(the `:fast` parser); and, for dictionaries up to 16 MB, 16 bytes with 4 entries and 32 bytes
with 8, 6-bit tags and 24-bit positions (the position modulo 2^24: every candidate is verified
against the window and the distance never exceeds the dictionary, so the stream is valid even
past 2^24 positions; with a dictionary of at most 16 MB no in-window distance is lost). Pairs come out in increasing length like `bt4`'s, so the
multi-thread finder (a thread searches the rows from length 3, the compressing thread keeps
the pairs longer than its hash2/hash3 matches) writes the same stream as one thread.

`:fast` parser: the SDK's `GetOptimumFast` with own thresholds: a match of 3 at distance ≥ 2 KB
or of 4 at ≥ 64 KB is coded as a literal, `ChangePair` takes the shorter match when the longer
one is more than 32 times farther (SDK: 128), and a rep of length L wins over a match of L + 4
at distance ≥ 16 KB. The window keeps 1/4 of slack instead of the SDK's 1/2.

### 6.12 `4x4` (since 2026-11)

`4x4` is PArc's own parallel block stage (`src/parc_4x4.pas`), replacing FreeArc's 4x4 (GPL;
nothing is derived from it). **`4x4` blocks written before this change do not decode.** Method
string as before: `4x4[:b<mem>][:r<N>][:t<N>][:i<N>]:<inner method>` — the 4x4 parameters are
the leading ones that start with a digit or whose second character is a digit; the rest is the
inner method (`plz:1:1mb` if there is none). `t` and `i` are accepted and ignored. The block size
is `b`, else the inner method's window (plz, lz4) or its first memory size, else 8 MB.

Stream: `"4X"` + `U8 version` (1), then records until an end record. `VInt` is LEB128 (7 bits per
byte, low first).

| Record | Layout |
|---|---|
| end | `U8 0` |
| stored | `U8 1, VInt rawLen, rawLen bytes` |
| packed | `U8 2, VInt rawLen, VInt packLen, packLen bytes` — the inner method's stream of all rawLen bytes |
| mixed | `U8 3, VInt rawLen, VInt n, n × VInt segLen, VInt packLen, packLen bytes, stored bytes` |

`rawLen` is 1..2^31−1 and `packLen` is smaller than the bytes it packs. In a mixed record the
segments (n ≥ 2, summing to rawLen) alternate packed / stored starting with a packed one (which
may be empty): the packed segments, joined, are the inner method's stream of `packLen` bytes;
then come the stored segments' bytes in order. Every record decodes on its own: the decoder runs
them on a pool of the thread budget and delivers them in order. A packed part that does not
decode becomes zeros with a warning (the file's CRC reports it) and the next records continue;
a damaged record header is an error.

The encoder (none of this is in the stream) makes one record per block, compressed in parallel.
With a slow inner method (not plz/lz4) it looks for noise in 64 KB cells: order-0 entropy at or
above `r` (default 99 %) and an estimate of an LZ with entropy coding (4-byte greedy matches up to
1 MB back) that saves less than 0.2 % (4 % in a block whose own order-0 entropy is at or above
`r`). Runs of at least 256 KB of noise cells are stored in a mixed record unless at least 4 % of
the run repeats elsewhere in the block or is repeated (content-defined anchors, ~1 per 512 bytes,
then byte comparison), so the inner method spends no time on data it cannot shrink and the parts
around a run keep their common context. The stream depends on the data, the parameters and the
block size only; the block size depends on `PARC_THREADS` only through the PArc-wide rules for
fast inner methods (`Adaptive4x4Block`, `Balance4x4` and, with 2+ threads, equal blocks for the
tail of a solid block whose size is known).

### 6.13 `srep` (since 2026-11-26): OSREP -m6, replaces FreeArc's SREP

`srep` is OSREP's long-range method `-m6` (OSREP 0.0.16 by osrep, MIT; the embeddable unit is
vendored unchanged in `src/osrep/`, version and commit in `src/osrep/VERSION`; glue in
`src/parc_osrep.pas`). It replaced the port of FreeArc's SREP 3.93 (GPL): **`srep` blocks written
before this change do not decode** (a block that holds a FreeArc SREP stream fails with "this
srep block is FreeArc SREP, which is no longer supported"; extract it with PArc 0.0.5). `osrep`
is accepted as another name of the same method and is stored as `srep`.

Method string: `srep[:<min length>][:l<n>][:a<n>][:b<mem>]`

| parameter | meaning | default | range |
|---|---|---|---|
| `l<n>` or a bare integer | shortest match | 512 | 32 .. 65536 |
| `a<n>` | match lengths are multiples of `a` (16 keeps the position modulo 16 that lzma models; 1 with no backend or a plain LZ) | 16 | 1 .. 4096 |
| `b<mem>` | literal block of the stream (does not change the matches) | 8mb | 64kb .. 256mb |
| `m…` | FreeArc SREP's mode (`m3f`…): accepted and ignored | | |

The stored (canonical) string has only the parameters that differ from the defaults
(`srep`, `srep:l64:a1`, `srep:l128:a1:b1mb`).

Block: empty for an empty input; otherwise one flag byte and the payload:

| flag | payload |
|---|---|
| 0 | the input as is (when the OSREP stream would not be smaller) |
| 1 | an OSREP `.osr` v7 stream of the whole input (`spec/format-v7.md` of OSREP, frozen; the `osrep` CLI decodes it with `osrep -d`), written without the per-block VHASH-128 digest: the stream table and every stream block still carry a CRC-32C, and the PArc block its own CRC |

The encoder needs the whole solid block in memory: the stage collects it and calls
`OsrepM6Encode` when the block ends, on the thread that writes the block (OSREP starts no
thread, so it uses one token of `PARC_THREADS`). The stream depends on the data and the
parameters only (not on `PARC_THREADS` or the write sizes), and the native C core and the Pascal
reference (`-dOSREP_NO_NATIVE`) give the same bytes on every platform. Sizes are 64-bit: a solid
block over 4 GiB works on 64-bit builds. Memory: the block, the output (`OsrepM6Bound`, the block
plus a few bytes per 8 MB) and `OsrepM6EncMem` (hash table, bit filter and match list: about
5–10 % of the block with `l512`, counted at its worst case). The decoder reads the whole stream,
checks header, table and footer (`OsrepM6OrigSize`), allocates the original size and decodes in
place (`OsrepM6Decode`, ~1 MB besides the stream and the output); a damaged stream is an error.
