# Plan de la GUI de PArc (v0.1, 2026-09-24)

Basado en el relevamiento de la GUI de FreeArc 0.67 (GUI.hs, FileManager*.hs, UI.hs, CUI.hs,
DLLUI.hs, ArcShellExt/). Todavía no hay decisiones tomadas: ver §5.

## 0. Restricciones del entorno
- **La LCL para Windows todavía no se puede compilar desde Linux.** El cross win64 instalado
  solo tiene `rtl*`, sin `fcl-*` ni `winunits`. La CLI sí compila, porque usa solo la RTL.
  Para win32 no hay cross (PA-Lab está armando `ppcross386`).
- En Linux solo está compilado el widgetset **gtk2** (Lazarus 4.0). qt5 necesita `libqt5pas`.
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
| F0 | `parc_ui`/`parc_ops`; la CLI `x/t` usa `TConsoleUI` (progreso, sobrescritura, Ctrl-C) | extracción con puntos de cancelación (en curso) |
| F1 | `gui/parcgui.lpi` (gtk2): abrir, árbol + lista virtual, navegar, ordenar | `TArchive` (listo). Check: coincide con `parc l` |
| F2 (MVP) | extraer/test en worker, progreso con Pausa/Cancelar, diálogos de sobrescritura y contraseña | F0 + errores tipados. Check: cancelar no deja basura; detecta un .arc corrupto |
| F3 | `parc.ini`, historial, i18n | — |
| F4 | builds win32/win64 probados en Win7; Explorador etapa A | toolchain Windows con LCL |
| F5 | agregar, borrar, comentario, lock | escritor `.parc`, compresores |
| F6 | SFX, recovery, repair, cifrado | módulos en el núcleo |
| F7 | DLL del shell (etapa B) | F4 |

## 5. Decisiones pendientes (humano)
1. Visual: ¿clon de FreeArc o diseño nuevo? (recomendado: misma estructura, widgets nativos)
2. i18n: ¿formato `arc.<idioma>.txt` compatible o `.po` con `LCLTranslator`?
3. Widgetset Linux: ¿gtk2 o qt5?
4. Toolchain Windows: ¿cross completo desde Linux o build nativo en Windows?
5. Explorador: ¿alcanza con la etapa A o hace falta la DLL COM?
6. Alcance del MVP: ¿solo lectura hasta tener el escritor `.parc`?
7. ¿Se mantiene "Background" o alcanza con Pausa/Cancelar?
