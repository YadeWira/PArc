# Plan de la GUI de PArc (v0.1, 2026-09-24)

Basado en el relevamiento de la GUI de FreeArc 0.67 (GUI.hs, FileManager*.hs, UI.hs, CUI.hs,
DLLUI.hs, ArcShellExt/). Esos fuentes ya no están en el árbol de trabajo (se recortó
`reference/freearc-0.67/` a `Compression/`); se recuperan con
`git show 82ea8d9:reference/freearc-0.67/GUI.hs` (o del commit completo) o de la distribución
original de FreeArc. Todavía no hay decisiones tomadas: ver §5.

> **Estado (2026-10-20):** la GUI **no se empieza hasta que el humano lo diga**. No es una
> fase en curso: primero van los bugs y la actualización de codecs. Decisiones ya tomadas:
> será un **clon 1:1** de la GUI de FreeArc y **no usará GTK2**.

## 0. Restricciones del entorno
- **La LCL para Windows todavía no se puede compilar desde Linux.** El cross win64 instalado
  solo tiene `rtl*`, sin `fcl-*` ni `winunits`. La CLI sí compila, porque usa solo la RTL.
  Para win32 no hay cross (PA-Lab está armando `ppcross386`).
- En Linux el único widgetset instalado es **gtk2** (Lazarus 4.0), pero **está descartado por
  decisión**; habrá que instalar qt5 (`libqt5pas`) o resolver el widgetset antes de empezar.
- Los archivos de idioma de FreeArc (`arc.languages/`) no están en el repo.

## 1. Cómo es la GUI de FreeArc
- **La GUI arma líneas de comando** y las encola a un hilo de trabajo (`cmdChan`,
  FileManager.hs:593). Todo entra por `parseGUIcommands` (FileManager.hs:54):
  `--add-dialog`, `--extract-dialog`, `--settings-dialog`, `--register`.
- **File manager**
  - Estado del panel en `FM_State` (FileManUtils.hs:41). `PathInfo` distingue rutas en
    archivo y en disco (:105). Árbol virtual `FileTree` (:235).
  - Orden por nombre/tamaño/fecha/tipo (FileManPanel.hs:288-310). Menús en `uiDef`
    (FileManager.hs:105): Add, Extract, Test, Info, Delete, Lock, Comment, Recompress, SFX,
    Encrypt, Protect, Repair, Join.
- **Diálogos**
  - `extractDialog` (FileManDialogs.hs:45): destino, 4 modos de sobrescritura, conservar archivos rotos.
  - `addDialog` (FileManDialogAdd.hs:46).
  - Info (:151), Settings (:224), método y cifrado (:543).
- **Progreso** (GUI.hs:114): barra, archivo actual, Background/Pause/Cancel (:153-185),
  progreso en la barra de tareas de Win7 (:210). Se refresca cada 0,5 s.
- **Conexión con el núcleo**: callbacks `uiStartProcessing` (UI.hs:101), `uiStartFile` (:191),
  `uiReadData`/`uiWriteData` (:393/:407). Hay tres frontends: CUI (consola), GUI (Gtk) y DLLUI (callback C).
  - Sobrescritura: `askOverwrite` (GUI.hs:550) con memoria de "siempre", "saltar todos" y
    "actualizar todos" (:570, respuestas y/n/q/a/s/u).
  - Contraseñas: `ask_passwords` (:630).
- **Config**: `freearc.ini` (Options.hs:653), con historial y posición de ventanas.
- **Idiomas**: `arc.<idioma>.txt` con ids numéricos (`"0078 Confirm File Replace"`).
- **Explorador**: `registerShellExtensions'` (FileManDialogs.hs:446). DLL COM de menú
  contextual (ArcShellExt.cpp) con menú armado en Lua 5.1.

## 2. Arquitectura propuesta (Lazarus/LCL)
- **`parc_ops.pas`**: records de operación (`TExtractOptions` ya existe en `parc_extract`;
  después `TAddOptions`). Llamadas directas, sin armar líneas de comando como FreeArc.
- **`parc_ui.pas`**: interfaz de callbacks `IParcUI` (CORBA, sin conteo de referencias):
  - `StartOperation`, `StartFile`, `Progress`, `Warning`, `Error`;
  - `AskOverwrite` → `oaYes/oaNo/oaAll/oaSkipAll/oaUpdateAll/oaCancel`;
  - `AskPassword`, `BadPassword`;
  - `CheckCancel`, que también sirve de punto de pausa.

  La memoria de "siempre" y "saltar todos" vive en el núcleo, así CLI y GUI se comportan igual.
- **Hilos**: `TParcWorker(TThread)`.
  - Progreso por contadores atómicos que lee un `TTimer` (250-500 ms).
  - Preguntas con `Synchronize`.
  - Cancelar = flag; Pausar = `TEvent` esperado en `CheckCancel` entre bloques de E/S.
  - Ninguna excepción sale del worker sin capturar.
