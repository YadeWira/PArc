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

### Máscaras y enlaces (a, u, f)

- Un argumento puede ser una máscara con `*` y `?` en el último componente: `*.txt`,
  `src/*.pas`. La expande el propio PArc (en Windows `cmd.exe` no lo hace). Los directorios
  que coinciden entran completos. `*.*` incluye los nombres sin punto, como en Windows.
- `-r`: la máscara busca también en todos los subdirectorios (`parc a x.parc -r '*.txt'`).
- Si nada coincide y el archivo no existía, no se crea un archivo vacío.
- Un archivo que no se puede leer (sin permiso, o bloqueado por otro programa) se saltea con
  aviso: el resto se agrega igual y, si ya estaba en el archivo, queda la versión anterior.
  PArc termina con el código 6.
- Enlaces simbólicos (y junctions de Windows): en `.parc` se guardan como enlaces, sin
  seguirlos. En `.arc`, que no los admite, el enlace a un archivo se guarda con el contenido
  del destino (como FreeArc) y el enlace a un directorio o roto se saltea con aviso.
- El archivo que se está escribiendo, sus volúmenes y sus temporales no se agregan aunque
  caigan dentro de una máscara (`parc a x.arc .` no mete `x.arc` dentro de sí mismo).
  FreeArc 0.67.1 sí lo incluye; en PArc se excluye a propósito.

## Opciones

### Destino y sobrescritura (x, e)

| opción | efecto |
|---|---|
| `-dp<dir>` | directorio de destino |
| `-o+` | sobrescribe los archivos que ya existen |
| `-o-` | los saltea (es lo que se hace si no se indica nada) |
| `-snld` | crea también los enlaces que apuntan fuera del destino (absolutos o con `..` que sube más allá) |

Los enlaces se crean al final de la extracción. Por seguridad, sin `-snld` no se crean los que
apuntan fuera del destino: a través de uno así, otro archivo podría escribirse en cualquier
lugar del disco. En Windows crear un enlace requiere ser administrador o el modo
desarrollador; si no se puede, se avisa y se saltea.

### Compresión (a, u, f, d)

| opción | efecto |
|---|---|
| `-m<N>` | preset de FreeArc: `-m0` (sin compresión) a `-m9`, `-mx`. El default es `-m4`, como en FreeArc |
| `-m<método>` | un método explícito, por ejemplo `-mlzma:64mb:max` o `-mrep:96m+exe+lzma` |
| `-fmt=arc` / `-fmt=parc` | formato de salida. Sin la opción: el del archivo que se actualiza, o por la extensión (`.arc` = FreeArc, otra = `.parc`) |
| `--recompress` | al actualizar, rehace todos los bloques con el método pedido en vez de copiar los que quedan enteros |
| `-x<máscara>` | excluye archivos; se puede repetir |

Los presets eligen el método según el tipo de cada archivo, como FreeArc: por `arc.groups`
(extensión) y, si el preset distingue textos o datos ya comprimidos, mirando el contenido. El
diccionario de cada compresor se achica al tamaño del bloque, así que extraer un archivo chico
no pide la memoria del preset completo.

Al actualizar (`a`, `u`, `f`), los bloques sólidos que quedan enteros se copian sin recomprimir;
`--recompress` fuerza a rehacerlos. Con `d` y un `-m` explícito se recompila todo el archivo
con ese método, igual que FreeArc (es un comando que "copia": `is_COPYING_COMMAND` en
`Cmdline.hs`).

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

En `.parc` el registro es Reed-Solomon. En `.arc` sigue siendo el XOR de FreeArc, para que
`arc.exe` lo use. Con el mismo tamaño:

- el XOR repara un solo sector dañado por grupo: dos daños sueltos que caen en el mismo grupo
  ya no tienen arreglo;
- Reed-Solomon reparte el archivo en franjas de hasta 255 sectores, cada una con `m`
  sectores de paridad. Repara hasta `m` sectores dañados por franja, en cualquier posición,
  incluida la propia paridad. Los sectores se intercalan entre franjas, así que un tramo
  contiguo dañado de hasta franjas × `m` sectores también se repara.

Con `-rr1%` hay unas 2 o 3 paridades por franja, y con `-rr5%` unas 12. Cuanto más daño suelto
se quiera tolerar, más por ciento. `parc r` dice qué sectores no pudo reparar.

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

### Autoextraíble: `-sfx`

| opción | efecto |
|---|---|
| `-sfx` | crea un ejecutable que se extrae solo: `copia.exe` en Windows, `copia` en Linux |
| `-sfx=<módulo>` | usa ese módulo; por ejemplo, desde Linux, `-sfx=build/win64/parcsfx.exe` arma uno para Windows |

