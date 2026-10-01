#!/usr/bin/env node
// Nib relay: Node >=20, no dependencies. RFC 6455 transport; no document interpretation or persistence.
import http from 'node:http';
import net from 'node:net';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { TextDecoder } from 'node:util';
import { once } from 'node:events';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';

const MAX_DATA = 64 * 1024, MAX_WIRE = 96 * 1024, MAX_PEERS = 50;
const HIGH_WATER = 1024 * 1024, HARD_CAP = 16 * 1024 * 1024;
const utf8 = new TextDecoder('utf-8', { fatal: true });
const digest = value => createHash('sha256').update(value).digest();
const acceptKey = key => createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
const validID = value => typeof value === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(value) && value !== 'relay';
const base64 = bytes => Buffer.from(bytes).toString('base64');
function payload(data) {
  if (typeof data !== 'string' || data.length > Math.ceil(MAX_DATA / 3) * 4) throw new Error('invalid data');
  const bytes = Buffer.from(data, 'base64');
  if (bytes.length > MAX_DATA || base64(bytes) !== data) throw new Error('invalid base64');
  return bytes;
}
function envelope(type, from, data, to) {
  return { type, from, ...(to === undefined ? {} : { to }), data: base64(data) };
}
const control = (type, body, to) => envelope(type, 'relay', Buffer.from(JSON.stringify(body)), to);

function wire(bytes, opcode = 1, masked = false, fin = true) {
  bytes = Buffer.from(bytes);
  const extra = bytes.length < 126 ? 0 : bytes.length <= 65535 ? 2 : 8;
  const header = Buffer.alloc(2 + extra + (masked ? 4 : 0));
  header[0] = (fin ? 0x80 : 0) | opcode;
  header[1] = (masked ? 0x80 : 0) | (extra === 0 ? bytes.length : extra === 2 ? 126 : 127);
  if (extra === 2) header.writeUInt16BE(bytes.length, 2);
  if (extra === 8) header.writeBigUInt64BE(BigInt(bytes.length), 2);
  if (masked) {
    const mask = randomBytes(4); mask.copy(header, 2 + extra);
    bytes = Buffer.from(bytes);
    for (let i = 0; i < bytes.length; i++) bytes[i] ^= mask[i % 4];
  }
  return Buffer.concat([header, bytes]);
}

