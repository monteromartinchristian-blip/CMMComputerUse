# LIVE aislado — procedimiento (2026-11-02)

Segunda instancia del helper, lanzada por LaunchServices desde una **copia**
del build staged firmado (`build/stage-20261102/CMMComputerUse.app`, 0.3.0 b3,
Apple Development `7NH822RKEQ`), sirviendo un socket y una política temporales.
Producción no se instala, no se edita y no se reinicia.

Orquestador: `scripts/verification/isolated-live.py` (+ `isolated_live_lib.py`,
probe `scripts/verification/rearm-probe/main.swift`).

## Qué queda dónde

| Cosa | Ubicación |
|---|---|
| Directorio del carril | `/tmp/cmm-cu-isolated-XXXX` (0700, marcador `.cmm-isolated-live`) |
| Copia del helper | `<lane>/CMMComputerUse.app` (`ditto` del staged; firma verificada) |
| Socket / política / latch / auditoría / log | `<lane>/bridge.sock`, `policy.json`, `breach-latch.json`, `breach-audit.jsonl`, `helper.log` |
| Probe firmado | `<lane>/rearm-probe`, identificador `com.cmm.computer-use.test-rearm` |
| Fixture, monitor, informe e2e | `<lane>/tcc-fixture/…`, `<lane>/e2e/…` |
| Evidencia que se conserva | `build/isolated-live-evidence/<lane>/` (gitignored) |

`assert_isolated` rechaza cualquier ruta que sea o contenga
`~/.cmm/computer-bridge`, su `policy.json`/`bridge.sock`,
`~/Library/LaunchAgents`, `~/Applications/CMMComputerUse.app` o el propio HOME.
El probe se niega a hablar con un socket fuera de un directorio con el
marcador, y con el socket de producción en cualquier caso.

## Antes de empezar

- Cierra DeepSeek Harness (o al menos no uses Computer Use): el diff final de
  producción compara también el log del helper de producción; si DSH lo usa
  durante la prueba, el diff lo marcará (correctamente) como cambio.
- No toques ratón ni apps mientras corre `live`.
- Requiere `swiftc` (Xcode CLT) y una identidad *Apple Development*.

## Ejecución

Todo seguido (siempre desmonta y verifica producción al final, falle lo que falle):

```bash
cd ~/"CMM Desarrollo/CMM Computer Use"
python3 scripts/verification/isolated-live.py all \
  --staged-app build/stage-20261102/CMMComputerUse.app \
  --electron-app com.anthropic.claudefordesktop
```

Sin LIVE ni breach (sólo aislamiento + TCC + autoridad de rearm), recomendado
como primer pase:

```bash
python3 scripts/verification/isolated-live.py all --no-live \
  --staged-app build/stage-20261102/CMMComputerUse.app
```

Por fases (para revisar entre una y otra; `<lane>` lo imprime `prepare`):

```bash
python3 scripts/verification/isolated-live.py prepare --staged-app build/stage-20261102/CMMComputerUse.app --electron-app com.anthropic.claudefordesktop
python3 scripts/verification/isolated-live.py start        --work <lane>
python3 scripts/verification/isolated-live.py verify-tcc   --work <lane>
python3 scripts/verification/isolated-live.py rearm-tests  --work <lane>
python3 scripts/verification/isolated-live.py live         --work <lane>   # breach controlado = último paso
python3 scripts/verification/isolated-live.py after-breach --work <lane> [--confirm-control]
python3 scripts/verification/isolated-live.py teardown     --work <lane>
python3 scripts/verification/isolated-live.py verify-production --evidence build/isolated-live-evidence/<basename de lane>
```

Usa el mismo `python3` en todas las fases: la política temporal fija la
identidad de código (cdhash) del intérprete que actúa como agente.

## Fases y puertas

