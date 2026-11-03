# CMM Computer Use 0.3.3 — Informe final del encargo (Multi-App Workspace, arquitectura C)

Fecha: 2026-11-03 · Agente de desarrollo: Claude Code (Opus) · Estado: **VERIFIED en desarrollo · AUDIT_READY · no integrado, no desplegado**

Arquitectura, seguridad, matriz de harnesses y plan de migración:
[CMM-Computer-Use-0.3.3-Arquitectura-20261103.md](CMM-Computer-Use-0.3.3-Arquitectura-20261103.md).
Contrato público: [../workspace-contract.md](../workspace-contract.md).

## 1. Base, rama y worktree

| Campo | Valor |
|---|---|
| Base verificada | `e0a14cbc81cc826072f5393547a2f3f46e59e11c` = `main` = `origin/main` = tag `v0.3.2` |
| Por qué es la base correcta | contiene como ancestros `1d84925`, `62c1afd` y `e763964` (snapshot `claude-cloud/…-062200`); el acta de cierre 0.3.2 registra la integración por fast-forward; no hay otras ramas, worktrees ni stashes; `git ls-remote` coincide |
| Rama | `feature/computer-use-033` (nueva) |
| Worktree | `/Users/chris/CMM Desarrollo/CMM Computer Use-033` |
| Estado inicial | limpio; el checkout principal (`main`) no se tocó |
| HEAD verificado | `b675d617593a5459f409f0fab2642846b0e5ffd4` (árbol limpio) más este informe |
| Push / merge / tag / release | **ninguno** |

## 2. Commits

| Commit | Contenido |
|---|---|
| `624f962` | Núcleo puro `Shared/`: workspace, registro de streams, fiabilidad (+47 XCTest) |
| `28fa197` | Helper: handles por contexto, dos streams con dueño, ledger de operaciones, guards W1–W6 |
| `0c0f213` | Adapter: contextos, `op_id`, nunca reenviar una mutación con respuesta perdida |
| `01316be` | DSH: proyección v13 por carriles, streamer de dos slots, PiP dividido |
| `f000dc9` | Carril aislado contra el binario real (+ fixture de dos ventanas) |
| `3952364` | Harness de referencia sin DSH |
| `d62671e` | Prueba de backpressure por visor |
| `60cab8e` | Contrato `workspace` v1, changelogs, versión 0.3.3 (6) |
| `7ead8db` | `build-helper.sh`: `CFBundleVersion` = `CMM_HELPER_BUILD_NUMBER` (6) |
| `b675d61` | Arquitectura, revisión de seguridad, plan de migración, matriz de harnesses |

Diff frente a la base: 34 ficheros, +6713 / −703.

## 3. Pruebas — evidencia sobre `b675d61`

Entorno: macOS 26 (Darwin 25.6), Apple Swift 6.4.2, Xcode/xcodegen, Node 26.8.2, Python 3.14.8
(Homebrew), `/usr/bin/ruby`. Build sin firma (`CODE_SIGNING_ALLOWED=NO`), DerivedData en el
scratchpad de la sesión.

| Suite | Comando | Resultado |
|---|---|---|
| XCTest (helper + Shared) | `xcodebuild test -scheme CMMComputerUse` | **PASS 253/253** (206 previas + 47 nuevas), 0 warnings |
| Source guards | `scripts/verification/check-helper-source.py` | **PASS 38/38** (R/T adaptados, W1–W6 nuevos) |
| Adapter Python | `python3 -m unittest discover -s tests` | **PASS 107/107** (87 previas + 20 nuevas) |
| Node (runtime, cliente, streamer) | `node --test tests/*.test.mjs` ×3 | **PASS 143/143** en las 3 ejecuciones |
| Manifiesto / cliente renderizado | `render-client.mjs`, `verify-manifest.mjs` | **PASS** (dist sin cambios) |
| Tarball | `npm pack --dry-run --json` + `check-tarball.py` | **PASS** (15 ficheros) |
| Patch DSH | `tests/test_patch.py` | **PASS 9/9** |
| Carril aislado, binario real | `workspace-lane.py --streams` | **PASS 27/27** |
| Mutaciones de control | desactivar el enrutado por carril en `fold` | 7 de 13 pruebas fallan, como debe |

