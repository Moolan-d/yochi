// Yochi Relay — pieces shared by the Node and Cloudflare editions.
//
// Forked from Alma Relay (https://github.com/yetone/alma-relay, MIT,
// Copyright (c) 2025-2026 yetone) and cut down to one WebSocket tunnel.
// Everything here uses WebCrypto and standard globals, so it runs unchanged
// in Node >= 20 and inside a Worker. The wire protocol is in PROTOCOL.md.

export const VERSION = '0.1.0';

/** Tunnel protocol version, sent in `register` / `registered`. */
export const PROTOCOL = 1;

/** Binary frame kinds. */
export const BIN = Object.freeze({
    DATA: 1, // both ways: one binary WebSocket message of a phone stream
});

/** Largest phone message. A Noise message is at most 65535 bytes. */
export const MAX_MESSAGE = 128 * 1024;
/** Largest Gateway frame: one phone message plus the frame header. */
export const MAX_FRAME = MAX_MESSAGE + 2 + 255;
/** A Gateway socket must register within this. */
export const REGISTER_TIMEOUT_MS = 10_000;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** `[kind:u8][idLength:u8][id:utf8][payload]` */
export function encodeFrame(kind, id, payload) {
    const idBytes = encoder.encode(String(id));
    if (idBytes.length > 255) throw new Error('frame id too long');
    const bytes = payload instanceof Uint8Array ? payload : new Uint8Array(payload);
    const out = new Uint8Array(2 + idBytes.length + bytes.length);
    out[0] = kind;
    out[1] = idBytes.length;
    out.set(idBytes, 2);
    out.set(bytes, 2 + idBytes.length);
    return out;
}

/** -> {kind, id, data} (data is a view into `bytes`), or null if malformed. */
export function decodeFrame(bytes) {
    const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    if (view.length < 2 || view.length < 2 + view[1]) return null;
    return { kind: view[0], id: decoder.decode(view.subarray(2, 2 + view[1])), data: view.subarray(2 + view[1]) };
}

/** Phone paths look like /c/<route token>. Never log the token. */
const PHONE_PATH = /^\/c\/([A-Za-z0-9_-]{16,128})\/?$/;

/** The route token of a phone path, or null. */
export function phoneRoute(pathname) {
    return PHONE_PATH.exec(pathname || '')?.[1] ?? null;
}

/** The Gateway path is /gateway?route=<sha256 hex of the route token>. */
export const isRouteHash = s => typeof s === 'string' && /^[a-f0-9]{64}$/.test(s);

export async function sha256hex(text) {
    const digest = await crypto.subtle.digest('SHA-256', encoder.encode(text));
    return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
}

/** Constant-time string compare (length leaks, content doesn't). */
export function safeEqual(a, b) {
    const x = encoder.encode(String(a));
    const y = encoder.encode(String(b));
    if (x.length !== y.length) return false;
    let diff = 0;
    for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
    return diff === 0;
}

/**
 * Who may register a Gateway. With RELAY_REGISTRATION_KEY set, only a Gateway
 * that presents it; without, anyone (a Gateway is still only reachable with
 * its 256-bit route token, and only paired phones get past its Noise
 * handshake). Returns {ok:true} or {ok:false, message, code}.
 */
export function authorize(env, presented) {
    if (env.RELAY_REGISTRATION_KEY && !safeEqual(presented || '', env.RELAY_REGISTRATION_KEY)) {
        return { ok: false, message: 'Invalid registration key', code: 4003 };
    }
    return { ok: true };
}

/** WebSocket close codes a server may legally send. */
export function closeCode(code) {
    const n = Number(code);
    return n === 1000 || (n >= 3000 && n <= 4999) ? n : 1000;
}

/** Close reasons are at most 123 bytes; keep them short. */
export const closeReason = reason => String(reason || '').slice(0, 100);

export const BANNER = `Yochi relay ${VERSION} is running.\nRun \`yochi relay setup\` on your Mac to use it.\n`;
