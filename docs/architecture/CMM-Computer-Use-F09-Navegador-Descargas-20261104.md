# F-09 — Fiabilidad del navegador y gestión de descargas (informe)

- **Fecha:** 2026-11-04.
- **Rama:** `feature/computer-use-033-browser`, creada sobre `feature/computer-use-033` en `3311034`.
- **Estado:** IMPLEMENTADO y VERIFICADO en el alcance que se indica más abajo.
- **Integración:** no se ha integrado, publicado, instalado ni desplegado nada. Producción no se ha tocado.
- **Contrato:** [docs/browser-contract.md](../browser-contract.md).

## 1. Auditoría del funcionamiento actual (0.3.2 / 0.3.3 antes de F-09)

Cada causa sale del código. No hay suposiciones.

| Síntoma que se observaba | Causa raíz | Dónde |
|---|---|---|
| "Se desconecta al cambiar de pestaña" (PiP) | La URL del espejo en vivo y la clave del slot del streamer incluían el **título** de la ventana. Un cambio de pestaña o una navegación renombra la ventana, así que se cerraba y se reabría el stream del helper. | `client.template.js` (`liveUrl`), `index.js` (`acquire` key) |
| "Se desconecta al cambiar de pestaña" (agente) | Una acción sobre un elemento de la página anterior se rechazaba con `document_changed`. El rechazo llegaba como un error genérico y la proyección DSH **borraba el objetivo verificado** igual que con una revocación de permisos. | `runtime.mjs` (`foldCore`, rama de rechazo) |
| Pérdida de la ventana con varias ventanas abiertas | `observation.describe` observaba siempre la ventana **enfocada**. Un contexto no podía seguir una ventana concreta. | `main.swift` `describe` |
| Pestañas sin identidad | No había enumeración de pestañas ni ids. La única señal era el digest del documento, sin forma de distinguir pestaña, navegación o recarga. | — |
| Sin descargas | No existía ninguna capacidad de descarga. El agente pulsaba un botón y daba por hecho que el archivo existía, o usaba ⌘S global, que exige el navegador en primer plano. | — |
| Respuesta perdida en una descarga | Un `ui.press` con resultado desconocido no tenía forma de comprobarse; reintentarlo duplicaba la descarga. | — |

## 2. Arquitectura

Las piezas se reparten en cuatro capas. Ninguna depende del harness.

### 2.1 Modelos puros

Viven en `apps/macos/Shared/` y XCTest los cubre por completo.

**`ComputerUseBrowser.swift`:**
- Ids estables de ventana y de pestaña. Se identifican primero por la identidad del elemento de accesibilidad; el título solo se usa si es único y no hay otra evidencia; la posición nunca se usa por sí sola.
- Clasificación de transiciones, de mayor a menor gravedad:
  - `app_closed`, `app_relaunched`;
  - `window_closed`, `tab_closed`;
  - `tab_switched`, `navigated`, `reloaded`;
  - `loading`, `unchanged`.

  Cada transición dice si el contexto sobrevive y si los handles quedan invalidados.
- Resumen de una espera: número de redirecciones y si la página se ha asentado.
- URLs redactadas: nunca salen la consulta, el fragmento ni las credenciales.
- Reconocimiento del cuadro de guardado mediante `AXDefaultButton` y `AXCancelButton`, que no dependen del idioma. El botón Reemplazar solo se acepta si se identifica de forma positiva.

**`ComputerUseDownloads.swift`:**
- Expectativas con línea base.
- Artefactos seguidos a través de los renombrados, por inode y por nombre final.
- Formatos parciales de WebKit, Chromium y Gecko.
- Cada artefacto lo reclama una sola expectativa.
- Una descarga solo es `complete` cuando el archivo está presente, no vacío y estable.
- Estados `interrupted` y `resumed`; `failed` cuando desaparece el parcial.
- Límite de 8 expectativas abiertas por cliente.

**Política:** cada grant de aplicación declara sus `downloads.roots`. Un grant sin raíces no puede vigilar ningún directorio.

