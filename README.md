# PArc

PArc is a command-line archiver written in Free Pascal for **Windows 7+ (x86/x64)**,
**Linux (x86, x64, arm64)** and **macOS (arm64)**. It uses its own archive format, **`.parc`**, designed as a modernized descendant
of the FreeArc container: nanosecond timestamps, Windows attributes, Unix permissions,
symlinks, Reed–Solomon recovery, volumes and authenticated encryption.

> **PArc does not read or write FreeArc `.arc` files.** The `.arc` format is handled by the
> companion project [FreeArc-ex](https://github.com/YadeWira/FreeArc-ex), a C++ support fork of
> FreeArc 0.67. PArc is the Pascal implementation of the `.parc` format.
>
> SFX **creation** was dropped (`-sfx` and the `parcsfx` module no longer exist). Existing
> self-extractors can still be listed, tested and extracted; updating one preserves its stub.

Documentation: [manual](docs/USO.md) · [format](docs/formato/FORMATO-PARC.md) ·
[status](docs/ESTADO.md) · [**wiki**](https://github.com/YadeWira/PArc/wiki).

| Component | Status |
|---|---|
| Latest release | [![Release][relBadge]][relLink] (pre-releases until 1.0.0; no format compatibility promised before then) |
| CI | [![CI][ciBadge]][ciLink] [![macOS][macBadge]][macLink] Linux x64, Linux arm64 and macOS arm64: build and round trip at every level with 1 and 4 threads |
| vs FreeArc 0.67.1 | smaller and faster at `-m1`…`-m9` on TILIN.tar with 1 thread; with 4 threads too, except a tie in `-m5` compression ([details](docs/ESTADO.md)) |
| License | GPL-2.0 (moving to MIT: the FreeArc-derived code is being rewritten) |

## Platforms

| OS | Architectures | State |
|---|---|---|
| Windows (7 and later) | x86-64, x86 | release binaries (no extra DLLs); cross-built with MinGW, tested under Wine (and by users on Windows) |
| Linux | x86-64 | release binary; built and tested in CI and on the host (full test battery) |
| Linux | x86 (32-bit) | release binary; cross-built, tested on the host; archives byte-identical to x86-64 |
| Linux | arm64 | release binary; built and tested in CI; archives byte-identical to x86-64 |
| macOS | arm64 (Apple silicon) | release binary (from CI); built and tested in CI |

x86-64 uses assembler hot paths; the other architectures run the portable Pascal code, which
writes the same bytes.

[relBadge]: https://img.shields.io/github/v/release/YadeWira/PArc?include_prereleases "Latest release"
[relLink]: https://github.com/YadeWira/PArc/releases
[ciBadge]: https://github.com/YadeWira/PArc/actions/workflows/ci.yml/badge.svg "Continuous Integration"
[ciLink]: https://github.com/YadeWira/PArc/actions/workflows/ci.yml
[macBadge]: https://github.com/YadeWira/PArc/actions/workflows/macos.yml/badge.svg "macOS"
[macLink]: https://github.com/YadeWira/PArc/actions/workflows/macos.yml

## Highlights

- **Own format**: `.parc` keeps names, sizes, CRCs and solid blocks from the FreeArc layout,
  and adds 64-bit nanosecond timestamps, Windows attributes and Unix modes/links as optional
  directory fields.
- **Codecs implemented in Pascal** (hot loops in inline assembler), no third-party compression
  libraries linked; the only C/C++ is FreeArc's own Tornado encoder, used for `tor:10` and
  `tor:15` where it measured faster (`src/parc_torglue.cpp`):
  `storing`, `lzma`, `ppmd`, `grzip`, `dict`, `rep`, `delta`, `tor` (Tornado), `lzp`, `mm`,
  `tta`, `4x4`, `exe` (BCJ x86), `lz4`, `dispack070` (DisPack), `srep` (SREP) and `cm` (context mixing), alone or in
  chains (`exe+dispack070+lzma`, `srep+lzma`, …).
- **Smaller and faster than FreeArc 0.67.1** at `-m1`…`-m9` on the test corpora. `-mx` gives
  the smallest archives that still decompress fast; `-mxx` adds context mixing (`cm`) for the
  absolute smallest archives, at the cost of decompression speed (see `docs/ESTADO.md`).
- **Reed–Solomon recovery record** (`-rr`): repairs a damaged range or scattered sectors,
  not just single sectors per group.
- **Volumes** (`-v`), **authenticated encryption** (`-p`/`-hp`: XChaCha20-Poly1305 or
  AES-256-GCM in 64 KiB chunks, Argon2id key derivation), stdin/stdout (`-si`, `-so`, `-`).
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
| `v` / `lt` | verbose / technical listing |
| `create` | like `a`, but always a new archive |
| `m` / `mf` | move into the archive (delete from disk afterwards) |
| `ch` | rewrite with new options (method, password, recovery record, lock, comment) |
| `rr<spec>` | add a recovery record |
| `c` / `cw` | set / write the archive comment |
| `j` | join other archives into the first |
| `k` | lock the archive |

```sh
parc a backup.parc project/ -m5 -rr        # 5% recovery record
parc a photos.parc photos/ -mx -s-         # max ratio, fast decode, not solid
parc a photos.parc photos/ -mxx -s-        # absolute max ratio (CM), slow decode
parc a secret.parc docs/ -p -hp            # encrypted (asks for the password)
parc u backup.parc project/                # update changed files
parc t backup.parc                         # verify
parc x backup.parc -dpout -o+              # extract, overwrite
parc r backup.parc                         # repair -> fixed.backup.parc
```

Exit codes: `0` OK, `1` usage error, `2` damaged data, `3` unsupported method/parameter,
`4` other I/O error, `5` missing/wrong password, `6` finished but some files were unreadable,
`7` a block needs more memory than `-ld` allows, `130` cancelled.

Most FreeArc 0.67 options work the same way: `-x`/`-n` and `@listfile`, size and time filters
(`-sm`, `-sl`, `-ta`, `-tb`, `-tn`, `-to`), `-ep`/`-ep1`/`-ap`, `-t`/`-tp`, `-y`, `-ag`, `--sync`,
`-w`, `-mt`, `-lc`/`-ld`, `-mc-<alg>`, `-kb`, `-kf`, `--print-config`… (see the
[manual](docs/USO.md)).

## Build

Requires Free Pascal 3.2 or newer, `g++` (linux64) and the MinGW-w64 `g++`
(`x86_64-w64-mingw32-g++`, `i686-w64-mingw32-g++`) for the Windows targets: `build.sh` compiles
FreeArc's Tornado encoder (`reference/freearc-0.67/Compression/Tornado`, patched with
`src/parc_torglue.patch`) and links it statically (no extra DLLs: the `.exe` imports the same
system DLLs as before, kernel32/user32/shell32/oleaut32/msvcrt).

```sh
./build.sh linux64     # default; produces build/linux64/parc
./build.sh linux32     # Linux x86: g++ -m32 and the FPC i386 cross compiler (FPC_CROSS)
./build.sh linuxarm64  # native on arm64, or with aarch64-linux-gnu-g++ and the FPC cross compiler
./build.sh macos       # on a Mac: clang++ (Xcode) and Homebrew fpc
./build.sh win64       # needs the Windows cross toolchain (FPC_CROSS)
./build.sh win32
./build.sh all         # every target except macos
```

Tested on Linux x64 (full battery), Linux x86 and arm64 (round trips), macOS arm64 (CI), and Windows x64/x86 (Wine; Windows 10 and 7 VMs for earlier releases).

## Testing

The suite runs against `.parc` archives and the C reference sources kept in
`reference/freearc-0.67/Compression/` for the codecs.

```sh
bash tests/cli.sh tests/cli_options.sh tests/cli_commands.sh
bash tests/stdio.sh tests/volumes.sh
bash tests/rs_recovery.sh tests/parc_crypt.sh tests/cm.sh
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
docs/                    manual and format specification
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
