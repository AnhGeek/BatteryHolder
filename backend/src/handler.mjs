// BatteryHolder API Lambda.
//
// Firmware catalog (app, Cognito JWT):
//   GET  /boards/{boardId}/firmware  -> list builds for a board
//   GET  /firmware/{buildId}         -> detail + presigned download URL
//   POST /firmware                   -> register a new build (CI)
//
// Device fleet (app, Cognito JWT):
//   POST   /devices/claim              -> claim a board, mint its device token
//   GET    /devices                    -> the caller's devices + latest state
//   GET    /devices/{deviceId}         -> one device, state + recent readings
//   POST   /devices/{deviceId}/commands-> queue a command for the next check-in
//   DELETE /devices/{deviceId}         -> release the board
//
// Device fleet (board, X-Device-Token — no JWT, boards have no user session):
//   POST /devices/{deviceId}/telemetry -> store a reading, drain the command queue

import { createHash, randomBytes } from 'node:crypto';

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient, QueryCommand, GetCommand, PutCommand,
  DeleteCommand, UpdateCommand, BatchWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

const TABLE = process.env.FIRMWARE_TABLE;
const BUCKET = process.env.FIRMWARE_BUCKET;
const TTL = Number(process.env.PRESIGN_TTL || 300);
const READING_TTL_DAYS = Number(process.env.READING_TTL_DAYS || 30);
const DEFAULT_REPORT_SEC = Number(process.env.DEFAULT_REPORT_SEC || 900);

const json = (statusCode, body) => ({
  statusCode,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

const buildId = (boardId, version, channel) => `${boardId}_${version}_${channel}`;

export const handler = async (event) => {
  const route = event.routeKey; // e.g. "GET /firmware/{buildId}"
  try {
    switch (route) {
      // Firmware catalog.
      case 'GET /boards/{boardId}/firmware': return await listForBoard(event);
      case 'GET /firmware/{buildId}':        return await getDetail(event);
      case 'POST /firmware':                 return await register(event);
      // Fleet — app.
      case 'POST /devices/claim':               return await claimDevice(event);
      case 'GET /devices':                      return await listDevices(event);
      case 'GET /devices/{deviceId}':           return await getDevice(event);
      case 'POST /devices/{deviceId}/commands': return await queueCommand(event);
      case 'DELETE /devices/{deviceId}':        return await releaseDevice(event);
      // Fleet — device.
      case 'POST /devices/{deviceId}/telemetry': return await telemetry(event);
      default: return json(404, { message: 'Not found' });
    }
  } catch (err) {
    console.error(err);
    return json(500, { message: 'Internal error' });
  }
};

// ------------------------------------------------------------- firmware -----

async function listForBoard(event) {
  const boardId = event.pathParameters.boardId;
  const res = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'PK = :pk',
    ExpressionAttributeValues: { ':pk': `BOARD#${boardId}` },
    ScanIndexForward: false, // newest first
  }));
  const items = (res.Items || []).map(toApiItem);
  return json(200, { items });
}

async function getDetail(event) {
  const id = event.pathParameters.buildId;
  const [boardId, version, channel] = id.split('_');
  const res = await ddb.send(new GetCommand({
    TableName: TABLE,
    Key: { PK: `BOARD#${boardId}`, SK: `VER#${version}#${channel}` },
  }));
  if (!res.Item) return json(404, { message: 'Build not found' });

  const downloadUrl = await presign(res.Item.s3Key);
  return json(200, { ...toApiItem(res.Item), downloadUrl, expiresIn: TTL });
}

async function register(event) {
  // In production, gate this on a Cognito "publisher" group/scope.
  const b = JSON.parse(event.body || '{}');
  for (const f of ['boardId', 'version', 'channel', 's3Key', 'sizeBytes', 'sha256']) {
    if (b[f] === undefined) return json(400, { message: `Missing field: ${f}` });
  }
  const item = {
    PK: `BOARD#${b.boardId}`,
    SK: `VER#${b.version}#${b.channel}`,
    version: b.version,
    channel: b.channel,
    s3Key: b.s3Key,
    sizeBytes: b.sizeBytes,
    sha256: b.sha256,
    releaseNotes: b.releaseNotes || '',
    createdAt: new Date().toISOString(),
  };
  await ddb.send(new PutCommand({ TableName: TABLE, Item: item }));
  return json(201, { buildId: buildId(b.boardId, b.version, b.channel), ...toApiItem(item) });
}

