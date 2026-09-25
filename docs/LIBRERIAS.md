# Librerías de terceros en FreeArc 0.67 y su estado (relevado 2026-09-24)

| Librería | En FreeArc | Actual | ¿Formato compatible al actualizar? | Notas |
|---|---|---|---|---|
| LZMA SDK (`Compression/LZMA2/C`: LzmaDec/Enc, Bra86/BCJ, LzFind) | 2009-02 (~4.65/9.x) | 26.x | **Sí**: el stream LZMA y BCJ x86 no cambian desde 2001 | Decoder nuevo mucho más rápido (LzmaDec optimizado). El encoder nuevo produce otros bytes, pero igual de válidos |
| LZ4 (`Compression/LZ4`) | r? 2011-2012 | 1.10.0 | **Sí**: el formato de bloque es estable | Las versiones de 2012 tienen CVE-2014-4611 (overflow en el decoder): **actualizar es un fix de seguridad** |
| LibTomCrypt (`_Encryption`) | 1.17 | 1.18.2 | **Sí**: AES/Blowfish/Serpent/Twofish/SHA dan la misma salida | 1.18.x es bugfix. Verificar también PBKDF2 y los modos (CTR/CFB) que usa FreeArc |
| AES de 7-Zip (`_Encryption/7zAES`) | 2009 | 26.x | Sí | Solo si se usa ese AES en vez del de LibTomCrypt |
| PPMd (`Compression/PPMD`, D. Shkarin) | var. H/I (1999-2001), **modificado por FreeArc** | sin upstream compatible | **No hay reemplazo directo**: Ppmd7 de 7-Zip es var.H con otro range coder | Mantener el propio. Ojo con el bug de x64 que encontró PA-Lab (UNIT_SIZE=12, copia de punteros) |
| Lua (`HsLua`) | 5.1 | 5.4.x | **No**: 5.4 rompe scripts 5.1 | Solo afecta a los scripts/eventos de `arc.ini`; no al formato |
| 7z.dll (interop `Arhive7zLib.hs`, `Client7z*.cpp`) | 7-Zip 9.x | 26.x | API COM parecida, con cambios | Solo para abrir .7z/.zip/.rar; no es parte del formato .arc |
| SREP | 3.93 beta (2013) | — | (propio de Bulat Ziganshin) | Revisar si hay una versión posterior publicada por el autor |
| Métodos propios de Bulat Ziganshin: Tornado, REP, 4x4, Dict, LZP, Delta, MM/TTA, GRZip, DisPack | 0.67 | sin upstream mantenido | — | Hay que portarlos desde estas fuentes; el formato de sus streams lo define este código |

## Implicancia para PArc
- PArc se escribe en Pascal, así que "actualizar" significa **portar desde la versión actual**
  cuando el formato es estable (LZMA/BCJ desde el SDK 26.x, LZ4 desde 1.10, crypto desde
  1.18.2), y **no** desde las copias de 2009-2012 que trae FreeArc.
- La verificación siempre es contra archivos creados por FreeArc 0.67.1 (oráculo `arc.exe`
  bajo wine + `unarc` de PA-Lab): una librería nueva no puede cambiar lo que se lee.
- Los métodos sin upstream se portan desde `Compression/`, usando `unarc` como referencia.

## Estado en PArc (2026-09-25)

PArc no enlaza código de terceros: todo está portado a Pascal. De dónde sale cada parte:

| Componente | Portado desde | Verificación |
|---|---|---|
| LZMA (descompresión) | especificación de referencia (LzmaSpec) | archivos de arc.exe; matriz de lectura |
| LZMA (compresión) | LZMA SDK 26.03 | byte a byte contra el SDK C; arc.exe t/x |
| BCJ x86 (`exe`) | LZMA SDK 26.03 | contra Bra86.c compilado |
| LZ4 (descompresión) | semántica de LZ4 1.10 (`LZ4_decompress_safe`), sin CVE-2014-4611 | archivos de arc.exe |
| LZ4 (compresión) | en curso: LZ4 1.10 (fast y HC) | — (todavía no hay codificador: `-mlz4` no comprime) |
| AES, Blowfish, Twofish, SHA-512, PBKDF2 | LibTomCrypt | `tests/crypto_vectors.sh`: 0 diferencias en miles de vectores al azar contra la 1.17 de FreeArc **y** contra la 1.18.2 oficial (las dos dan lo mismo: actualizar no cambia nada) |
| Serpent | el agregado de FreeArc sobre LibTomCrypt 1.17 (1.18.2 no trae Serpent) | ídem, contra la 1.17 |
| CTR / CFB | LibTomCrypt (contador little-endian, como FreeArc) | ídem |
| PPMd, Tornado, REP, 4x4, Dict, LZP, Delta, MM, TTA, GRZip | FreeArc 0.67 (no hay versiones más nuevas compatibles) | matrices de lectura y escritura |

Diferencia que apareció al comparar: LibTomCrypt rechaza claves de Blowfish de menos de 8
bytes (y AES/Twofish que no sean de 16/24/32); PArc las aceptaba y podía escribir un archivo
que FreeArc no abre. Ahora las rechaza igual (`CipherKeySizeValid`).

No portados, porque no hacen al formato: Lua 5.1 (scripts de arc.ini), 7z.dll y SREP.