1. **prepare** — instantánea de producción → `production-before.json`.
   Copia el helper staged y verifica que su *designated requirement* es
   **idéntico** al del helper instalado (TCC lo usa como clave; si difieren se
   para aquí). Compila el probe, lo firma con tu identidad Apple Development e
   `--identifier com.cmm.computer-use.test-rearm`, y genera su requirement
   exacto: `identifier … and anchor apple generic and certificate
   leaf[subject.OU] = "<TEAM>" and cdhash H"<cdhash>"` (sin comodines). Siembra
   el latch con dos breaches de apps ficticias: uno causado por `test-rearm`
   (self) y otro por `live-agent`.
2. **start** — `open -n -g -a <lane>/CMMComputerUse.app --args --serve-socket
   <lane>/bridge.sock --policy background --policy-file <lane>/policy.json
   --log-file <lane>/helper.log --no-permission-bootstrap`. Exactamente una
   instancia en ese socket. Identifica al intérprete conductor, compone su
   requirement exacto y valida **ambos** con `policy.requirements.check`:
   el del driver casa con el peer; el del probe casa con el binario firmado y
   NO con el driver. Política completa (probe sin apps, sin scopes, sin admin;
   driver sin admin), `policy.reload`, ambos `requirement_valid`.
3. **verify-tcc** — ver "Cómo se demuestra TCC" abajo.
4. **rearm-tests** — el probe rechaza en local `apps.list`, `observe`, rearm sin
   motivo y con motivo en blanco, y el socket de producción. Luego, contra el
   helper: (7a) sin `admin` → `rearm_not_granted;client=test-rearm` (y el
   agente → `rearm_not_granted;client=live-agent`); (7b) con `admin` →
   breach propio → `self_rearm_not_permitted`; (7c) rearm del otro con motivo →
   `rearmed`. Auditoría: un `rearmed` con `actor_client_id=test-rearm`,
   `actor_signing_id=com.cmm.computer-use.test-rearm` y el motivo, y ≥3
   `rearm_refused`.
5. **live** — sólo si 3 y 4 pasaron. Gates actualizados (2026-11-02, tras el
   primer LIVE): el scroll del fixture debe estar verificado por el helper
   (`effect=moved`) y por el `scroll_y` del fixture; Claude se juzga por
   `electron_observe_readable` (observe-only), y `actionable` es sólo
   diagnóstico — el control real de Claude sigue sin demostrar; cualquier
   movimiento de cursor sigue haciendo FAIL y se diagnostica por paso.
   Ventana del testigo: tras cada paso quiet el runner espera una cola real de
   `TAIL`=1,5 s antes del siguiente paso (no se recorta la ventana), y el gate
   `witness_windows_disjoint` exige que ninguna llamada posterior empiece
   dentro de esa cola; si ocurre, se imprime `witness_window_overlap`. Así el
   breach deliberado (quiet=False) ya no cae en la ventana de `9b observe`.
   El frontmost inicial de la persona se toma de `lsappinfo` (ASN de `front`),
   y si sale vacío del testigo o del helper, indicando la fuente. `live-background-e2e.sh --electron-app …
   --breach-control` contra el socket aislado: status, observe, nombre en
   PiP, botón de ventana rechazado, press sin robo de foco, scroll, Electron
   (sólo observe), guard anti-bypass y, **al final**, el breach controlado del
   fixture (`INTERFERENCE_BREACH`, latch en helper y DSH, testigo
   independiente lo ve, sin `focus_restore`).
6. **after-breach** — en `all` se ejecuta SIEMPRE tras `live`, aunque algún
   check de `live` haya fallado (el fallo de `live` sigue siendo el resultado
   final), y siempre con `--confirm-control`. Al final se imprime un resumen
   por fase. El breach real está latcheado a nombre de `live-agent`;
   reinicio de la instancia aislada → **sigue latcheado**; el agente no puede
   rearmarlo; el probe lo rearma con motivo. `--confirm-control` añade un press
   del fixture para demostrar que el control vuelve.