function toApiItem(item) {
  const boardId = item.PK.replace('BOARD#', '');
  return {
    buildId: buildId(boardId, item.version, item.channel),
    boardId,
    version: item.version,
    channel: item.channel,
    sizeBytes: item.sizeBytes,
    sha256: item.sha256,
    releaseNotes: item.releaseNotes,
    createdAt: item.createdAt,
  };
}

const presign = (key) => getSignedUrl(
  s3, new GetObjectCommand({ Bucket: BUCKET, Key: key }), { expiresIn: TTL },
);

// ---------------------------------------------------------------- fleet -----

const userSub = (event) => event.requestContext?.authorizer?.jwt?.claims?.sub;
const hashToken = (token) => createHash('sha256').update(token).digest('hex');

const deviceKey = (deviceId) => ({ PK: `DEVICE#${deviceId}`, SK: 'META' });
const stateKey = (deviceId) => ({ PK: `DEVICE#${deviceId}`, SK: 'STATE' });

async function loadDevice(deviceId) {
  const res = await ddb.send(new GetCommand({ TableName: TABLE, Key: deviceKey(deviceId) }));
  return res.Item;
}

// The app claims a board it has just met over BLE. The plaintext token is
// returned exactly once — the app writes it straight into the board's
// provisioning characteristic and never stores it.
async function claimDevice(event) {
  const sub = userSub(event);
  if (!sub) return json(401, { message: 'Unauthorized' });

  const b = JSON.parse(event.body || '{}');
  if (!b.deviceId) return json(400, { message: 'Missing field: deviceId' });

  const existing = await loadDevice(b.deviceId);
  if (existing && existing.ownerSub !== sub) {
    // Already owned by somebody else: the physical holder must factory-reset it.
    return json(409, { message: 'Device already claimed' });
  }

  const token = randomBytes(24).toString('hex');
  const now = new Date().toISOString();
  const item = {
    ...deviceKey(b.deviceId),
    GSI1PK: `USER#${sub}`,
    GSI1SK: `DEVICE#${b.deviceId}`,
    deviceId: b.deviceId,
    ownerSub: sub,
    name: b.name || existing?.name || b.deviceId,
    boardId: b.boardId || existing?.boardId || 'esp32-wroom',
    transport: b.transport || 'wifi',
    reportIntervalSec: b.reportIntervalSec || existing?.reportIntervalSec || DEFAULT_REPORT_SEC,
    tokenHash: hashToken(token),
    claimedAt: existing?.claimedAt || now,
    updatedAt: now,
  };
  await ddb.send(new PutCommand({ TableName: TABLE, Item: item }));

  return json(201, {
    deviceId: item.deviceId,
    deviceToken: token,               // shown once, then only its hash is kept
    backendUrl: apiBaseUrl(event),
    reportIntervalSec: item.reportIntervalSec,
    name: item.name,
  });
}

async function listDevices(event) {
  const sub = userSub(event);
  if (!sub) return json(401, { message: 'Unauthorized' });

  const res = await ddb.send(new QueryCommand({
    TableName: TABLE,
    IndexName: 'GSI1',
    KeyConditionExpression: 'GSI1PK = :pk',
    ExpressionAttributeValues: { ':pk': `USER#${sub}` },
  }));

  const items = await Promise.all((res.Items || []).map(async (d) => {
    const state = await ddb.send(new GetCommand({ TableName: TABLE, Key: stateKey(d.deviceId) }));
    return toApiDevice(d, state.Item);
  }));
  return json(200, { items });
}

