#!/bin/bash
# tests/compat_matrix.sh — matriz de compatibilidad de PArc contra FreeArc 0.67.1
#
# Qué hace:
#   (a) genera un corpus variado de forma determinista (texto grande, un .exe,
#       imágenes, audio PCM, ya comprimidos, muchos archivos chicos, un archivo
#       configurable >200MB, nombres raros, un directorio vacío y un archivo de
#       0 bytes) y crea UN .arc por método con arc.exe 0.67.1 (vía wine);
#   (b) verifica con `wine arc.exe t` (AUTORIDAD), `unarc.i386 t` (referencia) y
#       `parc t`; y extrae con `parc x`, `wine arc.exe x` y `unarc.i386 x`,
#       comparando por sha256 contra el corpus;
#   (c) imprime una tabla método × resultado + tiempos de parc vs unarc.
#
#   Un método que parc todavía no soporta se reporta como "no-soportado" en su
#   propia columna y NO cuenta como fallo.
#
# Uso:
#   tests/compat_matrix.sh [--quick] [--sin-grande] [--solo m1,m5,ppmd] [--keep]
#
#   --quick        corpus chico (no hace falta para nada, sólo acelera)
#   --sin-grande   omite el archivo >200MB (la matriz corre mucho más rápido)
#   --solo LISTA   sólo esos métodos (claves de la lista de abajo)
#   --keep         no borra los .arc ni las extracciones al terminar
#
# Variables de entorno (con defaults de este entorno):
#   PARC_ROOT   raíz del repo PArc            (default: directorio padre de tests/)
#   PARC_BIN    binario a probar              (default: $PARC_ROOT/build/linux64/parc)
#   ARC_EXE     arc.exe 0.67.1                (default: ref-clean de PA-Lab)
#   WINEPREFIX  prefix de wine                (default: el de PA-Lab)
#   UNARC       oráculo i386 de referencia    (default: bin/unarc.i386 de PA-Lab)
#   BIG_MB      tamaño del archivo grande     (default: 210)
#   WORK        directorio de trabajo         (default: /mnt/IA_LAB/agentes/PA-Lab/compat)
set -u

QUICK=0; SINGRANDE=0; KEEP=0; SOLO=""
while [ $# -gt 0 ]; do
  case $1 in
    --quick) QUICK=1 ;;
    --sin-grande) SINGRANDE=1 ;;
    --keep) KEEP=1 ;;
    --solo) shift; SOLO=$1 ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac; shift
done

