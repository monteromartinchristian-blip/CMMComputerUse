# Cambio requerido en `~/CMM Skills` (repo separado) — prohibición de bypasses

**Estado:** NO aplicado. Ese repositorio no está disponible en esta sesión cloud
(sólo `monteromartinchristian-blip/cmmcomputeruse`). No se mezcla aquí; este
documento describe el cambio para aplicarlo allí.

## Qué se ha hecho en ESTE repo (enforcement, no sólo prompt)

| Capa | Archivo | Efecto |
|---|---|---|
| MCP `instructions` | `packages/dsh-computer-use/adapter/cmm_computer_use/mcp_server.py` (`NO_BYPASS_POLICY`) | Enviado en `initialize`; DSH lo recibe como instrucciones del servidor |
| Cada rechazo | mismo archivo (`NO_BYPASS_LINE`) | Toda respuesta `REFUSED …` termina con la prohibición explícita |
| `AX_TREE_UNAVAILABLE` | mismo archivo (`_render_ax_tree`) | Árbol Electron vacío ⇒ gap explícito + prohibición |
| Guard de herramientas DSH | `packages/dsh-computer-use/index.js` + `runtime.mjs` (`bypassReason`) | **Bloquea** la llamada (no sólo aconseja) en sesiones que ya usaron `computer_use_*` |

El guard es por contenido (no por nombre de herramienta) sobre herramientas que
ejecutan/escriben (`bash|shell|exec|command|terminal|run|script|python|node|swift|write|edit|patch|apply`):
`osascript`, `-l JavaScript`/JXA, `tell application`/`NSAppleScript`/`OSAScript`,
`System Events`, `CGEvent*`/`CGWarpMouseCursorPosition`/`CGDisplayMoveCursorToPoint`,
`AXUIElement*`/`AXManualAccessibility`/`AXEnhancedUserInterface`/`kAX…Action`,
`import Quartz|ApplicationServices|AppKit`/`atomacos`/`pyautogui`/`pynput`,
`cliclick`/`xdotool`/`hs -c`/`skhd`, `open -a|-b`.

Limitación conocida: depende de que DSH pase los argumentos de la llamada en
`exec.arguments|args|input|params`. Si la versión instalada de DSH no los pasa,
el guard no puede ver el contenido y **no bloquea** (falla abierto para no
romper herramientas ajenas). Verificarlo en LIVE (paso 8 del script E2E sólo
prueba la función pura; hay que comprobar con DSH real que un `bash osascript …`
en una sesión con Computer Use se rechaza).

## Cambio a aplicar en `~/CMM Skills`

Localizar el skill/prompt de Computer Use que el agente DSH carga (buscar
`computer_use_`, `Computer Use`, `CGEvent`, `osascript`, `Swift` en el repo).
Sustituir/añadir esta sección, sin suavizarla:

```markdown
## Límite duro: sólo computer_use_*

Para observar u operar ventanas de otras aplicaciones, la ÚNICA vía permitida
son las herramientas `computer_use_*` de CMM Computer Use.

Si una herramienta `computer_use_*`:
- rechaza (`REFUSED …`), o
- devuelve `CAPABILITY_UNSUPPORTED`, `AX_TREE_UNAVAILABLE` o `INTERFERENCE_BREACH`, o
- simplemente no ofrece lo que necesitas (p. ej. scroll en un área sin barra),

entonces PARA y dile a la persona qué falta y por qué. **Prohibido** sustituirla con:
Bash, osascript, AppleScript, JXA, System Events, scripts Swift/Python,
CGEvent/Quartz, mover o "warpear" el cursor, cliclick, `open -a`, o cualquier
otra herramienta de accesibilidad o automatización.

Motivo: esas rutas saltan la allowlist de CMM Console, pueden robar el foco y
el cursor, y son invisibles para el ledger de interferencia. Tras un
`INTERFERENCE_BREACH` no se reintenta nada: se informa.

No pulses controles de ventana (cerrar, minimizar, zoom, pantalla completa): en
modo background el helper los rechaza porque traen la ventana al frente.
```

Si el skill contiene ejemplos o "trucos" con `osascript`, `swift -e`, CGEvent o
manipulación de `AXManualAccessibility`/`AXEnhancedUserInterface` desde
procesos auxiliares, eliminarlos: la materialización del árbol Electron la hace
ahora el helper firmado (`ax_enrichment` en la observación).

## Verificación tras aplicarlo

1. Sesión DSH con Computer Use activo; pedir algo que requiera scroll en Claude.
2. Esperado: `computer_use_scroll` → éxito o `CAPABILITY_UNSUPPORTED`; el agente
   informa y **no** intenta Bash/Swift. Si lo intenta, el guard lo rechaza con
   `CMM: … is not an allowed route in a Computer Use session`.
