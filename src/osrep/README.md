# OSREP embeddable -m6 API

`src/pascal/osrep_m6.pas` is OSREP's long-range method (`-m6`) memory to
memory: `OsrepM6Encode` writes a standard `.osr` v7 stream (the `osrep` CLI
decodes it, and this unit decodes the CLI's), `OsrepM6Decode` writes the
original in place into a buffer of its exact size. See the unit's header
and `TOsrepM6Params`.

Build: put `src/pascal` on the unit path (`-Fu`) and the object directory
of the target on the object path (`-Fo`, the units link `osrep_lr.o`,
`osrep_match.o`, `osrep_vhash_nh.o` and `osrep_crc_native.o` with `{$L}`).
`obj/<target>/` has them for linux-x86_64, linux-x86, linux-arm64, win64
and win32; for another target compile `src/c/*.c` with
`-O3 -fno-builtin -fno-stack-protector` (they call nothing from libc).
With `-dOSREP_NO_NATIVE` the units are all Pascal and need no object: the
streams are byte for byte the same, slower.

Memory: `OsrepM6EncMem` and `OsrepM6DecMem` (besides the input and output
buffers). Threads: the search runs on the calling thread and starts none.
License: MIT (`LICENSE`).