// Shared parser used by the server and the independent raw TCP selftest client. Handles arbitrary TCP chunks,
// fragmentation, interleaved ping/pong, UTF-8 validation and close. Extensions/compression are not negotiated.
class WebSocketConnection {
  constructor(socket, serverSide = true) {
    this.socket = socket; this.serverSide = serverSide; this.buffer = Buffer.alloc(0);
    this.fragments = []; this.fragmentBytes = 0; this.fragmentOpcode = 0;
    this.blocked = new Map();
    this.closed = false; this.onText = () => {}; this.onClose = () => {}; this.onPong = () => {};
    socket.on('data', chunk => this.feed(chunk));
    socket.on('error', () => this.finish());
    socket.on('close', () => this.finish());
    socket.on('end', () => { socket.destroy(); this.finish(); });
  }
  finish() {
    if (!this.closed) {
      this.closed = true;
      for (const release of [...this.blocked.values()]) release();
      this.onClose();
    }
  }
  // Pause both TCP ingress and parsing already-read frames until EVERY congested broadcast target drains.
  waitForDrain(target) {
    if (target.closed || target.socket.writableLength < HIGH_WATER || this.blocked.has(target)) return;
    const release = () => {
      clearTimeout(timer);
      target.socket.off('drain', release); target.socket.off('close', release);
      this.blocked.delete(target);
      if (!this.closed && this.blocked.size === 0) {
        this.feed(Buffer.alloc(0));
        if (this.blocked.size === 0) this.socket.resume();
      }
    };
    const timer = setTimeout(() => { target.socket.destroy(); release(); }, 30_000); timer.unref();
    this.blocked.set(target, release);
    target.socket.once('drain', release); target.socket.once('close', release);
    this.socket.pause();
  }
  endSocket() {
    this.socket.end(); this.finish();
    const timer = setTimeout(() => this.socket.destroy(), 1000); timer.unref();
  }
  sendFrame(bytes, opcode = 1) {
    if (this.closed || this.socket.destroyed) return;
    if (this.socket.writableLength > HARD_CAP) { this.socket.destroy(); return; }
    this.socket.write(wire(bytes, opcode, !this.serverSide));
  }
  send(value) { this.sendFrame(Buffer.from(JSON.stringify(value))); }
  close(code = 1000, reason = '') {
    if (this.closed) return;
    const text = Buffer.from(reason).subarray(0, 123), data = Buffer.alloc(2 + text.length);
    data.writeUInt16BE(code); text.copy(data, 2);
    this.sendFrame(data, 8); this.endSocket();
  }
  feed(chunk) {
    if (this.closed) return;
    this.buffer = Buffer.concat([this.buffer, chunk]);
    try {
      while (this.buffer.length >= 2 && !this.closed && this.blocked.size === 0) {
        const b = this.buffer, fin = !!(b[0] & 0x80), opcode = b[0] & 15, masked = !!(b[1] & 0x80);
        if ((b[0] & 0x70) || masked !== this.serverSide || ![0, 1, 2, 8, 9, 10].includes(opcode)) throw new Error('protocol');
        let length = b[1] & 127, offset = 2;
        if (length === 126) {
          if (b.length < 4) break;
          length = b.readUInt16BE(2); offset = 4;
          if (length < 126) throw new Error('non-minimal length');
        } else if (length === 127) {
          if (b.length < 10) break;
          const big = b.readBigUInt64BE(2);
          if (big < 65536n || big > BigInt(MAX_WIRE)) throw new Error('length');
          length = Number(big); offset = 10;
        }
        const isControl = opcode >= 8;
        if (length > MAX_WIRE || (isControl && (!fin || length > 125))) throw new Error('length');
        if (b.length < offset + (masked ? 4 : 0) + length) break;
        const mask = masked ? b.subarray(offset, offset + 4) : null;
        offset += masked ? 4 : 0;
        const bytes = Buffer.from(b.subarray(offset, offset + length));
        this.buffer = b.subarray(offset + length);
        if (mask) for (let i = 0; i < bytes.length; i++) bytes[i] ^= mask[i % 4];
        if (opcode === 8) {
          if (bytes.length === 1) throw new Error('close');
          if (bytes.length >= 2) {
            const code = bytes.readUInt16BE();
            if (!([1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014].includes(code) || (code >= 3000 && code <= 4999))) throw new Error('close code');
            utf8.decode(bytes.subarray(2));
          }
          this.sendFrame(bytes, 8); this.endSocket(); return;
        }
        if (opcode === 9) { this.sendFrame(bytes, 10); continue; }
        if (opcode === 10) { this.onPong(); continue; }
        if (opcode === 0) { if (!this.fragmentOpcode) throw new Error('continuation'); }
        else {
          if (this.fragmentOpcode) throw new Error('fragment');
          if (opcode !== 1) { this.close(1003, 'JSON text required'); return; }
          this.fragmentOpcode = opcode;
        }
        this.fragmentBytes += bytes.length;
        if (this.fragmentBytes > MAX_WIRE) { this.close(1009, 'Message too large'); return; }
        if (this.fragments.length >= 1024) { this.close(1009, 'Too many fragments'); return; }
        this.fragments.push(bytes);
        if (fin) {
          const text = utf8.decode(Buffer.concat(this.fragments));
          this.fragments = []; this.fragmentBytes = 0; this.fragmentOpcode = 0;
          this.onText(text);
        }
      }
      if (this.buffer.length > 2 * MAX_WIRE + 64 * 1024) throw new Error('buffer');
    } catch (error) { this.close(error instanceof TypeError ? 1007 : 1002, 'Invalid WebSocket frame'); }
  }
}

