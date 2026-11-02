# Cambio requerido en CMM Console — desbloqueo (rearm) de breaches

**Estado:** el lado helper (protocolo, estado persistente, auditoría, decisión
de autoridad) está implementado en esta rama. **El lado Console no**: CMM
Console es otro proyecto y no está en esta sesión. Hasta que se implemente, un
breach queda latcheado y **no hay UX de desbloqueo** — de forma deliberada: el
reinicio del helper no lo limpia y no debe convertirse en el mecanismo.

Mientras tanto, para el LIVE controlado existe un sustituto de prueba:
`scripts/verification/rearm-probe` (`com.cmm.computer-use.test-rearm`), sólo
`breach.status`/`breach.rearm`, motivo obligatorio, y que sólo funciona en un
carril aislado (`CMM-Computer-Use-LIVE-Aislado-20261102.md`). No es la UX ni
debe añadirse a la política de producción.

## 1. Política (v2): conceder el permiso sólo a Console

```json
{
  "version": 2,
  "mode": "background",
  "default": "deny",
  "clients": [
    {
      "client_id": "cmm-console",
      "requirement": "identifier \"com.cmm.console\" and anchor apple generic and certificate leaf[subject.OU] = \"TEAMID\"",
      "apps": [],
      "scopes": [],
      "admin": ["breach.rearm"]
    },
    {
      "client_id": "dsh-agent",
      "requirement": "…requirement del proceso del adaptador…",
      "apps": ["com.anthropic.claudefordesktop"],
      "scopes": ["observe", "control"]
    }
  ],
  "apps": [
    { "bundle_id": "com.anthropic.claudefordesktop", "scopes": ["observe", "control"] }
  ]
}
```

- `admin` es un conjunto cerrado; un valor desconocido invalida el documento.
- Console NO necesita `apps`/`scopes` para rearmar: rearmar no es operar apps.
- El cliente agente nunca recibe `admin`. Aunque lo recibiera, no podría
  rearmar un breach causado por él mismo (`self_rearm_not_permitted`).
- En política v1 (sin `clients`) el rearm está **cerrado**
  (`rearm_requires_client_identity`): migrar a v2 es requisito.

## 2. Lectura: listar breaches abiertos

Por el socket del helper (`~/.cmm/computer-bridge/bridge.sock`), NDJSON v1:

```json
{"version":1,"id":"…","operation":"breach.status","arguments":{}}
```

Respuesta: `state` (`ok`/`invalid`), `breaches[]` con `id`, `target_name`,
`target_bundle`, `kind`, `policy`, `at`, `verdict`, `focus_became_target`,
`window_raised_over_person`, `target_front_at_ms`, `client_id`; y las rutas
`latch_path`/`audit_path`.

UI mínima: lista por app (nombre humano, bundle como detalle), hora, qué acción,
qué cliente, si fue activación o ventana elevada, y a cuántos ms.

## 3. Escritura: rearm explícito

```json
{"version":1,"id":"…","operation":"breach.rearm",
 "arguments":{"breach_id":"<uuid>","reason":"Revisado: el agente pulsó zoom; se desactivó esa ruta"}}
```

- Botón "Rearmar" por breach, con **motivo obligatorio** (campo de texto; el
  helper lo sanea y lo limita a 500 caracteres).
- Confirmación previa mostrando qué se desbloquea.
- Mostrar la entrada de auditoría devuelta (`audit`) y refrescar `breach.status`.
- Errores a presentar tal cual: `auth=rearm_not_granted`,
  `auth=client_not_authorized` (Console no firmado como dice la política),
  `reason=unknown_breach`, `reason=latch_write_failed` (sigue latcheado).

Estado inválido (`state: invalid`): ofrecer "Restablecer latch" →
`{"reset_invalid_state": true, "reason": "…"}`; también auditado.

## 4. Auditoría

`breach-audit.jsonl` junto a la política. Console debería mostrar el
historial (`latched`, `rearmed`, `rearm_refused`, `reset_invalid`,
`cleared_outside_console`, `latch_write_failed`) y avisar de
`cleared_outside_console`: alguien editó o borró el archivo a mano.

## 5. Verificación del lado Console (cuando exista)

1. Provocar un breach controlado (fixture, `live-background-e2e.sh --breach-control`).
2. Reiniciar el helper → `breach.status` sigue mostrándolo; el control sigue rechazado.
3. Rearmar desde el agente/adaptador → imposible (no hay herramienta).
4. Rearmar desde un binario firmado distinto de Console → `rearm_not_granted` o `client_not_authorized`, auditado como `rearm_refused`.
5. Rearmar desde Console con motivo → `rearmed` en la auditoría; el control vuelve a funcionar en una sesión DSH nueva.