### 2.2 Helper (`BrowserSupport.swift`)

- **Operaciones de lectura:** `browser.state` y `browser.wait`.
- **Expectativas de descarga:** `download.expect`, `download.status`, `download.wait`, `download.list` y `download.forget`.
- **Acciones:** dos tipos nuevos que pasan por el pipeline completo de `action.execute` (modo, grant `control`, latch, muestreo de interferencias, ledger de op_id):
  - `browser.select_tab`;
  - `browser.save_dialog`.
- **Esperas sin bloquear:** las esperas toman `dispatchLock` muestra a muestra. Una espera larga nunca bloquea al otro contexto, a los streams ni a otros clientes.
- **Ventana por id:** `observation.describe` acepta `window_id`, y un contexto explícito conserva su ventana.

### 2.3 Adaptador neutral (`adapter/cmm_computer_use/browser.py`)

- `classify_failure`, que nombra qué ha pasado.
- `download_by_pressing`, que sigue estos pasos:
  1. declara la expectativa;
  2. pulsa una sola vez;
  3. verifica el archivo.

  Si la respuesta de la pulsación se pierde, no vuelve a pulsar.
- Siete herramientas MCP y la invocación automática ampliada a navegadores y descargas.
- Tras un cambio de página o de pestaña, añade una observación nueva. Es solo una lectura: la acción no se repite.

### 2.4 DSH / PiP

- El espejo en vivo y su stream del helper ya no cambian cuando solo cambia el título (mismo `window_id`).
- Un cambio de documento o un paso de navegador o descarga que no termina **conserva el panel**: se descarta solo el frame estático y se muestra el motivo.
- Los motivos que sí revocan siguen vaciando el panel: grant, proceso, ventana, breach y navegador cerrado.
- Los carriles A y B son independientes.

## 3. Seguridad

La cumplen los guardas de código F1–F5 y XCTest:

- **Sin vías alternativas.** No hay AppleScript, JXA, System Events, CGEvent, subprocesos, CDP, WebDriver ni Marionette.
- **Sin datos del perfil.** No se accede a perfiles, cookies, historial ni llavero.
- **Contenido de los archivos.** El contenido de un archivo descargado no se lee nunca, salvo que se pida `checksum: true` de forma explícita, que devuelve solo el SHA-256.
- **Nada de la página sale en claro.** Las URLs van redactadas y los documentos, como digest.
- **Sobrescritura.** Exige `overwrite=true` y un botón Reemplazar identificado.
- **Mismas puertas que el resto.** Las acciones pasan por las mismas puertas que `ui.press`.
- **Raíces exactas.** Las raíces de descarga son exactas y fallan de forma cerrada.
- **Contextos propios.** Ninguna capacidad se presenta como universal si depende de un adaptador concreto.

## 4. Pruebas

Las suites se ejecutaron sobre el árbol final de esta rama.

| Suite | Comando | Resultado |
|---|---|---|
| XCTest (helper + Shared) | `xcodebuild test -scheme CMMComputerUse` | **293/293** (253 previas + 40 nuevas), sin avisos nuevos |
| Guardas de código | `python3 scripts/verification/check-helper-source.py` | **44/44** (+F1–F5 y BrowserSupport en el build) |
| Adaptador Python | `python3 -m unittest discover -s tests` | **128/128** (+21) |
| Node (proyección, PiP, streamer) | `node --test tests/*.test.mjs`, 3 ejecuciones | **151/151** en las tres (+8) |
| Manifest, cliente renderizado, `test_patch.py`, tarball | `verify-manifest.mjs`, `check-tarball.py` | PASS (16 ficheros: ahora incluye `browser.py`) |
| Lane en vivo con navegadores reales | `scripts/verification/browser-lane.py` | **26/26** en dos ejecuciones seguidas (§5) |

## 5. Pruebas en vivo

### 5.1 Entorno de la prueba

El lane combina un helper real, navegadores reales y un servidor local:

