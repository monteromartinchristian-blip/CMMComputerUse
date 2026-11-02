# Validación en el Mac — orden obligatorio (2026-11-02)

Rama: `claude-cloud/cmm-computer-use-20261102-062200`. Cada fase es una
**puerta**: si falla, se para y se reporta la salida; no se pasa a la siguiente.
Ninguna fase de 1–3 instala nada, toca TCC, el LaunchAgent ni el socket real.

```bash
cd ~/"CMM Desarrollo/CMM Computer Use"
git fetch origin claude-cloud/cmm-computer-use-20261102-062200
git status                        # debe estar limpio antes de cambiar de rama
git switch claude-cloud/cmm-computer-use-20261102-062200
git pull --ff-only
git log --oneline -4
```

## Fase 1 — Node / Python / manifest / contrato estático

```bash
cd packages/dsh-computer-use
node --test tests/*.test.mjs
(cd adapter && python3 -m unittest discover -s tests)
node scripts/render-client.mjs --check
node scripts/verify-manifest.mjs
cd ../..
python3 -I scripts/verification/check-helper-source.py
(cd packages/dsh-computer-use && python3 -m unittest tests/test_patch.py)   # necesita /usr/bin/ruby
node packages/dsh-computer-use/tests/official-host.cjs packages/dsh-computer-use   # necesita DeepSeek Harness.app
```

Obtenido en la nube (Linux): Node 106/106, Python 70/70, manifest OK,
`check-helper-source` 8/8 PASS. `test_patch.py` (9 tests) y
`official-host.cjs` **no se han podido ejecutar en la nube** sobre esta rama
(falta ruby / DeepSeek Harness.app): su resultado en el Mac es nuevo.

## Fase 2 — XcodeGen + Swift 6 + XCTest

```bash
cd apps/macos
xcodegen generate
xcodebuild -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tee /tmp/cmm-build.log | tail -30
xcodebuild test -project CMMComputerUse.xcodeproj -scheme CMMComputerUse \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/cmm-test.log | tail -40
grep -E "error:|warning: .*(Sendable|concurrency|actor)" /tmp/cmm-build.log | head -40
cd ../..
```

`project.yml` fija `SWIFT_VERSION: 6.0`, así que esta fase es la que compila en
modo Swift 6 estricto. Suites nuevas que deben aparecer y pasar:
`BackgroundInterferenceTests`, `BreachLatchTests`; además las existentes
(`ComputerUsePolicyTests`, `ComputerUseAuthorizationTests`, `BridgeTargetingTests`,
`ComputerUseRequirementTests`). **Este código Swift no se ha compilado nunca**:
errores de compilación son el resultado más probable de esta fase y se corrigen
antes de seguir.

## Fase 3 — Build staged del helper, SIN instalar

```bash
CMM_HELPER_BUILD_DIR="$PWD/build/stage-20261102" scripts/build-helper.sh   # sin --install
STAGED="$PWD/build/stage-20261102/CMMComputerUse.app"
codesign --verify --deep --strict "$STAGED" && echo signature-ok
codesign -dv --verbose=4 "$STAGED" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority" | head
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" -c "Print :CFBundleShortVersionString" \
  -c "Print :CFBundleVersion" "$STAGED/Contents/Info.plist"
"$STAGED/Contents/MacOS/CMMComputerUse" --preflight-only
ls -la ~/Applications/CMMComputerUse.app/Contents/MacOS/   # fecha: debe seguir siendo la del helper INSTALADO anterior
```

Esperado: compila con `swiftc` (modo de lenguaje por defecto, no Swift 6 —
por eso la Fase 2 va antes), firma válida, `com.cmm.chat.computer-use`,
`0.3.0` / `3`, `--preflight-only` imprime el JSON sin tocar TCC ni socket, y el
helper instalado no ha cambiado.

Fíjate en qué identidad usa la firma (`signed_with:` al final). Si sale
`ad-hoc`, los permisos TCC del helper instalado **no** valdrán para éste: hay
que resolverlo antes de la fase 4.

## Fase 4 — Sólo si 1–3 pasan: instalación y LIVE

No se hace en esta iteración sin tu confirmación. Resumen de lo que vendrá:

1. Copia de seguridad: `~/Applications/CMMComputerUse.app`, `~/.cmm/computer-bridge/policy.json`.
2. `scripts/build-helper.sh --install && scripts/install-helper.sh`.
3. Política con el fixture (`observe,control`) y Claude; idealmente v2 con
   Console `admin: ["breach.rearm"]`.
4. `scripts/verification/live-background-e2e.sh --electron-app com.anthropic.claudefordesktop`
5. `scripts/verification/live-background-e2e.sh --breach-control` (último).
6. Reiniciar el helper y comprobar con `computer_use_status` que el latch
   **sigue** ahí (`breach_latch: state=ok open=1`): el reinicio no desbloquea.
7. Hasta que exista el rearm en Console, desbloquear el fixture es un paso
   manual y auditado como `cleared_outside_console` (editar
   `breach-latch.json` + `policy.reload`). Es para el banco de pruebas, no la
   UX.

## Qué traer de vuelta

- Fase 1: los recuentos `pass/fail` y cualquier `FAIL`.
- Fase 2: `tail` de `/tmp/cmm-build.log` y `/tmp/cmm-test.log`, y los `error:`.
- Fase 3: salida completa de `build-helper.sh` y de `--preflight-only`.
