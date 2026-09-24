#!/bin/bash
# Valida parc_crypt contra los archivos cifrados reales de arc.exe 0.67.1.
#   - descifra cada payload y lo compara con el original
#   - prueba password incorrecta (debe dar error claro, exit 4)
#   - prueba password UTF-8
#   - para -hp, comprueba que la derivación con el footer en claro es correcta
set -u
D=/mnt/IA_LAB/agentes/PA-Lab/crypt-port
R=/mnt/IA_LAB/agentes/PA-Lab/ref-clean
export WINEPREFIX=/mnt/IA_LAB/agentes/PA-Lab/wine WINEDEBUG=-all
TEST=$D/testcrypt
A=$D/arcs
ok=0; mal=0; fallas=""

blk() {  # offset y tamaño comprimido del bloque de DATOS (mayor Size; la fila arranca con '*')
  wine "$R/Arc.exe" lt "$1" 2>/dev/null | sed -n '/Pos/,$p' | \
    awk '/^[* ]*[0-9]+ +[0-9]/ {p=$2; sz=$3; c=$4; gsub(/,/,"",p); gsub(/,/,"",sz); gsub(/,/,"",c);
         if (sz+0>max){max=sz+0; po=p; co=c}} END {print po, co}'
}
# ojo: el método del manifiesto puede traer el CR del `lt` y espacios de más
metodo_de() { grep -a "^metodo" "$A/$1.txt" | sed 's/^metodo *: *//' | tr -d '\r' | sed 's/ *$//'; }
pwd_de()    { grep -a "^password" "$A/$1.txt" | sed 's/^password *: *//' | tr -d '\r' | sed 's/ *$//'; }

probar() { # $1=caso  $2=password a usar
  local caso=$1 pwd=$2 arc=$A/$1.arc
  local m; m=$(metodo_de "$caso")
  local etapa=${m#*+}                       # la etapa de cifrado (lo que sigue al '+')
  if [ "$m" = "$etapa" ]; then etapa=$m; fi
  set -- $(blk "$arc")
  local off=$1 sz=$2
  local out rc
  out=$($TEST "$arc" "$off" "$sz" "$A/files/f.txt" "$etapa" "$pwd" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    ok=$((ok+1)); printf '  %-22s %-28s OK\n' "$caso" "$etapa"
  else
    mal=$((mal+1)); fallas="$fallas $caso"
    printf '  %-22s %-28s FALLA(rc=%s): %s\n' "$caso" "$etapa" "$rc" "$(echo "$out" | tail -1)"
  fi
}

echo "== descifrado con la password correcta =="
for c in p_aes-128 p_aes-192 p_aes-256 p_aes-256_cfb p_blowfish p_serpent p_twofish; do
  [ -f "$A/$c.arc" ] || continue
  probar "$c" "$(pwd_de "$c")"
done

echo "== password incorrecta (debe decir 'PASSWORD INCORRECTA', exit 4) =="
for c in p_aes-256 p_aes-256_cfb; do
  m=$(metodo_de "$c"); etapa=${m#*+}
  set -- $(blk "$A/$c.arc")
  out=$($TEST "$A/$c.arc" "$1" "$2" "$A/files/f.txt" "$etapa" "password_mala" 2>&1); rc=$?
  if [ $rc -eq 4 ]; then ok=$((ok+1)); printf '  %-22s exit 4 (correcto)\n' "$c"
  else mal=$((mal+1)); fallas="$fallas $c-mala"; printf '  %-22s ERROR: rc=%s %s\n' "$c" "$rc" "$out"; fi
done

echo "== password UTF-8 =="
probar utf8_aes "$(pwd_de utf8_aes)"

echo "== -hp: la derivación desde el footer en claro =="
for c in hp_aes hp_serpent; do
  # el footer (en claro) lleva la etapa de cifrado con :s :c :i
  m=$(grep -aoE "(aes|serpent|blowfish|twofish)-[0-9]+/(ctr|cfb):n[0-9]+:r[0-9]+:s[0-9a-f]+:c[0-9a-f]+:i[0-9a-f]+" "$A/$c.arc" | head -1)
  if [ -z "$m" ]; then mal=$((mal+1)); fallas="$fallas $c"; printf '  %-22s no encontré la etapa en el footer\n' "$c"; continue; fi
  out=$($TEST "$A/$c.arc" 0 0 "$A/files/f.txt" "$m" "$(pwd_de "$c")" 2>&1); rc=$?
  if [ $rc -eq 4 ]; then mal=$((mal+1)); fallas="$fallas $c"
  else ok=$((ok+1)); printf '  %-22s derivación OK con el footer (%s)\n' "$c" "$(echo "$m" | cut -c1-30)"
  fi
done

echo
echo "===== parc_crypt: $ok OK / $mal FALLAS ====="
[ -n "$fallas" ] && echo "fallas:$fallas"
[ $mal -eq 0 ]
