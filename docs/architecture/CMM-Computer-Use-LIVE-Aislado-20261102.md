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
5. **live** — sólo si 3 y 4 pasaron. `live-background-e2e.sh --electron-app …
   --breach-control` contra el socket aislado: status, observe, nombre en
   PiP, botón de ventana rechazado, press sin robo de foco, scroll, Electron
   (sólo observe), guard anti-bypass y, **al final**, el breach controlado del
   fixture (`INTERFERENCE_BREACH`, latch en helper y DSH, testigo
   independiente lo ve, sin `focus_restore`).
6. **after-breach** — el breach real está latcheado a nombre de `live-agent`;
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
- Registros de LaunchServices para `com.cmm.chat.computer-use` (rutas).

Límites: TCC no es legible (se apoya en que el carril no llama a `tccutil` ni
pide permisos, y lo fija un test sobre el código del orquestador); y
`AXManualAccessibility` puede quedar activado en Claude si se usa
`--electron-app` (efecto en la app, no en la configuración de producción).