- **Linux**: gtk2 para el MVP (instalado); qt5 queda como opción.
- **Win7**: manifest `dpiAware=true` (DPI de sistema, nada de PerMonitorV2); `ITaskbarList3`
  (existe desde Win7); cadenas UTF-8; prefijo `\\?\` para rutas largas; probar siempre en la
  VM win7 real.

### Progreso y cancelación (hecho, `src/parc_progress.pas`)
- Sin dependencias de interfaz: `ProgressHandler` (un procedimiento) recibe `TProgressInfo`
  (fase, bytes hechos/total, archivo actual, ms transcurridos, `Finished`), a lo sumo cada
  100 ms, desde el hilo que corre la operación. La GUI copia eso a contadores y lo lee su
  `TTimer`; la CLI dibuja una línea en stderr (solo si es consola; `--no-progress` la apaga).
- `RequestCancel` (desde cualquier hilo) → `EOperationCancelled` en el próximo
  `CheckCancel`. `ResetCancel` antes de cada operación nueva en el mismo proceso.
- Puntos de cancelación: cada ~1 MB de E/S, `TOutStage.Emit`, cada bloque de lzma (~128 KB),
  las fases de dict y el bucle de tornado, también dentro de los hilos del pool 4x4. Latencia
  medida < 0,1 s, salvo un bloque de grzip ya en vuelo (≤ ~1 s).
- Garantías: `a/u/f/d` cancelado borra el temporal y el archivo original queda intacto;
  `x/e` cancelado borra el archivo a medio escribir. Probado en Linux, win10 (x64) y Win7 (x86).
- Pausa: se puede agregar en `CheckCancel` (esperar un evento) sin tocar los codificadores.

## 3. Integración con el Explorador
- **Etapa A: solo registro.** `HKCU\Software\Classes`, sin UAC:
  - asociación `.parc`/`.arc`;
  - submenú `*\shell\PArc` y `Directory\shell\PArc` con `SubCommands` (existe desde Win7);
  - instancia única (mutex + named pipe) para juntar selecciones múltiples.
- **Etapa B: DLL COM** `IShellExtInit` + `IContextMenu`, en x64 (Explorer) y x86. Riesgos:
  - un crash tira abajo `explorer.exe`;
  - la RTL de FPC corre dentro del Explorer, así que va sin LCL;
  - el registro necesita HKLM/regsvr32;
  - antivirus y SmartScreen si no está firmada.

## 4. Fases
| Fase | Entregable verificable | Qué necesita el núcleo |
|---|---|---|
| F0 | `parc_ui`/`parc_ops`; la CLI `x/t` usa `TConsoleUI` (progreso, sobrescritura, Ctrl-C) | **hecho: progreso y cancelación** (`parc_progress`, ver abajo). Falta: preguntas de sobrescritura/contraseña por callback |
| F1 | `gui/parcgui.lpi` (gtk2): abrir, árbol + lista virtual, navegar, ordenar | `TArchive` (listo). Check: coincide con `parc l` |
| F2 (MVP) | extraer/test en worker, progreso con Pausa/Cancelar, diálogos de sobrescritura y contraseña | F0 + errores tipados. Check: cancelar no deja basura; detecta un .arc corrupto |
| F3 | `parc.ini`, historial, i18n | — |
| F4 | builds win32/win64 probados en Win7; Explorador etapa A | toolchain Windows con LCL |
| F5 | agregar, borrar, comentario, lock | escritor `.parc`, compresores |
| F6 | SFX, recovery, repair, cifrado | módulos en el núcleo |
| F7 | DLL del shell (etapa B) | F4 |

## 5. Decisiones pendientes (humano)
1. Visual: ~~¿clon de FreeArc o diseño nuevo?~~ **decidido: clon 1:1**.
2. i18n: ¿formato `arc.<idioma>.txt` compatible o `.po` con `LCLTranslator`?
3. Widgetset Linux: ~~¿gtk2 o qt5?~~ **gtk2 descartado**. Falta elegir (qt5 u otro) y
   confirmarlo; hoy solo gtk2 está instalado.
4. Toolchain Windows: ¿cross completo desde Linux o build nativo en Windows?
   (decidido: priorizar el cross, ver la respuesta del 2026-10-20)
5. Explorador: ¿alcanza con la etapa A o hace falta la DLL COM?
6. Alcance del MVP: ¿solo lectura hasta tener el escritor `.parc`?
7. ¿Se mantiene "Background" o alcanza con Pausa/Cancelar?

## 6. Cuándo se empieza
Cuando el humano lo indique. Antes de tocar código de GUI: cerrar la fase de bugs y la de
codecs. No agregar dependencias de LCL al build de la CLI (`build.sh`) mientras tanto.
