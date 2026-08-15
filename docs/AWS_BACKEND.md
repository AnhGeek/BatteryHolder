# AWS Backend — Firmware Distribution

The backend is **serverless** and does one job well: store firmware builds and
serve them to the app securely. Boards are flashed by the phone (BLE/Wi‑Fi), so
the cloud never talks to a device directly — it is a firmware catalog and CDN.

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

## REST API

Base URL after deploy: `https://{api-id}.execute-api.{region}.amazonaws.com/prod`

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/boards/{boardId}/firmware` | JWT | List builds for a board |
| `GET` | `/firmware/{buildId}` | JWT | Build detail + `downloadUrl` (presigned, 5‑min TTL) |
| `POST` | `/firmware` | JWT (publisher scope) | Register a new build (used by CI) |

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