export function createRelay({ token, host = '127.0.0.1', port = 8787, path = '/', roomGraceMs = 120_000, maxRooms = 1000 } = {}) {
  if (typeof token !== 'string' || token.length < 16 || /[\r\n]/.test(token)) throw new Error('RELAY_TOKEN must contain at least 16 characters and no line breaks');
  const rooms = new Map(), links = new Set(), roomTimers = new Set();
  const server = http.createServer((req, res) => {
    res.writeHead(req.url === '/health' ? 200 : 404, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
    res.end(req.url === '/health' ? 'ok\n' : 'not found\n');
  });
  server.headersTimeout = 10_000; server.requestTimeout = 10_000;
  const reject = (socket, status) => socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  function roster(room, link, type = 'peers') {
    const peers = [...room.members.values()].filter(member => member !== link).map(member => ({ id: member.id, name: member.name }));
    link.send(control(type, { peers, host: room.host }, link.id));
  }
  function notify(room) { for (const member of room.members.values()) roster(room, member); }
  function releaseRoom(code, room) {
    if (room.timer) { clearTimeout(room.timer); roomTimers.delete(room.timer); }
    room.timer = setTimeout(() => {
      roomTimers.delete(room.timer);
      if (!room.members.has(room.host)) {
        rooms.delete(code);
        for (const member of room.members.values()) member.close(1001, 'Host left');
      }
    }, roomGraceMs);
    roomTimers.add(room.timer); room.timer.unref();
  }
  server.on('upgrade', (req, socket, head) => {
    const auth = req.headers.authorization ?? '';
    if (!timingSafeEqual(digest(auth), digest('Bearer ' + token))) { reject(socket, '401 Unauthorized'); return; }
    const key = req.headers['sec-websocket-key'];
    if (req.method !== 'GET' || req.url !== path || req.headers.upgrade?.toLowerCase() !== 'websocket' ||
        !req.headers.connection?.toLowerCase().split(',').map(x => x.trim()).includes('upgrade') ||
        req.headers['sec-websocket-version'] !== '13' || typeof key !== 'string' ||
        Buffer.from(key, 'base64').length !== 16 || base64(Buffer.from(key, 'base64')) !== key || req.headers.origin) {
      reject(socket, '400 Bad Request'); return;
    }
    if (links.size >= 1000) { reject(socket, '503 Service Unavailable'); return; }
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + acceptKey(key) + '\r\n\r\n');
    socket.setNoDelay(true);
    const link = new WebSocketConnection(socket); links.add(link);
    link.alive = true; link.onPong = () => { link.alive = true; };
    const registrationTimer = setTimeout(() => link.close(1008, 'Register a room'), 10_000); registrationTimer.unref();
    const fail = (code, message) => {
      link.send(control('error', { code, message }, link.id)); link.close(1008, code);
    };
    link.onClose = () => {
      clearTimeout(registrationTimer); links.delete(link);
      const room = rooms.get(link.code);
      if (!room || room.members.get(link.id) !== link) return;
      room.members.delete(link.id);
      if (link.id !== room.host) room.reservations.set(link.id, Date.now() + roomGraceMs);
      if (link.id === room.host) releaseRoom(link.code, room);
      notify(room);
    };
    link.onText = text => {
      try {
        const frame = JSON.parse(text);
        if (!frame || !validID(frame.from) || (frame.to !== undefined && !validID(frame.to)) ||
            (frame.except !== undefined && (!Array.isArray(frame.except) || frame.except.length > MAX_PEERS || !frame.except.every(validID)))) throw new Error('envelope');
        const bytes = payload(frame.data);
        if (!link.id) {
          if (!['host', 'join'].includes(frame.type) || frame.to !== undefined || frame.except !== undefined) throw new Error('registration');
          const { code, name, resume } = JSON.parse(utf8.decode(bytes));
          if (typeof code !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(code) || typeof name !== 'string' || Buffer.byteLength(name) > 256 || typeof resume !== 'string' || resume.length < 32 || resume.length > 128) throw new Error('room');
          let room = rooms.get(code);
          link.id = frame.from; link.name = name;
          if (frame.type === 'host') {
            if (room && (room.host !== link.id || !timingSafeEqual(room.resume, digest(resume)))) { fail('conflict', 'That room already has a host.'); return; }
            if (!room) {
              if (rooms.size >= maxRooms) { fail('unavailable', 'The relay has too many retained rooms. Try again later.'); return; }
              room = { host: link.id, resume: digest(resume), members: new Map(), secrets: new Map(), reservations: new Map() }; rooms.set(code, room);
            }
            if (room.timer) { clearTimeout(room.timer); roomTimers.delete(room.timer); room.timer = null; }
          } else if (!room || !room.members.has(room.host)) { fail('not_found', 'No live host with that code.'); return; }
          for (const [id, expiry] of room.reservations) if (expiry <= Date.now()) {
            room.reservations.delete(id); room.secrets.delete(id);
          }
          const old = room.members.get(link.id);
          if (room.secrets.has(link.id) && !timingSafeEqual(room.secrets.get(link.id), digest(resume))) { fail('permission_denied', 'Invalid reconnect credentials.'); return; }
          if (!old && room.members.size >= MAX_PEERS) { fail('full', '50 participants maximum. Use folder sync for larger groups.'); return; }
          if (!room.secrets.has(link.id) && room.secrets.size >= 1000) { fail('unavailable', 'Too many reserved identities. Try again later.'); return; }
          // F072 unbinds guests when the host disconnects. Guests must see hostLost even when its stale link
          // has not timed out yet, so they rejoin with their admission secret and run two-way digest sync.
          if (old && link.id === room.host) { room.members.delete(link.id); notify(room); }
          room.reservations.delete(link.id);
          link.code = code; room.members.set(link.id, link); room.secrets.set(link.id, digest(resume));
          old?.close(1001, 'Reconnected');
          clearTimeout(registrationTimer);
          roster(room, link, 'welcome');
          for (const member of room.members.values()) if (member !== link) roster(room, member);
          return;
        }
        if (!['message', 'bye'].includes(frame.type) || frame.from !== link.id) throw new Error('sender');
        const room = rooms.get(link.code);
        if (!room || room.members.get(link.id) !== link) throw new Error('room');
        if (frame.type === 'bye') {
          if (link.id !== room.host) { room.members.delete(link.id); room.secrets.delete(link.id); room.reservations.delete(link.id); notify(room); }
          link.close(); return;
        }
        // Admission and permissions belong to F072. Route guest messages only to the host, preventing guests from
        // forging host welcome/approval messages or writing directly to another guest.
        let targets;
        if (link.id !== room.host) {
          if ((frame.to !== undefined && frame.to !== room.host) || frame.except !== undefined) throw new Error('guest target');
          targets = [room.members.get(room.host)].filter(Boolean);
        } else {
          targets = frame.to === undefined ? [...room.members.values()].filter(x => x !== link && !(frame.except ?? []).includes(x.id))
            : [room.members.get(frame.to)].filter(x => x && x !== link);
        }
        for (const target of targets) {
          target.send(envelope('message', link.id, bytes, target.id));
          link.waitForDrain(target);
        }
      } catch { fail('invalid_params', 'Invalid relay JSON frame.'); }
    };
    if (head.length) link.feed(head);
  });
  const heartbeat = setInterval(() => {
    for (const link of links) {
      if (!link.alive) { link.socket.destroy(); continue; }
      link.alive = false; link.sendFrame(Buffer.alloc(0), 9);
    }
  }, 25_000); heartbeat.unref();
  return {
    server,
    async listen() { server.listen(port, host); await once(server, 'listening'); return server.address().port; },
    async close() {
      clearInterval(heartbeat);
      for (const timer of roomTimers) clearTimeout(timer);
      rooms.clear();
      for (const link of links) link.socket.destroy();
      await new Promise(resolve => server.close(resolve));
    }
  };
}

