#!/usr/bin/env node
// Yochi Relay — Node edition.
//
// Forked from Alma Relay (https://github.com/yetone/alma-relay, MIT,
// Copyright (c) 2025-2026 yetone) and cut down to one WebSocket tunnel:
//
//   Gateway --WSS /gateway?route=<hash>-->  relay  <--WSS /c/<route token>--  phone
//
// The Gateway dials out and registers with the SHA-256 of its route token.
// Each phone socket becomes a stream on the Gateway's socket; its binary
// messages (Noise ciphertext) pass through untouched. Nothing is written to
// disk; only hashes are kept, in memory. Wire protocol: PROTOCOL.md.
//
// Run behind a TLS-terminating proxy (Caddy, nginx, Cloudflare) in production.

import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';
import {
    BANNER,
    BIN,
    MAX_FRAME,
    MAX_MESSAGE,
    PROTOCOL,
    REGISTER_TIMEOUT_MS,
    VERSION,
    authorize,
    closeCode,
    closeReason,
    decodeFrame,
    encodeFrame,
    isRouteHash,
    phoneRoute,
} from './shared.mjs';

const env = process.env;
const PORT = Number(env.PORT || 8787);
const HOST = env.HOST || '0.0.0.0';
/** A non-negative number from the environment, or the default. 0 means "no limit". */
const limit = (value, fallback) => {
    const n = Number(value);
    return value !== undefined && value !== '' && Number.isFinite(n) && n >= 0 ? n : fallback;
};
const MAX_GATEWAYS = limit(env.MAX_GATEWAYS, 1000);
const MAX_STREAMS = limit(env.MAX_STREAMS, 64); // phone streams per Gateway
const STALL_MS = limit(env.STALL_TIMEOUT_S, 60) * 1000; // a phone that drains nothing this long is cut off
const PING_INTERVAL_MS = limit(env.PING_INTERVAL_S, 30) * 1000;
// Flow control: above HIGH_WATER buffered bytes the sender is paused until
// the buffer drains below LOW_WATER.
const HIGH_WATER = 4 * 1024 * 1024;
const LOW_WATER = 512 * 1024;
const FLOW_TICK_MS = 25;

const sha256 = text => createHash('sha256').update(text).digest('hex');

/** routeHash -> Gateway */
const gateways = new Map();

class Gateway {
    constructor(ws, route) {
        this.ws = ws;
        this.route = route;
        /** stream id -> phone WebSocket */
        this.streams = new Map();
        this.nextId = 1;
        this.isAlive = true;
        // Downstream (Gateway -> phone): while a phone can't keep up, stop
        // reading the Gateway socket so TCP pushes back on the Gateway.
        // Upstream (phone -> Gateway): while the Gateway socket's send buffer
        // is full, stop reading the phones.
        /** stream id -> {phone, last, since}: phones over HIGH_WATER */
        this.sinks = new Map();
        /** phone sockets paused until the Gateway socket drains */
        this.waiting = new Set();
        this.paused = false;
        this.flowTimer = null;
    }

    send(frame) {
        if (this.ws.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(frame));
    }

    sendData(id, data) {
        if (this.ws.readyState === WebSocket.OPEN) this.ws.send(encodeFrame(BIN.DATA, id, data));
    }

    open(phone) {
        const id = `s${this.nextId++}`;
        this.streams.set(id, phone);
        this.send({ t: 'open', id });
        return id;
    }

    /** The phone side of a stream is gone; tell the Gateway once. */
    phoneClosed(id, code, reason) {
        if (!this.streams.delete(id)) return;
        this.sinks.delete(id);
        this.send({ t: 'close', id, code: closeCode(code), reason: closeReason(reason) });
    }

    /** The Gateway ended a stream. */
    gatewayClosed(id, code, reason) {
        const phone = this.streams.get(id);
        if (!phone) return;
        this.streams.delete(id);
        this.sinks.delete(id);
        try {
            phone.close(closeCode(code), closeReason(reason));
        } catch {}
    }

