# parc_ppmd — decodificador PPMd de FreeArc en Pascal (para PArc)

Entrega de la tarea: portar el decodificador PPMd de FreeArc 0.67 a FPC 3.2.2,
emulando el layout de memoria de 32 bits.

## Archivos

| archivo | qué es |
|---|---|
| `parc_ppmd.pas` | el unit, **en un solo archivo** (1704 líneas, sin includes) |
| `testppmd.pas` | prueba unitaria: decodifica un bloque PPMd crudo y compara byte a byte |
| `validate.sh` | batería completa (matriz orden/memoria + corpus + fuzzing) |

Compila con:
```
fpc -Fu<tu>/src -Fu<acá> -FU/tmp -FE. -otestppmd testppmd.pas
```
(`parc_bytes` y `parc_stream` se toman de `PArc/src`.)

## Interfaz

```pascal
uses parc_bytes, parc_stream, parc_ppmd;
stage := TPpmdStage.Create(ASource, Order, MemSize, MRMethod, Chunk);
n := stage.Read(Buf, Count);     { pull, como las demás etapas }
```
- `Order`/`MemSize` salen de `parse_PPMD` (método `ppmd:ORDER:MEM`), `MRMethod`
  por defecto 0 (`MRM_RESTART`), `Chunk` 0.
- Errores por `Corrupt()` de `parc_bytes`.
- Los parámetros se validan **antes** de `inherited Create`, para no liberar una
  fuente que sigue siendo del llamador.

## Por qué emula 32 bits (no es capricho)

Esta variante de PPMd guarda `Successor`/`Suffix` como **punteros reales** bajo
`#pragma pack(1)`, y sus decisiones dependen de la *posición absoluta* en el heap
(`pText >= UnitsStart`, `(BYTE*)Successor >= UnitsStart`,
`GetUsedMemory() < SubAllocatorSize>>1`). El encoder real es 32-bit, así que con
punteros de 8 bytes el layout cambia, esas decisiones se corren y el decoder da
bytes distintos **sin un solo acceso inválido** (verificado con valgrind sobre la
versión C++ x64: el fallo es de lógica, no de memoria).

Por eso acá todas las referencias internas son offsets `UInt32` desde la base del
heap (0 = NULL) y los records tienen los tamaños de 32 bits:

    TContext 12 = UNIT_SIZE, TState 6, TMemBlk 12, TSee2 4

Dos detalles que NO hay que "simplificar" (están comentados en el código):
1. `GlueFreeBlocks` encadena **en orden** (`p0->link(p); p0=p`), no antepone:
   el orden cambia qué direcciones devuelven después las free lists, y como las
   decisiones dependen de direcciones, un orden distinto = divergencia.
2. `ExpandTextArea` recorre la free list **desde la cabeza**, que vive FUERA del
   heap (es un contador): por eso la cabeza se copia a un `TBlkNode` local.

## Validación (criterio de listo)

`./validate.sh` → **19 OK / 0 fallas**, contra archivos creados por `arc.exe`
0.67.1 y con lo esperado verificado por contenido:

- barrido de orden 2, 4, 6, 8, 10, 12, 16, 24, 32
- barrido de memoria 1, 8, 48, 256 MB
- **2 MB de `/dev/urandom` con `ppmd:10:48mb`** — el caso que rompe el build x64
  en C++
- archivo chico, órdenes y memorias variadas
- el bloque PPMd de `gen/ppmd.arc` (corpus de 14 archivos, 9.897.404 bytes):
  se parte el stream por contenido de archivo conocido y se exige consumirlo
  entero usando los 13 archivos no vacíos
- fuzzing: 200 mutaciones de 1 byte en el payload → **0 crashes**

## Pendiente / notas

- **`4x4:ppmd`**: no hace falta un camino aparte. `ppmd_de_compress` (el
  "memoria-a-memoria") sólo se elige si `compress_all_at_once`, que es una opción
  de *compresión*; al descomprimir se usa siempre el camino normal.
- `MRMethod` (freeze/restart) está implementado con las mismas ramas que el C++
  pero sólo se ejercitó con `MRMethod=0` (lo que produce `arc.exe`).
- No probado con streams producidos por otra build de FreeArc (sólo 0.67.1).