// Raw client keeps --selftest compatible with Node 20, which has no stable built-in WebSocket client.
async function client(port, token) {
  const socket = net.connect(port, '127.0.0.1'); await once(socket, 'connect');
  const key = base64(randomBytes(16));
  socket.write(`GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ${key}\r\nAuthorization: Bearer ${token}\r\n\r\n`);
  return await new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    const onData = chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      const end = buffer.indexOf('\r\n\r\n'); if (end < 0) return;
      socket.off('data', onData);
      const headers = buffer.subarray(0, end).toString();
      if (!headers.startsWith('HTTP/1.1 101') || !headers.includes(acceptKey(key))) {
        socket.destroy(); reject(new Error(headers.split('\r\n')[0])); return;
      }
      const link = new WebSocketConnection(socket, false), messages = [], waiters = [];
      link.onText = text => {
        const value = JSON.parse(text); const waiter = waiters.shift();
        if (waiter) waiter(value); else messages.push(value);
      };
      link.next = async () => messages.length ? messages.shift() : await new Promise(resolve => waiters.push(resolve));
      link.feed(buffer.subarray(end + 4)); resolve(link);
    };
    socket.on('data', onData); socket.once('error', reject);
  });
}
async function nextType(link, type) {
  for (;;) { const frame = await link.next(); if (frame.type === type) return frame; }
}

