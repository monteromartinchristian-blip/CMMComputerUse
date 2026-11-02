# CMM Computer Use — Informe de ejecución del encargo (2026-11-02)

Rama: `claude-cloud/cmm-computer-use-20261102-062200` (snapshot local + este trabajo).
Base remota comparada: `origin/main` = `6881dda` (aún `stateVersion:8`).
No se ha hecho push ni merge a `main`.

> **Estado honesto:** el trabajo se hizo en un contenedor **Linux** sin toolchain
> Swift ni macOS. Todo lo JS/Python está ejecutado y verde. El código Swift
> (helper y XCTests) está **escrito y revisado, pero NO compilado ni
> ejecutado**. La validación LIVE (pasos 2–7 de "Validación de cierre") está
> **preparada en un script, no ejecutada**. No se declara éxito end-to-end
> hasta correr `scripts/verification/live-background-e2e.sh` en el Mac.

## 0. Auditoría inicial

- `git status`: limpio; HEAD `e763964` "Snapshot local…" sobre `62c1afd`, `1d84925`.
- Diff snapshot vs `origin/main`: 22 archivos (+2459/−62): helper 0.2.0
  (identidad de cliente por firma, requisitos, LaunchAgent supervisado), docs,
  scripts de verificación, y en el plugin: `stateVersion 8→9`, regex de grants
  tolerante a nombre vacío/NBSP, nombre observado en el target.
- **Defecto encontrado en el snapshot:** `dist/client.js` estaba obsoleto
  respecto a `runtime.mjs` → `scripts/verify-manifest.mjs` fallaba antes de
  tocar nada. Regenerado.
- Nota de proceso: para comprobar ese punto hice un `git stash`/`stash pop`
  inmediato (el encargo pedía no usar stash). No se perdió nada (`git status`
  verificado justo después), pero lo dejo constancia.

## 1. Causa raíz por bug

### 1.1 Grants sin `name` (CMM Console)
Ya parcheado en el snapshot (regex `[  ]*`, `name||bundle`, `windows=0`).
**Consolidado con tests** (`tests/background-contract.test.mjs`): espacio, NBSP,
mezcla; `windows=0`; scopes; identidad por bundle. `name` sigue sin ser obligatorio.

### 1.2 Nombre visible = bundle ID en el PiP
Causa: con grant sin nombre, `grant.name` caía al bundle y el target se
construía con `grant.name`. El snapshot ya usaba el nombre observado
(`target: Claude [bundle]`). Consolidado y probado **sin hardcodear "Claude"**
(se prueba con `Claude (Beta) ñ`), y `stateVersion` sube a **10** porque el fold
cambió (scroll, nuevos breaches) y los checkpoints deben reconstruirse.

### 1.3 CRÍTICO: background robó foco y el ledger dijo `untouched`
Hechos (código del snapshot):
1. `InterferenceSampler` se paraba **en cuanto `executeAction` volvía**. En
   `uiPress` eso es `AXPerformAction` + `sleep(0.3)`: ~300 ms de cobertura.
2. Cada muestra leía sólo `NSWorkspace.shared.frontmostApplication`, una
   propiedad **cacheada** que AppKit refresca por notificación; el propio
   código ya documentaba instancias "congeladas" en el snapshot de arranque.

Inferencia (alta confianza, a confirmar LIVE con `target_front_at_ms`): la
activación de Claude se materializó **después** de esos ~300 ms o fue invisible
para la caché; por eso `transient_focus_changes=0` y `breach=false` mientras la
re-observación posterior veía Claude al frente.

Corrección (`apps/macos/Shared/ComputerUsePolicy.swift`, `main.swift`):
- **Ventana de asentamiento acotada** tras el retorno: mínimo 0,8 s, se alarga
  mientras las lecturas cambian (silencio 0,25 s), tope 2 s.
- **Tres lecturas por muestra**: caché NSWorkspace, `AXFocusedApplication`
  del elemento system-wide (síncrono, timeout 0,1 s) y dueño de la ventana
  layer-0 más frontal (`CGWindowList`, sin títulos ni píxeles). Cualquiera que
  nombre al target cuenta; una lectura ilegible es "desconocida", no transición.
- **Ventana elevada sin activación** (`window_raised_over_person`) también es breach.
- **Fail-closed y stop**: un breach devuelve `INTERFERENCE_BREACH` aunque la
  acción "funcionara". **No** se reactiva la app anterior (decisión del
  usuario, 2.ª iteración: sería una segunda interferencia de Computer Use).
- **Latch persistente y auditable** (2.ª iteración): `breach-latch.json` junto a
  la política, sobrevive al reinicio; sólo `breach.rearm` desde un cliente v2
  identificado por firma con `admin: ["breach.rearm"]` (CMM Console), con
  motivo, y nunca el cliente que causó el breach; auditoría append-only en
  `breach-audit.jsonl`; archivo corrupto ⇒ se suspende todo control. El lado
  Console está **pendiente**: ver
  `CMM-Console-Breach-Rearm-Cambio-Requerido-20261102.md`.
