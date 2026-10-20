# Estado de PArc (2026-10-20)

Resumen para retomar el trabajo sin releer toda la historia. Lo que está hecho, lo que falta y
cómo verificarlo.

## Fases

| fase | estado | dónde |
|---|---|---|
| Bugs de FreeArc y propios | ✅ cerrada (2026-10-20) | `docs/BUGS-FREEARC.md`, commits `23f7e74`, `5ebf73c` |
| Códecs que faltaban | ✅ cerrada (2026-10-20) | `docs/LIBRERIAS.md`, commits `634d149`, `47cf522`, `6a11bfc`, `b10a530`, `6fe3434` |
| GUI 1:1 | ⏸ **no empezar hasta que el humano lo diga** | `docs/PLAN-GUI.md` |

## Qué se hizo en la fase de códecs

- **DisPack (`dispack070`)**: port completo (lectura y escritura) en `src/parc_dispack.pas`.
  El bloque de datos que escribe PArc es byte a byte el de `arc.exe`. `tests/dispack.sh`.
- **SREP (`srep`)**: decodificador v1–v4 y codificador v3 en `src/parc_srep.pas`.
  El codificador es un LZ77 greedy de matches ≥512 bytes: válido y compatible, pero comprime
  menos que el srep original (que hace búsqueda exhaustiva). `tests/srep.sh`.
- **Diccionarios después de un compresor externo**: en `srep+lzma` el lzma conserva su default
  (como `compressionLimitDictionary`), en `lzma+srep` se limita al bloque.

## Pruebas

Suite completa (necesita `arc.exe` bajo wine y, para srep, haber construido el `srep` de
referencia; `tests/srep.sh` lo hace solo):

```sh
./build.sh linux64
bash tests/order_matrix.sh      # bloques sólidos vs arc.exe
bash tests/update_matrix.sh     # a/u/f/d vs arc.exe
bash tests/write_matrix.sh      # PArc comprime, FreeArc lee
bash tests/regress.sh           # extracción vs unarc
bash tests/compat_matrix.sh     # lectura de todos los métodos
bash tests/dispack.sh           # DisPack en las dos direcciones
bash tests/srep.sh              # SREP: v1-v4, codificador, robustez
bash tests/canon_methods.sh     # texto canónico de los métodos
bash tests/stdio.sh tests/volumes.sh tests/sfx.sh tests/rs_recovery.sh tests/parc_crypt.sh
sudo bash tests/fixes.sh        # máscaras, enlaces, disco lleno, FAT32
python3 tests/fuzz_update.py --iters 20 --seed N   # fuzz de actualización
```

## Limitaciones conocidas

- El codificador SREP es greedy: ratio peor que el `srep` original, streams válidos.
- `srep` codifica solo formato v3; el v4 (Index-LZ) se lee pero no se escribe.
- `parc a x.arc .` no incluye el propio `x.arc` (FreeArc sí); es intencional.
- El fuzz de actualización omite el `arc.exe t` de archivos srep si el entorno no tiene el
  `srep.exe` externo.
- El `arc.ini` de `/mnt/IA_LAB/agentes/PArc/ref` se corrigió para usar comillas dobles: con
  comillas simples el srep externo no arranca bajo wine (queda `arc.ini.bak`).

## Próximos pasos posibles

1. GUI (cuando el humano la habilite): decisiones abiertas en `docs/PLAN-GUI.md` §5.
2. Mejorar el codificador SREP (búsqueda de matches más exhaustiva) si importa el ratio.
3. Escribir v4/Index-LZ en srep (opcional; FreeArc usa `-m3f`, que ya se escribe).
