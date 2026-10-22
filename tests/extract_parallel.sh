#!/bin/bash
# tests/extract_parallel.sh — extracción paralela directa (un hilo por bloque, -s-):
#  - con poca memoria (ulimit -v) no puede fallar donde el camino serial no falla;
#  - si un bloque falla sin remedio, lo que queda en el disco está completo y se informó.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PARC=${PARC_BIN:-$ROOT/build/linux64/parc}
W=${XPAR_WORK:-${TMPDIR:-/tmp}/parc_xpar_test}
rm -rf -- "${W:?}"; mkdir -p "$W/mem" "$W/fat" && cd "$W" || exit 2
fail=0
ck() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=$((fail+1)); fi; }

# Memoria: 3 bloques de 160 MB (dispersos, casi todo ceros) con ventana de rep de 256 MB. Con
# 4 decodificadores a la vez no entra en 500 MB de espacio de direcciones; uno por vez sí
for i in 1 2 3; do
  truncate -s 160M mem/f$i.bin
  printf 'bloque %d' $i | dd of=mem/f$i.bin bs=1 seek=4096 conv=notrunc 2>/dev/null
done
(cd mem && "$PARC" a ../m.parc -s- -mrep:256mb+lzma:16m:fast f1.bin f2.bin f3.bin --no-progress >/dev/null 2>&1)
mkdir outm
( ulimit -v 500000; PARC_THREADS=4 "$PARC" x m.parc -dpoutm --no-progress > m.log 2>&1 ); rc=$?
ck "poca memoria: rc 0"        '[ $rc = 0 ]'
ck "poca memoria: archivos"    'cmp -s mem/f1.bin outm/f1.bin && cmp -s mem/f2.bin outm/f2.bin && cmp -s mem/f3.bin outm/f3.bin'
rm -rf -- outm mem

# Error fatal en un bloque (el destino de b es un directorio) mientras los demás terminan:
# ningún archivo a medias (0 bytes) y todo lo que quedó se informó
head -c 100000000 /dev/urandom > fat/a
for f in b c d; do head -c 1000000 /dev/urandom > fat/$f; done
(cd fat && "$PARC" a ../f.parc -s- -m1 a b c d --no-progress >/dev/null 2>&1)
mkdir -p outf/b
PARC_THREADS=4 "$PARC" x f.parc -o+ -dpoutf --no-progress > f.log 2>&1; rc=$?
ck "error fatal: rc 4"         '[ $rc = 4 ]'
ok=1
for f in a c d; do
  if [ -e outf/$f ]; then
    cmp -s fat/$f outf/$f || ok=0
    grep -q "^Extracted $f\$" f.log || ok=0
  fi
done
ck "error fatal: lo que queda está completo e informado" '[ $ok = 1 ]'

# Nombres que solo difieren en mayúsculas, en bloques distintos, sobre vfat (no las distingue):
# como en el camino serial, rc 0 y el resultado no depende del orden entre hilos. Hace falta
# montar un volumen, así que solo con sudo sin contraseña
if [ -x /sbin/mkfs.fat ] && sudo -n true 2>/dev/null; then
  mkdir -p cs/in cs/mnt
  head -c 3000000 /dev/urandom > cs/in/README; head -c 1500000 /dev/urandom > cs/in/readme
  (cd cs/in && "$PARC" a ../../c.parc -s- -m1 README readme --no-progress >/dev/null 2>&1)
  truncate -s 32M cs.img && /sbin/mkfs.fat cs.img >/dev/null
  sudo -n mount -o loop,uid="$(id -u)",gid="$(id -g)" cs.img cs/mnt
  okk=1; oko=1
  for r in 1 2 3 4 5 6; do
    rm -rf cs/mnt/k cs/mnt/o
    PARC_THREADS=4 "$PARC" x c.parc -o- -dpcs/mnt/k --no-progress >/dev/null 2>&1 || okk=0
    cmp -s cs/in/README cs/mnt/k/README || okk=0
    PARC_THREADS=4 "$PARC" x c.parc -o+ -dpcs/mnt/o --no-progress >/dev/null 2>&1 || oko=0
    cmp -s cs/in/readme cs/mnt/o/README || oko=0
  done
  sudo -n umount cs/mnt; rm -f cs.img
  ck "vfat, README/readme con -o-: rc 0, queda el primero" '[ $okk = 1 ]'
  ck "vfat, README/readme con -o+: rc 0, queda el último"  '[ $oko = 1 ]'
fi

cd / && rm -rf -- "${W:?}"
echo "== extract_parallel: $fail failures"
[ $fail -eq 0 ]
