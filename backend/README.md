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

| Method | Path | Purpose |
|---|---|---|
| GET  | `/boards/{boardId}/firmware` | list builds |
| GET  | `/firmware/{buildId}` | detail + presigned URL |
| POST | `/firmware` | register a build (CI/publisher) |
