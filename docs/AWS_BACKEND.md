# AWS Backend — Firmware Distribution + Device Fleet

The backend is **serverless** and does two jobs: it stores firmware builds and
serves them to the app securely, and it is the endpoint that Wi‑Fi‑mode boards
check in with while the phone is nowhere near them.

Boards never hold a Cognito session. They are provisioned over Bluetooth with a
backend URL and a **device token**, and authenticate with that token on a single
route. Everything else is JWT‑authorized as before.

## Overview

```
           ┌──────────────┐   HTTPS (JWT)    ┌───────────────┐
  iOS app  │ FirmwareRepo │ ───────────────▶ │  API Gateway  │
           └──────┬───────┘                  │  (HTTP API)   │
                  │                          └──────┬────────┘
                  │  presigned GET                  │ Lambda proxy
                  ▼                                  ▼
           ┌──────────────┐   metadata    ┌────────────────────┐
           │      S3      │◀──────────────│   Lambda (Node)    │
           │ firmware/*.  │               │ list / detail /    │
           │ bin (blobs)  │──presign URL─▶│ presign / register │
           └──────────────┘               └─────────┬──────────┘
                                                     ▼
                                          ┌────────────────────┐
                                          │     DynamoDB       │
                                          │  FirmwareTable     │
                                          │  (build metadata)  │
                                          └────────────────────┘

     Auth: Amazon Cognito User Pool  ──▶  JWT authorizer on API Gateway
     CI/CD publisher: PutObject to S3 + PutItem to DynamoDB
```

## Components

| Service | Purpose |
|---|---|
| **S3** | Stores the immutable `.bin` firmware artifacts. Private bucket; access only via presigned URLs. |
| **DynamoDB** | `FirmwareTable` — one item per build: board, version, size, sha256, S3 key, release notes, channel (`stable`/`beta`). |
| **Lambda** | Business logic behind the API: list builds for a board, get detail, mint a presigned download URL, register a new build (CI). |
| **API Gateway (HTTP API)** | Public REST surface, JWT‑authorized. |
| **Cognito User Pool** | Issues JWTs for app users. The app signs in and attaches the token as `Authorization: Bearer`. |
| **CloudWatch** | Logs + metrics for Lambda and API Gateway. |

## Data model — `FirmwareTable`

| Attribute | Type | Notes |
|---|---|---|
| `PK` | S | `BOARD#esp32-wroom` (partition = board id) |
| `SK` | S | `VER#1.4.2#stable` (sort = version+channel) |
| `version` | S | `1.4.2` |
| `channel` | S | `stable` \| `beta` |
| `s3Key` | S | `firmware/esp32-wroom/1.4.2.bin` |
| `sizeBytes` | N | artifact size |
| `sha256` | S | integrity hash the app verifies before flashing |
| `releaseNotes` | S | markdown |
| `createdAt` | S | ISO‑8601 |

Query pattern: `PK = BOARD#<id>` returns every build for a board, newest first.

## Data model — devices & telemetry

Same table, different partitions. `ttl` expires telemetry history automatically
(30 days by default).

| Item | PK | SK | Notes |
|---|---|---|---|
| Device | `DEVICE#bh-a1b2…` | `META` | owner, name, boardId, `tokenHash`, `reportIntervalSec` |
| Latest state | `DEVICE#bh-a1b2…` | `STATE` | last reading + `fw`, `ip`, `timestamp` |
| Reading | `DEVICE#bh-a1b2…` | `TS#2026-08-18T09:14:02Z` | raw/volts/soc/rssi, TTL'd |
| Queued command | `DEVICE#bh-a1b2…` | `CMD#<iso>` | deleted once delivered |

`GSI1` (`GSI1PK = USER#<sub>`) answers "every device this user owns".

## REST API

