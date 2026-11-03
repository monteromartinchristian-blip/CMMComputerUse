# CMM Computer Use 0.3.3 — Multi-App Workspace: arquitectura, seguridad y operación

Fecha: 2026-11-03 · Rama: `feature/computer-use-033` · Base: `e0a14cb` (= `v0.3.2`)
Contrato público: [`docs/workspace-contract.md`](../workspace-contract.md) (en inglés, neutral respecto al harness).

Estado: **implementado y verificado en desarrollo; no integrado ni desplegado.**

## 1. Qué cambia respecto a 0.3.2

| Aspecto | 0.3.2 | 0.3.3 |
|---|---|---|
| Tabla de elementos | una por proceso (`elementTable` global) | una por **contexto**, dentro de un **principal** |
| Generación / reloj / liberadas | globales | por contexto |
| Observar la app B | reemplazaba los handles de A (de cualquier cliente) | no toca A |
| Identidad del handle | app + pid + ventana | + documento (`AXDocument` / `AXURL`, como digest) |
| Streams | uno por helper; un segundo `stream_start` (de cualquiera) lo sustituía | hasta dos, cada uno con su dueño, sink, cola, índice, salud y recuperación |
| Autorización del stream | **sin `client:`** (defecto) | decisión `.observe` del cliente que lo pide; reevaluada en `policy.reload` |
| Resultado de una acción | éxito / error | + `execution {executed, outcome, op_id, instance_id, replayed}` |
| Respuesta perdida de una acción | `COMPUTER_RUNTIME_UNAVAILABLE` | `OUTCOME_UNKNOWN`, nunca se reenvía |
| PiP en DSH | un panel | hasta dos paneles (A, B) independientes |

## 2. Componentes

```
harness (DSH, harness de referencia, otro)            ← decide CUÁNDO usar Computer Use
   │  MCP stdio                                         (instrucciones del servidor)
   ▼
adapter Python (cmm_computer_use)                      ← contrato del cliente: contexto,
   │  NDJSON v1 sobre socket UNIX                        op_id, reintentos solo de lecturas,
   ▼                                                     OUTCOME_UNKNOWN
helper firmado (CMMComputerUse.app)                    ← autoridad: principal, autorización,
   ├─ Shared/ComputerUseWorkspace.swift  (puro)          contextos, streams, ledger, guard,
   ├─ Shared/ComputerUseStreams.swift    (puro)          breach, takeover
   ├─ Shared/ComputerUseReliability.swift(puro)
   ├─ main.swift          (dispatch, AX, acciones)
   └─ WindowStream.swift  (SCStream ×2)
   ▲
   │  NDJSON v1 (otro proceso: el streamer de DSH)
DSH host plugin: index.js (streamer HTTP loopback, slots A/B) → client (PiP dividido)
```

Las reglas nuevas viven en tres ficheros `Shared/` **puros y genéricos** (el helper guarda
`AXUIElement`, las pruebas guardan cadenas): se prueban con XCTest sin servidor de ventanas
ni TCC, y `main.swift` solo las aplica.

## 3. Workspace

### 3.1 Principal

El dueño de contextos, streams y resultados registrados se calcula **en el helper**, por
petición, a partir del peer verificado por el kernel (audit token + firma), nunca de un
campo de la petición:

1. cliente de la política v2 que casa con el requirement → `client:<id>` (`verified_client`);
2. sin clientes (política v1) y peer firmado válidamente → `code:<identifier>@<team>` (`code_identity`);
3. peer sin firma válida → `pid:<pid>` (`process`);
4. stdio → `local`.

Consecuencia documentada: con política v1, dos procesos con la misma identidad de código son el
mismo principal (comparten contextos y el límite de 2). Para aislar dos programas entre sí hace
falta política v2 con dos `clients`.

### 3.2 Contextos

- Identificador `ctx_` + 128 bits aleatorios (`SecRandomCopyBytes`), opaco, **no es autorización**.
- Dos contextos explícitos por principal (16 por helper) + el contexto `default` de 0.3.2,
  que no cuenta.
- Un contexto explícito es **una aplicación**: observar otra a través de él es
  `CONTEXT_TARGET_MISMATCH`. Puede crearse ligado a una app (`app`), que debe estar en ejecución
  y autorizada `observe` para ese cliente.
- Cada observación hace `beginObservation` (nueva generación **de ese contexto**, reloj = ahora)
  y `commit` de los handles del recorrido; un `commit` de una observación ya superada se descarta.
- Un handle se resuelve con `resolveHandle(principal, context, snapshot, element)` en el orden de
  0.3.2: `released` → `expired` → `stale_snapshot` → `unknown_element`; después, en `main.swift`,
  pid, ventana, **documento** y la decisión `.control` con el título actual.