Observación: en una ejecución intermedia, la suite Node falló 1 prueba una vez y no se reprodujo en
10 ejecuciones posteriores; no se identificó la prueba. Se deja constancia.

### 3.1 Carril aislado (binario real, sin tocar producción)

Copia del `.app` de desarrollo re-firmada ad hoc con bundle `com.cmm.chat.computer-use.dev-lane`,
socket/política/log temporales, `--no-permission-bootstrap`. Accesibilidad: **no** concedida.
Screen Recording: **heredada del proceso responsable** (el agente que la lanza), por eso solo se
capturan ventanas de un fixture propio (`.accessory`, nunca activado, ventanas al fondo).

| # | Comprobación | Resultado |
|---|---|---|
| L1 | `instance_id` y `capabilities.workspace` | PASS |
| L2 | contextos A/B; el tercero `CONTEXT_LIMIT` | PASS |
| L3 | contexto para una app no disponible/no autorizada rechazado | PASS |
| L4 | generaciones por contexto (A=1,2; B=1; default=1) | PASS |
| L4b | contexto ligado rechaza otra app | PASS |
| L5 | otro proceso (`/usr/bin/nc`) no lee, cierra, libera ni actúa en A | PASS |
| L6–L7 | acción rechazada = `not_executed`; `op_id` no registrado; `op_id` inválido rechazado | PASS |
| L8 | `release` retira solo la generación de A (`reason=released`, sin edad) | PASS |
| L9–L10 | stream sobre ventana inexistente rechazado sin registro; ids de stream ajenos/malformados `STREAM_UNKNOWN` | PASS |
| L11 | cierre idempotente; `CONTEXT_CLOSED` | PASS |
| L11b | harness de referencia (sin DSH) ejecuta un flujo de dos contextos | PASS |
| S1 | **dos SCStreams reales** con índices y ventanas propios, sin cruce de frames | PASS |
| S2 | tercer stream `STREAM_LIMIT`; reiniciar A es idempotente | PASS |
| S3 | otro cliente no lee, para ni recupera A | PASS |
| S4 | parar A deja B en vivo | PASS |
| S5 | cerrar la ventana de B: B sale de `live` (`stale`), A sigue | PASS |
| S6 | recuperar B falla honestamente (ventana desaparecida) sin tocar A | PASS |
| S7 | log: streams por id, sin breach | PASS |
| S8 | testigo continuo (≈110 muestras): ningún proceso del carril estuvo al frente | PASS |
| L12 | adapter **0.3.2 byte a byte** contra el helper 0.3.3 | PASS |
| L13 | reinicio: nueva instancia, contextos perdidos, pulsación perdida `OUTCOME_UNKNOWN` y no reenviada, lecturas reconectan | PASS |
| L14 | log sin breach ni activación | PASS |
| L15 | **producción idéntica** antes/después (policy, latch, audit, socket, LaunchAgent, binario instalado, pid del helper) | PASS |
| L16 | teardown sin procesos del carril | PASS |

## 4. Cobertura de la lista obligatoria (§9 del encargo)

| # | Caso | Resultado | Evidencia |
|---|---|---|---|
| 1 | Dos apps observadas a la vez | PASS (sin AX real) | XCTest; carril L4/L11b |
| 2 | Dos ventanas de una app | PASS (lógica) | XCTest; carril L11b (dos contextos de Finder) |
| 3 | Dos streams vivos, índices independientes | **PASS real** | S1; XCTest; Node |
| 4 | Iniciar B no detiene A; detener A no afecta B | **PASS real** | S1/S4; Node |
| 5 | Mismo título, ventanas distintas | PASS | XCTest |
| 6 | IDs de elemento coincidentes | PASS | XCTest |
| 7 | Observar B no invalida A | PASS | XCTest; carril L4/L8 |
| 8 | PID cambiado / ventana reemplazada / documento-pestaña | PASS (lógica); **NOT RUN** con navegador real | XCTest; comprobaciones existentes en `elementPreconditions` |
| 9 | Autorización denegada en A sin afectar B | PASS | carril L3/L4b; Node (carriles) |
| 10 | Un cliente no accede al contexto de otro | **PASS real** | carril L5/S3; XCTest |
| 11 | Límite de dos streams, rechazo del tercero | **PASS real** | S2; XCTest; Node |
| 12 | Backpressure y desconexión de un visor | PASS | Node (streamer) |
| 13 | Frame congelado y recuperación de un panel | **PASS real** (detección); recuperación con éxito solo en Node | S5/S6; XCTest; Node |
| 14 | Helper reiniciado, socket cerrado, timeout, reconexión | **PASS real** | L13; adapter |
| 15 | Timeout de mutación sin duplicar | PASS | adapter (5 casos); L13 |
| 16 | `USER_TAKEOVER` solo el contexto afectado, sin breach | PASS (lógica); **NOT RUN** LIVE | XCTest; Node |
| 17 | Breach conserva el guard | PASS (lógica + guards); **NOT RUN** LIVE | guards 20–22, R/T; Node |
| 18 | Cierre repetido y limpieza | **PASS real** | L11/S4; XCTest |
| 19 | Herramientas antiguas y checkpoints | **PASS real** (adapter 0.3.2) | L12; Node (checkpoint v13, log 0.3.2) |

