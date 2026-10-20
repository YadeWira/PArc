# PArc

PArc is a command-line archiver written in Free Pascal for **Windows 7+ (x86/x64)** and
**Linux x64**. It uses its own archive format, **`.parc`**, designed as a modernized descendant
of the FreeArc container: nanosecond timestamps, Windows attributes, Unix permissions,
symlinks, Reed–Solomon recovery, volumes and authenticated encryption.

> **PArc does not read or write FreeArc `.arc` files.** The `.arc` format is handled by the
> companion project [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex), a C++ support fork of
> FreeArc 0.67. PArc is the Pascal implementation of the `.parc` format.
>
> SFX **creation** was dropped (`-sfx` and the `parcsfx` module no longer exist). Existing
> self-extractors can still be listed, tested and extracted; updating one preserves its stub.

## Highlights

- **Own format**: `.parc` keeps names, sizes, CRCs and solid blocks from the FreeArc layout,
  and adds 64-bit nanosecond timestamps, Windows attributes and Unix modes/links as optional
  directory fields.
- **All codecs implemented in Pascal**, no third-party compression libraries linked:
  `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor` (Tornado), `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ x86), `lz4`, `dispack070` (DisPack) and `srep` (SREP), alone or in
  chains (`exe+dispack070+lzma`, `srep+lzma`, …).
- **Faster and smaller than FreeArc 0.67.1** at `-m1`…`-mx` on the test corpora (both
  compressed size and wall-clock time; see `docs/ESTADO.md`).
- **Reed–Solomon recovery record** (`-rr`): repairs a damaged range or scattered sectors,
  not just single sectors per group.
- **Volumes** (`-v`), **strong encryption** (`-p`/`-hp`: AES/Blowfish/Serpent/Twofish,
  authenticated, 200k PBKDF2 iterations), stdin/stdout (`-si`, `-so`, `-`).
- **Long paths** (`\\?\` on Windows), symlinks/junctions, masks and recursion.
- Cancellation leaves no partial files; writes go to a temporary file that replaces the
  original only on success.

## Commands

```
parc <command> <archive.parc> [files/patterns...] [options]
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
parc a backup.parc project/ -m5 -rr        # 5% recovery record
parc a photos.parc photos/ -mx -s-         # max compression, not solid
parc a secret.parc docs/ -p -hp            # encrypted (asks for the password)
parc u backup.parc project/                # update changed files
parc t backup.parc                         # verify
parc x backup.parc -dpout -o+              # extract, overwrite
parc r backup.parc                         # repair -> fixed.backup.parc
```

Exit codes: `0` OK, `1` usage error, `2` damaged data, `3` unsupported method/parameter,
`4` other I/O error, `5` missing/wrong password, `6` finished but some files were unreadable,
`130` cancelled.

## Build

Requires Free Pascal 3.2 or newer.

```sh
./build.sh linux64     # default; produces build/linux64/parc
./build.sh win64       # needs the Windows cross toolchain (FPC_CROSS)
./build.sh win32
./build.sh all
```

Tested on Linux x64, Windows 10 x64 and Windows 7 SP1 x64 (32- and 64-bit binaries).

## Testing

The suite runs against `.parc` archives and the C reference sources kept in
`reference/freearc-0.67/Compression/` for the codecs.

```sh
bash tests/cli.sh
bash tests/stdio.sh tests/volumes.sh
bash tests/rs_recovery.sh tests/parc_crypt.sh
bash tests/dispack.sh tests/srep.sh tests/bcj.sh
bash tests/run_tornado_tests.sh tests/crypto_vectors.sh
sudo bash tests/fixes.sh
python3 tests/fuzz.py build/linux64/parc 100 build/linux64/*.parc
```

To compare size and speed against FreeArc 0.67.1 (performance oracle only; `.arc` is not
read or written by PArc):

```sh
ARC_EXE=/path/to/Arc.exe bash tests/bench_vs_freearc.sh some-directory
```

## Repository layout

```
src/                     PArc sources (Free Pascal)
docs/                    manual and format specification (currently in Spanish)
tests/                   test suite, codec oracles and fuzzers
reference/freearc-0.67/  only Compression/: FreeArc 0.67 codec sources used as
                         reference and test oracle for the ported codecs
build.sh                 builds parc
```

The rest of the original FreeArc 0.67 tree (Haskell sources, Unarc, ArcShellExt, docs) is not
part of PArc; it lives in the FreeArc-ex repository and in PArc's git history (commit
`82ea8d9`).

## Related project

- [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex): extended support fork of FreeArc 0.67,
  in C++20, for `.arc` and the other container formats.

## License

GNU General Public License v2.0; see [`LICENSE`](LICENSE).

The codec implementations are ports of FreeArc 0.67 sources by Bulat Ziganshin and
contributors; `reference/` preserves the original notices.