El ejecutable es el módulo `parcsfx` (se busca al lado de `parc`) con el archivo pegado al
final; funciona con `.parc` y `.arc`, con `-rr` y con cifrado, pero no con `-v`. `parc` lo lee
como a cualquier archivo (`parc l copia.exe`, `parc t`, `parc x`), y al actualizarlo
(`parc a copia.exe nuevo.txt`) sigue siendo autoextraíble.

El autoextraíble entiende:

```
copia.exe [t|l] [-dp<dir>] [-o+|-o-] [-p<contraseña>] [--no-progress]
```

Sin comando extrae en el directorio actual. Si un archivo ya existe pregunta
(`[s]í, [n]o, [t]odos, n[i]nguno`), o lo saltea si no hay consola; `-o+` y `-o-` fuerzan una
u otra cosa. La contraseña que falta se pide por consola. Abierto con doble clic en Windows,
espera un Enter antes de cerrar la ventana. Los códigos de salida son los de `parc`.

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

En `.parc` el cifrado es más fuerte que el de FreeArc (el `.arc` sigue igual, para que
`arc.exe` lo abra):

- la clave se deriva con 200 000 iteraciones de PBKDF2-HMAC-SHA512, contra 1000 de FreeArc.
  Cuesta ~0,6 s, una sola vez por archivo. `-ae=aes:n<N>` elige otra cantidad;
- la clave se usa completa. FreeArc decodifica mal el hex de la clave y AES-256 le queda en
  ~212 bits;
- cada bloque cifrado lleva una etiqueta de autenticación (HMAC-SHA512 de 32 bytes): un
  cambio en los datos cifrados se detecta ("la autenticación falló"), cosa que el CRC solo
  no garantiza con el modo CTR;
- la contraseña va en UTF-8, así que cualquier carácter cuenta.

Los `.parc` cifrados con versiones anteriores de PArc se siguen leyendo y actualizando.

### Entrada y salida estándar

| opción | efecto |
|---|---|
| `-so` | `x`/`e`: el contenido de los archivos pedidos va a stdout, sin crear nada en el disco |
| `-si[nombre]` | `a`: agrega lo que llega por stdin como un archivo con ese nombre (sin nombre: `stdin`) |
| `-` como archivo | `l`, `lb`, `t`, `x`, `e`: lo lee de stdin; `a`: lo escribe en stdout |

```sh
tar cf - proyecto | parc a copia.parc -siproyecto.tar -m5   # comprimir lo que sale de tar
parc x copia.parc proyecto.tar -so | tar xf -               # y de vuelta
parc x copia.parc config.ini -so                            # ver un archivo sin extraerlo
parc a - docs | ssh otra 'cat > docs.parc'                  # el archivo, directo por la red
```

Con `-so` o con `a -`, los mensajes van a stderr para no mezclarse con los datos. Un archivo no
se puede escribir ni leer de corrido (los descriptores apuntan hacia atrás y el directorio va al
final), así que lo que llega por stdin se vuelca primero a un temporal: con `-si`, al lado del
archivo; con `-`, en el directorio temporal del sistema (`TMPDIR`). Los temporales se borran
al terminar, también con error o Ctrl-C.

### Bloques dañados

Si un bloque está dañado, la extracción sigue con los demás. De ese bloque se informa cada
archivo que no se pudo extraer; el que estaba a medio escribir queda con lo que se recuperó.
Si el archivo tiene registro de recuperación, se sugiere `parc r`.

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
| 6 | terminó, pero algunos archivos no se pudieron leer y no se agregaron |
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
  el registro de recuperación. Los métodos son `storing`, `lzma`, `ppmd`, `grzip`, `dict`,
  `rep`, `delta`, `tor`, `lzp`, `mm`, `tta`, `4x4`, `exe` (BCJ), `lz4`, `dispack070` (DisPack)
  y `srep` (SREP v1–v4), solos o en cadena (`exe+dispack070+lzma`, `srep+lzma`, …).
- `srep` al comprimir usa un LZ77 greedy de matches largos (≥512 bytes) con *lazy matching*:
  genera streams válidos que lee el `srep` de referencia y FreeArc, con un ratio parecido al
  del `srep` original.
- Lo que escribe PArc en `.arc` lo abren y extraen `arc.exe` 0.67.1 y `unarc`.
- Con el mismo árbol y el mismo preset, PArc arma los mismos bloques sólidos, con los mismos
  archivos en el mismo orden y el mismo método guardado que `arc.exe`
  (`tests/order_matrix.sh`). Los tamaños comprimidos coinciden en la mayoría de los bloques;
  algunos difieren por pocos bytes porque los codificadores LZMA, GRZip y Tornado no son las
  mismas versiones que trae FreeArc.
- Con `-m0 -rr...` el archivo completo es idéntico byte a byte al de `arc.exe`.
- El formato `.parc` (`docs/formato/FORMATO-PARC.md`) solo lo lee PArc.