DSH (§7.3): invocación automática por el modelo y visibilidad del PiP en DSH real → **NOT RUN**
(requiere una sesión DSH instalada con el plugin nuevo, que sería integración). Lo verificado: la
corrección de visibilidad en la proyección (una observación sin `status` previo se verifica y se
muestra), las instrucciones de invocación del servidor MCP, y la decisión de invocación en el
harness de referencia.

## 5. Defectos encontrados y corregidos (preexistentes en 0.3.2)

1. `startWindowStream` decidía la autorización **sin el cliente**: con política `required` todo
   stream se rechazaba y el mirror caía al sondeo por capturas.
2. Un `stream_start`/`stream_stop` legacy de **cualquier** cliente sustituía o paraba el único
   stream de todos.
3. La lectura de frames no tenía dueño: cualquier conexión leía el stream activo.
4. DSH: observar sin `computer_use_status` previo dejaba el PiP en `UNVERIFIED_TARGET` (causa
   confirmada de "no se ve actividad").

## 6. Cambios de comportamiento visibles para clientes 0.3.2

- La observación de otro cliente ya no reemplaza sus handles.
- Una mutación con timeout o respuesta desincronizada es `OUTCOME_UNKNOWN` (antes
  `COMPUTER_RUNTIME_UNAVAILABLE`) y no se reenvía. Dos pruebas antiguas que fijaban el
  comportamiento anterior se actualizaron a este contrato.
- Un cambio de documento verificado rechaza un handle antiguo (`reason=document_changed`).
- El catálogo MCP crece de 8 a 11 herramientas (aditivo); las instrucciones del servidor
  empiezan por la guía de invocación.

## 7. Limitaciones y riesgos residuales

Detallados en el documento de arquitectura (§7.3). En resumen: principal compartido por identidad
de código con política v1; ledger en memoria; identidad de documento solo por título en apps sin
`AXDocument`/`AXURL`; el stream legacy no se recoge por inactividad; en DSH el stream del panel se
liga a la identidad verificada (bundle + pid + ventana) y no al contexto del adapter, porque streamer
y adapter son principales distintos; con política `required` el streamer de DSH necesita su propio
`client`. Nada de esto se ha validado con AX real ni en DSH real.

## 8. Producción y sesiones

No se instaló, sustituyó ni reinició nada; no se tocaron políticas, TCC, sockets, LaunchAgents ni
`/Applications`/`~/Applications`; no se activaron ni manipularon ventanas del usuario (testigo
continuo). El streamer de producción de DSH escucha en `127.0.0.1:47183`: ninguna prueba nueva usa
ese puerto (el streamer acepta `--port` solo para pruebas; las pruebas existentes simulan `fetch`).
Snapshot de producción idéntico antes/después del carril (L15).

## 9. Pasos para una integración posterior (requieren autorización)

Ver el plan de migración (§10 del documento de arquitectura): revisión/auditoría independiente →
build staged firmado y continuidad del designated requirement → carriles `isolated-live` y
`workspace-lane` con el staged → gates nuevos con AX real (dos apps, cambio de pestaña,
`USER_TAKEOVER`, breach con dos contextos) → revisión de la política (`client` para el streamer si es
`required`) → perfil DSH de prueba (stateVersion 13, PiP dividido, invocación automática) →
promoción → rollback por CDHash `656c495ed84f5a7b0aee208e41fed8562f301bf2`.
