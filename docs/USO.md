# PArc — command-line manual

PArc is an archiver written in Free Pascal for Windows 7 or later (x86 and x64) and Linux x64.
It uses its own format, `.parc` (derived from the FreeArc container), which stores nanosecond
timestamps, Windows attributes and Unix permissions. PArc does not read or write `.arc`: use
FreeArc-ex for that (https://github.com/YadeWira/FreeArc-ex).

```
parc <command> <archive> [files/patterns...] [options]
parc help [command]
parc --version
```

Running `parc` without arguments shows a short help summary (exit code 0). `parc help` shows
the full option reference, and `parc help <command>` explains one command. Options may appear
in any position. The first non-option argument is the archive; the rest are
the files or patterns the command operates on.

## Commands

| command | what it does |
|---|---|
| `l` | list contents: date (UTC), size, CRC and name |
| `lb` | list internal blocks: control, data, method and contained files |
| `t` | test: decompress everything and compare CRCs, without writing |
| `x` | extract keeping paths |
| `e` | extract without paths (everything into the destination directory) |
| `a` | add files and replace existing ones; create the archive if missing |
| `u` | like `a`, but replace only when the disk copy is newer |
| `f` | freshen: update only files already in the archive when the disk copy is newer |
| `d` | delete the given names or patterns from the archive |
| `r` | repair with the recovery record: writes `fixed.<name>`; the original is untouched |

Directories passed to `a`/`u`/`f` are scanned recursively.

### Patterns and links (a, u, f)

- An argument may be a pattern with `*` and `?` in its last component: `*.txt`, `src/*.pas`.
  PArc expands it itself (Windows `cmd.exe` does not). Matching directories are added in full.
  `*.*` includes names without a dot, as on Windows.
- `-r`: the pattern also searches every subdirectory (`parc a x.parc -r '*.txt'`).
- If nothing matches and the archive did not exist, no empty archive is created.
- A file that cannot be read (no permission, or locked by another program) is skipped with a
  warning: the rest is still added, and if it was already in the archive the previous version is
  kept. PArc exits with code 6.
- Symbolic links (and Windows junctions) are stored as links, without following them.
- The archive being written, its volumes and its temporary files are not added even if they
  match a pattern (`parc a x.parc .` does not put `x.parc` inside itself).

## Options

### Destination and overwriting (x, e)

| option | effect |
|---|---|
| `-dp<dir>` | destination directory |
| `-o+` | overwrite existing files |
| `-o-` | skip them (this is what happens when nothing is specified) |
| `-snld` | also create links that point outside the destination (absolute, or with `..` escaping it) |

Links are created at the end of extraction. For safety, without `-snld` PArc does not create
links that point outside the destination: through such a link another file could be written
anywhere on disk. On Windows, creating a link requires administrator rights or developer mode;
if that fails, PArc warns and skips it.

### Compression (a, u, f, d)

| option | effect |
|---|---|
| `-m<N>` | preset (from FreeArc): `-m0` (store) to `-m9`, `-mx` (maximum ratio with fast decompression), `-mxx` (CM maximum ratio, slow decompression). Default is `-m4` |
| `-m<method>` | explicit method, e.g. `-mlzma:64mb:max`, `-mcm` or `-mrep:96m+exe+lzma` |
| `--recompress` | when updating, rebuild every block with the requested method instead of copying intact ones |
| `-x<pattern>` | exclude files; may be repeated |

Presets choose a method per file type, like FreeArc: through `arc.groups` (extension) and, when
the preset distinguishes text or already-compressed data, by inspecting content. Each
compressor's dictionary is reduced to the block size, so extracting a small file does not
require the full preset memory.

`-mx` is the maximum preset that still decompresses fast: PPMd for text and LZMA for binaries
(both with the level's filters). It is slightly smaller than `-m9` and decompresses at similar
speed. `-mxx` uses the **context-mixing** codec (`cm`, lpaq1-style) for text and binaries: it
produces clearly smaller archives, but decompression is roughly 5–40× slower than `-mx`.
Independent data blocks are compressed in parallel (workers limited by `PARC_THREADS`) at every
level; encrypted and incremental repacks stay serial.

When updating (`a`, `u`, `f`), solid blocks that remain intact are copied without recompression;
`--recompress` forces rebuilding them. With `d` and an explicit `-m`, the whole archive is
recompressed with that method, just like FreeArc (a "copying" command:
`is_COPYING_COMMAND` in `Cmdline.hs`).

### Solid blocks: `-s`

Without `-s`, PArc uses an automatic solid-block size: **64 MB** for `-m1`…`-m3` and
**32 MB** for `-m4`…`-m9`/`-mx`. This lets large archives use several workers; small archives
still fit in one block. Use `-s-`, `-s...` or an explicit `-s<N>m` to override it. `-mxx` keeps
all data together to maximize the CM ratio.

| option | effect |
|---|---|
| `-s-` | non-solid: each file in its own block |
| `-se` | one block per extension |
| `-s<N>` or `-s<N>f` | at most N files per block (`-s1f` = non-solid) |
| `-s<N>m` (or `k`, `g`, `b`) | blocks of *at least* that size: the block closes with the file that exceeds it |
| combined | `-se100f10m`: closes on the first criterion met |

### Recovery record: `-rr`

Adds parity data that lets `parc r` (or `arc r`) repair damaged sectors.

| option | effect |
|---|---|
| `-rr` | recommended by size: 4%, 2% or 1% |
| `-rr<N>%` | N percent of the archive |
| `-rr<N>` or `-rr<N>s` | N sectors of 512 bytes |
| `-rr<N>b`, `-rr<N>k`, `-rr<N>m` | that many bytes |
| `-rr<amount>;<sector>` | an amount as above, with sectors of that size |
| `-rr<N>*<sector>` | exactly N sectors of that size |
| `-rr0.1%` / `-rr0.01%` | only CRCs for 4 KB / 64 KB sectors: detect damage, do not repair |
| `-rr-` | remove the record when updating |

Without `-rr`, updating an archive keeps whatever it had. Sectors smaller than 512 bytes are
rejected (FreeArc runs out of memory with them).

The record is Reed-Solomon: it splits the archive into stripes of up to 255 sectors, each with
`m` parity sectors. It repairs up to `m` damaged sectors per stripe, at any position, including
parity itself. Sectors are interleaved across stripes, so a contiguous damaged range of up to
stripes × `m` sectors is also repaired.

With `-rr1%` there are about 2 or 3 parities per stripe, and with `-rr5%` about 12. The more
scattered damage you want to tolerate, the higher the percentage. `parc r` reports which
sectors it could not repair.

### Volumes: `-v` (`.parc` only)

Splits the archive into fixed-size pieces, 7-Zip style: `backup.parc.001`, `backup.parc.002`…
(the last one smaller).

| option | effect |
|---|---|
| `-v<N>` | volumes of N bytes; with suffix `k`, `m`, `g`: `-v100m`, `-v4g`, `-v700000k` |

- To list, extract, test or update, pass the first volume (`backup.parc.001`) or the base name
  (`backup.parc`); PArc joins the volumes on the fly.
- It is the same archive cut into pieces: `cat backup.parc.0* > backup.parc` (or `copy /b` on
  Windows) produces a normal `.parc`.
- Updating a volume set keeps the volume size (that of the first volume) and deletes extra
  volumes. `-v` on a single-file archive turns it into volumes.
- With `-rr`, the record protects the whole set; `parc r` writes a single-file `fixed.<name>`.
- If a middle volume is missing, PArc reports which one; if the last one is missing, the error
  suggests it.

### Encryption

| option | effect |
|---|---|
| `-p<password>` | on read: password of an encrypted archive. When compressing: encrypt data |
| `-p` | no value: prompt on the console (twice when encrypting) |
| `-hp[<password>]` | also encrypt the directory and footer: without the password not even the listing is visible |
| `-ae=<alg>`, `--encryption=<alg>` | `aes` (default, aes-256/ctr), `blowfish`, `serpent`, `twofish`; with size and mode: `serpent-256/cfb`, `blowfish-448/ctr`… |

`-p` and `-hp` may carry different passwords; both are tried when reading.
If the password of an encrypted archive is missing, PArc prompts (up to three attempts).
When updating an encrypted archive, blocks that are repacked are encrypted again even if `-p`
was not given: deleting a file does not leave the rest in plaintext.

`.parc` encryption uses:

- 200,000 PBKDF2-HMAC-SHA512 iterations to derive the key. This costs ~0.6 s, once per archive.
  `-ae=aes:n<N>` selects another count;
- the full key (32 bytes for AES-256), without FreeArc's defective decoding;
- one authentication tag per block (32-byte HMAC-SHA512): a change in the encrypted data is
  detected ("authentication failed"), which CRC alone does not guarantee with CTR;
- the password in UTF-8, so any character counts.

`.parc` archives encrypted by older PArc versions can still be read and updated.

### Standard input and output

| option | effect |
|---|---|
| `-so` | `x`/`e`: write the requested files' contents to stdout, without creating anything on disk |
| `-si[name]` | `a`: add data from stdin as a file with that name (no name: `stdin`) |
| `-` as archive | `l`, `lb`, `t`, `x`, `e`: read it from stdin; `a`: write it to stdout |

```sh
tar cf - project | parc a backup.parc -siproject.tar -m5   # compress tar output
parc x backup.parc project.tar -so | tar xf -               # and back
parc x backup.parc config.ini -so                           # view a file without extracting it
parc a - docs | ssh other 'cat > docs.parc'                 # the archive, straight over the network
```

With `-so` or with `a -`, messages go to stderr so they do not mix with data. An archive cannot
be read or written sequentially (descriptors point backwards and the directory is at the end),
so stdin is first copied to a temporary file: with `-si`, next to the archive; with `-`, in the
system temporary directory (`TMPDIR`). Temporary files are deleted on completion, including on
error or Ctrl-C.

### Damaged blocks

If a block is damaged, extraction continues with the others. For that block PArc reports every
file it could not extract; a file that was being written keeps whatever was recovered. If the
archive has a recovery record, PArc suggests `parc r`.

### Progress and cancellation

| option | effect |
|---|---|
| `--no-progress` | disable the progress line |

The `t` command verifies independent blocks in parallel (workers limited by `PARC_THREADS`), so
its speed scales with the number of blocks. Extraction (`x`/`e`) decodes independent blocks in
parallel to temporary files and then writes the files sequentially, so output order, overwrite
prompts, links and error reporting are unchanged. Temporary space is up to the decoded size;
archives with more than 2 GB of decoded blocks use the serial path. The progress line (phase, percentage, MB, speed,
remaining time and current file) is shown on
stderr only when it is a console; when redirected it does not appear. Ctrl-C cancels cleanly:
when compressing, the temporary file is removed and an existing archive remains intact; when
extracting, the half-written file is deleted. A second Ctrl-C stops immediately.

## Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 1 | usage error (unknown option, missing arguments, locked archive, or missing archive in `f`/`d`) |
| 2 | corrupt data: wrong CRC or broken structure; with `r`, unrecoverable sectors |
| 3 | a method PArc cannot decompress or compress yet |
| 4 | I/O error (could not open or create a file, for example) |
| 5 | missing or wrong password |
| 6 | finished, but some files could not be read and were not added |
| 130 | cancelled with Ctrl-C |

## Environment variables

| variable | effect |
|---|---|
| `PARC_THREADS` | threads for parallel compressors (4x4, grzip), block compression, `t` verification and parallel block decoding for extraction; defaults to CPU cores |

## Examples

```sh
parc a backup.parc project/ -m5 -rr       # with a recovery record
parc a photos.parc photos/ -mx -s-        # maximum ratio with fast decode, non-solid
parc a photos.parc photos/ -mxx -s-       # absolute maximum ratio (CM), slow decode
parc a private.parc docs/ -p -hp          # encryption; prompts for the password
parc u backup.parc project/               # update what changed
parc d backup.parc 'project/tmp/*'        # delete
parc t backup.parc                        # test
parc x backup.parc -dpdestination -o+     # extract, overwriting
parc r backup.parc                        # repair -> fixed.backup.parc
```

## Relationship with FreeArc

PArc started as a compatible rewrite of FreeArc 0.67, but it no longer reads or writes `.arc`.
The `.parc` format keeps the block structure and methods, with its own extensions
(`docs/formato/FORMATO-PARC.md`). The compressors are the same, ported to Pascal and verified
against the C sources in `reference/freearc-0.67/Compression/`.

Support for `.arc` (and the other containers) lives in
[FreeArc-ex](https://github.com/YadeWira/FreeArc-ex).

Self-extractor creation (`-sfx` and the `parcsfx` module) was also dropped. PArc still opens,
tests and extracts existing SFX archives, and updating one preserves the stub in front of it.