PARC_ROOT=${PARC_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
PARC_BIN=${PARC_BIN:-$PARC_ROOT/build/linux64/parc}
ARC_EXE=${ARC_EXE:-/mnt/IA_LAB/agentes/PA-Lab/ref-clean/Arc.exe}
export WINEPREFIX=${WINEPREFIX:-/mnt/IA_LAB/agentes/PA-Lab/wine}
export WINEDEBUG=-all
UNARC=${UNARC:-/mnt/IA_LAB/agentes/PA-Lab/bin/unarc.i386}
BIG_MB=${BIG_MB:-210}
WORK=${WORK:-/mnt/IA_LAB/agentes/PA-Lab/compat}

CORPUS=$WORK/corpus
ARCS=$WORK/arcs
XPARC=$WORK/x_parc
XARC=$WORK/x_arc
XUNARC=$WORK/x_unarc

# clave:spec  — -m0..-m9/-mx son perfiles; el resto, métodos sueltos
METODOS=(
  "m0:-m0" "m1:-m1" "m2:-m2" "m3:-m3" "m4:-m4" "m5:-m5" "m6:-m6" "m7:-m7"
  "m8:-m8" "m9:-m9" "mx:-mx"
  "lzma:-mlzma" "exe_lzma:-mexe+lzma" "delta:-mdelta" "delta_lzma:-mdelta+lzma"
  "rep:-mrep" "rep_lzma:-mrep+lzma" "tor:-mtor" "lz4:-mlz4" "4x4_lzma:-m4x4:lzma"
  "ppmd:-mppmd" "dict_ppmd:-mdict+ppmd" "lzp_ppmd:-mlzp+ppmd" "grzip:-mgrzip"
  # opciones de multimedia (eligen método según el archivo: $wav->tta, $bmp->mm+...)
  "mm_plus:-mm+" "mmfast:-mmfast" "mm_minus:-mm-"
)

[ -x "$PARC_BIN" ] || { echo "no encuentro parc en $PARC_BIN (compilalo; este script no lo toca)" >&2; exit 2; }
[ -f "$ARC_EXE" ]  || { echo "no encuentro arc.exe en $ARC_EXE" >&2; exit 2; }

mkdir -p "$WORK"

# ---------------------------------------------------------------- (a) corpus
if [ ! -d "$CORPUS" ]; then
  echo "== generando corpus en $CORPUS (grande = ${BIG_MB}MB, quick=$QUICK) =="
  BIGMB_ARG=$BIG_MB; [ $SINGRANDE = 1 ] && BIGMB_ARG=0; [ $QUICK = 1 ] && BIGMB_ARG=$((BIG_MB/10))
  rm -rf "$CORPUS"    # si el generador falla a la mitad, no correr con corpus parcial
  if python3 - "$CORPUS" "$BIGMB_ARG" "$ARC_EXE" <<'PY'
import gzip, io, os, random, shutil, struct, sys, zlib, wave, math
dst, bigmb, arcexe = sys.argv[1], int(sys.argv[2]), sys.argv[3]
os.makedirs(dst, exist_ok=True)
W = "archivo compresion formato bloque cabecera metodo referencia oracle unarc freearc pascal".split()

def w(rel, data):
    p = os.path.join(dst, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb' if isinstance(data,(bytes,bytearray)) else 'w').write(data)

def rnd(n, seed):
    r = random.Random(seed); return bytes(r.getrandbits(8) for _ in range(n))

# texto grande y redundante
r = random.Random(11); out = []
for i in range(20000):
    out.append("linea %07d: %s" % (i, " ".join(r.choice(W) for _ in range(14))))
    if i % 23 == 0: out.append("BLOQUE-REPETIDO " * 30)
w("texto_grande/notas.txt", "\n".join(out) + "\n")

# ejecutables / binarios reales si están
for cand, rel in ((arcexe, "exe/arc067.exe"),
                  ("/mnt/IA_LAB/agentes/PA-Lab/bin/unarc.i386", "exe/unarc32.elf")):
    if os.path.exists(cand):
        d = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copyfile(cand, d)

# imágenes: PNG con degradé + JPEG (si hay PIL)
def png(wp, hp):
    rows = b""
    for y in range(hp):
        row = bytearray([0])
        for x in range(wp): row += bytes(((x*255)//wp, (y*255)//hp, ((x+y)*255)//(wp+hp)))
        rows += bytes(row)
    def ch(t, d):
        c = t + d; return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", wp, hp, 8, 2, 0, 0, 0))
            + ch(b"IDAT", zlib.compress(rows, 6)) + ch(b"IEND", b""))
w("imagenes/grafico.png", png(400, 300))
try:
    from PIL import Image
    img = Image.new("RGB", (320, 240))
    px = img.load()
    for y in range(240):
        for x in range(320): px[x, y] = ((x*7) % 256, (y*5) % 256, ((x ^ y)*3) % 256)
    b = io.BytesIO(); img.save(b, "JPEG", quality=88); w("imagenes/foto.jpg", b.getvalue())
except ImportError:
    w("imagenes/foto.jpg", rnd(20000, 5))

# audio PCM (WAV) -> onda senoidal con ruido
sr, dur = 22050, 6
os.makedirs(os.path.join(dst, "audio"), exist_ok=True)
wf = wave.open(os.path.join(dst, "audio/tono.wav"), 'wb')
wf.setnchannels(1); wf.setsampwidth(2); wf.setframerate(sr)
r = random.Random(3)
frames = bytearray()
for i in range(sr*dur):
    v = int(12000*math.sin(2*math.pi*440*i/sr) + r.randrange(-300, 300))
    v = max(-32768, min(32767, v)); frames += struct.pack("<h", v)
wf.writeframes(bytes(frames)); wf.close()

# ya comprimidos
w("comprimidos/notas.txt.gz", gzip.compress(open(os.path.join(dst,"texto_grande/notas.txt"),"rb").read(), 9))
w("comprimidos/ruido.z", zlib.compress(rnd(400000, 7), 9))
if os.path.exists(os.path.join(dst, "imagenes/foto.jpg")):
    w("comprimidos/foto2.jpg", open(os.path.join(dst, "imagenes/foto.jpg"), "rb").read())

# muchos archivos chicos (mezcla texto/binario)
for i in range(300):
    if i % 3 == 0: w("chicos/f%04d.dat" % i, "registro %04d %s\n" % (i, " ".join(W[i % len(W):] + W[:i % len(W)])))
    else:          w("chicos/f%04d.dat" % i, rnd(1024, 1000+i))

# un archivo grande (>200MB por default): patrón repetido + zonas de ruido
if bigmb > 0:
    os.makedirs(os.path.join(dst, "grande"), exist_ok=True)
    n = bigmb * 1024 * 1024
    r = random.Random(42); base = bytes(r.getrandbits(8) for _ in range(65536))
    with open(os.path.join(dst, "grande/grande.bin"), 'wb') as f:
        hecho = 0
        while hecho < n:
            trozo = base if (hecho // (16*1024*1024)) % 4 != 3 else rnd(1024*1024, hecho)
            f.write(trozo); hecho += len(trozo)

# nombres raros
w("raros/con espacios y 'comillas'.txt", "nombres raros\n")
w("raros/acentos_ñ_日本語.txt", "áéíóú ü ñ ç ¿¡ 日本語 テスト\n")
w("raros/tilde_áéíóú_ÿΩ.md", "# diacríticos\n")
w("raros/" + "muy_largo_" * 20 + ".txt", "nombre de 200 caracteres\n")
w("raros/emoji_😀_bin.bin", rnd(5000, 9))

# multimedia: es lo que ejercita los grupos $wav (tta) y $bmp (mm+...) y las
# opciones -mm+ / -mmfast / -mm-  (WAV 8/16/24 bits, mono/estéreo, 44.1/48k,
# un WAV con cabecera "extensible", y BMP 8/24/32)
def wavgen(rel, bits, chans, rate, secs=2, extensible=False):
    import wave as _w, struct as _s, math as _m
    p = os.path.join(dst, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    r = random.Random(hash(rel) & 0xffff)
    frames = bytearray()
    for i in range(int(rate * secs)):
        v = int(9000 * _m.sin(2 * _m.pi * 300 * i / rate))
        for c in range(chans):
            vv = max(-(1 << (bits - 1)), min((1 << (bits - 1)) - 1, v + r.randrange(-40, 40) + c * 100))
            if bits == 8:   frames += _s.pack('<B', vv + 128)
            elif bits == 16: frames += _s.pack('<h', vv)
            else:            frames += _s.pack('<i', vv)[0:3]
    data = bytes(frames)
    if extensible:
        # WAVE_FORMAT_EXTENSIBLE (0xFFFE) con subformato PCM y cbSize
        bw = bits // 8
        fmt = _s.pack('<HHIIHH', 0xFFFE, chans, rate, rate * chans * bw, chans * bw, bits)
        fmt += _s.pack('<HHI', 22, bits, 0) + _s.pack('<H', 1) + b'\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71'
        chunks = b'fmt ' + _s.pack('<I', len(fmt)) + fmt + b'data' + _s.pack('<I', len(data)) + data
        open(p, 'wb').write(b'RIFF' + _s.pack('<I', 4 + len(chunks)) + b'WAVE' + chunks)
    else:
        ww = _w.open(p, 'wb'); ww.setnchannels(chans); ww.setsampwidth(bw_ := bits // 8)
        ww.setframerate(rate); ww.writeframes(data); ww.close()

def bmpgen(rel, bits, wp, hp):
    import struct as _s
    p = os.path.join(dst, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    row = (wp * bits + 31) // 32 * 4; size = row * hp
    hdr = b'BM' + _s.pack('<IHHI', 14 + 40 + (1024 if bits == 8 else 0), 0, 0,
                          14 + 40 + (1024 if bits == 8 else 0))
    info = _s.pack('<IiiHHIIiiII', 40, wp, hp, 1, bits, 0, size, 2835, 2835,
                   (256 if bits == 8 else 0), 0)
    data = bytearray()
    for y in range(hp):
        line = bytearray()
        for x in range(wp):
            if bits == 8:    line += _s.pack('<B', (x + y) & 0xff)
            elif bits == 24: line += _s.pack('<BBB', (x*3) & 0xff, (y*5) & 0xff, ((x+y)*7) & 0xff)
            else:            line += _s.pack('<BBBB', (x*3) & 0xff, (y*5) & 0xff, ((x+y)*7) & 0xff, 0x80)
        line += bytes(row - len(line)); data += line
    open(p, 'wb').write(hdr + info + bytes(data))

for bits in (8, 16, 24):
    for chans in (1, 2):
        for rate in (44100, 48000):
            wavgen("multimedia/w%d_%dch_%d.wav" % (bits, chans, rate), bits, chans, rate)
wavgen("multimedia/w16_extensible.wav", 16, 2, 44100, 1, extensible=True)
for bits in (8, 24, 32):
    bmpgen("multimedia/b%d.bmp" % bits, bits, 120, 80)

# archivo vacío y directorio vacío
w("varios/vacio.bin", b"")
os.makedirs(os.path.join(dst, "dir_vacio"), exist_ok=True)
tot = sum(os.path.getsize(os.path.join(dp,f)) for dp,_,fs in os.walk(dst) for f in fs)
print("  corpus: %d archivos, %.1f MB" % (sum(len(fs) for _,_,fs in os.walk(dst)), tot/1048576.0))
PY
  then :; else echo "FALLO la generación del corpus" >&2; rm -rf "$CORPUS"; exit 2; fi
else
  echo "== corpus ya existe en $CORPUS (usá otro WORK o borralo para regenerar) =="
fi

# ojo: -print0/xargs -0 para que no rompan los nombres con espacios o comillas
hash_corpus() { ( cd "$1" && find . -type f -print0 | sort -z | xargs -0 -r sha256sum ); }

# El archivo se crea con `arc a ... arc corpus` desde $WORK, así que las rutas
# guardadas son "corpus/..." y la extracción recrea ESE subdirectorio.
extraido() { [ -d "$1/corpus" ] && echo "$1/corpus" || echo "$1"; }

# ------------------------------------------------------- (b)(c) matriz
mkdir -p "$ARCS"
printf '\n%-11s %-11s %-13s %-12s %-14s %-16s %s\n' metodo "arc.exe t" "unarc.i386 t" "parc t" "parc x" "tiempos p/u" notas
printf '%s\n' "----------------------------------------------------------------------------------------------------"
n_ok=0; n_nosop=0; n_falla=0; n_reffalla=0; FALLAS=""

for entrada in "${METODOS[@]}"; do
  clave=${entrada%%:*}; spec=${entrada#*:}
  if [ -n "$SOLO" ]; then case ",$SOLO," in *",$clave,"*) ;; *) continue ;; esac; fi
  arc=$ARCS/$clave.arc
  rm -f "$arc"

  # crear con arc.exe (autoridad)
  if ! ( cd "$WORK" && wine "$ARC_EXE" a -cfg- "$spec" "$arc" corpus ) >/tmp/cm_create.out 2>&1; then
    printf '%-11s %-11s\n' "$clave" "CREACION FALLO"; n_falla=$((n_falla+1)); FALLAS="$FALLAS $clave(creacion)"; continue
  fi

  # arc.exe t (autoridad) — si esto no da OK, el archivo está mal y no se sigue
  if wine "$ARC_EXE" t "$arc" 2>&1 | grep -q "All OK"; then a_ok=OK; else a_ok=FALLA; fi

  # unarc.i386 t (referencia) + tiempo.  Se guarda su salida completa: si falla
  # (p.ej. el 4x4 grande que revienta el heap de 32 bits multihilo) hay que poder
  # ver POR QUÉ, no sólo que falló.
  mkdir -p "$WORK/logs"
  t0=$(date +%s%N)
  u_out=$("$UNARC" t "$arc" 2>&1); u_rc=$?
  t1=$(date +%s%N)
  u_ms=$(( (t1-t0)/1000000 ))
  printf '%s\n' "$u_out" > "$WORK/logs/unarc-$clave.log"
  [ $u_rc -eq 0 ] && u_res=OK || u_res=FALLA

  # parc t + tiempo
  t2=$(date +%s%N)
  p_out=$("$PARC_BIN" t "$arc" 2>&1); p_rc=$?
  t3=$(date +%s%N)
  p_ms=$(( (t3-t2)/1000000 ))
  if [ $p_rc -eq 0 ]; then p_res=OK
  elif echo "$p_out" | grep -qi "no soportado"; then p_res=no-soportado
  else p_res=FALLA; fi

  # parc x + comparación con el corpus
  xres="-"; notas=""
  if [ "$p_res" = "OK" ]; then
    rm -rf "$XPARC"; mkdir -p "$XPARC"
    if "$PARC_BIN" x -o+ -dp"$XPARC" "$arc" >/tmp/cm_x.out 2>&1; then
      hash_corpus "$CORPUS" > /tmp/cm_a.sha; hash_corpus "$(extraido "$XPARC")" > /tmp/cm_b.sha
      if cmp -s /tmp/cm_a.sha /tmp/cm_b.sha; then xres="OK"; else xres="DIFIERE"
        diff <(cut -c1-16 /tmp/cm_a.sha) <(cut -c1-16 /tmp/cm_b.sha) | head -3 > /tmp/cm_d; notas="$notas diferencias:$(tr '\n' ' ' < /tmp/cm_d)"
      fi
    else xres="x fallo"; fi
  fi

  # extracción de la autoridad, para comparar.  Se saltea si parc no soporta el
  # método: `arc.exe t` ya probó que el archivo es válido y extraer 200MB al
  # pedo es carísimo.
  if [ "$xres" != "OK" ] && [ "$p_res" != "no-soportado" ]; then
    rm -rf "$XARC"; mkdir -p "$XARC"
    if ( cd "$XARC" && wine "$ARC_EXE" x -o+ "$arc" ) >/dev/null 2>&1; then
      hash_corpus "$CORPUS" > /tmp/cm_a.sha; hash_corpus "$(extraido "$XARC")" > /tmp/cm_b.sha
      cmp -s /tmp/cm_a.sha /tmp/cm_b.sha && notas="$notas arc.exe-x=OK" || notas="$notas arc.exe-x=DIFIERE"
    else notas="$notas arc.exe-x=no-corrio"; fi
  fi

  # Clasificación.  El criterio REAL es: parc t OK y parc x reproduce el corpus
  # byte a byte (y el archivo lo dio por bueno la autoridad).  El resultado de
  # unarc.i386 es INFORMATIVO: hay casos conocidos (lz4) donde el decoder C++ de
  # este árbol está roto y parc sí acierta — eso NO es un fallo de PArc.
  if [ "$p_res" = "no-soportado" ]; then
    n_nosop=$((n_nosop+1)); estado="no-soportado"
  elif [ "$p_res" = OK ] && [ "$xres" = OK ] && [ "$a_ok" = OK ]; then
    n_ok=$((n_ok+1)); estado=""
    if [ "$u_res" = FALLA ]; then
      n_reffalla=$((n_reffalla+1))
      # la nota nombra el MÉTODO real (la causa no es siempre lz4) y apunta al log
      if [ "$clave" = "lz4" ]; then
        notas="$notas ref-C++-falla(metodo=$clave; lz4.c de este arbol) log=$WORK/logs/unarc-$clave.log"
      else
        notas="$notas ref-C++-falla(metodo=$clave) log=$WORK/logs/unarc-$clave.log"
      fi
    fi
  else
    n_falla=$((n_falla+1)); estado="<-- FALLA"; FALLAS="$FALLAS $clave"
  fi
  printf '%-11s %-11s %-13s %-12s %-14s %5d/%-5d ms  %s %s\n' \
    "$clave" "$a_ok" "$u_res" "$p_res" "$xres" "$p_ms" "$u_ms" "$notas" "$estado"
done

echo
echo "===== RESUMEN: $n_ok OK · $n_nosop no-soportados · $n_falla fallas · $n_reffalla OK-con-referencia-C++-caida (esperado en lz4) ====="
[ -n "$FALLAS" ] && echo "fallas:$FALLAS"
echo "(los métodos del README que PArc todavía no portó se cuentan aparte, no como fallo)"

if [ $KEEP = 0 ]; then
  rm -rf "$XPARC" "$XARC"
  echo "arcs y corpus quedan en $WORK (--keep no cambia nada más; borralos si no los querés)"
fi
[ $n_falla -eq 0 ]
