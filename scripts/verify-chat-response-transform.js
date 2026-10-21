#!/usr/bin/env node
/**
 * Offline unit-style checks for transforms/chat-response.js.
 * Does not call live chat (avoids free-plan quota).
 */
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const transform = require(path.join(__dirname, '..', 'transforms', 'chat-response.js'));

const CLEAN =
  'Your primary Plaid-linked checking account is **TOTAL CHECKING** (Chase, ending in 7070) with an available balance of **$2,085.29**.';

function run(name, fn) {
  try {
    fn();
    console.log(`  ok  ${name}`);
  } catch (err) {
    console.error(`  FAIL ${name}`);
    console.error(err);
    process.exitCode = 1;
  }
}

console.log('verify-chat-response-transform\n');

run('plain { result: { output } }', () => {
  const out = transform({ result: { output: CLEAN, model: 'haiku' } });
  assert.strictEqual(out, CLEAN);
});

run('stringified data wrapping result.output object', () => {
  const body = JSON.stringify({
    result: { output: CLEAN, toolsUsed: [{ name: 'get_bank_balances', ok: true }] },
  });
  const out = transform({ data: body, status: 200, statusText: 'OK' });
  assert.strictEqual(out, CLEAN);
});

run('screenshot shape: data string + result string + output', () => {
  const innerResult = JSON.stringify({
    output: CLEAN,
    model: 'haiku',
    modelId: 'claude-haiku-3-5-20251001',
    inputTokens: 3151,
    outputTokens: 291,
    estimatedCostUsd: 0.0004315,
    toolsUsed: [{ name: 'get_bank_balances', ok: true }],
  });
  const dataStr = JSON.stringify({ result: innerResult });
  const axiosLike = {
    data: dataStr,
    status: 200,
    statusText: 'OK',
    headers: { 'content-type': 'application/json' },
  };
  const out = transform(axiosLike);
  assert.strictEqual(out, CLEAN);
  assert.ok(!out.includes('"data"'), 'must not leak wrapper JSON');
  assert.ok(!out.includes('\\"output\\"'), 'must not leave escaped JSON');
});

run('context.response preferred path (promptfoo wrapper)', () => {
  const inner = JSON.stringify({
    result: JSON.stringify({ output: CLEAN }),
  });
  const out = transform({ ignored: true }, '', {
    response: { data: inner, status: 200, statusText: 'OK' },
  });
  assert.strictEqual(out, CLEAN);
});

run('json candidate wins when it already has output', () => {
  const out = transform(
    { result: { output: CLEAN } },
    '',
    { response: { data: 'not-json', status: 500 } }
  );
  assert.strictEqual(out, CLEAN);
});

run('PLAN_LIMIT error surface', () => {
  const out = transform({
    error: 'Monthly query limit reached',
    code: 'PLAN_LIMIT',
    used: 15,
    max: 15,
    planId: 'free',
  });
  assert.ok(out.includes('PLAN_LIMIT'));
  assert.ok(out.includes('15/15'));
});

run('error inside stringified data', () => {
  const out = transform({
    data: JSON.stringify({
      error: 'Unauthorized',
      code: 'AUTH',
    }),
  });
  assert.ok(out.includes('Unauthorized'));
  assert.ok(out.includes('AUTH'));
});

run('raw text body fallback via _text', () => {
  const out = transform(null, JSON.stringify({ result: { output: CLEAN } }));
  assert.strictEqual(out, CLEAN);
});

run('fixture: real promptfoo Output blob (data/status envelope)', () => {
  const fixturePath = path.join(
    __dirname,
    '..',
    'fixtures',
    'promptfoo-output-blob.json'
  );
  const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  const before = JSON.stringify(fixture.blob);
  const after = transform(fixture.blob);
  console.log('\n  --- before/after (fixture) ---');
  console.log('  BEFORE (first 200):', before.slice(0, 200));
  console.log('  AFTER  (first 200):', after.slice(0, 200));
  assert.ok(after.startsWith(fixture.expectedPrefix));
  assert.ok(!after.trim().startsWith('{'), 'must be plain markdown, not JSON');
  assert.ok(!after.includes('"toolsUsed"'));
  assert.ok(!after.includes('"modelId"'));

  // Also when the blob was already stringified into the Output column
  const fromStoredString = transform(before);
  assert.strictEqual(fromStoredString, after);
});

run('promptfoo call signature: parsed body + raw + context.response', () => {
  const raw = JSON.stringify({
    result: {
      output: CLEAN,
      modelId: 'claude-x',
      toolsUsed: [{ name: 'get_bank_balances', ok: true }],
    },
  });
  const parsed = JSON.parse(raw);
  const out = transform(parsed, raw, {
    response: {
      data: raw,
      status: 200,
      statusText: 'OK',
      headers: {},
      cached: false,
      latencyMs: 12,
    },
  });
  assert.strictEqual(out, CLEAN);
});

if (process.exitCode) {
  console.error('\nSome checks failed.');
  process.exit(1);
}
console.log('\nAll checks passed — Promptfoo Output will show clean assistant text.');