    toPhone(id, data) {
        const phone = this.streams.get(id);
        if (!phone || phone.readyState !== WebSocket.OPEN) return;
        phone.send(data, { binary: true });
        if (phone.bufferedAmount > HIGH_WATER && !this.sinks.has(id)) {
            this.sinks.set(id, { phone, last: phone.bufferedAmount, since: Date.now() });
            if (!this.paused) {
                this.paused = true;
                this.ws.pause();
            }
            this.startFlow();
        }
    }

    toGateway(id, phone, data) {
        this.sendData(id, data);
        if (this.ws.bufferedAmount > HIGH_WATER && !this.waiting.has(phone)) {
            phone.pause();
            this.waiting.add(phone);
            this.startFlow();
        }
    }

    startFlow() {
        if (!this.flowTimer) this.flowTimer = setInterval(() => this.flowTick(), FLOW_TICK_MS);
    }

    flowTick() {
        const now = Date.now();
        for (const [id, sink] of this.sinks) {
            const level = sink.phone.readyState === WebSocket.OPEN ? sink.phone.bufferedAmount : -1;
            if (level < LOW_WATER) {
                this.sinks.delete(id);
            } else if (level < sink.last) {
                sink.last = level;
                sink.since = now;
            } else if (STALL_MS && now - sink.since > STALL_MS) {
                this.sinks.delete(id);
                sink.phone.terminate(); // its close handler tells the Gateway
            }
        }
        if (this.paused && !this.sinks.size) {
            this.paused = false;
            this.isAlive = true; // pongs were not read while paused
            if (this.ws.readyState === WebSocket.OPEN) this.ws.resume();
        }
        if (this.waiting.size && (this.ws.bufferedAmount < LOW_WATER || this.ws.readyState !== WebSocket.OPEN)) {
            for (const phone of this.waiting) phone.resume();
            this.waiting.clear();
        }
        if (!this.sinks.size && !this.waiting.size) this.stopFlow();
    }

    stopFlow() {
        clearInterval(this.flowTimer);
        this.flowTimer = null;
    }

    /** Close every phone stream. */
    destroy(reason) {
        this.stopFlow();
        this.sinks.clear();
        this.waiting.clear();
        for (const phone of this.streams.values()) {
            try {
                phone.close(1012, reason);
            } catch {}
        }
        this.streams.clear();
    }
}

const json = (res, status, obj) => {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj));
};

const server = createServer((req, res) => {
    const { pathname } = new URL(req.url || '/', 'http://relay');
    if (pathname === '/healthz') return json(res, 200, { ok: true, edition: 'node', version: VERSION, protocol: PROTOCOL });
    if (pathname === '/') {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(BANNER);
    }
    if (pathname === '/gateway' || phoneRoute(pathname)) return json(res, 426, { error: 'WebSocket upgrade required' });
    json(res, 404, { error: 'Not found' });
});

const gatewayWss = new WebSocketServer({ noServer: true, maxPayload: MAX_FRAME });
const phoneWss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE });

function refuseUpgrade(socket, status) {
    socket.write(`HTTP/1.1 ${status}\r\nconnection: close\r\ncontent-length: 0\r\n\r\n`);
    socket.destroy();
}

server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url || '/', 'http://relay');
    if (url.pathname === '/gateway') {
        const route = url.searchParams.get('route') || '';
        gatewayWss.handleUpgrade(req, socket, head, ws => handleGateway(ws, route));
        return;
    }
    const token = phoneRoute(url.pathname);
    if (token) {
        const gateway = gateways.get(sha256(token));
        if (!gateway) return refuseUpgrade(socket, '502 Bad Gateway');
        if (MAX_STREAMS && gateway.streams.size >= MAX_STREAMS) return refuseUpgrade(socket, '503 Service Unavailable');
        phoneWss.handleUpgrade(req, socket, head, ws => handlePhone(ws, gateway));
        return;
    }
    refuseUpgrade(socket, '404 Not Found');
});

function refuse(ws, code, message) {
    try {
        ws.send(JSON.stringify({ t: 'error', message }));
        ws.close(code, message);
    } catch {}
}

