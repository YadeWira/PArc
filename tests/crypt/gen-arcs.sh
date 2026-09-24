#!/bin/bash
# Genera el set de archivos cifrados con arc.exe 0.67.1 para especificar el
# formato y para probar el descifrado.
#
#   ../crypt-port/arcs/<caso>.arc      el archivo
#   ../crypt-port/arcs/<caso>.txt      el caso: password, comando, método real
#   ../crypt-port/arcs/files/f.txt     la entrada (200 KB de texto)
set -u
D=/mnt/IA_LAB/agentes/PA-Lab/crypt-port
R=/mnt/IA_LAB/agentes/PA-Lab/ref-clean
export WINEPREFIX=/mnt/IA_LAB/agentes/PA-Lab/wine WINEDEBUG=-all
A=$D/arcs; rm -rf $A; mkdir -p $A/files
head -c 200000 /mnt/IA_LAB/compartido/parc/samples/src/texto/notas.txt > $A/files/f.txt

# ojo: un archivo cifrado tiene DOS bloques (el de los dirs, Size=0, y el de los
# datos) y CADA UNO lleva su propio IV/salt/check-code.  Se toma el de mayor Size,
# que es el de los datos.  Para que la cripto se pueda probar sola se crea con -m0
# (storing), así el payload es el archivo cifrado tal cual.
metodo() {
  wine "$R/Arc.exe" lt "$1" 2>/dev/null | sed -n '/Pos/,$p' | \
    awk '/^[* ]*[0-9]+ +[0-9]/ {sz=$3; gsub(/,/,"",sz); if (sz+0>max) {max=sz+0; for (i=6;i<=NF;i++) printf "%s", $i}; } END {print ""}'
}
bloque() {  # posicion y tamaño comprimido del bloque de datos
  wine "$R/Arc.exe" lt "$1" 2>/dev/null | sed -n '/Pos/,$p' | \
    awk '/^[* ]*[0-9]+ +[0-9]/ {sz=$3; p=$2; c=$4; gsub(/,/,"",sz); gsub(/,/,"",p); gsub(/,/,"",c);
         if (sz+0>max) {max=sz+0; po=p; co=c}} END {print po, co}'
}

gen() { # $1=clave  $2=password  $3... = argumentos extra de arc.exe
  local clave=$1 pwd=$2; shift 2
  local arc=$A/$clave.arc
  rm -f "$arc"
  ( cd $A && wine "$R/Arc.exe" a -cfg- -m0 -p"$pwd" "$@" "$arc" files ) >/tmp/gen-crypt.out 2>&1
  local rc=$?
  if [ $rc -ne 0 ]; then
    printf '%-22s FALLO la creación (rc=%s): %s\n' "$clave" "$rc" "$(tail -2 /tmp/gen-crypt.out | tr '\n' ' ')"
    return 1
  fi
  local m; m=$(metodo "$arc")
  {
    echo "caso     : $clave"
    echo "password : $pwd"
    echo "comando  : wine $R/Arc.exe a -cfg- -p'$pwd' $* $clave.arc files"
    echo "metodo   : $m"
    echo "tamaño   : $(stat -c%s "$arc") bytes"
  } > "$A/$clave.txt"
  printf '%-22s %s\n' "$clave" "$m"
}

# el cifrado se elige con --encryption=<algoritmo>  (short: -ae)
echo "== un cifrado por algoritmo (perfil por defecto) =="
for c in aes-128 aes-192 aes-256 blowfish serpent twofish; do
  gen "p_$c" "1234" --encryption="$c"
done
echo "== modo cfb =="
for c in aes-256 blowfish serpent twofish; do
  gen "p_${c}_cfb" "1234" --encryption="$c/cfb"
done
echo "== cabecera/directorio cifrados (-hp) =="
gen "hp_aes"     "1234" -hp --encryption="aes-256"
gen "hp_serpent" "1234" -hp --encryption="serpent"
echo "== password con UTF-8 =="
gen "utf8_aes" "contraseña_ñ_日本語" --encryption="aes-256"
echo
echo "archivos generados: $(ls $A/*.arc 2>/dev/null | wc -l)"
