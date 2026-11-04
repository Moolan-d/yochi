#!/usr/bin/env node
// End-to-end tests for both relay editions: a fake Gateway and fake phones
// talk through a real relay process.
//
//   node test/relay.test.mjs               # Node edition (spawns index.mjs)
//   node test/relay.test.mjs --cloudflare  # Cloudflare edition (spawns `wrangler dev --local`)
//
// Exit status is the number of failed checks (0 = all pass).

import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { WebSocket } from 'ws';
import { BIN, decodeFrame, encodeFrame } from '../shared.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLOUDFLARE = process.argv.includes('--cloudflare');
const KEY = 'test-registration-key';
const PORT = 19000 + Math.floor(Math.random() * 500);
const BASE = `ws://127.0.0.1:${PORT}`;

let failures = 0;
const check = (name, ok, detail = '') => {
    console.log(`${ok ? '  ✓' : '  ✗'} ${name}${ok || !detail ? '' : ` — ${detail}`}`);
    if (!ok) failures++;
};
const newRoute = () => randomBytes(32).toString('base64url');
const hashOf = token => createHash('sha256').update(token).digest('hex');

/** A WebSocket with an awaitable inbox. */
function socket(url) {
    const ws = new WebSocket(url);
    const inbox = [];
    const waiters = [];
    ws.closed = new Promise(resolve => ws.on('close', (code, reason) => resolve({ code, reason: reason.toString() })));
    ws.opened = new Promise((resolve, reject) => {
        ws.on('open', resolve);
        ws.on('unexpected-response', (_, res) => reject(new Error(`HTTP ${res.statusCode}`)));
        ws.on('error', reject);
    });
    ws.on('message', (data, isBinary) => {
        const item = { data: isBinary ? new Uint8Array(data) : data.toString(), isBinary };
        const waiter = waiters.shift();
        if (waiter) waiter(item);
        else inbox.push(item);
    });
    /** The next message, or null after `ms` (a timed-out wait takes nothing later). */
    ws.next = (ms = 3000) => {
        if (inbox.length) return Promise.resolve(inbox.shift());
        return new Promise(resolve => {
            const waiter = item => {
                clearTimeout(timer);
                resolve(item);
            };
            const timer = setTimeout(() => {
                waiters.splice(waiters.indexOf(waiter), 1);
                resolve(null);
            }, ms);
            waiters.push(waiter);
        });
    };
    return ws;
}

/** A registered fake Gateway on `token`'s route. */
async function gateway(token, key = KEY) {
    const ws = socket(`${BASE}/gateway?route=${hashOf(token)}`);
    await ws.opened;
    ws.send(JSON.stringify({ t: 'register', v: 1, key }));
    const reply = await ws.next();
    ws.registered = reply && !reply.isBinary ? JSON.parse(reply.data) : null;
    return ws;
}

const control = item => (item && !item.isBinary ? JSON.parse(item.data) : null);
const data = item => (item?.isBinary ? decodeFrame(item.data) : null);

async function startRelay() {
    const env = { ...process.env, PORT: String(PORT), HOST: '127.0.0.1', RELAY_REGISTRATION_KEY: KEY, PING_INTERVAL_S: '0' };
    const child = CLOUDFLARE
        ? spawn(path.join(ROOT, 'node_modules/.bin/wrangler'), ['dev', '--local', '--port', String(PORT), '--var', `RELAY_REGISTRATION_KEY:${KEY}`], { cwd: ROOT, env, stdio: ['ignore', 'pipe', 'pipe'] })
        : spawn(process.execPath, ['index.mjs'], { cwd: ROOT, env, stdio: ['ignore', 'pipe', 'pipe'] });
    let log = '';
    child.stdout.on('data', d => (log += d));
    child.stderr.on('data', d => (log += d));
    for (let i = 0; i < (CLOUDFLARE ? 120 : 50); i++) {
        try {
            const res = await fetch(`http://127.0.0.1:${PORT}/healthz`);
            if (res.ok) return { child, health: await res.json() };
        } catch {}
        await sleep(250);
    }
    child.kill();
    throw new Error(`relay did not start:\n${log}`);
}

const { child, health } = await startRelay();
console.log(`Yochi relay (${CLOUDFLARE ? 'cloudflare' : 'node'}) on :${PORT}`);