function handleGateway(ws, route) {
    let gateway = null;
    // Sockets that never register would otherwise sit here forever.
    const registerTimer = setTimeout(() => {
        if (!gateway) ws.terminate();
    }, REGISTER_TIMEOUT_MS);

    ws.on('message', (data, isBinary) => {
        if (isBinary) {
            if (!gateway) return;
            const frame = decodeFrame(data);
            if (frame?.kind === BIN.DATA) gateway.toPhone(frame.id, frame.data);
            return;
        }
        let frame;
        try {
            frame = JSON.parse(data.toString());
        } catch {
            return;
        }
        if (frame.t === 'register') {
            if (gateway) return;
            const auth = authorize(env, frame.key);
            if (!auth.ok) return refuse(ws, auth.code, auth.message);
            if (!isRouteHash(route)) return refuse(ws, 4002, 'Invalid route');
            const existing = gateways.get(route);
            if (!existing && MAX_GATEWAYS && gateways.size >= MAX_GATEWAYS) return refuse(ws, 1013, 'Relay is full');
            clearTimeout(registerTimer);
            if (existing) {
                existing.destroy('Gateway reconnected');
                try {
                    existing.ws.close(4000, 'Replaced by a newer connection');
                } catch {}
            }
            gateway = new Gateway(ws, route);
            gateways.set(route, gateway);
            ws.send(JSON.stringify({ t: 'registered', v: PROTOCOL }));
            console.log(`[relay] gateway registered; gateways=${gateways.size}`);
            return;
        }
        if (gateway && frame.t === 'close') gateway.gatewayClosed(String(frame.id), frame.code, frame.reason);
    });

    ws.on('pong', () => {
        if (gateway) gateway.isAlive = true;
    });

    ws.on('close', () => {
        clearTimeout(registerTimer);
        if (!gateway) return;
        gateway.stopFlow();
        if (gateways.get(gateway.route) === gateway) {
            gateways.delete(gateway.route);
            gateway.destroy('Gateway disconnected');
            console.log(`[relay] gateway disconnected; gateways=${gateways.size}`);
        }
    });

    ws.on('error', () => {});
}

function handlePhone(phone, gateway) {
    const id = gateway.open(phone);
    phone.isAlive = true;
    phone.on('message', (data, isBinary) => {
        if (!isBinary) {
            phone.close(1003, 'Binary messages only');
            return;
        }
        gateway.toGateway(id, phone, data);
    });
    phone.on('pong', () => {
        phone.isAlive = true;
    });
    phone.on('close', (code, reason) => gateway.phoneClosed(id, code, reason?.toString()));
    phone.on('error', () => {});
}

// Terminate dead connections.
const pinger = PING_INTERVAL_MS
    ? setInterval(() => {
          for (const gateway of gateways.values()) {
              for (const phone of gateway.streams.values()) {
                  if (!phone.isAlive) phone.terminate();
                  else {
                      phone.isAlive = false;
                      try {
                          phone.ping();
                      } catch {}
                  }
              }
              if (gateway.paused) continue; // pongs aren't read while paused; flow control has its own timeout
              if (!gateway.isAlive) {
                  gateway.ws.terminate();
                  continue;
              }
              gateway.isAlive = false;
              try {
                  gateway.ws.ping();
              } catch {}
          }
      }, PING_INTERVAL_MS)
    : null;

server.listen(PORT, HOST, () => {
    const gate = env.RELAY_REGISTRATION_KEY ? 'registration key' : 'open';
    console.log(`[relay] Yochi relay ${VERSION} listening on ${HOST}:${server.address().port} (access: ${gate})`);
});

// Docker sends SIGTERM; close cleanly so Gateways reconnect right away.
for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => {
        clearInterval(pinger);
        for (const gateway of gateways.values()) {
            gateway.destroy('Relay restarting');
            try {
                gateway.ws.close(1012, 'Relay restarting');
            } catch {}
        }
        server.close(() => process.exit(0));
        setTimeout(() => process.exit(0), 3000).unref();
    });
}