Base URL after deploy: `https://{api-id}.execute-api.{region}.amazonaws.com/prod`

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/boards/{boardId}/firmware` | JWT | List builds for a board |
| `GET` | `/firmware/{buildId}` | JWT | Build detail + `downloadUrl` (presigned, 5‑min TTL) |
| `POST` | `/firmware` | JWT (publisher scope) | Register a new build (used by CI) |
| `POST` | `/devices/claim` | JWT | Claim a board; returns its device token **once** |
| `GET` | `/devices` | JWT | The user's devices, latest reading, online state |
| `GET` | `/devices/{deviceId}` | JWT | One device + recent readings |
| `POST` | `/devices/{deviceId}/commands` | JWT | Queue work for the next check-in |
| `DELETE` | `/devices/{deviceId}` | JWT | Release the board |
| `POST` | `/devices/{deviceId}/telemetry` | **Device token** | Board check-in |

### Claim → provision → check in

```
 app ──POST /devices/claim───────────────▶ backend   (mints deviceToken, stores its SHA-256)
 app ──BLE write {ssid, password,
        backendUrl, deviceToken}────────▶ board     (verifies Wi-Fi, then commits)
 board ─POST /devices/{id}/telemetry────▶ backend   (every reportIntervalSec, forever)
        ◀── { nextReportSec, stayAwakeMs, commands[] }
```

The board is asleep between check-ins, so anything the app wants to change is
**queued**, not pushed: `setConfig`, `setPower`, `setMode`, `identify`,
`stayAwake`, `ble`, `ota`. An `ota` command carrying a `buildId` makes the
Lambda mint the presigned S3 URL itself, so the board pulls firmware directly
and the phone is never in the path. Full payloads in
[DEVICE_PROTOCOL.md](DEVICE_PROTOCOL.md) §5.

Example — list builds:

```http
GET /boards/esp32-wroom/firmware
Authorization: Bearer <jwt>
```
```json
{
  "items": [
    {
      "buildId": "esp32-wroom_1.4.2_stable",
      "version": "1.4.2",
      "channel": "stable",
      "sizeBytes": 918272,
      "sha256": "9f2c…",
      "releaseNotes": "Fix ADC1 calibration on WROOM-32E",
      "createdAt": "2026-08-01T09:12:00Z"
    }
  ]
}
```

Example — get download URL:

```json
{
  "buildId": "esp32-wroom_1.4.2_stable",
  "downloadUrl": "https://s3…X-Amz-Signature=…",
  "sha256": "9f2c…",
  "expiresIn": 300
}
```

The app downloads the `.bin`, verifies `sha256`, then hands it to
`FirmwareFlasher` for BLE or Wi‑Fi OTA.

## Deploy (AWS SAM)

The full stack is defined in [`backend/template.yaml`](../backend/template.yaml).

```bash
cd backend
sam build
sam deploy --guided        # first time: pick region, stack name, confirm
# Outputs: ApiBaseUrl, UserPoolId, UserPoolClientId, FirmwareBucketName
```

Then wire the app:

```swift
// ios/BatteryHolder/App/AppState.swift
struct AppConfig {
    static let firmwareApiBaseURL = URL(string: "https://<api-id>.execute-api.<region>.amazonaws.com/prod")!
    static let cognitoUserPoolId  = "<UserPoolId>"
    static let cognitoClientId    = "<UserPoolClientId>"
}
```

## Publishing a build from CI

```bash
aws s3 cp build/firmware.bin s3://$BUCKET/firmware/esp32-wroom/1.4.2.bin
curl -X POST "$API/firmware" \
  -H "Authorization: Bearer $CI_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
        "boardId": "esp32-wroom",
        "version": "1.4.2",
        "channel": "stable",
        "s3Key": "firmware/esp32-wroom/1.4.2.bin",
        "sizeBytes": 918272,
        "sha256": "9f2c…",
        "releaseNotes": "Fix ADC1 calibration"
      }'
```

## Cost & scaling

Everything is pay‑per‑use and sits comfortably in the free tier for hobby use:
Lambda (first 1M req/mo free), DynamoDB on‑demand, API Gateway HTTP API
(cheaper than REST API), S3 storage pennies/GB. No idle servers.

## Security

- Bucket is **private**; downloads only through short‑lived presigned URLs.
- API is JWT‑authorized via Cognito; the `POST /firmware` publisher route
  additionally checks a `publisher` scope/group.
- `sha256` in metadata lets the app detect a corrupted or tampered artifact
  before it ever reaches the board.
- Least‑privilege IAM: the Lambda role can only `GetObject`/`PutObject` on the
  firmware prefix and read/write the one DynamoDB table.
- Device tokens are random 24‑byte values, stored only as SHA‑256, and scoped to
  a single device's telemetry path. Re‑claiming a board rotates its token.
- The telemetry route is the one unauthenticated‑by‑JWT route in the API; it
  rejects any request whose token hash does not match the claimed device, and a
  board that was never claimed gets a 404 rather than a stored reading.
