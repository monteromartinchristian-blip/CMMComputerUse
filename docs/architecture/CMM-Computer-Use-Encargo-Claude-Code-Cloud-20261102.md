# CMM Computer Use — Encargo para Claude Code Cloud

## Base de trabajo

Trabaja sobre la rama snapshot publicada desde el checkout local:

`~/CMM Desarrollo/CMM Computer Use`

NO asumas que `main` contiene los cambios más recientes. El `main` remoto verificado antes de publicar estaba en:

`6881dda8fe074f9d5ac2cff5ebbeb898881b9e74`

y aún tenía `packages/dsh-computer-use/index.js` con `stateVersion:8`.

La rama snapshot debe contener los parches locales posteriores, incluidos los aplicados el 2026-11-02.

Antes de modificar nada:

1. inspecciona `git status`, branch, HEAD y diff contra `origin/main`;
2. identifica todos los cambios locales incluidos en el snapshot;
3. no hagas reset, restore, clean, stash ni reescribas historial;
4. no borres ni reviertas cambios sólo porque no estén en `main`;
5. no hagas merge/push a `main` sin autorización del usuario.

## Objetivo

Dejar **CMM Computer Use realmente funcional y coherente en DeepSeek Harness**, no sólo pasando tests aislados.

El producto debe mantener estas garantías en modo `background`:

- no robar foco;
- no activar/elevar la app target;
- no mover el cursor;
- no usar teclado global;
- no fabricar bypasses con Bash/JXA/AppleScript/Swift/CGEvent/System Events;
- default deny y allowlist gestionada por CMM Console;
- identidad técnica por bundle ID;
- UI humana con nombre de app, no bundle ID.

## Estado y bugs observados

### 1. Grants de CMM Console sin `name`

La policy real puede producir:

`- authorized:  [com.anthropic.claudefordesktop] scopes=control,observe windows=0`

Eso es válido.

El runtime local ya fue parcheado para:

- aceptar nombre vacío;
- aceptar NBSP;
- interpretar `windows=0` como “cualquier ventana”;
- usar bundle ID como identidad técnica.

Verifica que esta semántica quede consolidada con tests.

### 2. Nombre visible incorrecto

El PiP llegó a mostrar:

`com.anthropic.claudefordesktop`

cuando debe mostrar:

`Claude`

El runtime local fue parcheado para usar el nombre observado:

`target: Claude [com.anthropic.claudefordesktop] (background)`

y conservar el bundle sólo como identidad.

También se incrementó la `stateVersion` local de 8 a 9 para invalidar checkpoints antiguos y reconstruir la proyección desde el log.

Consolida esto correctamente, sin hardcodear “Claude”.

### 3. BUG CRÍTICO: background roba foco pero el ledger dice que no

Prueba real únicamente con `computer_use_*`:

- antes del press: frontmost = DeepSeek Harness;
- target = Claude;
- `effective_mode = background`;
- `ui.press` sobre el botón verde de la ventana;
- helper reportó:
  - `verdict=untouched`
  - `focus_became_target=False`
  - `transient_focus_changes=0`
  - `breach=False`
- re-observación posterior:
  - frontmost = Claude.

Esto viola el contrato de `background` y además el ledger no lo detecta.

Investiga la causa real.

Hipótesis a validar:
`AXUIElementPerformAction(AXPress)` puede devolver antes de que WindowServer/AppKit materialice el cambio de frontmost; el helper deja de muestrear demasiado pronto.

Requisitos:

- medir una ventana post-acción acotada;
- detectar si el target llega a ser frontmost;
- `focus_became_target=true`;
- `breach=true` cuando el modo prometía no interferencia;
- fail-closed;
- sticky breach en DSH;
- tests unitarios y LIVE controlado.

Además, determina si controles de chrome de ventana como cerrar/minimizar/zoom/fullscreen deben rechazarse preventivamente en `background` si son intrínsecamente activadores.

### 4. Claude/Electron inicialmente expone sólo 3 elementos AX

La observación oficial devolvió únicamente:

- cerrar;
- ampliar/zoom;
- minimizar.

Sin embargo, durante investigación manual se consiguió posteriormente un árbol AX mucho más completo al manipular accesibilidad de Electron.

No queremos depender de procesos auxiliares.

Investiga una solución correcta desde el helper firmado CMM Computer Use:

- el helper es la autoridad TCC;
- target ya autorizado por policy;
- no Bash/JXA/AppleScript/Swift temporal;
- no cambiar TCC global;
- si existe un mecanismo Electron/AX para materializar el árbol, hacerlo desde el helper y verificar resultado;
- si no puede hacerse de forma segura, devolver error/capability explícito.

### 5. Scroll

Electron puede exponer `AXScrollArea` sin `AXScrollBar`.

El agente intentó crear un Swift con CGEvent/warp de cursor. Esto NO es aceptable en background.

Evalúa una primitiva oficial:

`computer_use_scroll`

Sólo si puede ser:

- dirigida a target/ventana autorizada;
- sin mover cursor;
- sin input global;
- coherente con `background`.

Si no existe implementación segura:
`CAPABILITY_UNSUPPORTED`.

### 6. Prohibir bypasses del agente

Cuando falte una capacidad de `computer_use_*`, DSH no debe intentar arreglarla con:

- Bash;
- JXA;
- AppleScript;
- Swift;
- CGEvent;
- System Events;
- herramientas AX externas.

Localiza el skill/prompt/tool description que controla este comportamiento.

Si está en otro repo (p. ej. `~/CMM Skills`), no mezcles repos silenciosamente: documenta el cambio requerido por separado.

## CMM Console / policy

No romper:

- `default=deny`;
- allowlist por bundle ID;
- `windows=None` / `windows=0` = cualquier ventana;
- scopes `observe` / `control`;
- identidad de cliente verificada;
- rechazo de procesos sin identidad.

No hagas obligatorio `name`.

## Validación de cierre

No declarar éxito sólo porque “carga el plugin”.

Quiero pruebas de extremo a extremo:

1. `status`;
2. `observe`;
3. PiP con nombre humano correcto;
4. una acción `press` que no robe foco;
5. comprobación independiente de frontmost y cursor durante + después;
6. árbol AX útil en Claude/Electron o error explícito bien definido;
7. scroll seguro o `CAPABILITY_UNSUPPORTED`;
8. ninguna ruta alternativa con Bash/JXA/Swift/CGEvent;
9. suite completa verde;
10. informe final con:
   - causa raíz de cada bug;
   - archivos modificados;
   - tests;
   - evidencia LIVE;
   - riesgos pendientes;
   - diff frente a `origin/main`.

No hagas push/merge a `main` hasta autorización expresa del usuario.
