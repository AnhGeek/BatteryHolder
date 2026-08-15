// BatteryHolder firmware catalog Lambda.
// Routes:
//   GET  /boards/{boardId}/firmware  -> list builds for a board
//   GET  /firmware/{buildId}         -> detail + presigned download URL
//   POST /firmware                   -> register a new build (CI)

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient, QueryCommand, GetCommand, PutCommand,
} from '@aws-sdk/lib-dynamodb';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3 = new S3Client({});

const TABLE = process.env.FIRMWARE_TABLE;
const BUCKET = process.env.FIRMWARE_BUCKET;
const TTL = Number(process.env.PRESIGN_TTL || 300);

const json = (statusCode, body) => ({
  statusCode,
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});

const buildId = (boardId, version, channel) => `${boardId}_${version}_${channel}`;

export const handler = async (event) => {
  const route = event.routeKey; // e.g. "GET /firmware/{buildId}"
  try {
    if (route === 'GET /boards/{boardId}/firmware') return await listForBoard(event);
    if (route === 'GET /firmware/{buildId}') return await getDetail(event);
    if (route === 'POST /firmware') return await register(event);
    return json(404, { message: 'Not found' });
  } catch (err) {
    console.error(err);
    return json(500, { message: 'Internal error' });
  }
};

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

  const downloadUrl = await getSignedUrl(
    s3,
    new GetObjectCommand({ Bucket: BUCKET, Key: res.Item.s3Key }),
    { expiresIn: TTL },
  );
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
