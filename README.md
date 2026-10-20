# PArc

PArc is a from-scratch rewrite of [FreeArc 0.67](https://sourceforge.net/projects/freearc/) in
Free Pascal. It is a command-line archiver for **Windows 7+ (x86/x64)** and **Linux x64** that
reads and writes FreeArc `.arc` archives, plus its own `.parc` format with extra features.

Everything is written in Pascal: no third-party compression libraries are linked, every codec
is ported from its reference source (with the original C sources kept in the tree for
comparison and tests).

## Highlights

- **FreeArc compatible**: reads everything FreeArc 0.67.1 writes (all methods, encrypted
  archives, recovery record); `.arc` files written by PArc are verified and extracted by
  `arc.exe`/`unarc` from FreeArc 0.67.1.
- **Native x64**: LZMA, PPMd, Tornado, REP, Dict, LZP, Delta, MM, TTA, GRZip, 4x4 and LZ4 are
  ported with 64-bit-safe code (FreeArc had several 32-bit assumptions).
- **All the core methods**, singly or chained: `storing`, `lzma`, `ppmd`, `grzip`, `dict`,
  `rep`, `delta`, `tor`, `lzp`, `mm`, `tta`, `4x4`, `exe` (BCJ x86), `lz4`, `dispack070`
  (DisPack) and `srep` (SREP).
- **`.parc` format**: nanosecond timestamps, Windows attributes and Unix permissions,
  Reed–Solomon recovery record (a damaged range is repairable, not just single sectors),
  volumes (`-v`), strong encryption (`:f` key decoding, authentication tag, 200k PBKDF2
  iterations) and SFX modules.
- Long paths (`\\?\` on Windows), symlinks/junctions, stdin/stdout (`-si`, `-so`, `-`),
  multi-volume extraction, masks and recursion.
- Cancellation leaves no partial files; writes go to a temporary file that replaces the
  original only when the operation succeeds.

## Repository layout

```
src/                     PArc sources (Free Pascal)
docs/                    manuals and format notes (currently in Spanish)
tests/                   test suite, oracles and fuzzers
reference/freearc-0.67/  original FreeArc 0.67 sources (Haskell/C++), used as the
                         format/codec reference and test oracle; not part of the build
build.sh                 builds parc and parcsfx
```

## Commands

```
parc <command> <archive> [files/patterns...] [options]
```

| command | action |
|---|---|
| `l` | list contents (UTC date, size, CRC, name) |
| `lb` | list internal blocks (method, sizes, files per block) |
| `t` | test: decompress and check CRCs, write nothing |
| `x` | extract with paths |
| `e` | extract without paths (flat) |
| `a` | add/replace files; create the archive if needed |
| `u` | like `a`, but only replace when the file on disk is newer |
| `f` | freshen: update only files already in the archive |
| `d` | delete names or masks from the archive |
| `r` | repair with the recovery record (writes `fixed.<name>`) |

```sh
parc a backup.arc project/ -m5 -rr        # FreeArc-compatible, 5% recovery record
parc a photos.parc photos/ -mx -s-        # own format, max compression, not solid
parc a secret.arc docs/ -p -hp            # encrypted (asks for the password)
parc u backup.arc project/                # update changed files
parc t backup.arc                         # verify
parc x backup.arc -dpout -o+              # extract, overwrite
parc r backup.arc                         # repair -> fixed.backup.arc
```

Exit codes: `0` OK, `1` usage error, `2` damaged data, `3` unsupported method/parameter,
`4` other I/O error, `5` missing/wrong password, `6` finished but some files were unreadable,
`130` cancelled.

## Build

Requires Free Pascal 3.2 or newer.

```sh
./build.sh linux64     # default; produces build/linux64/parc and parcsfx
./build.sh win64       # needs the Windows cross toolchain (FPC_CROSS)
./build.sh win32
./build.sh all
```

`parcsfx` is the self-extractor module used by `parc a -sfx`.

## Testing

The test suite compares PArc against the real FreeArc 0.67.1 binaries as an oracle. Most
scripts need `arc.exe` running under Wine and a sample corpus; `tests/srep.sh` also builds the
reference `srep` from `Compression/SREP`.

```sh
bash tests/regress.sh        # extraction vs unarc on arc.exe-made archives
bash tests/order_matrix.sh   # solid block layout vs arc.exe
bash tests/update_matrix.sh  # a/u/f/d semantics vs arc.exe
bash tests/write_matrix.sh   # PArc writes, FreeArc reads
bash tests/compat_matrix.sh  # read matrix for every method
bash tests/dispack.sh        # DisPack, both directions
bash tests/srep.sh           # SREP v1-v4 decode, v3 encode, corrupt-stream robustness
bash tests/canon_methods.sh  # canonical method strings vs arc.exe
bash tests/stdio.sh tests/volumes.sh tests/sfx.sh tests/rs_recovery.sh tests/parc_crypt.sh
sudo bash tests/fixes.sh     # masks, symlinks, disk-full, FAT32
python3 tests/fuzz_update.py --iters 20 --seed 1   # randomized update fuzz vs arc.exe
```

## Status

- CLI: complete and heavily tested against FreeArc 0.67.1 (Linux, Windows 10 x64/x86 and
  Windows 7 x86).
- Bugs and codec gaps found in FreeArc 0.67 (and PArc's own) are tracked in
  `docs/BUGS-FREEARC.md`.
- A **GUI is planned** as a 1:1 clone of FreeArc's GUI (no GTK2); it has not been started yet.
- The detailed manuals are currently written in Spanish:
  [`docs/USO.md`](docs/USO.md) (CLI manual), [`docs/formato/`](docs/formato) (`.arc` and
  `.parc` format notes), [`docs/BUGS-FREEARC.md`](docs/BUGS-FREEARC.md),
  [`docs/LIBRERIAS.md`](docs/LIBRERIAS.md) (codec provenance and status),
  [`docs/ESTADO.md`](docs/ESTADO.md) (project status), [`docs/PLAN-GUI.md`](docs/PLAN-GUI.md).

## License

GNU General Public License v2.0; see [`LICENSE`](LICENSE).

FreeArc itself is by Bulat Ziganshin; its original source is included in this tree as the
reference for the format, the codecs and the compatibility tests.
