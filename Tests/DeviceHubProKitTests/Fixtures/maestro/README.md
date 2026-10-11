# Maestro CLI captures

Real output of the Maestro CLI 2.11.0 (`maestro.zip` of the `cli-2.11.0`
release, sha256 `5384593c…283a`), run with
`MAESTRO_CLI_NO_ANALYTICS=1 MAESTRO_DISABLE_UPDATE_CHECK=1
MAESTRO_CLI_ANALYSIS_NOTIFICATION_DISABLED=true` on OpenJDK 21, byte for byte.
No device was attached, so there is no capture of a running flow: the step
lines `MaestroOutputParserTests` reads are SOURCE-DERIVED (see that test).

| File | Command | Stream, exit |
|---|---|---|
| `version.txt` | `maestro --version` | stdout, 0 |
| `check-syntax-ok.txt` | `maestro check-syntax -` with a valid flow on stdin | stdout, 0 |
| `check-syntax-invalid-command.err.txt` | the same with `- tapOnn: "Sign in"` as the last line | stderr, 1 |
| `check-syntax-misplaced-command.err.txt` | the same with `  - tapOn: "x"` indented under `- launchApp` | stderr, 1 |
| `check-syntax-empty.err.txt` | the same with empty stdin | stderr, 1 |
| `test-device-not-connected.err.txt` | `maestro test --no-ansi --device emulator-5554 f.yaml` with no device | stderr, 1 |

The flows on stdin were:

```yaml
appId: com.example.app
---
- launchApp
- tapOn: "Sign in"
```
