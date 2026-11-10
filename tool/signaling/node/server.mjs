// Notation signalling server (Node). Protocol: see ../README.md.
//
//   npm install && node server.mjs            (PORT=8787 HOST=0.0.0.0 by default)
//
// Relays every text frame to the other devices in the same room and keeps nothing.
import { createServer } from 'node:http';
import { createHash, createPublicKey, randomBytes, verify } from 'node:crypto';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? '0.0.0.0';
const MAX_PEERS = 8; // devices per room
const MAX_BYTES = 64 * 1024; // per frame
// A device may ask for the servers of a relay (TURN); this server has none, and says so at once, so that nobody waits for it.
const ICE_REQUEST = '{"s":"ice"}';
const NO_RELAY = JSON.stringify({ s: 'ice', none: 'unconfigured' });
const MAX_PER_SECOND = 60; // frames per device
const ROOM = /^\/live\/([0-9a-f]{32})$/;
const SYNC_ROOM = /^\/sync\/([0-9a-f]{32})$/; // profile sync: devices must prove they know the secret of the profile
const MAX_UNAUTHENTICATED = 16; // per sync room
const AUTH_TIMEOUT_MS = 8000;
const LEFT = JSON.stringify({ s: 'left' });
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

/** @type {Map<string, Set<import('ws').WebSocket>>} */
const rooms = new Map();
/** Sync rooms: the devices that proved themselves, and those that have not yet. */
const syncRooms = new Map();
const syncWaiting = new Map();

/** Whether `signature` answers `nonce` for the room that the public key names (the proof of knowing the profile's secret). */
function proofIsGood(publicKey, room, nonce, signature) {
  if (publicKey.length !== 32 || signature.length !== 64) return false;
  if (createHash('sha256').update(publicKey).digest('hex').slice(0, 32) !== room) return false;
  try {
    const key = createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, publicKey]), format: 'der', type: 'spki' });
    return verify(null, Buffer.from(`uninotes-sync-v1|${room}|${nonce}`), key, signature);
  } catch {
    return false;
  }
}

const http = createServer((_req, res) => {
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('Notation signalling server');
});

// the library's own checks are off: the limits are the protocol's, applied below
const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_BYTES * 2, perMessageDeflate: false });

function refuse(socket, status, text) {
  socket.write(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  socket.destroy();
}

function acceptSync(req, socket, head, name) {
  const waiting = syncWaiting.get(name) ?? new Set();
  if (waiting.size >= MAX_UNAUTHENTICATED) return refuse(socket, 429, 'Too Many Requests');
  wss.handleUpgrade(req, socket, head, (ws) => {
    waiting.add(ws);
    syncWaiting.set(name, waiting);
    const nonce = randomBytes(16).toString('hex');
    ws.send(JSON.stringify({ s: 'challenge', n: nonce }));
    let authenticated = false;
    const deadline = setTimeout(() => {
      if (!authenticated) ws.close(1008, 'no proof');
    }, AUTH_TIMEOUT_MS);
    let second = 0;
    let count = 0;
    ws.isAlive = true;
    ws.on('pong', () => (ws.isAlive = true));
    ws.on('message', (data, isBinary) => {
      const now = Math.floor(Date.now() / 1000);
      if (now !== second) {
        second = now;
        count = 0;
      }
      if (isBinary || data.length > MAX_BYTES || ++count > MAX_PER_SECOND) return ws.close(1008, 'policy');
      const text = data.toString();
      if (!authenticated) {
        let ok = false;
        try {
          const m = JSON.parse(text);
          ok = m.s === 'auth' && proofIsGood(Buffer.from(m.k, 'base64'), name, nonce, Buffer.from(m.g, 'base64'));
        } catch {
          ok = false;
        }
        if (!ok) return ws.close(1008, 'no proof');
        const room = syncRooms.get(name) ?? new Set();
        if (room.size >= MAX_PEERS) return ws.close(1013, 'full');
        authenticated = true;
        clearTimeout(deadline);
        waiting.delete(ws);
        room.add(ws);
        syncRooms.set(name, room);
        return ws.send(JSON.stringify({ s: 'ready' }));
      }
      if (text === 'ping') return ws.send('pong');
      if (text === ICE_REQUEST) return ws.send(NO_RELAY);
      for (const other of syncRooms.get(name) ?? []) {
        if (other !== ws && other.readyState === other.OPEN) other.send(text);
      }
    });
    ws.on('error', () => {});
    ws.on('close', () => {
      clearTimeout(deadline);
      waiting.delete(ws);
      if (waiting.size === 0) syncWaiting.delete(name);
      const room = syncRooms.get(name);
      if (room?.delete(ws)) {
        if (room.size === 0) syncRooms.delete(name);
        // the others learn that a connection closed (not whose: they ask who is still here), so an app that was killed is not
        // waited for until it misses its signs of life
        for (const other of room) if (other.readyState === other.OPEN) other.send(LEFT);
      }
    });
  });
}

http.on('upgrade', (req, socket, head) => {
  const path = new URL(req.url ?? '/', 'http://x').pathname;
  const sync = SYNC_ROOM.exec(path);
  if (sync && req.headers.upgrade?.toLowerCase() === 'websocket') return acceptSync(req, socket, head, sync[1]);
  const match = ROOM.exec(path);
  if (!match || req.headers.upgrade?.toLowerCase() !== 'websocket') return refuse(socket, 404, 'Not Found');
  const room = rooms.get(match[1]) ?? new Set();
  if (room.size >= MAX_PEERS) return refuse(socket, 429, 'Too Many Requests');
  wss.handleUpgrade(req, socket, head, (ws) => {
    room.add(ws);
    rooms.set(match[1], room);
    let second = 0;
    let count = 0;
    ws.isAlive = true;
    ws.on('pong', () => (ws.isAlive = true));
    ws.on('message', (data, isBinary) => {
      const now = Math.floor(Date.now() / 1000);
      if (now !== second) {
        second = now;
        count = 0;
      }
      if (isBinary || data.length > MAX_BYTES || ++count > MAX_PER_SECOND) return ws.close(1008, 'policy');
      const text = data.toString();
      if (text === 'ping') return ws.send('pong');
      if (text === ICE_REQUEST) return ws.send(NO_RELAY);
      for (const other of room) {
        if (other !== ws && other.readyState === other.OPEN) other.send(text);
      }
    });
    ws.on('error', () => {});
    ws.on('close', () => {
      room.delete(ws);
      if (room.size === 0) rooms.delete(match[1]);
    });
  });
});

// a device that vanished without saying goodbye is noticed within a minute
const sweep = setInterval(() => {
  for (const room of [...rooms.values(), ...syncRooms.values()]) {
    for (const ws of room) {
      if (!ws.isAlive) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      ws.ping();
    }
  }
}, 30_000);
sweep.unref();

http.listen(PORT, HOST, () => {
  console.log(`Notation signalling server on ${HOST}:${http.address().port} (ws://<this machine>:${http.address().port}/live/<room>)`);
  console.log('Put it behind a TLS proxy to offer wss://. It stores nothing and sees only sealed messages.');
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    http.close();
    for (const room of [...rooms.values(), ...syncRooms.values(), ...syncWaiting.values()]) for (const ws of room) ws.close(1001, 'going away');
    setTimeout(() => process.exit(0), 200).unref();
  });
}
