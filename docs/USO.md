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
| `v` | verbose listing: time with nanoseconds (UTC), Unix mode or Windows attributes, size, share of its packed block, ratio, CRC, block number and method |
| `lt` | technical listing: the blocks (as `lb`) plus, for every entry, its block, offset in the uncompressed block, size, CRC, mtime in ns and mode |
| `create` | like `a`, but always starts a new archive: an existing one is replaced (only once the new one is complete) |
| `m` / `mf` | like `a`, then delete from disk what was archived (`m`: files, then the folders it added if empty; `mf`: files only) |
| `ch` | rewrite the archive with the options given (method, encryption, recovery record, lock, comment); untouched blocks are copied |
| `rr<spec>` | add or replace the recovery record: `rr`, `rr5%`, `rr10`… (= `ch -rr<spec>`) |
| `c` | set the archive comment (`-z<file>`, `-z` for stdin, `--archive-comment=<text>`) |
| `cw` | write the comment to a file: `parc cw <archive> <file>` (`-` = stdout) |
| `j` | join: `parc j <archive> <other.parc>...` adds the files of the others; their blocks are copied |
| `k` | lock the archive: afterwards no command modifies it |

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
| `-y` | answer yes to all queries: overwrite (unless `-o-` is given) |
| `-snld` | also create links that point outside the destination (absolute, or with `..` escaping it) |

Links are created at the end of extraction. For safety, without `-snld` PArc does not create
links that point outside the destination: through such a link another file could be written
anywhere on disk. On Windows, creating a link requires administrator rights or developer mode;
if that fails, PArc warns and skips it.

### Compression (a, u, f, d)

| option | effect |
|---|---|
| `-m<N>` | preset (from FreeArc): `-m0` (store) to `-m9`, `-mx` (maximum ratio with fast decompression), `-mxx` (CM maximum ratio, slow decompression). Default is `-m4` |
| `-m<method>` | explicit method, e.g. `-mlzma:64mb:max`, `-mcm` or `-morep:96m:l256+exe+lzma` |
| `--recompress` | when updating, rebuild every block with the requested method instead of copying intact ones |
| `-x<pattern>` | exclude files; may be repeated |