async function getDevice(event) {
  const sub = userSub(event);
  const deviceId = event.pathParameters.deviceId;
  const device = await loadDevice(deviceId);
  if (!device || device.ownerSub !== sub) return json(404, { message: 'Device not found' });

  const [state, readings] = await Promise.all([
    ddb.send(new GetCommand({ TableName: TABLE, Key: stateKey(deviceId) })),
    ddb.send(new QueryCommand({
      TableName: TABLE,
      KeyConditionExpression: 'PK = :pk AND begins_with(SK, :sk)',
      ExpressionAttributeValues: { ':pk': `DEVICE#${deviceId}`, ':sk': 'TS#' },
      ScanIndexForward: false,
      Limit: Number(event.queryStringParameters?.limit || 200),
    })),
  ]);

  return json(200, {
    ...toApiDevice(device, state.Item),
    readings: (readings.Items || []).map((r) => ({
      timestamp: r.SK.replace('TS#', ''),
      raw: r.raw,
      volts: r.volts,
      soc: r.soc,
      rssi: r.rssi,
    })).reverse(),
  });
}

// Queue work for the board's next check-in. Boards are asleep most of the time,
// so a command is a promise to act, not an immediate effect: the response says
// when the device is expected to pick it up.
async function queueCommand(event) {
  const sub = userSub(event);
  const deviceId = event.pathParameters.deviceId;
  const device = await loadDevice(deviceId);
  if (!device || device.ownerSub !== sub) return json(404, { message: 'Device not found' });

  const body = JSON.parse(event.body || '{}');
  const commands = Array.isArray(body.commands) ? body.commands : [body];
  const allowed = new Set(['setConfig', 'setPower', 'setMode', 'identify', 'stayAwake', 'ble', 'ota']);
  for (const cmd of commands) {
    if (!allowed.has(cmd?.type)) return json(400, { message: `Unsupported command: ${cmd?.type}` });
  }

  const now = Date.now();
  const items = [];
  for (const [i, raw] of commands.entries()) {
    let cmd = raw;
    // An OTA command carries a presigned URL the board fetches by itself.
    if (cmd.type === 'ota' && cmd.buildId && !cmd.url) {
      const [boardId, version, channel] = cmd.buildId.split('_');
      const build = await ddb.send(new GetCommand({
        TableName: TABLE, Key: { PK: `BOARD#${boardId}`, SK: `VER#${version}#${channel}` },
      }));
      if (!build.Item) return json(400, { message: `Unknown build: ${cmd.buildId}` });
      cmd = { ...cmd, url: await presign(build.Item.s3Key), sha256: build.Item.sha256 };
    }
    items.push({
      PK: `DEVICE#${deviceId}`,
      SK: `CMD#${new Date(now + i).toISOString()}`,
      command: cmd,
      queuedAt: new Date(now).toISOString(),
      ttl: Math.floor(now / 1000) + 7 * 24 * 3600,
    });
  }

  await Promise.all(items.map((Item) => ddb.send(new PutCommand({ TableName: TABLE, Item }))));

  const state = await ddb.send(new GetCommand({ TableName: TABLE, Key: stateKey(deviceId) }));
  return json(202, {
    queued: items.length,
    // Rough hint for the UI: "the board will pick this up within N seconds."
    deliverWithinSec: device.reportIntervalSec || DEFAULT_REPORT_SEC,
    lastSeen: state.Item?.timestamp || null,
  });
}

async function releaseDevice(event) {
  const sub = userSub(event);
  const deviceId = event.pathParameters.deviceId;
  const device = await loadDevice(deviceId);
  if (!device || device.ownerSub !== sub) return json(404, { message: 'Device not found' });

  await ddb.send(new DeleteCommand({ TableName: TABLE, Key: deviceKey(deviceId) }));
  return json(200, { released: deviceId });
}