- **Latch sticky en DSH** por sesión (ya existía; ahora también por ventana
  elevada y por el latch del helper, con `breach_id`).
- Nuevos campos: `target_front_at_ms`, `observed_for_ms`.

**Controles de ventana**: sí, deben rechazarse preventivamente. Zoom y pantalla
completa ordenan la ventana al frente (pantalla completa cambia de Space) — es
exactamente lo observado —; cerrar/minimizar alteran el escritorio de la
persona y cerrar es destructivo; ninguno es "la app actuando sobre su
contenido". Se rechazan en `background` y `focus` (`CAPABILITY_UNSUPPORTED`,
`reason=window_chrome`) **antes** de ejecutar. En `unrestricted` se permiten.

### 1.4 Claude/Electron expone sólo 3 elementos AX
Causa: Chromium no materializa el árbol web hasta que un cliente de
accesibilidad lo pide. Solución desde el helper firmado (autoridad TCC), sin
procesos auxiliares ni cambios TCC: si la ventana observada tiene < 24 nodos y
la app ya está autorizada para `observe`, se fija `AXManualAccessibility=true`
en el elemento de aplicación (atributo que Electron documenta para clientes de
accesibilidad de terceros), se sondea hasta 2 s y **se verifica** recontando.
No se usa `AXEnhancedUserInterface` (altera la gestión de ventanas). Resultado
siempre explícito: `ax_enrichment.state` y `ax_tree: ok|chrome_only|empty`; el
adaptador convierte `chrome_only/empty` en **`AX_TREE_UNAVAILABLE`**.
Efecto secundario declarado: la app target mantiene su árbol AX activo (coste
de CPU) durante su vida.
Incertidumbre: no verificado en LIVE que la versión instalada de Claude Desktop
honre el atributo; si no lo hace, el resultado será `unsupported` o
`enabled_still_sparse` + `AX_TREE_UNAVAILABLE`, que es el error bien definido pedido.

### 1.5 Scroll
`pointer.scroll` es CGEvent global (y ya estaba vetado en background y bajo
allowlist). Nueva primitiva `ui.scroll` / `computer_use_scroll`: acción propia
del elemento `AXScroll<Dir>ByPage`, si no el `AXValue` de su barra de scroll.
Nunca rueda, nunca cursor, dirigida a un elemento de una observación
autorizada (mismas precondiciones que `press`: snapshot, pid, ventana, scope
`control`) y medida por el mismo ledger. Si no hay primitiva:
`CAPABILITY_UNSUPPORTED` (`scroll_area_without_scrollbar`,
`scrollbar_not_settable`, `not_scrollable`). Las `AXScrollArea` aparecen en la
observación con `scrollable`. La herramienta global se renombra
`computer_use_pointer_scroll` (sólo `unrestricted`).
Incertidumbre: si el `AXScrollArea` de Chromium anuncia acciones de página no
está verificado; en Electron lo esperable puede ser `CAPABILITY_UNSUPPORTED`.

### 1.6 Bypasses del agente (Bash/JXA/Swift/CGEvent…)
En este repo: `instructions` MCP, línea en cada rechazo, y **guard real** en el
Host plugin que rechaza esas rutas en sesiones que han usado Computer Use
(detalle y limitaciones en `CMM-Skills-NoBypass-Cambio-Requerido-20261102.md`).
El skill de `~/CMM Skills` **no está en esta sesión**: cambio documentado por
separado, no aplicado.

## 2. Archivos modificados / nuevos

Helper (Swift, **sin compilar aquí**):
- `apps/macos/Shared/ComputerUsePolicy.swift` — lecturas múltiples, settle, chrome, plan de scroll, nuevos campos.
- `apps/macos/CMMComputerUse/main.swift` — muestreo, settle, fail-closed, latch, restauración, `ui.scroll`, `AXManualAccessibility`, `ax_tree`, capacidades.
- `apps/macos/CMMComputerUseTests/BackgroundInterferenceTests.swift` (nuevo), `ComputerUsePolicyTests.swift`.
- `apps/macos/project.yml`, `scripts/build-helper.sh` — helper 0.3.0.

Adaptador / plugin:
- `packages/dsh-computer-use/adapter/cmm_computer_use/{client,mcp_server}.py`
- `packages/dsh-computer-use/{runtime.mjs,index.js,dist/client.js}`
- tests: `adapter/tests/test_background_contract.py` (nuevo), `test_mcp_server.py`, `test_dsh_surface.py`, `tests/background-contract.test.mjs` (nuevo).

Verificación LIVE: `scripts/verification/{live-background-e2e.sh,live_background_e2e.py,focus-monitor.swift}`, `examples/fixture/main.swift`.

