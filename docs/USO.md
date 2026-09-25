# PArc — manual de la línea de comandos

PArc es una reescritura de FreeArc 0.67 en Free Pascal, para Windows 7 o posterior (x86 y
x64) y Linux x64. Lee y escribe archivos `.arc` de FreeArc, y además tiene un formato propio,
`.parc`, que guarda fechas en nanosegundos y los atributos de Windows y los permisos de Unix.

```
parc <comando> <archivo> [archivos/máscaras...] [opciones]
```

Las opciones pueden ir en cualquier posición. El primer argumento que no es una opción es el
archivo; los demás son los archivos o máscaras sobre los que actúa el comando.

## Comandos

| comando | qué hace |
|---|---|
| `l` | lista el contenido: fecha (UTC), tamaño, CRC y nombre |
| `lb` | lista los bloques internos: control, datos, método de cada uno y qué archivos tiene |
| `t` | verifica: descomprime todo y compara los CRC, sin escribir nada |
| `x` | extrae con rutas |
| `e` | extrae sin rutas (todo en el directorio de destino) |
| `a` | agrega archivos y reemplaza los que ya estaban; crea el archivo si no existe |
| `u` | como `a`, pero reemplaza solo si el del disco es más nuevo |
| `f` | actualiza solo los que ya están en el archivo, si el del disco es más nuevo |
| `d` | borra del archivo los nombres o máscaras indicados |
| `r` | repara con el registro de recuperación: escribe `fixed.<nombre>`; el original no se toca |

Los directorios que se pasan a `a`/`u`/`f` se recorren recursivamente.

## Opciones

### Destino y sobrescritura (x, e)

| opción | efecto |
|---|---|
| `-dp<dir>` | directorio de destino |
| `-o+` | sobrescribe los archivos que ya existen |
| `-o-` | los saltea (es lo que se hace si no se indica nada) |

### Compresión (a, u, f, d)

| opción | efecto |
|---|---|
| `-m<N>` | preset de FreeArc: `-m0` (sin compresión) a `-m9`, `-mx`. El default es `-m4`, como en FreeArc |
| `-m<método>` | un método explícito, por ejemplo `-mlzma:64mb:max` o `-mrep:96m+exe+lzma` |
| `-fmt=arc` / `-fmt=parc` | formato de salida. Sin la opción: el del archivo que se actualiza, o por la extensión (`.arc` = FreeArc, otra = `.parc`) |
| `-x<máscara>` | excluye archivos; se puede repetir |

Los presets eligen el método según el tipo de cada archivo, como FreeArc: por `arc.groups`
(extensión) y, si el preset distingue textos o datos ya comprimidos, mirando el contenido. El
diccionario de cada compresor se achica al tamaño del bloque, así que extraer un archivo chico
no pide la memoria del preset completo.

### Bloques sólidos: `-s`

Igual que en FreeArc. Sin `-s`, todos los archivos que usan el mismo método van en un solo
bloque sólido (salvo los cortes propios de cada compresor).

| opción | efecto |
|---|---|
| `-s-` | sin sólido: cada archivo en su propio bloque |
| `-se` | un bloque por extensión |
| `-s<N>` o `-s<N>f` | a lo sumo N archivos por bloque (`-s1f` = sin sólido) |
| `-s<N>m` (o `k`, `g`, `b`) | bloques de *al menos* ese tamaño: el bloque se cierra con el archivo que lo supera |
| combinados | `-se100f10m`: se corta con el primer criterio que se cumpla |

### Registro de recuperación: `-rr`

Agrega datos de paridad que permiten reparar sectores dañados con `parc r` (o `arc r`).

| opción | efecto |
|---|---|
| `-rr` | lo recomendado según el tamaño: 4%, 2% o 1% |
| `-rr<N>%` | N por ciento del archivo |
| `-rr<N>` o `-rr<N>s` | N sectores de 512 bytes |
| `-rr<N>b`, `-rr<N>k`, `-rr<N>m` | esa cantidad de bytes |
| `-rr<cant>;<sector>` | una cantidad de las anteriores, con sectores de ese tamaño |
| `-rr<N>*<sector>` | exactamente N sectores de ese tamaño |
| `-rr0.1%` / `-rr0.01%` | solo los CRC de sectores de 4 KB / 64 KB: detecta daño, no repara |
| `-rr-` | quita el registro al actualizar |

Sin `-rr`, al actualizar un archivo se conserva lo que tenía. Los sectores de menos de 512
bytes se rechazan (FreeArc se queda sin memoria con ellos).

### Volúmenes: `-v` (solo `.parc`)

Parte el archivo en pedazos de tamaño fijo, al estilo de 7-Zip: `copia.parc.001`,
`copia.parc.002`… (el último, más chico). Es una función de PArc: FreeArc no parte sus `.arc`,
así que con `.arc` se rechaza.