- `release` y `USER_TAKEOVER` retiran solo la generación del contexto afectado, con la misma
  regla compartida `bridgeRetireObservation` de 0.3.2.
- Contextos sin uso durante 30 min se recogen (con sus handles y su stream). La recogida es
  perezosa: ocurre en la siguiente operación de workspace, observación o inicio de stream.

### 3.3 Documento / pestaña

La ventana no identifica el documento: cambiar de pestaña conserva el `window_id`. Solo cuentan
atributos AX soportados: `AXDocument` de la ventana o `AXURL` del primer `AXWebArea`. Se publica
un digest (SHA-256, 16 hex), nunca la URL. Reglas:

| Observado → actual | Contexto explícito | Contexto `default` (0.3.2) |
|---|---|---|
| verificado → verificado, digest distinto | `document_changed` | `document_changed` |
| verificado → sin verificar | `document_changed;evidence=lost` | se acepta (como 0.3.2) |
| solo título → título distinto | `document_unverified` | se acepta (como 0.3.2) |

No se inventan IDs de pestaña. Limitación declarada: una app que no expone `AXDocument` ni
`AXURL` solo obtiene reobservación conservadora en contextos explícitos.

## 4. Streams

- Registro acotado `BridgeStreamRegistry` (2 por helper, 2 por principal), protegido por su propio
  lock porque los frames se sirven **fuera** de `dispatchLock` y los sinks informan desde sus colas.
- Cada stream: `SCStream`, `WindowFrameSink`, `WindowStreamDelegate` y `DispatchQueue` propios;
  índice de frame monótono (sobrevive a la recuperación); latido por buffers `idle` de
  ScreenCaptureKit.
- Inicio en tres pasos: (1) identificar y autorizar la ventana **sin abrir nada**; (2) el registro
  decide (reutilizar, sustituir el stream propio de ese slot, o `STREAM_LIMIT`); (3) abrir con el id
  reservado comprobando que la ventana no cambió entre medias (`STREAM_IDENTITY_MISMATCH`).
- `expected_bundle` / `expected_pid` (de una observación verificada) se comprueban antes de abrir.
- Fases honestas: `warming`, `live` (frame < 2 s, o buffers `idle` < 2 s → `unchanged`), `stale`
  (`frozen` o `no_first_frame`), `recovering`, `error`, `closed`. **Un frame antiguo nunca es `live`.**
- Recuperación de un solo stream: mismo id, mismo `window_id`, autorización decidida de nuevo,
  5 intentos con backoff 0,5 → 8 s (`STREAM_RECOVERY_BACKOFF` con `retry_after_ms`). Nunca toca el otro.
- `policy.reload` detiene los streams cuya ventana ya no autoriza a su dueño.
- `kill(pid, 0)` en `stream_status` marca `pid_changed` si el proceso desapareció.

## 5. Reliability Engine

| Mecanismo | Dónde | Qué garantiza |
|---|---|---|
| `execution.executed` + `outcome` | helper | distingue `not_executed` (rechazo previo), `succeeded`, `failed` |
| `op_id` + ledger por principal (256) | helper | reenviar el mismo id **reproduce** la respuesta registrada; id reutilizado para otra acción → `OPERATION_ID_CONFLICT`; id en vuelo → `OPERATION_IN_PROGRESS` |
| `instance_id` | helper | un cambio indica reinicio: contextos, streams y ledger perdidos |
| `action.outcome` | helper | consulta de solo lectura; `unknown` cuando no consta (nunca `not_executed`) |
| Clases de reintento | Swift + Python (prueba de paridad) | lecturas 2 reintentos, idempotentes 1, mutadoras 0 |
| Recuperación de respuesta perdida | adapter | solo `ping` + `action.outcome`; resultado registrado → `recovered`; si no → `OUTCOME_UNKNOWN` (`unreachable`, `helper_restarted`, `no_ledger`, `not_recorded`, `in_progress`) |
| Fallo global del helper | adapter + DSH | toda la sesión pasa a `disconnected`; todos los paneles muestran el error |

El ledger vive en memoria. Persistirlo para sobrevivir a un reinicio se evaluó y se descartó en
esta versión: el adapter ya informa `OUTCOME_UNKNOWN` tras un reinicio, que es la respuesta honesta.

`USER_TAKEOVER` se conserva: no es breach, no se reintenta, no se latchea, e invalida solo el
contexto afectado (el del handle usado; sin handle, los contextos del cliente sobre la app objetivo
más su `default`). El breach, el latch persistente, la ventana de asentamiento, la atribución
humana y la guarda de controles de ventana no cambian (fijados por los source guards).

## 6. PiP dividido y visibilidad en DSH

### 6.1 Proyección (stateVersion 13)