// The board's only endpoint. Authenticated by the token it was provisioned
// with over BLE, not by a user session.
async function telemetry(event) {
  const deviceId = event.pathParameters.deviceId;
  const token = event.headers?.['x-device-token'] || event.headers?.['X-Device-Token'];
  const device = await loadDevice(deviceId);
  if (!device) return json(404, { message: 'Device not claimed' });
  if (!token || hashToken(token) !== device.tokenHash) {
    return json(401, { message: 'Bad device token' });
  }

  const b = JSON.parse(event.body || '{}');
  const now = new Date();
  const iso = now.toISOString();

  const reading = {
    raw: b.raw ?? null,
    volts: b.volts ?? null,
    soc: b.soc ?? null,
    rssi: b.rssi ?? null,
  };

  await Promise.all([
    // Latest state, cheap to read for the device list.
    ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        ...stateKey(deviceId),
        ...reading,
        deviceId,
        fw: b.fw || null,
        ip: b.ip || null,
        pin: b.pin || null,
        boot: b.boot ?? null,
        uptimeMs: b.uptimeMs ?? null,
        wake: b.wake ?? null,
        timestamp: iso,
      },
    })),
    // History point, expired by DynamoDB TTL.
    ddb.send(new PutCommand({
      TableName: TABLE,
      Item: {
        PK: `DEVICE#${deviceId}`,
        SK: `TS#${iso}`,
        ...reading,
        ttl: Math.floor(now.getTime() / 1000) + READING_TTL_DAYS * 24 * 3600,
      },
    })),
    ddb.send(new UpdateCommand({
      TableName: TABLE,
      Key: deviceKey(deviceId),
      UpdateExpression: 'SET lastSeen = :ts, fw = :fw',
      ExpressionAttributeValues: { ':ts': iso, ':fw': b.fw || null },
    })),
  ]);

  // Drain the command queue: the board applies these before it sleeps again.
  const pending = await ddb.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'PK = :pk AND begins_with(SK, :sk)',
    ExpressionAttributeValues: { ':pk': `DEVICE#${deviceId}`, ':sk': 'CMD#' },
    Limit: 10,
  }));
  const commands = (pending.Items || []).map((i) => i.command);

  if (pending.Items?.length) {
    await ddb.send(new BatchWriteCommand({
      RequestItems: {
        [TABLE]: pending.Items.map((i) => ({
          DeleteRequest: { Key: { PK: i.PK, SK: i.SK } },
        })),
      },
    }));
  }

  return json(200, {
    ack: true,
    serverTime: iso,
    nextReportSec: device.reportIntervalSec || DEFAULT_REPORT_SEC,
    // Anything that needs a round trip (OTA, a phone about to connect) keeps
    // the board awake past its normal window.
    stayAwakeMs: commands.some((c) => ['ota', 'ble', 'stayAwake'].includes(c.type)) ? 60000 : 0,
    commands,
  });
}

function toApiDevice(device, state) {
  const reportSec = device.reportIntervalSec || DEFAULT_REPORT_SEC;
  const lastSeen = state?.timestamp || device.lastSeen || null;
  // A sleeping board is "online" if it checked in within two report cycles.
  const online = lastSeen
    ? Date.now() - Date.parse(lastSeen) < reportSec * 2000
    : false;
  return {
    deviceId: device.deviceId,
    name: device.name,
    boardId: device.boardId,
    transport: device.transport,
    reportIntervalSec: reportSec,
    claimedAt: device.claimedAt,
    fw: state?.fw || device.fw || null,
    lastSeen,
    online,
    latest: state ? {
      timestamp: state.timestamp,
      raw: state.raw,
      volts: state.volts,
      soc: state.soc,
      rssi: state.rssi,
      ip: state.ip,
      pin: state.pin,
    } : null,
  };
}

// The board needs an absolute URL to POST to; derive it from the invoking
// request so a claim minted on any stage points back at that same stage.
function apiBaseUrl(event) {
  if (process.env.API_BASE_URL) return process.env.API_BASE_URL;
  const host = event.requestContext?.domainName;
  const stage = event.requestContext?.stage;
  if (!host) return '';
  return stage && stage !== '$default' ? `https://${host}/${stage}` : `https://${host}`;
}