7. **teardown** — mata sólo procesos cuyo ejecutable está dentro del carril
   (comprobado con `proc_pidpath` antes de cada señal), borra el socket,
   `lsregister -u` de cada `.app` temporal, copia la evidencia y borra el carril.
8. **verify-production** — ver abajo.

## Cómo se demuestra que la instancia temporal tiene los TCC actuales

No se puede leer `TCC.db` sin Full Disk Access, así que la demostración es
por equivalencia de identidad + funcionamiento real:

1. **Misma clave TCC**: el *designated requirement* de la copia es
   byte a byte el del helper instalado (`codesign -d -r-`), y el bundle id es
   `com.cmm.chat.computer-use`. TCC concede por bundle id + requirement, no por ruta.
2. **Proceso atribuido a la app**: la imagen en ejecución (`proc_pidpath`) es la
   copia del carril; `ppid = 1` (lanzada por launchd vía LaunchServices, no por
   el shell); `lsappinfo` registra ese pid con `com.cmm.chat.computer-use` y la
   ruta de la copia; el cdhash en ejecución es el del build staged.
3. **Flags**: `permissions.status` de la instancia → `accessibility=True`,
   `screen_recording=True` (consultas que no muestran diálogos; la instancia
   corre con `--no-permission-bootstrap`).
4. **Funcional**: Accessibility — observar el fixture devuelve su árbol
   (≥3 elementos, `Incrementar`); Screen Recording — `capture_window` del
   fixture devuelve una imagen por ScreenCaptureKit (que es justo lo que falla
   si la atribución "responsible" se pierde).

Si cualquiera falla, la puerta se cierra antes de rearm-tests y del LIVE.

## Cómo se demuestra que producción no cambió

`verify-production` vuelve a tomar la instancia y la compara campo a campo con
la de `prepare` (`production-diff.txt` vacío = PASS):

- `~/.cmm/computer-bridge/` completo: por fichero sha256, tamaño, modo y mtime;
  el socket por tipo, inodo, modo y mtime; incluye `policy.json` y el log.
- `~/Library/LaunchAgents/com.cmm.chat.computer-use.plist`: sha256, modo, mtime.
- `~/Applications/CMMComputerUse.app`: sha256 de **cada** fichero del bundle y
  su firma (identificador, team, cdhash).
- `launchctl print gui/<uid>/com.cmm.chat.computer-use`: estado, pid, programa,
  argumentos.
- Procesos del helper de producción (los que sirven el socket de producción):
  pid y hora de arranque.
- Registros de LaunchServices para `com.cmm.chat.computer-use`, con su propia
  puerta (no entran en el diff estricto): la ruta canónica
  `~/Applications/CMMComputerUse.app` debe estar registrada antes y después;
  ninguna ruta `/private/tmp/cmm-cu-isolated-*` puede sobrevivir; los builds no
  productivos (`<repo>/build/stage-*`, DerivedData) que aparecen o desaparecen
  son deriva diagnóstica (`DIAG`), no fallo; cualquier otra ruta que cambie
  sí es fallo. Las listas completas ANTES/DESPUÉS, fallos y deriva quedan en
  `launchservices-audit.json`. El orquestador no desregistra builds para
  hacer pasar el diff: sólo desregistra los `.app` del propio carril.

Límites: TCC no es legible (se apoya en que el carril no llama a `tccutil` ni
pide permisos, y lo fija un test sobre el código del orquestador); y
`AXManualAccessibility` puede quedar activado en Claude si se usa
`--electron-app` (efecto en la app, no en la configuración de producción).


## Prueba aislada de control real de Claude Desktop (2026-11-02)

Objetivo: demostrar una acción **reversible y no destructiva** sobre Claude en
background, sólo por `computer_use_*`: poner un texto de prueba en el composer
**sin enviarlo**, verificarlo, y restaurarlo. Nunca se pulsa nada (ni Enter ni
botones), nunca controles de ventana.

