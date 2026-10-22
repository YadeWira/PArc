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
- **Footer**: the same fields, including `locked`, `recovery` and `comment`.
- **Encryption**: the same method string as the base container, plus two parameters that PArc
  always writes in `.parc` (a reader also accepts old archives without them):
  - `:f`: the hex of `:s`, `:c`, `:i` and the key decodes correctly and the password is in
    UTF-8 (in FreeArc, `:f` existed but was unused; without it, hex is decoded with
    `buggy_decode16`);
  - `:m`: at the end of a block's encrypted data there are 32 tag bytes:
    HMAC-SHA512(K_mac, IV ‖ ciphertext) truncated, with K_mac = HMAC-SHA512(key, "PArc-MAC-v1").
    `compsize` includes the tag.
  Default is `:n200000`. All blocks of an archive written in one go share the salt (and key);
  each one carries its own random IV.

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