`fold` aplica las reglas de 0.3.2 sin cambios (`foldCore`) al **carril** del contexto de cada
llamada; los hechos de sesión (helper, grants, breach, llamadas pendientes) son compartidos.
Resultado: un rechazo, frame, takeover o estado ocupado de A nunca toca B; un breach o un fallo del
helper aparece en ambos; un `status` que revoca el grant vacía ese carril. Máximo dos carriles;
el esquema del checkpoint los valida (forma cerrada, claves `ctx_…`). Las sesiones 0.3.2 se
reconstruyen desde el log con el mismo resultado.

### 6.2 Streamer y cliente

El streamer (proceso hijo del host) mantiene un slot por panel (`slot=A|B`), cada uno con su stream
del helper (`stream_key`), contadores, fase, visores y recuperación; un tercer slot → 429; con un
helper 0.3.2 (un solo stream) el segundo slot cae a captura en lugar de robar el stream del primero.
El cliente dibuja un PiP por panel, con su propio estado de vista y sondeo de estado; el título
lleva la etiqueta (`A · Safari`).

### 6.3 Causa del "DSH usa Computer Use y no se ve nada"

Causa confirmada en el código: la proyección solo verifica (y por tanto solo muestra) un objetivo
si antes hubo un `computer_use_status` con el grant. Un modelo que observa directamente terminaba
en `UNVERIFIED_TARGET`. Corrección: cada observación imprime, **antes de cualquier contenido AX**,
las mismas líneas de hechos que `status` (helper, política, grant del objetivo); la proyección las
adopta solo de esa cabecera (el contenido AX no puede falsificarlas; prueba incluida).

Causa adicional encontrada: con política `required`, `startWindowStream` decidía sin `client:` y
todo stream se rechazaba, así que el mirror caía al sondeo por capturas (~3–4 fps).

Hipótesis no verificable sin DSH real: `visibleSessionId` oculta el overlay mientras hay un panel
lateral abierto (`activePanelId !== null`). Se mantiene (es una decisión deliberada de no revelar
nada en estados ambiguos) y queda como punto a comprobar en la integración.

## 7. Revisión de seguridad

### 7.1 `currentClient`, `currentPeer`, `dispatchLock`

- `handleLine` resuelve, **bajo `dispatchLock`**, `currentPeer`, `currentClient` y ahora
  `currentPrincipal`; despacha; y los limpia (también `requestContext`) antes de soltar el lock.
  Como toda operación (salvo el frame) se serializa, ninguna petición puede ver el cliente o el
  contexto de otra.
- `requestContext` (el contexto resuelto para la acción en curso) sigue el mismo patrón y se
  limpia en el mismo punto.
- **Ruta del frame** (fuera del lock, a propósito, para no congelar el mirror): resuelve su propio
  principal desde el peer de **esa** conexión contra una copia de `authorization` leída bajo el nuevo
  `authorizationLock` (el mismo lock protege la sustitución en `policy.reload`). Solo lee el registro
  de streams (su lock) y el sink (su lock); nunca lee `currentClient`.
- Las Tasks de captura/stream capturan `client` en una constante local antes de lanzarse; no leen
  el global desde otro hilo.
- Los ids pendientes de `op_id` usan su propio lock y se registran antes de esperar `dispatchLock`,
  para detectar un reenvío concurrente.

### 7.2 Propiedades preservadas

| Propiedad | Cómo |
|---|---|
| Deny by default | toda observación/captura/stream/acción sigue pasando por `authorization.decision`; crear un contexto ligado exige `observe` |
| Un id no autoriza | contextos/streams se resuelven por principal; la decisión de grant se toma igualmente |
| Aislamiento entre clientes | rechazo idéntico para id ajeno e inexistente (sin oráculo); ledger por principal; frames solo al dueño |
| Sin captura de pantalla completa | sin cambios (`bridgeAuthorizedCaptureDecision`) |
| Sin activar/elevar/mover cursor | ninguna ruta nueva activa; el streamer y el PiP no tocan la app objetivo; testigo continuo en el carril |
| Sin AppleScript/JXA/CGEvent nuevos | source guard 19 sobre todo el helper + `Shared/` |
| Guard DSH, breach, takeover | sin cambios funcionales; source guards R/T actualizados a la estructura por contexto y W1–W6 nuevos |
| Fail-closed | identidad ambigua, contexto desconocido, documento cambiado, stream de otro → rechazo antes de tocar nada |

### 7.3 Riesgos residuales

