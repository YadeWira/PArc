# parc_crypt — descifrado de FreeArc 0.67: estado

## Hecho y validado

- **Especificación** la especificación del formato base (FreeArc-ex, `docs/FORMATO-ARC.md`) §7.3 (+ dos subsecciones nuevas: el hex
  "buggy" de `:k`/`:i` y que cada bloque lleva su propio IV/salt/check-code).
- **`parc_crypt.pas`**:
  - SHA-512, HMAC-SHA512, PBKDF2-HMAC-SHA512 → verificados contra vectores
    oficiales (`sha512("abc")`, `""`, FIPS de 1 MB; PBKDF2 con c=1 y c=4096).
  - AES-128/192/256 (dirección de cifrado) → verificado contra los tres
    vectores FIPS-197 y el del Apéndice B.
  - Modos CTR (contador little-endian) y CFB; parseo de la etapa; derivación +
    comprobación del check-code; `KeyedMethod`; `TDecryptStage`; `DecryptMem`.
  - **Descifrado AES y BLOWFISH validados byte a byte contra archivos cifrados
    reales de arc.exe 0.67.1** (aes-128/192/256 en ctr y cfb, blowfish-448 en ctr
    y cfb), con password incorrecta dando `PASSWORD INCORRECTA` (no basura ni
    crash). Blowfish verificado además con los 3 vectores de la propia
    LibTomCrypt (`blowfish_test`).
  - **SERPENT validado byte a byte** contra el archivo real de arc.exe
    (serpent-256/ctr) y con los **9 vectores oficiales** de `serpent.c`
    (claves de 16, 24 y 32 bytes), todos OK.
  - **TWOFISH validado byte a byte** contra el archivo real (twofish-256/ctr) y
    con los **3 vectores oficiales** de `twofish.c` (claves de 16, 24 y 32 bytes).
    Ojo con un detalle que ahorra tiempo: el build de FreeArc define `LTC_TWOFISH`
    pero **no** `LTC_TWOFISH_ALL_TABLES`, así que compila el camino **sin tablas
    precalculadas**: `sbox(i,x)` se calcula con `qbox`, el MDS/RS con `gf_mult`, y
    `g_func` es la macro que usa las 4x256 S-boxes que arma el setup en runtime
    (`h_func`). Es el camino largo, no el de `twofish_tab.c`.
- `arcs/`: 13 archivos de prueba con su manifiesto; `testcrypt.pas`;
  `validate.sh` → **8 OK / 4 fallas** (las 4 son los 3 cifrados que faltan, que
  reportan "cifrado todavía no implementado", y el caso de password UTF-8).

## Los dos bugs que costaron (y que conviene no reintroducir)

1. **SHA-512**: las palabras de 64 bits se cargan **big-endian** (`LOAD64H`:
   `buf[0]<<56`), no little-endian; y el digest también va big-endian
   (`STORE64H`). Tenía ambos al revés. Síntoma: el PBKDF2 no daba y el
   check-code rechazaba la password correcta.
2. **AES**: en el `FT4` final el índice es `(i + x)`; el `(i - x)` es el del
   *descifrado* (`FD4`). Síntoma inconfundible: los bytes pares del bloque de
   salida salían bien y los impares mal.
3. **Hex "buggy"** (no es un bug mío, es del formato): ver §7.3.6. La clave y el
   IV se decodifican con `buggy_char2int` salvo `:f`. Sin esto, la derivación y
   el check-code dan bien pero el descifrado devuelve basura.

## Lo que falta

- **`utf8_aes`**: es un problema del **arnés de prueba**, no del unit. El archivo
  lo creó `arc.exe` bajo wine con un password no-ASCII (`contraseña_ñ_日本語`) que
  pasa por la línea de comandos, y los bytes que efectivamente le llegaron a
  `arc.exe` no son los UTF-8. Probé las codificaciones plausibles (UTF-8, CP1252,
  latin-1, y sus variantes con `?` para lo que no es representable) y **ninguna**
  coincide, así que el mangling es más profundo que una conversión de página de
  códigos. La evidencia de que el decoder está bien: el resto de los archivos AES
  (passwords ASCII) descifran byte a byte, y el *check-code* —que es la propia
  verificación de password de FreeArc— rechaza exactamente como debe. Para cerrar
  el caso hay que crear el archivo por un camino que no pase el password por la
  línea de comandos de wine (por ejemplo en la VM Windows, o pasándolo de forma
  interactiva) y volver a probar.
- **Password UTF-8**: el caso falla porque al crear el archivo con `wine` la
  contraseña no llega como los mismos bytes (se pasa por la línea de comandos de
  Windows). Hay que crear el caso con el flag `:f` (contraseña Unicode→UTF-8) o
  encontrar cómo pasarla sin que wine la convierta. Es un tema del *test*, no del
  unit.
- **`deriveKeyAndCheck` con keyfiles** y el fuzzing del descifrado.

## Uso

```bash
fpc -Fu<PArc>/src -Fu. -FUunits -FE. -otestcrypt testcrypt.pas
./testcrypt <arc> <off> <size> <esperado> "<etapa-cifrado>" <password>
./validate.sh
```
`<off>`/`<size>` son los del bloque de datos (el de mayor `Size` en
`arc.exe lt`); `validate.sh` ya lo hace. Para probar la cripto sola conviene que
el bloque sea `storing+cifrado` (se generan con `-m0`).