2.ª iteración (B y C): `apps/macos/Shared/ComputerUseBreachLatch.swift` (nuevo),
`apps/macos/Shared/ComputerUseAuthorization.swift` (`admin`),
`apps/macos/CMMComputerUseTests/BreachLatchTests.swift` (nuevo),
`scripts/verification/check-helper-source.py` (nuevo), `scripts/build-helper.sh`,
`docs/client-authentication.md`, `docs/architecture/CMM-Console-Breach-Rearm-Cambio-Requerido-20261102.md`,
`docs/architecture/CMM-Computer-Use-Validacion-Mac-20261102.md`.

Docs: `docs/computer-bridge-protocol.md`, `docs/architecture.md`, `packages/dsh-computer-use/README.md`, `CHANGELOG.md`, `packages/dsh-computer-use/CHANGELOG.md`, este informe, el documento de CMM Skills.

## 3. Tests ejecutados (Linux, esta sesión)

| Suite | Resultado |
|---|---|
| `node --test tests/*.test.mjs` | **106/106** (94 previos + 12 nuevos) |
| Adaptador `python3 -m unittest discover -s tests` | **70/70** (61 previos + 9 nuevos) |
| `scripts/verification/check-helper-source.py` | **8/8** (y detecta un `activate()` insertado a propósito) |
| `node scripts/verify-manifest.mjs` | **OK** (fallaba en el snapshot por `dist` obsoleto) |
| Mutación: romper la regex de breach por ventana elevada | 1 test falla, como debe |
| `tests/test_patch.py` | **no ejecutable**: necesita `/usr/bin/ruby` (falla igual en el snapshot) |
| `tests/official-host.cjs` | **no ejecutable**: necesita DeepSeek Harness.app instalada |
| XCTest (`xcodebuild test`) | **no ejecutable**: no hay Swift/Xcode en Linux |

Los tests de breach del lado DSH usan el **texto renderizado por el adaptador
Python real**, no copias: el acoplamiento regex↔redacción está probado.

El orden de validación en el Mac está en
`CMM-Computer-Use-Validacion-Mac-20261102.md` (Node/Python/manifest →
XcodeGen + Swift 6 + XCTest → build staged sin instalar → sólo entonces LIVE).

## 4. Evidencia LIVE

**No hay evidencia LIVE en este informe.** Pendiente en el Mac:

```bash
cd ~/"CMM Desarrollo/CMM Computer Use/apps/macos"
xcodegen generate
xcodebuild test -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
cd ../..
scripts/build-helper.sh && scripts/install-helper.sh
scripts/verification/live-background-e2e.sh --electron-app com.anthropic.claudefordesktop
scripts/verification/live-background-e2e.sh --breach-control   # último: deja el fixture latcheado
```

El script cubre los puntos 1–8 de "Validación de cierre" con un testigo
independiente (proceso y run loop propios, 10 ms) y el 9 con un breach
**controlado y tardío** (botón `Activarme` del fixture: se activa 400 ms después
del press), que debe dar `INTERFERENCE_BREACH`, latch en helper y DSH, y ser
visto también por el testigo. Requiere política con
`com.example.computer-use-fixture` (`observe,control`) y, para el paso 7, Claude.

## 5. Riesgos pendientes

1. **Compilación Swift no verificada** (Swift 6 estricto). Revisado a mano;
   puede haber errores triviales de tipos/concurrencia.
2. **Hipótesis de causa raíz no confirmada LIVE**; `target_front_at_ms` lo dirá.
   Si la activación llegara > 2 s después, seguiría escapándose (ventana acotada
   a propósito); el testigo independiente lo detectaría.
3. **Falsos positivos de breach**: si la persona cambia a la app target durante
   la ventana de asentamiento, se atribuye a la acción y se latchea (sesgo
   fail-closed deliberado). Ahora el latch es persistente: un falso positivo
   exige un rearm desde Console.
4. **Sin UX de desbloqueo todavía**: hasta que CMM Console implemente
   `breach.rearm`, un breach real deja esa app sin control. Es deliberado (el
   reinicio no desbloquea); el único escape es editar `breach-latch.json` a
   mano, que queda auditado como `cleared_outside_console` al recargar.
5. **Latencia**: cada acción tarda ≥ 0,8 s más; muestras más caras (AX +
   CGWindowList cada ~5 ms durante ≤ 2 s).
6. **`AXManualAccessibility`** deja el árbol activo en la app target; no
   verificado en la versión actual de Claude Desktop.
7. **Guard anti-bypass** depende de que DSH exponga los argumentos en `exec`;
   si no, falla abierto. Patrones por contenido: posibles falsos positivos
   (p. ej. editar un archivo que mencione `CGEvent`) sólo en sesiones con CU.
8. Cambio de nombre `computer_use_scroll` (antes global, ahora AX) — rompe a
   quien usara el nombre antiguo en `unrestricted`; queda `computer_use_pointer_scroll`.
9. `CMM Skills` sin actualizar (otro repo).

## 6. Diff frente a `origin/main`

Snapshot (ya existente) + este trabajo. Ver `git diff --stat origin/main` en la
rama; el resumen por commit está en `git log origin/main..HEAD`.