async function selftest() {
  const token = base64(randomBytes(32)), relay = createRelay({ token, port: 0, maxRooms: 2 }), clients = [];
  const deadline = setTimeout(() => { console.error('Relay selftest timed out'); process.exit(1); }, 30_000);
  try {
    const port = await relay.listen();
    await assert.rejects(client(port, 'wrong-token'), /401/);
    const malformed = await client(port, token); clients.push(malformed);
    const protocolClosed = once(malformed.socket, 'close');
    // A literal unmasked client frame is invalid, independent of the selftest encoder.
    malformed.socket.write(Buffer.from([0x81, 0x02, 0x7b, 0x7d]));
    await protocolClosed; assert.equal(malformed.closed, true);
    const host = await client(port, token); clients.push(host);
    host.send(envelope('host', 'host', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Host', resume: 'host-private-resume-capability-12345' }))));
    assert.equal((await nextType(host, 'welcome')).to, 'host');
    let guest = await client(port, token); clients.push(guest);
    guest.send(envelope('join', 'guest', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Guest', resume: 'guest-private-resume-capability-12345' }))));
    const joined = await nextType(guest, 'welcome');
    assert.deepEqual(JSON.parse(payload(joined.data)), { peers: [{ id: 'host', name: 'Host' }], host: 'host' });
    const data = randomBytes(MAX_DATA);
    // Fragmented, extended-length message with an interleaved ping; TCP chunk boundaries are also split.
    const text = Buffer.from(JSON.stringify(envelope('message', 'guest', data, 'host')));
    const first = wire(text.subarray(0, 10_000), 1, true, false);
    guest.socket.write(first.subarray(0, 3)); guest.socket.write(first.subarray(3));
    guest.socket.write(wire(Buffer.from('ping'), 9, true));
    guest.socket.write(wire(text.subarray(10_000), 0, true));
    const relayed = await nextType(host, 'message');
    assert.equal(relayed.from, 'guest'); assert.equal(relayed.to, 'host'); assert.deepEqual(payload(relayed.data), data);
    host.send(envelope('message', 'host', Buffer.from('reply'), 'guest'));
    assert.equal(payload((await nextType(guest, 'message')).data).toString(), 'reply');
    // Broadcast pauses the sender until ALL slow receivers drain, preserving the complete 8 MiB burst.
    const slow = await client(port, token); clients.push(slow);
    slow.send(envelope('join', 'slow', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Slow', resume: 'slow-private-resume-capability-12345' }))));
    await nextType(slow, 'welcome'); await nextType(guest, 'peers');
    guest.socket.pause(); slow.socket.pause();
    for (let i = 0; i < 128; i++) host.send(envelope('message', 'host', data));
    await new Promise(resolve => setTimeout(resolve, 250));
    assert.equal(guest.closed, false); assert.equal(slow.closed, false);
    guest.socket.resume();
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(slow.closed, false);
    slow.socket.resume();
    for (let i = 0; i < 128; i++) {
      assert.deepEqual(payload((await nextType(guest, 'message')).data), data);
      assert.deepEqual(payload((await nextType(slow, 'message')).data), data);
    }
    assert.equal(guest.closed, false); assert.equal(slow.closed, false);
    // An explicit bye frees a guest reservation immediately.
    slow.send(envelope('bye', 'slow', Buffer.alloc(0)));
    await nextType(guest, 'peers');
    const freed = await client(port, token); clients.push(freed);
    freed.send(envelope('join', 'slow', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Freed', resume: 'new-private-resume-capability-12345' }))));
    await nextType(freed, 'welcome'); await nextType(guest, 'peers');
    freed.send(envelope('bye', 'slow', Buffer.alloc(0))); await nextType(guest, 'peers');
    // Replacement of a still-open host MUST publish an absent roster before the returning host roster.
    const returnedHost = await client(port, token); clients.push(returnedHost);
    returnedHost.send(envelope('host', 'host', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Host', resume: 'host-private-resume-capability-12345' }))));
    await nextType(returnedHost, 'welcome');
    assert.equal(JSON.parse(payload((await nextType(guest, 'peers')).data)).peers.some(p => p.id === 'host'), false);
    assert.equal(JSON.parse(payload((await nextType(guest, 'peers')).data)).peers.some(p => p.id === 'host'), true);
    // An abrupt guest disconnect reserves its capability, so another token holder cannot steal its visible id.
    guest.socket.destroy();
    for (;;) {
      const roster = JSON.parse(payload((await nextType(returnedHost, 'peers')).data));
      if (!roster.peers.some(p => p.id === 'guest')) break;
    }
    const guestImpostor = await client(port, token); clients.push(guestImpostor);
    guestImpostor.send(envelope('join', 'guest', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Impostor', resume: 'wrong-private-resume-capability-12345' }))));
    assert.equal(JSON.parse(payload((await nextType(guestImpostor, 'error')).data)).code, 'permission_denied');
    guest = await client(port, token); clients.push(guest);
    guest.send(envelope('join', 'guest', Buffer.from(JSON.stringify({ code: 'TEST01', name: 'Guest', resume: 'guest-private-resume-capability-12345' }))));
    await nextType(guest, 'welcome');
    guest.send(envelope('message', 'guest', Buffer.from('patch-after-reconnect'), 'host'));
    assert.equal(payload((await nextType(returnedHost, 'message')).data).toString(), 'patch-after-reconnect');
    // Room isolation and host-only guest routing.
    const other = await client(port, token); clients.push(other);
    other.send(envelope('host', 'other', Buffer.from(JSON.stringify({ code: 'OTHER', name: 'Other', resume: 'other-private-resume-capability-12345' }))));
    await nextType(other, 'welcome');
    guest.send(envelope('message', 'guest', Buffer.from('blocked'), 'other'));
    assert.equal(JSON.parse(payload((await nextType(guest, 'error')).data)).code, 'invalid_params');
    // Fill a fresh room to 50 total (host included), then ensure participant 51 sees the sync fallback.
    const members = [];
    for (let i = 1; i < MAX_PEERS; i++) {
      const member = await client(port, token); clients.push(member); members.push(member);
      member.send(envelope('join', `p${i}`, Buffer.from(JSON.stringify({ code: 'OTHER', name: `Person ${i}`, resume: `person-private-resume-capability-${i}` }))));
      await nextType(member, 'welcome');
    }
    const overflow = await client(port, token); clients.push(overflow);
    overflow.send(envelope('join', 'overflow', Buffer.from(JSON.stringify({ code: 'OTHER', name: 'Overflow', resume: 'overflow-private-resume-capability-12345' }))));
    assert.equal(JSON.parse(payload((await nextType(overflow, 'error')).data)).code, 'full');
    // Knowing the host's visible id does not grant its private reconnect capability.
    const impostor = await client(port, token); clients.push(impostor);
    impostor.send(envelope('host', 'other', Buffer.from(JSON.stringify({ code: 'OTHER', name: 'Impostor', resume: 'guessed-private-resume-capability-12345' }))));
    assert.equal(JSON.parse(payload((await nextType(impostor, 'error')).data)).code, 'conflict');
    // Identity survives reconnect; peers see the returning host, not a second host.
    const replacement = await client(port, token); clients.push(replacement);
    replacement.send(envelope('host', 'other', Buffer.from(JSON.stringify({ code: 'OTHER', name: 'Host again', resume: 'other-private-resume-capability-12345' }))));
    assert.equal(JSON.parse(payload((await nextType(replacement, 'welcome')).data)).peers.length, 49);
    // Select a known room member instead of relying on pending roster order.
    const recipient = await client(port, token); clients.push(recipient);
    recipient.send(envelope('join', 'p1', Buffer.from(JSON.stringify({ code: 'OTHER', name: 'Person 1', resume: 'person-private-resume-capability-1' }))));
    await nextType(recipient, 'welcome');
    replacement.send({ ...envelope('message', 'other', Buffer.from('broadcast'), undefined), except: ['p2'] });
    assert.equal(payload((await nextType(recipient, 'message')).data).toString(), 'broadcast');
    replacement.send(envelope('message', 'other', Buffer.from('excluded-marker'), 'p2'));
    assert.equal(payload((await nextType(members[1], 'message')).data).toString(), 'excluded-marker');
    // Room retention is bounded, including rooms whose host has disconnected.
    returnedHost.socket.destroy();
    const churn = await client(port, token); clients.push(churn);
    churn.send(envelope('host', 'churn', Buffer.from(JSON.stringify({ code: 'CHURN', name: 'Churn', resume: 'churn-private-resume-capability-12345' }))));
    assert.equal(JSON.parse(payload((await nextType(churn, 'error')).data)).code, 'unavailable');
    const fragmented = await client(port, token); clients.push(fragmented);
    const fragmentClosed = once(fragmented.socket, 'close');
    fragmented.socket.write(wire(Buffer.alloc(0), 1, true, false));
    for (let i = 0; i < 1024; i++) fragmented.socket.write(wire(Buffer.alloc(0), 0, true, false));
    await fragmentClosed; assert.equal(fragmented.closed, true);
    console.log('RELAY SELFTEST OK: auth, framing bounds, routing, slow receiver, host replacement, identity reservations, room/participant caps');
  } finally {
    clearTimeout(deadline);
    for (const link of clients) link.socket.destroy();
    await relay.close();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.includes('--selftest')) {
    selftest().catch(error => { console.error(error.message); process.exitCode = 1; });
  } else {
    try {
      const port = Number(process.env.PORT ?? 8787);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1...65535');
      const relay = createRelay({ token: process.env.RELAY_TOKEN, port, host: process.env.HOST ?? '127.0.0.1', path: process.env.RELAY_PATH ?? '/' });
      await relay.listen(); console.log(`Nib relay listening on port ${port}`);
      for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => relay.close().then(() => process.exit(0)));
    } catch (error) { console.error(error.message); process.exitCode = 1; }
  }
}
