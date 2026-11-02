# CMM Computer Use 0.3.2 — Acta de cierre y aceptación en producción

Fecha: 2026-11-02

Documento de cierre técnico. Registra la identidad exacta de la release
promovida, la validación que la sostiene y los matices que una auditoría
posterior debe conocer. No introduce cambios de código.

## 1. Identidad de la release

| Campo | Valor |
|---|---|
| Código validado (último commit de código) | `82e59577258c51012f7ca8b9ed01c7e39db62c76` |
| Rama | `claude-cloud/cmm-computer-use-20261102-062200` |
| Helper | `0.3.2` |
| Build (`CFBundleVersion`) | `5` |
| CDHash promovido | `656c495ed84f5a7b0aee208e41fed8562f301bf2` |
| TeamIdentifier | `7NH822RKEQ` |
| Bundle | `com.cmm.chat.computer-use` |
| DSH plugin `stateVersion` | `12` |
| Release anterior en producción | 0.3.1 (intacta durante todos los gates previos) |

Contenido funcional de 0.3.2 respecto a 0.3.1:

- Filter pushdown: `observation.describe.element_filter`; los controles que no
  coinciden no consumen presupuesto de elementos.
- `observation.release` retira la generación: un handle viejo se rechaza con
  `reason=released`, sin `age=`.
- `USER_TAKEOVER` invalida con la misma operación compartida que release
  (`invalidateObservation(reason:)` sobre `bridgeRetireObservation`).
- PiP: título visible = nombre humano verificado; nunca el bundle id; fallback
  localizado (es `Aplicación`, en `Application`).
- Ruta de socket UNIX: validada en bytes UTF-8 contra la capacidad real de
  `sockaddr_un.sun_path`; una ruta que no cabe falla cerrada (FATAL, exit 2),
  nunca se trunca.

## 2. Validación final

| Verificación | Resultado |
|---|---|
| Source guards (`check-helper-source.py`) | PASS |
| Packaging (render-client, verify-manifest, npm pack + check-tarball) | PASS |
| Mac XCTest | **206/206 PASS** |
| Continuidad del designated requirement | PASS |
| TCC (staged y producción) | PASS |
| Gate S — socket UNIX demasiado largo | PASS |
| Gate P — filter pushdown | PASS |
| Gate R — release / generación | PASS |
| PiP real DSH | PASS (título visual `Claude`) |
| Sanity productivo final | PASS |

### Gate S — longitud de ruta del socket UNIX

- Ruta de 148 bytes rechazada; exit code 2; log `FATAL` explícito.
- No se creó ni el socket largo ni la ruta truncada histórica.

```text
GATE_S_OVERLONG_SOCKET_FAILS_CLOSED=PASS
GATE_S_NO_TRUNCATED_SOCKET_CREATED=PASS
```

### Gate P — filter pushdown (Claude real)

- `element_filter="Configuración"`: `matched=1`, `non_matching_actionable=81`,
  `skipped_non_matching=84`, `budget_skipped_controls=0`.
- Control devuelto: `AXPopUpButton "Configuración"`.

```text
GATE_P_FILTER_LATE_CONTROL=PASS
```

### Gate R — release / invalidación de generación

- Snapshot 1 retirado; nuevo snapshot 2.
- Handle viejo rechazado antes de tocar la UI con `reason=released`, sin `age=`
  de epoch.

```text
GATE_R_RELEASE=PASS
RELEASE_EPOCH_AGE_GONE=PASS
```

### PiP real DSH

- `DSH_REAL_RUNTIME=PASS`, `HELPER_STATUS=PASS`, `CLAUDE_OBSERVE=PASS`.
- Confirmación visual humana en DeepSeek Harness: el PiP muestra `Claude`, no
  `com.anthropic.claudefordesktop`.
- El fallback localizado (`Aplicación` / `Application`) está cubierto por los
  tests Node; no se ejercitó visualmente.

```text
PIP_TITLE=Claude
PIP_TITLE_IS_BUNDLE_ID=NO
```

### Sanity productivo final

- `computer_use_status`: helper `cmm-computer-use` protocol 1, bundle
  `com.cmm.chat.computer-use`, `effective_mode=background`, Accessibility y
  Screen Recording concedidos, autorización cargada (12 apps, default deny),
  Claude con scopes `control,observe`, sin latch sobre Claude.
- `computer_use_observe(app="com.anthropic.claudefordesktop", filter="Configuración")`:
  Claude en background, DeepSeek Harness permaneció frontmost, snapshot 1,
  window_id 59, `ax_filter matched=1`, control `AXButton "Configuración de Code"`
  pressable, contenido AX real accesible.