try {
    check('healthz names the edition and protocol', health.ok && health.edition === (CLOUDFLARE ? 'cloudflare' : 'node') && health.protocol === 1, JSON.stringify(health));

    {
        const ws = await gateway(newRoute(), 'wrong');
        const closed = await ws.closed;
        check('a wrong registration key is refused with 4003', closed.code === 4003, `code ${closed.code}`);
    }

    {
        let refused = false;
        try {
            const ws = socket(`${BASE}/gateway?route=not-a-hash`);
            await ws.opened;
            ws.send(JSON.stringify({ t: 'register', v: 1, key: KEY }));
            refused = (await ws.closed).code === 4002;
        } catch {
            refused = true; // the Worker refuses the upgrade outright
        }
        check('a route that is not a hash is refused', refused);
    }

    {
        let status = '';
        try {
            await socket(`${BASE}/c/${newRoute()}`).opened;
        } catch (err) {
            status = err.message;
        }
        check('a phone on an unknown route is refused with 502', status === 'HTTP 502', status);
    }

    const token = newRoute();
    const gw = await gateway(token);
    check('a Gateway with the key registers', gw.registered?.t === 'registered' && gw.registered.v === 1, JSON.stringify(gw.registered));

    // Two phone streams, kept apart.
    const phoneA = socket(`${BASE}/c/${token}`);
    await phoneA.opened;
    const openA = control(await gw.next());
    const phoneB = socket(`${BASE}/c/${token}`);
    await phoneB.opened;
    const openB = control(await gw.next());
    check('each phone opens its own stream', openA?.t === 'open' && openB?.t === 'open' && openA.id !== openB.id, JSON.stringify([openA, openB]));

    phoneA.send(new Uint8Array([1, 2, 3]));
    const upA = data(await gw.next());
    check('phone bytes reach the Gateway on that stream', upA?.kind === BIN.DATA && upA.id === openA.id && Buffer.from(upA.data).equals(Buffer.from([1, 2, 3])));

    gw.send(encodeFrame(BIN.DATA, openB.id, new Uint8Array([9, 8])));
    const downB = await phoneB.next();
    check('Gateway bytes reach only that phone', downB?.isBinary && Buffer.from(downB.data).equals(Buffer.from([9, 8])));
    check('the other phone gets nothing', (await phoneA.next(300)) === null);

    const big = randomBytes(65535 + 16);
    phoneA.send(big);
    const upBig = data(await gw.next());
    gw.send(encodeFrame(BIN.DATA, openA.id, big));
    const downBig = await phoneA.next();
    check('a full-size Noise message passes both ways', upBig && Buffer.from(upBig.data).equals(big) && downBig && Buffer.from(downBig.data).equals(big));

    gw.send(JSON.stringify({ t: 'close', id: openB.id, code: 4100, reason: 'bye' }));
    const closedB = await phoneB.closed;
    check('the Gateway ending a stream closes that phone with its code', closedB.code === 4100, `code ${closedB.code}`);
    check('...without echoing a close back', (await gw.next(500)) === null);

    phoneA.send('text');
    const closedA = await phoneA.closed;
    const closeA = control(await gw.next());
    check('a text message from a phone closes it with 1003', closedA.code === 1003, `code ${closedA.code}`);
    check('...and the Gateway hears the stream closed', closeA?.t === 'close' && closeA.id === openA.id, JSON.stringify(closeA));

    const phoneC = socket(`${BASE}/c/${token}`);
    await phoneC.opened;
    const openC = control(await gw.next());
    phoneC.send(randomBytes(128 * 1024 + 1));
    const closedC = await phoneC.closed;
    check('a phone message over 128 KiB closes it with 1009', closedC.code === 1009, `code ${closedC.code}`);
    const closeC = control(await gw.next());
    check('...and the Gateway hears that stream closed', closeC?.t === 'close' && closeC.id === openC?.id, JSON.stringify(closeC));

    const phoneD = socket(`${BASE}/c/${token}`);
    await phoneD.opened;
    const openD = control(await gw.next());
    phoneD.close(1000);
    const closeD = control(await gw.next());
    check('a phone hanging up closes its stream', closeD?.t === 'close' && closeD.id === openD?.id, JSON.stringify(closeD));

    // A reconnecting Gateway replaces the old one.
    const phoneE = socket(`${BASE}/c/${token}`);
    await phoneE.opened;
    await gw.next();
    const gw2 = await gateway(token);
    const [oldClosed, phoneClosed] = await Promise.all([gw.closed, phoneE.closed]);
    check('a second Gateway on the route replaces the first (4000)', gw2.registered?.t === 'registered' && oldClosed.code === 4000, `code ${oldClosed.code}`);
    check('...and its phone streams close with 1012', phoneClosed.code === 1012, `code ${phoneClosed.code}`);

    const phoneF = socket(`${BASE}/c/${token}`);
    await phoneF.opened;
    const openF = control(await gw2.next());
    check('phones reach the new Gateway', openF?.t === 'open', JSON.stringify(openF));

    gw2.close(1000);
    const closedF = await phoneF.closed;
    check('a Gateway going away closes its phones with 1012', closedF.code === 1012, `code ${closedF.code}`);
    await sleep(200);
    let after = '';
    try {
        await socket(`${BASE}/c/${token}`).opened;
    } catch (err) {
        after = err.message;
    }
    check('...after which the route is offline (502)', after === 'HTTP 502', after);
} catch (err) {
    failures++;
    console.log(`  ✗ ${err.stack || err}`);
} finally {
    child.kill();
}

console.log(failures ? `${failures} failed` : 'all passed');
process.exit(failures);