Presets choose a method per file type: through the file groups (by name and extension, see
`--print-config`) and, when the preset distinguishes text or already-compressed data, by
inspecting content (PArc's own detector, `src/parc_filetype.pas`). Each
compressor's dictionary is reduced to the block size, so extracting a small file does not
require the full preset memory.

`-mx` is the maximum preset that still decompresses fast: PPMd for text and LZMA for binaries
(both with the level's filters). It is slightly smaller than `-m9` and decompresses at similar
speed. `-mxx` uses PArc's **context-mixing** codec (`cm`) for text and binaries: it
produces clearly smaller archives, but decompression is roughly 5–40× slower than `-mx`.
Independent data blocks are compressed in parallel (all threads together limited by
`PARC_THREADS`) at every level, also when encrypting; incremental repacks stay serial. The block being written goes straight into
the archive; blocks that finish ahead of their turn wait in memory (at most min(1 GB, RAM/4)
in total, 256 MB on 32-bit) and only what does not fit goes to a temporary file next to the
archive.

`plz` is PArc's own fast LZ codec, the engine of `-m1`/`-m2` and of already-compressed files
up to `-m4`: `-mplz:<level>[:<window>]`, levels 1–7 (1–2 greedy, 3–4 lazy, 5–7 slower and
smaller), default level 3; the window defaults to 8 MB (levels 1–2), 16 MB (3) or 64 MB (4–7),
e.g. `-morep:96m:l256+exe+delta+plz:4` or `-m4x4:plz:1` (blocks of the window size in parallel;
`xplz` = `4x4:plz`, and `eplz` picks `plz` with one thread and `xplz` with more). Stream format
in [FORMATO-PARC.md §6.3](formato/FORMATO-PARC.md).

FreeArc's Tornado (`tor`, `xtor`, `etor`) was removed after PArc 0.0.5 (it was FreeArc code;
PArc is moving to the MIT license). `plz` replaced it everywhere: `-m1` uses `plz:2` with one
thread and `4x4:plz:1` with more (was `tor:4:8mb:h4m` / `4x4:tor:3:8mb`), `-m2` `plz:4` /
`4x4:plz:3` (was `tor:6` / `4x4:tor:5`), `$compressed` files at `-m4` `eplz:3` (was `etor:c3`).
A `tor` method on the command line is an error (exit code 3, with a hint to use `plz`), and
blocks compressed with `tor` by older pre-releases no longer decode (exit code 3: extract them
with PArc 0.0.5).

**Long-range matching: `orep`.** The presets put `orep` (OREP, MIT, written for PArc) in front
of the binary chains; it replaces FreeArc's `rep`, which no longer exists (`-mrep` fails with a
hint, and `rep` blocks of archives from PArc 0.0.5 or earlier do not decode). Syntax:
`orep[:<window>][:<min length>][:w<mem>][:l<n>][:a<n>][:s<n>][:c<n>][:r<n>][:b<mem>][:d<mem>]` — window
(largest distance, default `512mb`, up to `3840mb`), shortest match (`l`, default 64, ≥ 16),
alignment (`a`: lengths multiple of `a` and literals kept at their position modulo `a`, which
helps lzma; default `a0` = per stream block, 1 for text and 4 otherwise), anchor density (`s`,
1..64, default 4: higher finds more short matches, slower and with a larger table), candidates
per anchor (`c`, 1..4, default 4: 1 is the fastest), single-byte runs left to the next compressor
(`r<n>`: matches over a run of one byte shorter than `n`; default 0), stream block (`b`, a power of 2, 64kb..64mb,
default 4mb) and a minimum distance (`d`, default 0: nearer matches are left to the next
compressor). For example `-morep:96m:l256+exe+delta+lzma:96m`. The presets use
`orep:96m:l256:c2:r512` at `-m1`, `orep:96m:l256:r512` at `-m2`, `orep:96m:l512` at `-m3`…`-m5` and `orep:<window>:l512` at
`-m6`…`-m9`/`-mx` (window 256m, 512m, 1024m, 2040m). The stored method shows the window
clipped to the block. `orep` searches with up to 4 threads of its own, taken from `PARC_THREADS`
(see `PARC_OREP_THREADS`).

