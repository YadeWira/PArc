# parc_mm / parc_tta — estado

Port a Pascal de los decodificadores multimedia de FreeArc
(`Compression/MM/`: `mm.cpp`, `tta.cpp`, `entropy.cpp`, `filters.cpp`).

## Archivos

| archivo | qué es |
|---|---|
| `parc_mm.pas` | stage MM (`undiff` por canal). **Funciona en BMP**; falta el AV con WAV |
| `parc_tta.pas` | stage TTA (Rice + 3 filtros adaptativos). **Todavía no byte-exacto** |
| `teststage.pas` | harness: decodifica el payload de un `.arc` y compara byte a byte |
| `validate.sh` | batería sobre `media/` (WAV 8/16/24 bits, mono/stéreo, 44.1/48k; BMP 8/24/32) |
| `media/` | 15 archivos generados (deterministas, `python3` en `validate.sh`… no: los generó un script aparte) |

Compilar: `fpc -Fu<tu>/src -Fu. -FUunits -FE. -oteststage teststage.pas`

## Estado

**MM — casi listo.** Byte a byte correcto en BMP de 8, 24 y 32 bits, tanto
autodetectado (`mm`) como forzado (`mm:1*8/24/32`). Falta: con WAV de entrada
(offset=44, 2 canales, 16 bits) da `EAccessViolation`, a depurar.

Bug ya corregido: los `undiff` de 16 y 32 bits avanzaban de a **N bytes** en vez
de **N*2** y **N*4** (el C usa `uint16*`/`uint32*`), lo que además leía fuera del
buffer y provocaba el AV.

**TTA — a medio camino.** El framing está bien (los tamaños coinciden exactos:
cabecera, offset, bloques, `rest`, entrelazado). Dos bugs reales ya encontrados y
corregidos en los filtros:

1. `PREDICTOR1(x,k)`: el C hace la resta y el shift en **uint64** y recién
   después castea a 32 bits; castear antes cambia el resultado con `x` negativo.
2. La actualización de `dx` escribía en `px+order-1 .. px+order-4`; el C escribe
   en `px+order .. px+order-3` (off-by-one, `*(pA-0)..*(pA-3)` con `pA=px+order`).

Con esos dos arreglos, la zona constante de la señal se decodifica perfecto (pasó
de 2 muestras correctas a ~74) y **la divergencia empieza exactamente en la
primera transición brusca** de la señal: ahí el residual es grande y el stream usa
el camino `unary >= 50` (`unary=50` + 32 bits). O sea: queda algo en ese camino
(o en la adaptación de `k0`/`k1`) — es el próximo lugar a mirar, no el framing.

Evidencia (WAV 8 bits mono, `tta`): original `8b ff ff …` constante; mío coincide
hasta el offset 117 y en 118 (justo donde el original pasa a `00`) sale basura.

## Próximos pasos

1. TTA: instrumentar `DecodeFrame` para volcar `unary`/`k`/`value` en las
   muestras 70-80 y compararlos con el stream a mano; mirar el camino `>= 50` y
   la adaptación de `k0`/`k1`.
2. MM: reproducir el AV con WAV bajo gdb (probablemente el mismo tipo de error de
   stride/alineación que ya apareció, o el manejo de `offset`).
3. Cuando estén: agregar a la suite los WAV/BMP de `media/` y los
   métodos `-mm+` / `-mmfast` / `-mm-` (las tres variantes que pidió PArc).