- **Helper.** Es el binario real compilado de esta rama, copiado en un directorio privado y firmado ad hoc con un bundle id propio. No tiene ningún permiso TCC.
- **Navegadores.** Google Chrome y Firefox reales en modo headless:
  - cada uno con un perfil desechable creado dentro del lane;
  - Chrome usa `--use-mock-keychain`, así que no toca el llavero;
  - descargan desde un servidor HTTP en 127.0.0.1 con puerto efímero.
- **Testigo.** Un testigo registró la app en primer plano cada 100 ms, identificada por pid.
- **Producción.** Se tomó una instantánea antes y otra después, y se comparó.

La evidencia está en `docs/architecture/evidence/f09-browser-lane-run5.json` y `…run6.json`.

### 5.2 Resultados

| Check | Chrome | Firefox |
|---|---|---|
| B3 descarga directa: `complete` y SHA-256 en disco = enviado | PASS | PASS |
| B4 PDF | PASS | PASS |
| B5 ZIP | PASS | PASS |
| B6 redirección 302 a un nombre generado dinámicamente, sin pista | PASS | PASS |
| B7 dos descargas simultáneas, cada una atribuida a su expectativa | PASS | PASS |
| B8 transferencia cortada: `failed`, nunca `complete` | PASS (`partial_removed`) | PASS (`size_mismatch`) |
| B9 transferencia bloqueada: `interrupted` y `resumable` | PASS | PASS |

Checks comunes:

- **B0, B1:** el contrato se anuncia y hay un contexto por navegador.
- **B2:** sin Accesibilidad, `browser.state` y `select_tab` fallan de forma cerrada y no se ejecuta nada.
- **B10:** se mata Firefox a mitad de una descarga. La descarga de Chrome termina verificada (renombrada `slow-a (1).bin` por conflicto), su contexto sigue válido y la de Firefox queda `interrupted`.
- **B11:** mismo `op_id`, misma expectativa.
- **B12:** otro proceso no puede leer la expectativa.
- **B13:** una raíz no permitida se rechaza, y un grant sin raíces no puede vigilar nada.
- **B14:** una espera de 6 s no bloquea otras peticiones (1–40 ms).
- **B15:** no quedó ningún proceso del lane.
- **B16:** ningún proceso del lane pasó a primer plano. En primer plano solo aparecieron las apps de la persona.
- **B17:** producción quedó idéntica.

### 5.3 Defectos que encontraron las pruebas en vivo

Los cinco están corregidos y cubiertos por una prueba de regresión:

1. **Firefox nombra los parciales `Nombre.<8 aleatorios>.ext.part`.** El modelo esperaba `Nombre.ext.part` y habría dado la descarga por fallida.
2. **El marcador de 0 bytes de Firefox puede aparecer antes que el `.part`.** Se contaba como una segunda descarga y la verdadera acababa en `failed`. Ahora un archivo vacío no es una descarga.
3. **Dos descargas simultáneas de Firefox se intercambiaron.** Un nombre que no casaba con ninguna pista se entregaba a la expectativa más antigua. Ahora espera.
4. **Firefox deja como terminado un archivo truncado.** Ocurre cuando se corta la conexión. Los metadatos no pueden detectarlo, así que se añadieron `expected_bytes` y `expected_sha256`. Sin ellos, `complete` significa "el navegador terminó de escribir", y así queda documentado.
5. **Las expectativas terminadas contaban para el límite de 8.** Tras ocho descargas no se podía declarar ninguna más. Ahora solo cuentan las abiertas.

Además, la comprobación del paquete detectó que `browser.py` faltaba en el tarball publicado; habría roto el arranque del adaptador.

El lane también tuvo que corregirse a sí mismo. Firefox se re-ejecuta con otro pid en un perfil nuevo, y el teardown inicial dejó una instancia viva. Se detuvo verificando su ruta, y ahora el teardown localiza los procesos por perfil.

## 6. Criterios de aceptación