When updating (`a`, `u`, `f`), solid blocks that remain intact are copied without recompression.
A block that loses files, or has a file replaced by a newer one, is rewritten: its remaining
files in their order, the new version in the place of the old one, with the preset's method of
the same kind (or the block's old method). New files that replace nothing go into new blocks,
so adding files never rewrites existing blocks. `--recompress` forces rebuilding everything.
With `d` and an explicit `-m`, the whole archive is recompressed with that method (a "copying"
command, as in FreeArc).

### Commands that rewrite or extend an archive

**`ch`** rewrites the archive applying the options given; blocks that do not need to change are
copied byte for byte. FreeArc's "copying command" rules apply: `-m<method>` implies
`--recompress`. It takes no file names.

| with `ch` | effect |
|---|---|
| `-m<method>`, `--recompress` | recompress every block |
| `-rr<spec>` / `-rr-` | add or replace / remove the recovery record (the `rr<spec>` command is the same) |
| `-k` | lock (the `k` command is the same) |
| `-z<file>`, `-z`, `--archive-comment=<text>` | set the comment (the `c` command is the same) |
| `-v<size>` | turn it into volumes (or change their size) |
| `-p<new>` | if the password does not open the current data, it is a **new** password: every block is re-encrypted with it (and the headers too if they were encrypted). A `-p` that already opens the data is only used to read and changes nothing |
| `-hp<new>` | encrypt (or re-encrypt) the directory and footer with it |
| `-p-` | remove all encryption (data and headers) |
| `-hp-` | remove only the headers encryption |
| `-op<old>` | the current password, used only for reading (otherwise it is prompted; without a console the command fails with exit code 5) |

```sh
parc ch backup.parc -mx                     # recompress everything with -mx
parc ch backup.parc -pNew -hp -opOld        # change the password (and encrypt the headers)
parc ch backup.parc -p- -opOld              # decrypt
parc rr5% backup.parc                       # add a 5% recovery record
parc c backup.parc -znotes.txt              # comment from a file
parc cw backup.parc -                       # print it
parc k backup.parc                          # lock
```

Updating an archive whose headers are encrypted (`-hp`) keeps them encrypted even if `-hp` is
not repeated, as long as the password given (or prompted) opens them; before, they were written
in clear.

**`j`** appends the files of other `.parc` archives to the first one. Blocks are copied as they
are, encrypted or not: an encrypted block keeps its own password, so the result may need several
passwords to read (all of them are tried, `-p`, `-hp`, prompts). If `-p` is given, every
encrypted block must use it (a different one is rejected as a wrong password, exit code 5). A
name present in several archives is taken from the last one (like `a`: what is joined replaces);
blocks that lose files because of that are repacked with their method (re-encrypted with the
main password if they were encrypted). Joining an archive with itself is rejected.

**`m` / `mf`** (and the options `-d` / `-df` with `a`, `u`, `f`) delete from disk what was
archived, but only after the archive was completely written and, with `-t`, tested without
errors; on any error nothing is deleted. A file whose size or modification time changed after it
was read is kept (with a warning, exit code 6). Symbolic links are deleted as links, never their
targets. `m`/`-d` then removes the folders it archived if they are empty (deepest first); `mf`/
`-df` leaves folders alone. With `u`, files that were not replaced (the archived copy is as new)
are not deleted. Files given with `-si` are not on disk and are never deleted.

**`k`** (or `-k` with any writing command) sets the `locked` flag of the footer. Afterwards `a`,
`u`, `f`, `d`, `m`, `mf`, `create` (it does not replace it), `ch`, `c`, `rr`, `j` and `k` refuse to
modify the archive (exit code 1, "is locked"); `l`, `v`, `lt`, `lb`, `t`, `x`, `e`, `cw` and `r` still
work. There is no unlock (as in FreeArc).

### Solid blocks: `-s`

Without `-s`, archives are solid: a block is only cut where the file kind changes (each kind has
its own method), where a method needs it (a solid block holds at most one `dict` or `lzp` block
or four `bwt` blocks; `tta`/`mm` without an explicit sample layout take one file per block).
Inside a block files are ordered by file group, extension, folder and name, and files with the
same name in different folders are put next to each other. The
threads are used inside each block (4x4, multithreaded LZMA). Use `-s-`, `-s...` or an explicit
`-s<N>m` to cut blocks, for example to extract single files faster.

| option | effect |
|---|---|
| `-s-` | non-solid: each file in its own block |
| `-se` | one block per extension |
| `-s<N>` or `-s<N>f` | at most N files per block (`-s1f` = non-solid) |
| `-s<N>m` (or `k`, `g`, `b`) | blocks of *at least* that size: the block closes with the file that exceeds it |
| combined | `-se100f10m`: closes on the first criterion met |

### Recovery record: `-rr`

Adds parity data that lets `parc r` repair damaged sectors anywhere in the archive: data,
index, locator, and the record itself. The size is the size of the **whole record**.

| option | effect |
|---|---|
| `-rr` | recommended by size: 4% (archives under 300 KB), 2% (under 2 MB) or 1% |
| `-rr<N>%` | N percent of the archive (decimals allowed: `-rr2.5%`) |
| `-rr<N>` or `-rr<N>s` | N sectors of 512 bytes (`-rr<N>;<sector>`: of that size) |
| `-rr<N>b`, `-rr<N>k`, `-rr<N>m`, `-rr<N>g` | that many bytes (`kb`, `mb`, `gb` also accepted) |
| `-rr<amount>;<sector>` | an amount as above, with sectors of that size (`-rr2%;4k`) |
| `-rr<N>*<sector>` | at least N parity sectors of that size (rounded up to whole stripes) |
| `-rr0.1%` / `-rr0.01%` | only checks for 4 KB / 64 KB sectors: detect damage, do not repair (`0*4kb`, `0*64kb`) |
| `-rr-` | remove the record when updating |

Without `-rr`, updating an archive keeps whatever it had (the specification is stored in the
archive). Sectors smaller than 512 bytes are rejected; an invalid specification is an error
before anything is written.

The record is Reed-Solomon: it splits the archive into stripes of up to 255 sectors, each with
`m` parity sectors. It repairs up to `m` damaged sectors per stripe, at any position, including
parity itself. Sectors are interleaved across stripes, so a contiguous damaged range of up to
stripes × `m` sectors is also repaired. Unless a sector size is given, PArc picks the smallest one
(from 512 bytes) whose checks take at most 1/8 of the record, and then as much parity as fits.

On a 10 MB archive `-rr1%` gives 2 parities per stripe of 2048-byte sectors (20 stripes: 80 KB
of contiguous damage), and `-rr5%` gives 11 per stripe of 512-byte sectors. The more scattered
damage you want to tolerate, the higher the percentage. `parc r` writes `fixed.<name>`, which is
byte-identical to the archive before it was damaged; it reports which sectors it could not repair
(exit code 2). Format: [FORMATO-PARC.md §5](formato/FORMATO-PARC.md).

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
| `-ae=<alg>`, `--encryption=<alg>` | `chacha` (default: XChaCha20-Poly1305) or `aes` (AES-256-GCM) |
| `-ae=<alg>:t<n>:m<size>:p<n>` | key derivation cost: Argon2id passes, memory (`65536` KiB, `64m`, `1g`) and lanes; default `t3:m64m:p4` |

`-p` and `-hp` may carry different passwords; both are tried when reading.
If the password of an encrypted archive is missing, PArc prompts (up to three attempts).
A wrong password is reported as such (exit code 5); damaged or modified encrypted data is reported
as "authentication failed" (exit code 2), never as a CRC error.

`.parc` encryption (format: [FORMATO-PARC.md §3b](formato/FORMATO-PARC.md)):

- the key comes from the password (its UTF-8 bytes) with **Argon2id** (64 MiB, 3 passes, 4 lanes
  computed in parallel: ~0.2 s, once per archive); the cost is stored in the archive;
- **XChaCha20-Poly1305** or **AES-256-GCM** (AES-NI and PCLMULQDQ when the CPU has them), in
  64 KiB chunks, each with its own authentication tag: any change, truncation or reordering is
  detected, and nothing unauthenticated is decompressed;
- `-p` alone encrypts the file data; names, sizes and dates stay visible. `-hp` also encrypts and
  authenticates the directory and footer.
- Speed on one x86-64 core (Xeon E5-2697A v4, AVX2): XChaCha20-Poly1305 ~1.5 GB/s, AES-256-GCM
  ~1.7 GB/s. Without AVX2/AES-NI (and on i386/ARM) the portable code is much slower
  (~0.2 GB/s for XChaCha20, ~0.07 GB/s for AES-GCM), so `chacha` is the better choice there. The
  portable AES is table based and not constant-time; the x86-64 AES-NI path is.

Updating an encrypted archive (`a`, `u`, `f`, `d`) needs its password: a different `-p` is
rejected as a wrong password, so the data of one archive never mixes passwords. Intact solid blocks
are copied as they are; blocks that are repacked are encrypted again even if `-p` was not given
(deleting a file does not leave the rest in plaintext).

Archives encrypted by PArc 0.0.3 or earlier (FreeArc's AES/Blowfish/Serpent/Twofish scheme) can no
longer be read; extract them with PArc 0.0.3.

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

### File selection (a, u, f and l, t, x, e, d)

The same rules apply when adding files from disk and when choosing entries of an archive.

| option | effect |
|---|---|
| `-x<pattern>` | exclude matching names (repeatable). Also applies to `l`/`t`/`x`/`e`/`d` |
| `-n<pattern>` | include only matching names (repeatable). An empty `-n@list` selects nothing |
| `@listfile` | anywhere a name or pattern is accepted (also `-x@file`, `-n@file`): one name/pattern per line, UTF-8 (BOM allowed), empty lines and lines starting with `#` ignored |
| `-sm<size>` / `-sl<size>` | only files larger / smaller than size: bytes, or with `k`, `m`, `g` (1024-based) |
| `-ta<time>` / `-tb<time>` | only files modified at or after / before a local time `YYYYMMDD[hh[mm[ss]]]` (separators `-_:. T/` ignored: `-ta2024-06-01_08:00`) |
| `-tn<period>` / `-to<period>` | only files newer / older than a period: `<n>w`, `<n>d`, `<n>h`, `<n>m`, `<n>s` combined (`2h30m`); a bare number is days |
| `--dirs` / `-ed` | include / exclude directory entries (see below) |

A name matches a pattern if the whole name, its last component or a directory prefix matches
(`-xsrc/tmp` excludes everything below `src/tmp`). Size and time filters look only at files and
links. Directory entries are included by default; with a content filter (`-n`, `-sm`, `-sl`,
`-ta`, `-tb`, `-tn`, `-to`) they are left out (so a filter does not leave empty directories of
what it skipped) unless `--dirs` is given; `-ed` always leaves them out. When adding, `-ed` means
empty directories are not archived (directories with files come back implicitly on
extraction, without their own time/permissions); when extracting, directory entries are not
created.

`d` needs at least one name/pattern or a selection option (`-n`, `-sm`…, `-ap`): `parc d x.parc
-sm1g` deletes every file larger than 1 GB; `parc d x.parc` alone is an error.

```sh
parc a src.parc project -n*.pas -n*.inc -x'*/backup/*'
parc a big.parc /data -sm100m -ta20260101          # large files changed this year
parc x logs.parc -tn7d -dprecent                   # only what changed in the last week
parc l backup.parc @wanted.txt
```

### Paths inside the archive: `-ep`, `-ep1`, `-ap`

| option | effect |
|---|---|
| `-ep` | adding: store only file names, without directories (no directory entries; a repeated name is skipped with a warning). `x -ep`: extract without paths, like `e` |
| `-ep1` | adding: drop the base directory given on the command line (`parc a x.parc /home/me/proj -ep1` stores `a.txt`, `sub/b.txt` instead of `home/me/proj/a.txt`); `dir/*.pas -ep1` stores names relative to `dir/` |
| `-ep2` | the default: the path as given, without root or `..` |
| `-ap<dir>` | base directory inside the archive. Adding: every stored name gets `<dir>/` in front. Reading (`l`, `t`, `x`, `e`, `d`): only entries below `<dir>/` are used, and names are relative to it (patterns too) |

FreeArc's `-ep3` (absolute paths) is not supported: absolute names are never stored.

```sh
parc a site.parc /var/www/site -ep1 -apwww/2026-11      # stored as www/2026-11/...
parc x site.parc -apwww/2026-11 -dprestore              # restore/index.html, not restore/www/...
parc x site.parc '*.css' -ep -dpcss                     # all .css files, flat
```

### Testing around updates: `-t`, `-tp`

| option | effect |
|---|---|
| `-t` | after a successful `a`/`u`/`f`/`d`, test the new archive (like `t`); if the test fails the exit code is the test's (2, 3, 5, 7) |
| `-tp` | before modifying an existing archive, test it; if it fails, stop with its exit code and leave the archive untouched |

### Archive name, times and temporary files

| option | effect |
|---|---|
| `-ag[FMT]` | append the local date/time to the archive name, before the extension: `backup.parc -ag` → `backup20261117153000.parc`. FMT: runs of `Y` (`YY` = 2 digits, otherwise 4), `M`, `D`, `h`, `m`, `s` (2 digits); other characters literal (`-ag_YYYY-MM-DD`). It applies to every command, so `parc l backup.parc -agYYYYMMDD` opens today's archive |
| `--nodates` | do not store file times (stored as 0); extracted files keep the extraction time. With `u`, such files always count as older |
| `-tk` | when updating, keep the archive file's previous modification time |
| `-tl` | set the archive file's time to that of the newest file inside |
| `-w<dir>` | temporary files (the archive being written, blocks waiting their turn, `-si` and `-` copies, parallel-extraction temporaries) go to `<dir>`. At the end the new archive is renamed into place; if `<dir>` is on another file system it is first copied next to the archive, so a failed copy never leaves the old archive missing |
| `--sync` | `a`/`u`: also delete from the archive the entries that no longer exist on disk, but only inside what the given arguments cover (`parc u x.parc src --sync` touches only `src/...`) and only entries the selection options choose (`-x`, `-n`, filters). Files that exist but could not be read are kept |
| `-y` | answer yes to every question: extraction overwrites existing files (an explicit `-o-` still wins). PArc never asks for anything else that `-y` could answer (passwords are not "yes") |

### Threads and memory: `-mt`, `-lc`, `-ld`

| option | effect |
|---|---|
| `-mt<N>` | thread budget for the whole process, exactly like `PARC_THREADS=N` (which it overrides): it also chooses the preset alternatives (`-mt1 -m1` uses the single-thread `plz:2`). `-mt0` = default |
| `-lc<size>` | memory limit for compression (bare number = MB; `k`/`m`/`g`; or `N%` of RAM; `-lc-` or `-lc0` = no limit). Default: automatic, see below |
| `-ld<size>` | `t`/`x`/`e`: do not decompress blocks whose method declares more memory than the limit; their files are reported and the exit code is **7** (for `orep` the method declares its ring: window + one stream block). `-ld-` = no limit (the default) |

The compression limit applies to the encoders running at the same time. PArc estimates what
each method chain needs (all stages of a chain run together: lzma by its exact encoder size,
match finder included; orep window ring and anchor table (`OrepEncMemory`); PPMd model; plz window and tables; lzp/dict/bwt
blocks; `4x4` counts one inner encoder per thread plus its blocks; `cm` its model (`cm:<level>`,
level 6 ≈ 170 MB, less for blocks under 1 MB) plus up to 64 MB of input; `srep` keeps the whole
block and its output in memory, plus OSREP's index, about 5–10 % of the block) and, if a block's chain does not fit, shrinks the largest consumer first
(dictionaries, windows, the PPMd model) until it fits, like FreeArc's memory limiting. Blocks
compressed in parallel are also limited so that their sum fits. The reduced method is what the
archive stores (`parc lb` shows it), so decompression needs less memory too. `cm`, `srep` and the
filters cannot be reduced.

Without `-lc` the limit is automatic: 75 % of the physical RAM; in the 32-bit builds (win32,
linux32) also at most 2.25 GB and 9/16 of the address space (a large-address-aware process on
64-bit Windows has 4 GB, on 32-bit Windows 2 GB), leaving room for buffers and DLL
fragmentation (measured: TILIN `-m9` with 8 threads peaks at 2.4 GB in win32). So with huge inputs at `-m7`…`-mx` the 32-bit builds choose smaller dictionaries
than x86-64 (their archives can differ), and an x86-64 machine with little RAM can too. The
result only depends on the data, `PARC_THREADS`/`-mt`, the limit and the bitness.

### Removing algorithms from the methods: `-mc`

| option | effect |
|---|---|
| `-mc-<alg>` or `-mc<alg>-` | remove the algorithm from every chain (`-mc-orep` — `-mc-rep` too, for FreeArc's sake —, `-mc-exe`, `-mc-delta`, `-mc-lzp`, `-mc-dict`, `-mc-dispack`…); a file group whose special method *ends* with it is dropped (its files use the main method). A chain left empty becomes `storing` |
| `-mc-$group` | drop that group's special method (`-mc-$text`, `-mc-$wav`) |
| `-mc$g1,$g2:-<alg>` | only in those groups (`$default` = the main method) |
| letters | as FreeArc/RAR: `-mcd-` delta, `-mce-` exe, `-mcl-` lzp, `-mcr-` orep, `-mcz-` dict, `-mca-` $wav, `-mcc-` $bmp, `-mct-` $text |

Adding algorithms (`-mc+...`) and replacing them (`-mca/b`) are not supported. `-mcm` is still the
`cm` method (an operation needs a leading or trailing `-` or a `$`).

### Key file: `-kf`

`-kf<file>` uses the contents of a file as (part of) the password. Alone, it is the password of
the data (like `-p`); with `-p`/`-hp` both are needed to open the archive. A wrong or missing key
file is reported as a wrong password (exit code 5). The key file can be anything (an image, a
random file): only its BLAKE2b-256 hash is used, so it may be large; it must not be empty.
The exact derivation is in [FORMATO-PARC.md §3b](formato/FORMATO-PARC.md); the archive format does
not change.

```sh
parc a secret.parc docs -kf/media/usb/key.bin -pSecret -hp
parc x secret.parc -kf/media/usb/key.bin -pSecret
```

### Other

| option | effect |
|---|---|
| `-kb` | `x`/`e`: keep broken files. Without it, a file whose CRC does not match, or that could not be completed because its block is damaged, is **deleted** (like FreeArc) and reported; with `-kb` whatever was written stays |
| `--print-config` | print the built-in preset table (rows `name [levels] [$group] = chain`, `N` = the level digit, with the variant used from K threads on), what each `-m0`…`-mxx` resolves to with the current thread budget (`-mt<N>` changes it) and the file groups with their masks, then exit. Works with or without a command |

### Damaged blocks

If a block is damaged, extraction continues with the others. For that block PArc reports every
file it could not extract; a file that was being written, or that came out with a wrong CRC, is
deleted (FreeArc's behaviour) unless `-kb` is given, which keeps whatever was recovered. If the
archive has a recovery record, PArc suggests `parc r`.

If the end of the archive is damaged or cut (the end locator), PArc finds the index by scanning
backwards and reads the archive with a warning. If the index itself is damaged the archive cannot
be listed: repair it with `parc r` if it has a recovery record. Archives written by PArc 0.0.5
and earlier use the old container and are rejected ("old PArc format"): extract them with
PArc 0.0.5.

### Progress and cancellation

| option | effect |
|---|---|
| `--no-progress` | disable the progress line |

The `t` command verifies independent blocks in parallel (threads limited by `PARC_THREADS`), so
its speed scales with the number of blocks. Extraction (`x`/`e`) also decodes independent blocks
in parallel, and each worker writes its files straight to the destination (no temporary
files, no size limit); messages are still printed in archive order, a damaged block is reported
exactly as in the serial path, and links and directory dates are set at the end. When two
archive entries would land on the same destination name (for example with `e`), the archive
is extracted in archive order instead (decoding in parallel to temporary files up to 2 GB).
With one thread everything is serial. The progress line (phase, percentage, MB, speed,
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
| 7 | some blocks were not decompressed: they need more memory than `-ld` allows |
| 130 | cancelled with Ctrl-C |

## Environment variables

| variable | effect |
|---|---|
| `PARC_THREADS` | maximum number of threads working at the same time in the whole process (default: CPU cores, at most 64): block compression, 4x4/bwt, `orep`, the multi-threaded LZMA match finder, `t` verification and parallel extraction all share it. It also picks the preset alternatives, like FreeArc's `-mtN` (e.g. `PARC_THREADS=1 -m1` uses the single-thread `plz:2`). The `-mt<N>` option overrides it |
| `PARC_OREP_THREADS` | threads of the `orep` encoder: by default the block's share of `PARC_THREADS` (up to 4) when it is at least 2, else 1 (on the writing thread). OREP's threads only work with a free `PARC_THREADS` token (they never wait for one; the writing thread searches the block itself when none is free), so the budget is never exceeded; the output is the same with any number. `1` = always on the writing thread |
| `PARC_BUFMEM` | MB of memory for compressed blocks waiting their turn when compressing in parallel (default min(1024, RAM/4), 256 on 32-bit); the rest goes to temporary files |
| `PARC_CRC` | `table` disables the PCLMULQDQ CRC-32 (for measurements) |

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