| opción | efecto |
|---|---|
| `-v<N>` | volúmenes de N bytes; con sufijo `k`, `m`, `g`: `-v100m`, `-v4g`, `-v700000k` |

- Para leer, extraer, verificar o actualizar se da el primero (`copia.parc.001`) o la base
  (`copia.parc`); PArc junta los volúmenes al vuelo.
- Es el mismo archivo cortado en pedazos: `cat copia.parc.0* > copia.parc` (o `copy /b` en
  Windows) da un `.parc` normal.
- Al actualizar un archivo en volúmenes se conserva el tamaño de volumen (el del primero) y
  se borran los que sobren. `-v` sobre un archivo suelto lo pasa a volúmenes.
- Con `-rr`, el registro protege todo el conjunto; `parc r` escribe `fixed.<nombre>` de una
  sola pieza.
- Si falta un volumen del medio se avisa cuál; si falta el último, el error lo sugiere.

### Cifrado

| opción | efecto |
|---|---|
| `-p<contraseña>` | al leer: la contraseña de un archivo cifrado. Al comprimir: cifra los datos |
| `-p` | sin valor: la pide por consola (dos veces, si es para cifrar) |
| `-hp[<contraseña>]` | cifra también el directorio y el footer: sin la contraseña no se ve ni la lista |
| `-ae=<alg>`, `--encryption=<alg>` | `aes` (default, aes-256/ctr), `blowfish`, `serpent`, `twofish`; con tamaño y modo: `serpent-256/cfb`, `blowfish-448/ctr`... |

`-p` y `-hp` pueden llevar contraseñas distintas; al leer se prueban las dos, como hace FreeArc.
Si falta la contraseña de un archivo cifrado, se pide por consola (hasta tres intentos).
Al actualizar un archivo cifrado, los bloques que se reempaquetan se vuelven a cifrar aunque
no se haya dado `-p`: borrar un archivo no deja el resto en claro.

### Progreso y cancelación

| opción | efecto |
|---|---|
| `--no-progress` | sin la línea de progreso |

La línea de progreso (fase, porcentaje, MB, velocidad, tiempo restante y archivo actual) se
muestra en stderr solo si es una consola; redirigida no aparece. Ctrl-C cancela limpiamente:
al comprimir no queda el temporal y un archivo existente queda intacto; al extraer se borra
el archivo que estaba a medio escribir. Un segundo Ctrl-C corta en el acto.

## Códigos de salida

| código | significado |
|---|---|
| 0 | todo bien |
| 1 | error de uso (opción desconocida, faltan argumentos, el archivo no existe o está bloqueado) |
| 2 | datos dañados: CRC incorrecto o estructura rota; en `r`, sectores irrecuperables |
| 3 | un método que PArc todavía no sabe descomprimir o comprimir |
| 4 | otro error (de E/S, por ejemplo) |
| 5 | contraseña faltante o incorrecta |
| 130 | cancelado con Ctrl-C |

## Variables de entorno

| variable | efecto |
|---|---|
| `PARC_THREADS` | cantidad de hilos para los compresores paralelos (4x4, grzip); por defecto, los núcleos |

## Ejemplos

```sh
parc a copia.arc proyecto/ -m5 -rr        # compatible con FreeArc, con recuperación
parc a copia.parc fotos/ -mx -s-          # formato propio, máxima compresión, sin sólido
parc a privado.arc docs/ -p -hp           # cifrado; pide la contraseña
parc u copia.arc proyecto/                # actualiza lo que cambió
parc d copia.arc 'proyecto/tmp/*'         # borra
parc t copia.arc                          # verifica
parc x copia.arc -dpdestino -o+           # extrae sobrescribiendo
parc r copia.arc                          # repara -> fixed.copia.arc
```

## Compatibilidad con FreeArc

- Lee todo lo que escribe FreeArc 0.67: todos los métodos, archivos cifrados (`-p`, `-hp`) y
  el registro de recuperación.
- Lo que escribe PArc en `.arc` lo abren y extraen `arc.exe` 0.67.1 y `unarc`.
- Con el mismo árbol y el mismo preset, PArc arma los mismos bloques sólidos, con los mismos
  archivos en el mismo orden y el mismo método guardado que `arc.exe`
  (`tests/order_matrix.sh`). Los tamaños comprimidos coinciden en la mayoría de los bloques;
  algunos difieren por pocos bytes porque los codificadores LZMA, GRZip y Tornado no son las
  mismas versiones que trae FreeArc.
- Con `-m0 -rr...` el archivo completo es idéntico byte a byte al de `arc.exe`.
- El formato `.parc` (`docs/formato/FORMATO-PARC.md`) solo lo lee PArc.