Preparación en el Mac:

- Claude Desktop abierto en **un chat nuevo con el composer vacío** (si el
  composer tiene texto, la prueba no lo toca: `composer_not_empty`).
- Terminal (o DSH) en primer plano; no toques ratón ni teclado.
- Build staged del HEAD actual (`build/stage-…`), como en las fases previas.

```bash
python3 scripts/verification/isolated-live.py all \
  --staged-app build/stage-<fecha>/CMMComputerUse.app \
  --electron-app com.anthropic.claudefordesktop --electron-control
```

`--electron-control` concede `control` a Claude **sólo en la política temporal
del carril**. Pasos E1–E5 (todos quiet; el testigo los juzga contra Claude):

1. E1 observe con `ax_diagnostics`: `ax_enrichment` (trigger, access
   antes→después), `ax_walk`, escaneo profundo antes/después.
2. Selección: el primer `AXTextArea` settable (si no, un campo settable), el
   más bajo en pantalla. Ninguno → `control_unproven: no_settable_text_input`.
3. E2 `set_value` de `CMM-CU control test - not sent <ts>`: el helper debe
   devolver `set_value: check=verified` y `verdict=untouched`.
4. E3 re-observe: el mismo control (por geometría) contiene el texto.
5. E4 `set_value ""`: verificado y untouched. E5 re-observe: vacío.

Si cualquier paso eleva o activa Claude → `INTERFERENCE_BREACH`, latch y STOP
(sin reintentar ni restaurar). Gates de seguridad: `electron_control_no_breach`
y, si el texto llegó a ponerse, `electron_control_restored` (si falla, el
script avisa: hay que borrar el texto a mano).

Resultado en `claims` (no deciden PASS/FAIL; un "unproven" honesto es válido):

| claim | significa |
|---|---|
| `observe_proven` | la ventana es legible (gate observe-only) |
| `actionable` | el helper informa un control real tras el enriquecimiento |
| `control_proven` | set verificado por helper Y por re-observación, Y restaurado y re-observado |
| `background_noninterference_proven` | E1–E5: testigo quiet (sin activar, sin elevar, cursor ≤ 0,5) + ledger untouched + sin breach |
| `control_unproven_reason` | `no_settable_text_input`, `composer_not_empty`, `value_not_settable`, `set_not_verified`, `breach_stop`, `not_restored`, … |

Qué traer: el bloque `claims`, las líneas `ax_enrichment` y `ax_walk` de E1, las
líneas `ax_diagnostics before/after` con sus candidatos, y las líneas
`set_value:` de E2/E4.


## Control de Claude por AXPress (sustituye al composer como prueba principal)

LIVE de `65a7145`: tras el nuevo recorrido Claude es `actionable` (61
controles, 162 candidatos en el escaneo profundo) pero no expone ningún campo
de texto settable (`text_inputs=[]`), así que la prueba del composer no llegó a
ejecutarse. La prueba de control pasa a ser **AXPress reversible**; el composer
queda como diagnóstico opcional (`--electron-composer-test`).

```bash
python3 scripts/verification/isolated-live.py all \
  --staged-app build/stage-<fecha>/CMMComputerUse.app \
  --electron-app com.anthropic.claudefordesktop --electron-control
```

0. **Precondición de entorno** antes del primer paso Claude: durante una
   ventana completa de `TAIL` el testigo debe ver `--person-app`
   (por defecto `com.apple.Terminal`) en primer plano, cursor quieto y muestras
   suficientes; hasta 3 intentos. Si no: `environment_not_quiet` (motivo
   concreto: `frontmost_not_person`, `cursor_moving`,
   `witness_samples_insufficient`), el check
   `electron_control_environment_quiet` falla y **Claude no se opera**.
   Cierra notificaciones antes de empezar (el run anterior tenía
   `com.apple.UserNotificationCenter` delante).
