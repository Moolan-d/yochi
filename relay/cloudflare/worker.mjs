// Yochi Relay — Cloudflare Workers + Durable Objects edition.
//
// Forked from Alma Relay (https://github.com/yetone/alma-relay, MIT,
// Copyright (c) 2025-2026 yetone) and cut down to one WebSocket tunnel. Same
// wire protocol as the Node edition (PROTOCOL.md). One Durable Object per
// Gateway, named by its route hash:
//
//   Gateway ──WSS /gateway?route=<hash>──▶ TunnelDO ◀──WSS /c/<route token>── phone
//
// Every socket is accepted through the WebSocket Hibernation API, so an idle
// tunnel costs next to nothing. The only storage write is the alarm that
// drops a Gateway socket which never registers.

import { DurableObject } from 'cloudflare:workers';
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
    sha256hex,
} from '../shared.mjs';

/** A non-negative number from the environment, or the default. 0 means "no limit". */
const limit = (value, fallback) => {
    const n = Number(value);
    return value !== undefined && value !== '' && Number.isFinite(n) && n >= 0 ? n : fallback;
};

const json = (status, obj) => new Response(JSON.stringify(obj), { status, headers: { 'content-type': 'application/json' } });
const isUpgrade = request => (request.headers.get('upgrade') || '').toLowerCase() === 'websocket';
const tunnelFor = (env, hash) => env.TUNNEL.get(env.TUNNEL.idFromName(hash));

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        if (url.pathname === '/healthz') return json(200, { ok: true, edition: 'cloudflare', version: VERSION, protocol: PROTOCOL });
        if (url.pathname === '/') return new Response(BANNER, { headers: { 'content-type': 'text/plain; charset=utf-8' } });

        if (url.pathname === '/gateway') {
            if (!isUpgrade(request)) return json(426, { error: 'WebSocket upgrade required' });
            const route = url.searchParams.get('route') || '';
            if (!isRouteHash(route)) return json(400, { error: 'Invalid route' });
            const forward = new Request('https://tunnel/gateway', request);
            forward.headers.set('x-yochi-role', 'gateway');
            return tunnelFor(env, route).fetch(forward);
        }

        const token = phoneRoute(url.pathname);
        if (!token) return json(404, { error: 'Not found' });
        if (!isUpgrade(request)) return json(426, { error: 'WebSocket upgrade required' });
        const forward = new Request('https://tunnel/phone', request);
        forward.headers.set('x-yochi-role', 'phone');
        return tunnelFor(env, await sha256hex(token)).fetch(forward);
    },
};

export class TunnelDO extends DurableObject {
    async fetch(request) {
        const role = request.headers.get('x-yochi-role');
        if (role === 'gateway') return this.acceptGateway();
        if (role === 'phone') return this.acceptPhone();
        return json(400, { error: 'Bad tunnel request' });
    }

    acceptGateway() {
        const [client, server] = Object.values(new WebSocketPair());
        this.ctx.acceptWebSocket(server, ['gateway']);
        server.serializeAttachment({ role: 'gateway', registered: false, since: Date.now() });
        // Sockets that never register would otherwise sit here forever.
        this.ctx.storage.setAlarm(Date.now() + REGISTER_TIMEOUT_MS);
        return new Response(null, { status: 101, webSocket: client });
    }

    acceptPhone() {
        if (!this.gatewaySocket()) return json(502, { error: 'Gateway is offline or the route is unknown' });
        const maxStreams = limit(this.env.MAX_STREAMS, 64);
        if (maxStreams && this.ctx.getWebSockets('phone').length >= maxStreams) return json(503, { error: 'Too many streams' });
        const id = `s${crypto.randomUUID().slice(0, 8)}`;
        const [client, server] = Object.values(new WebSocketPair());
        this.ctx.acceptWebSocket(server, ['phone', `s:${id}`]);
        server.serializeAttachment({ role: 'phone', id });
        this.sendToGateway({ t: 'open', id });
        return new Response(null, { status: 101, webSocket: client });
    }