1. Con política v1, procesos con la misma identidad de código comparten principal (documentado).
2. El ledger no sobrevive a un reinicio (se informa `OUTCOME_UNKNOWN`).
3. Apps sin `AXDocument`/`AXURL`: la identidad de documento es solo título.
4. El stream legacy de un principal no se recoge por inactividad (solo con `stop` o al salir el helper).
5. En DSH, el streamer (Node) y el adapter (Python) son principales distintos: el stream del panel
   no está ligado al contexto del adapter, sino a la identidad verificada (bundle + pid +
   `window_id`) que la proyección obtuvo de la observación. El helper la comprueba antes de abrir.
6. Con política `required`, el streamer de DSH necesita su propio `client` con `observe` sobre las
   apps; si no, el mirror cae a captura (que también exige cliente) y el panel muestra error.

## 8. Operación

Líneas de log nuevas (stderr / `--log-file`): `CONTEXT_CREATED`, `CONTEXT_CLOSED`,
`CONTEXT_REAPED`, `OBSERVATION_INVALIDATED … context=…`, `WINDOW_STREAM_STARTED id=… key=…`,
`WINDOW_STREAM_STOPPED id=… [reason=…]`, `WINDOW_STREAM_RECOVERED`, `OPERATION_REPLAYED`.
Diagnóstico sin contenido: `workspace.status`, `observation.stream_status`, y en `bridge.ping`
`instance_id`, `capabilities.workspace` y un resumen de streams (recuentos; detalles solo del propio
stream legacy del llamante).

## 9. Portabilidad y matriz de compatibilidad

| Harness / cliente | Estado | Evidencia |
|---|---|---|
| Adapter MCP (Python) | **probado** | 107 pruebas unitarias/contrato; carril real L11b–L13 |
| Harness de referencia (`examples/reference-harness`) | **probado** | 3 pruebas por stdio; carril real L11b |
| Adapter 0.3.2 (sin cambios) contra helper 0.3.3 | **probado** | carril real L12 |
| DeepSeek Harness 0.2.1-rc.3 (proyección, streamer, PiP) | **probado a nivel de código**; **no probado en DSH real** | 143 pruebas Node (seat sin DOM, streamer contra helper simulado) |
| Invocación automática por el modelo en DSH | **disponible, no probada** | instrucciones MCP; requiere sesión DSH real |
| Claude Code, Codex, Qoder u otros hosts MCP | **disponible, no probada** | mismo adapter MCP estándar; sin adaptador específico ni prueba |
| Hosts sin MCP | **no compatible** sin adaptador propio | el contrato de socket está documentado para escribir uno |

No se extrapola el PASS de un harness a otro.

## 10. Plan de migración 0.3.2 → 0.3.3 (NO ejecutado)

Requiere autorización expresa. Orden propuesto, siguiendo el procedimiento aceptado en 0.3.2:

1. **Revisión** de la rama (`git log e0a14cb..feature/computer-use-033`) y auditoría independiente.
2. **Build staged** firmado con la identidad de producción
   (`CMM_HELPER_BUILD_DIR=build/stage-0.3.3 scripts/build-helper.sh`, sin `--install`); anotar el
   CDHash; comprobar que el *designated requirement* es idéntico al instalado (continuidad TCC).
3. **Carril aislado LIVE** con el staged (`scripts/verification/isolated-live.py`, flujo 0.3.2) y,
   además, `scripts/verification/workspace-lane.py --streams --app build/stage-0.3.3/CMMComputerUse.app`
   (ojo: con la copia re-firmada del carril no hay AX; para gates con AX real usar el carril
   `isolated-live` con su política temporal).
4. **Gates nuevos con AX real** en el carril aislado: dos apps observadas y controladas sin cruce;
   cambio de pestaña en un navegador → `document_changed`; `USER_TAKEOVER` en A sin afectar B;
   breach controlado del fixture (Gate A) con dos contextos abiertos.
5. **Política**: comprobar (lectura) si producción usa `client_authorization: required`; si es así,
   añadir en CMM Console un `client` para el streamer de DSH con `observe` sobre las mismas apps
   (cambio de configuración: autorización aparte).
6. **Plugin DSH**: instalar la versión con `stateVersion` 13 en un perfil de prueba; verificar que las
   sesiones existentes se reconstruyen desde el log; PiP visible tras un `observe` sin `status`;
   dos paneles con dos contextos; cierre de un panel sin congelar el otro.
7. **Promoción** del helper (sustituir el bundle, reiniciar el LaunchAgent) y del plugin, solo con
   autorización y en una ventana sin sesiones activas.
8. **Rollback**: reinstalar el bundle 0.3.2 por **CDHash** `656c495ed84f5a7b0aee208e41fed8562f301bf2`
   y el plugin anterior; la proyección v13 → v12 se reconstruye desde el log (los carriles se
   pierden, el panel único se conserva). Los clientes 0.3.3 ven `capabilities.workspace` ausente y
   vuelven a la semántica 0.3.2.
