#!/usr/bin/env node
// Who may register a Gateway, without a relay process.
import assert from 'node:assert/strict';
import { authorize } from '../shared.mjs';

assert.deepEqual(authorize({}, undefined), { ok: true }, 'a relay without a key is open');
assert.equal(authorize({ RELAY_REGISTRATION_KEY: 'k' }, 'k').ok, true);
assert.equal(authorize({ RELAY_REGISTRATION_KEY: 'k' }, 'x').ok, false);
assert.equal(authorize({ RELAY_REGISTRATION_KEY: 'k' }, undefined).ok, false);
// Deployed by `yochi relay setup` before its secret is set: closed.
assert.equal(authorize({ REQUIRE_REGISTRATION_KEY: '1' }, 'anything').ok, false);
assert.equal(authorize({ REQUIRE_REGISTRATION_KEY: '1', RELAY_REGISTRATION_KEY: 'k' }, 'k').ok, true);
console.log('  ✓ authorize');