1. P1: observe de Claude y búsqueda con `filter` `Ajustes` / `Settings` /
   `Configuración`. Sólo se acepta **un** elemento pulsable, que no sea control
   de ventana, cuyo título sea exactamente esa etiqueta (o, si no hay exacto,
   la contenga como palabra y sea único). Varios → `ambiguous`, no se pulsa.
2. P2: `computer_use_press`. P3: re-observe; se exige evidencia AX de Ajustes:
   ≥ 2 marcadores nuevos (General, Cuenta, Privacidad, Apariencia, …) o el
   título de ventana.
3. P4–P6 (opcional): una pestaña interna (`Cuenta`/`Account`, si no
   `General`), pulsada y re-observada: el panel debe cambiar (≥ 3 líneas).
4. P7–P9 (opcional): `Cerrar`/`Close` dentro de la ventana (nunca el botón de
   ventana) para volver a dejarla como estaba; si no existe, Ajustes queda
   abierto y se informa.

Nunca se pulsa un interruptor o preferencia: sólo navegación. Todo es quiet y
el testigo lo juzga contra Claude. Un AXPress que eleve Claude →
`INTERFERENCE_BREACH`, latch, STOP.

Claims: `observe_proven`, `actionable`, `press_control_proven`,
`set_value_control_proven`, `control_proven` (= press OR set_value),
`background_noninterference_proven` (precondición OK + testigo quiet + ledger
untouched + sin breach), `control_unproven_reason`.

Qué traer: `claims`, `electron_environment`, `electron_press_control`
(elemento elegido, `settings_evidence`, `navigation`, `closed`, cada press con
`untouched`) y cualquier `INTERFERENCE_BREACH` / `witness_window_overlap` /
`CURSOR`.


## Gates A/B — atribución del foco (helper 0.3.1 build 4)

Build staged nuevo (0.3.1 / 4) y carril aislado como siempre. Cierra
notificaciones; Terminal delante.

```bash
cd ~/"CMM Desarrollo/CMM Computer Use"
CMM_HELPER_BUILD_DIR="$PWD/build/stage-0.3.1" scripts/build-helper.sh
codesign -dv --verbose=4 build/stage-0.3.1/CMMComputerUse.app 2>&1 | grep -E "Identifier|CDHash|TeamIdentifier"
python3 scripts/verification/isolated-live.py all --human-takeover \
  --staged-app build/stage-0.3.1/CMMComputerUse.app
```

- **Gate B (interactivo, antes del LIVE):** el script cuenta 3‑2‑1 y escribe
  `CLICK NOW`; entonces haz **un clic real** con el ratón dentro de la ventana
  «CMM Computer Use Fixture» (no en un botón). Nadie simula input. La acción
  en curso (`press` de «Incrementar») no activa nada, así que si el fixture
  pasa al frente, fuiste tú. Exige: `focus_became_target`, testigo HID
  `available`, `attribution=user` (o `ambiguous_external`), `external_activity`,
  **sin** `INTERFERENCE_BREACH`, `USER_TAKEOVER` informado, **sin latch** ni
  entrada `latched` en la auditoría, el snapshot anterior rechazado
  (`reason=expired`) y control de nuevo tras observar (sin rearm). Hasta 3
  intentos si el clic cae fuera de la ventana de medida. Al terminar, vuelve
  a hacer clic en Terminal.
- **Gate A (último paso del LIVE, sin tocar nada):** el fixture se autoactiva
  400 ms después del press; sin input humano debe seguir siendo
  `attribution=action`, `INTERFERENCE_BREACH`, latch persistente
  (`--breach-control`, como hasta ahora).

Qué traer: las líneas `attribution:` y `USER_TAKEOVER:` de Gate B, el
resumen `human_takeover` (B1–B10), la línea `attribution:` del breach de
Gate A, y el CDHash del staged. Verifica también que en Gate B el testigo
salió `available` sin conceder ningún permiso nuevo (si macOS pidiera
Input Monitoring, para y avisa).
