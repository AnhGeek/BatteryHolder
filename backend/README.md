# BatteryHolder Backend

Serverless firmware catalog. See [../docs/AWS_BACKEND.md](../docs/AWS_BACKEND.md)
for the full design.

## Deploy

```bash
sam build
sam deploy --guided
```

Note the stack outputs (`ApiBaseUrl`, `UserPoolId`, `UserPoolClientId`,
`FirmwareBucketName`) and paste them into `AppConfig` in the iOS app
(`ios/BatteryHolder/App/AppState.swift`).

## Local iteration

```bash
sam local start-api        # emulate the HTTP API on :3000
```

## Routes

Firmware catalog — app, Cognito JWT:

| Method | Path | Purpose |
|---|---|---|
| GET  | `/boards/{boardId}/firmware` | list builds |
| GET  | `/firmware/{buildId}` | detail + presigned URL |
| POST | `/firmware` | register a build (CI/publisher) |

Device fleet — app, Cognito JWT:

| Method | Path | Purpose |
|---|---|---|
| POST   | `/devices/claim` | claim a board, mint its device token (returned once) |
| GET    | `/devices` | the caller's devices + latest reading + online state |
| GET    | `/devices/{deviceId}` | one device + recent readings |
| POST   | `/devices/{deviceId}/commands` | queue work for the next check-in |
| DELETE | `/devices/{deviceId}` | release the board |

Device fleet — board, `X-Device-Token` (no JWT; boards have no user session):

| Method | Path | Purpose |
|---|---|---|
| POST | `/devices/{deviceId}/telemetry` | store a reading, drain the command queue |

Payloads and the command vocabulary are specified in
[../docs/DEVICE_PROTOCOL.md](../docs/DEVICE_PROTOCOL.md) §5.