| # | Criterio | Estado | Evidencia |
|---|---|---|---|
| 1 | Cambio de pestaña sin desconexión | **IMPLEMENTADO; probado a nivel de código** (XCTest del modelo, adaptador y DSH). **En vivo: NO EJECUTADO**, requiere Accesibilidad | `tab_switched` con el contexto vivo; el PiP conserva el stream |
| 2 | Navegación y recarga | igual que el 1 | `navigated` / `reloaded`; observación nueva automática |
| 3 | Abrir y cerrar pestañas y ventanas | igual que el 1 | `opened_tabs`, `closed_tabs`, `window_closed` |
| 4 | Descarga directa | **VERIFICADO EN VIVO** con Chrome y Firefox | B3 |
| 5 | PDF | **VERIFICADO EN VIVO** con Chrome y Firefox, como descarga | B4. El visor PDF en línea, ver §7 |
| 6 | ZIP | **VERIFICADO EN VIVO** con Chrome y Firefox | B5 |
| 7 | Redirección | **VERIFICADO EN VIVO** con Chrome y Firefox | B6 |
| 8 | Cuadro de diálogo de destino | **IMPLEMENTADO**; reconocedor en XCTest. **En vivo: NO EJECUTADO**, requiere Accesibilidad | `browser.save_dialog` |
| 9 | Interrupción y recuperación | Detección **VERIFICADA EN VIVO** (B8, B9). Pulsar "Reanudar" es una pulsación AX normal, **no ejecutada en vivo** | `interrupted` → `in_progress` → `resumed` en XCTest |
| 10 | Dos descargas simultáneas | **VERIFICADO EN VIVO** con Chrome y Firefox | B7 |
| 11 | Cambio de pestaña con una descarga en curso | El seguimiento de la descarga no depende de la pestaña (prueba de diseño). **En vivo: NO EJECUTADO** | — |
| 12 | Recuperación del navegador sin afectar a otros contextos ni al segundo panel | **VERIFICADO EN VIVO** con un navegador caído y el otro intacto (B10). Carril B intacto en el PiP (Node) | B10, `browser-lanes.test.mjs` |

Safari no se ha ejecutado en vivo en ningún criterio. El formato `.download` está implementado y cubierto por XCTest.

## 7. Límites y lo que queda pendiente

- **Accesibilidad en vivo.** Pestañas, `select_tab`, cuadro de guardado y "Reanudar" necesitan un helper de prueba con Accesibilidad. Concederla es un cambio de TCC y requiere tu autorización.
- **Safari en vivo.** No se puede ejecutar aislado de tu sesión: hay un solo proceso por usuario y la carpeta de descargas es global. Las alternativas están en la sección 8.
- **"Guardar como" de un PDF mostrado en línea, sin enlace de descarga.** Requiere el menú Archivo, mediante una pulsación AX de menú, o ⌘S, que es teclado global. No está implementado en segundo plano. El caso de DSH que motivó parte de F-09 (⌘S con el navegador delante) queda resuelto con `computer_use_download` cuando la página tiene un enlace o botón de descarga.
- **Selección de carpeta en el cuadro de guardado.** Se usa la carpeta que muestra el cuadro. Navegar a otra carpeta no forma parte de la v1.
- **Integridad.** Sin `expected_bytes` o `expected_sha256`, una descarga truncada que el navegador da por terminada no se puede detectar (pasa con Firefox).
- **Integración.** Para producción, la política tiene que declarar `downloads.roots`, y macOS puede pedir acceso a la carpeta Descargas para el helper. Ambas cosas forman parte de la integración, que no se ha hecho.

## 8. Safari en vivo: opciones

1. **Safari Technology Preview (recomendada).** Es una app de Apple separada, con su propio proceso, ajustes y datos, aislada de tu Safari. Habría que instalarla. Después el lane la usaría, con su carpeta de descargas apuntando al directorio del lane. Esto cubre las descargas sin Accesibilidad.
2. **Tu Safari, de forma explícita.** El lane abriría pestañas en segundo plano (`open -g`) en tu sesión, y los archivos irían a tu carpeta de descargas. Esto toca tu sesión abierta.
3. **Las pruebas de pestañas y del cuadro de guardado** necesitan además un helper de prueba con Accesibilidad, en cualquier navegador.