```text
PRODUCTION_HELPER_STATUS=PASS
PRODUCTION_TCC=PASS
PRODUCTION_CLAUDE_OBSERVE=PASS
PRODUCTION_PIP_TITLE_CLAUDE=PASS
```

## 3. Gate U — USER_TAKEOVER (matiz obligatorio)

```text
GATE_U=CLOSED_VERIFIED_BY_COMPOSITION
```

Gate U **no** es una prueba E2E LIVE del nuevo cableado de 0.3.2. Se cierra por
composición de evidencias:

1. **Gate B LIVE (anterior)** validó la atribución humana: takeover real,
   `attribution=user`, `human_input_detected=true`, `USER_TAKEOVER`, sin breach,
   sin latch, snapshot previo invalidado. Esa ejecución usó el binario 0.3.1,
   cuya invalidación era el antiguo timestamp a 0.
2. **Gate A LIVE (anterior)** validó el caso contrario: foco causado por la
   acción ⇒ `INTERFERENCE_BREACH`, latch persistente, fail-closed.
3. La lógica de attribution/interference (testigo HID, ventanas de
   correlación, settle, criterios de breach, latch/audit) **no cambió** en los
   commits posteriores.
4. La nueva invalidación tras takeover está cubierta por XCTest real en Mac
   (`UserTakeoverInvalidationTests`, dentro de 206/206): generación retirada,
   nuevo snapshot, handle viejo ⇒ `reason=released` sin `age=`, lista de
   generaciones retiradas acotada.
5. El cableado `if report.requiresReobserve { … invalidateObservation(reason: "user_takeover") }`
   está fijado por source guards (condición idéntica, atribución
   `user|ambiguous_external`, ningún timestamp a 0, sin latch/audit/activación/
   reintento en el bloque).
6. **Gate R LIVE** ejercitó en real la misma primitiva compartida de
   invalidación (`invalidateObservation` → `bridgeRetireObservation`).
7. La última repetición manual de Gate U fue **inconclusa**: el clic humano no
   cayó dentro de la ventana de correlación. El helper informó correctamente
   `verdict=untouched`, `human_input_detected=false`,
   `focus_change_attribution=none`, `breach=false`, `requires_reobserve=false`:
   no fabricó un takeover y no reintentó nada.

Conclusión: el riesgo residual es bajo (una sola llamada, a una función que sí
se ejercitó en LIVE por la vía de release), pero no nulo, y no debe etiquetarse
como prueba E2E LIVE de la llamada desde el bloque `USER_TAKEOVER`. No se abre
un pendiente obligatorio para 0.3.3.

## 4. Dos binarios con la etiqueta 0.3.2 build 5

Existieron dos builds distintas con la misma versión y build:

| Build | CDHash | Estado |
|---|---|---|
| Previa al fix del socket (`4ec03d3`) | `b61b5c90…` | Staged, no promovida |
| Final (`82e5957`) | `656c495ed84f5a7b0aee208e41fed8562f301bf2` | **Promovida a producción** |

Cualquier auditoría o rollback debe identificar la build por **CDHash**, no por
`0.3.2 (5)`.

## 5. Diferencia observada entre controles

- Gate P obtuvo `AXPopUpButton "Configuración"`.
- El sanity productivo obtuvo `AXButton "Configuración de Code"`.

Es coherente con pantallas/árboles AX distintos de Claude en cada momento y con
un filtro por subcadena sin distinción de mayúsculas (ambos títulos contienen
«Configuración»). No se considera un fallo.

## 6. Latch ajeno preservado

Sigue existiendo un latch de interferencia sobre:

- target `CMM Console Dev`
- bundle `com.cmm.console.development`
- kind `ui.press`

Se preservó deliberadamente: no se investigó ni se rearmó durante esta
intervención. Su eventual rearme corresponde a CMM Console (`breach.rearm`
auditado) en una intervención separada.

## 7. Integración

- La integración en `main` es por fast-forward puro desde
  `6881dda8fe074f9d5ac2cff5ebbeb898881b9e74`, sin merge commit, rebase, squash
  ni force push.
- El commit que añade este documento es exclusivamente documental; el último
  commit de código validado sigue siendo `82e5957`.

## 8. Estado final

```text
FINAL_PRODUCTION_ACCEPTANCE=PASS
CMM_COMPUTER_USE_0_3_2=CLOSED
```