    async alarm() {
        for (const ws of this.ctx.getWebSockets('gateway')) {
            const attachment = ws.deserializeAttachment() || {};
            if (!attachment.registered && Date.now() - (attachment.since || 0) >= REGISTER_TIMEOUT_MS) {
                try {
                    ws.close(4001, 'Register timeout');
                } catch {}
            }
        }
    }

    gatewaySocket() {
        for (const ws of this.ctx.getWebSockets('gateway')) {
            if (ws.deserializeAttachment()?.registered) return ws;
        }
        return null;
    }

    sendToGateway(frame) {
        try {
            this.gatewaySocket()?.send(frame instanceof Uint8Array ? frame : JSON.stringify(frame));
        } catch {}
    }

    phoneSocket(id) {
        return this.ctx.getWebSockets(`s:${id}`)[0] || null;
    }

    async webSocketMessage(ws, message) {
        const attachment = ws.deserializeAttachment() || {};

        if (attachment.role === 'phone') {
            if (typeof message === 'string') return ws.close(1003, 'Binary messages only');
            if (message.byteLength > MAX_MESSAGE) return ws.close(1009, 'Message too big');
            this.sendToGateway(encodeFrame(BIN.DATA, attachment.id, new Uint8Array(message)));
            return;
        }
        if (attachment.role !== 'gateway') return;

        if (typeof message !== 'string') {
            if (!attachment.registered) return;
            if (message.byteLength > MAX_FRAME) return ws.close(1009, 'Frame too big');
            const frame = decodeFrame(message);
            if (frame?.kind !== BIN.DATA) return;
            try {
                this.phoneSocket(frame.id)?.send(frame.data);
            } catch {}
            return;
        }

        let frame;
        try {
            frame = JSON.parse(message);
        } catch {
            return;
        }

        if (frame.t === 'register') {
            if (attachment.registered) return;
            const auth = authorize(this.env, frame.key);
            if (!auth.ok) {
                ws.send(JSON.stringify({ t: 'error', message: auth.message }));
                return ws.close(auth.code, auth.message);
            }
            let replaced = false;
            for (const other of this.ctx.getWebSockets('gateway')) {
                if (other === ws) continue;
                replaced = true;
                // Unregister first: a half-open old socket may report its
                // close minutes later, and must not tear down the new one's streams.
                try {
                    other.serializeAttachment({ role: 'gateway', registered: false, replaced: true });
                } catch {}
                try {
                    other.close(4000, 'Replaced by a newer connection');
                } catch {}
            }
            // Phone streams belonged to the old connection; the Gateway has dropped them.
            if (replaced) this.dropStreams('Gateway reconnected');
            ws.serializeAttachment({ role: 'gateway', registered: true });
            ws.send(JSON.stringify({ t: 'registered', v: PROTOCOL }));
            return;
        }

        if (attachment.registered && frame.t === 'close') {
            const phone = this.phoneSocket(String(frame.id));
            if (!phone) return;
            // Mark it so its own close event does not echo back to the Gateway.
            phone.serializeAttachment({ role: 'phone', id: String(frame.id), closedByGateway: true });
            try {
                phone.close(closeCode(frame.code), closeReason(frame.reason));
            } catch {}
        }
    }

    async webSocketClose(ws, code, reason) {
        // Finish the close handshake: the runtime does not answer the peer's
        // close frame for us.
        try {
            ws.close(closeCode(code), closeReason(reason));
        } catch {}
        const attachment = ws.deserializeAttachment() || {};
        if (attachment.role === 'gateway' && attachment.registered) {
            this.dropStreams('Gateway disconnected');
        } else if (attachment.role === 'phone' && !attachment.closedByGateway) {
            this.sendToGateway({ t: 'close', id: attachment.id, code: closeCode(code), reason: closeReason(reason) });
        }
    }

    async webSocketError(ws) {
        return this.webSocketClose(ws, 1011, 'WebSocket error');
    }

    /** Close every phone stream. */
    dropStreams(reason) {
        for (const phone of this.ctx.getWebSockets('phone')) {
            try {
                phone.serializeAttachment({ ...(phone.deserializeAttachment() || {}), closedByGateway: true });
                phone.close(1012, reason);
            } catch {}
        }
    }
}
