// SatsKeeper offline regression suite. No network calls, real accounts, or purchases.
const assert = require('assert');
const fs = require('fs');
const path = require('path');

let passed = 0;
let failed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
}
async function testAsync(name, fn) {
  try { await fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
}
function mockResponse() {
  return {
    statusCode: 200, headersSent: false, headers: {},
    setHeader(k, v) { this.headers[k] = v; },
    status(n) { this.statusCode = n; return this; },
    json(body) { this.body = body; this.headersSent = true; return this; },
  };
}
async function invoke(handler, req = {}) {
  const res = mockResponse();
  await handler({ method: 'POST', headers: {}, query: {}, body: {}, url: '/test', ...req }, res);
  return res;
}

// Replace external services before loading API modules. All tests remain offline.
const supabasePath = require.resolve('../api/_lib/supabase');
const authPath = require.resolve('../api/_lib/auth');
const rpcCalls = [];
let rpcResponse = null;
const supabase = {
  auth: {
    getUser: async () => ({ data: { user: { id: 'test-device-123', email_confirmed_at: '2026-01-01' } }, error: null }),
    admin: { getUserById: async () => ({ data: { user: { email: 'account@example.com' } }, error: null }) },
  },
  rpc: async (name, args) => { rpcCalls.push({ name, args }); if (rpcResponse) return { data: rpcResponse, error: null }; if (name === 'reserve_redemption') return { data: { status: 'ok', id: 77 }, error: null }; if (name === 'refund_redemption') return { data: true, error: null }; return { data: null, error: null }; },
  from: () => ({
    upsert: async () => ({ error: null }),
    select() { return this; }, update() { return this; }, eq() { return this; }, not() { return this; },
    lt() { return this; }, order() { return this; },
    single: async () => ({ data: { id: 77, points_spent: 5000, beneficiary_email: 'buyer@example.com', product_name: 'Gift', reward_amount: 5, reward_currency: 'USD', created_at: '2026-01-01T00:00:00Z' }, error: null }),
    limit: async () => ({ data: [], error: null }),
  }),
};
require.cache[supabasePath] = { id: supabasePath, filename: supabasePath, loaded: true, exports: supabase };
require.cache[authPath] = {
  id: authPath, filename: authPath, loaded: true,
  exports: {
    requireSession: async () => 'test-device-123',
    requireAppKey: () => true,
    requireAdmin: () => true,
    isCron: () => false,
    validDeviceId: (id) => typeof id === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(id),
  },
};

(async () => {
  const config = require('../api/_lib/config');
  const bit = require('../api/_lib/bitrefill');
  const payout = require('../api/_lib/payout');

  // Country mapping and currency caps.
  for (const [input, expected] of Object.entries({ US: 'US', UK: 'GB', GB: 'GB', EG: 'EG', SA: 'SA', AE: 'AE', JP: 'JP', ZA: 'ZA' }))
    test('country mapping ' + input, () => assert.strictEqual(bit.COUNTRY_MAP[input], expected));
  test('unknown country is not silently mapped', () => assert.strictEqual(bit.COUNTRY_MAP.ZZ, undefined));
  test('USD card cap', () => assert.strictEqual(config.maxCardValue('USD'), 10));
  test('GBP card cap', () => assert.strictEqual(config.maxCardValue('GBP'), 8));
  test('SAR card cap', () => assert.strictEqual(config.maxCardValue('SAR'), 40));
  test('EGP card cap', () => assert.strictEqual(config.maxCardValue('EGP'), 500));
  test('currency matching is case insensitive', () => assert.strictEqual(config.maxCardValue('sar'), 40));

  // Catalog normalization and redemption selection validation.
  const raw = { id: 'gift-1', name: 'Gift', currency: 'SAR', packages: [
    { id: 'small', value: 5 }, { package_id: 'large', amount: 20 }, { id: 'bad', value: -1 },
  ] };
  const product = bit.normalizeProduct(raw);
  test('product ID and name are normalized', () => { assert.strictEqual(product.id, 'gift-1'); assert.strictEqual(product.name, 'Gift'); });
  test('valid packages remain visible up to the manual request ceiling', () => assert.deepStrictEqual(product.packages, [{ package_id: 'small', value: 5 }, { package_id: 'large', value: 20 }]));
  test('out-of-stock products are rejected', () => assert.strictEqual(bit.normalizeProduct({ ...raw, in_stock: false }), null));
  test('missing product ID is rejected', () => assert.strictEqual(bit.normalizeProduct({ name: 'x', packages: [{ value: 1 }] }), null));
  test('products with no valid purchasable options are rejected', () => assert.strictEqual(bit.normalizeProduct({ id: 'x', currency: 'USD', packages: [{ value: 10001 }] }), null));
  test('negative package range step defaults safely', () => {
    const p = bit.normalizeProduct({ id: 'r', currency: 'USD', range: { min: 1, max: 10, step: -2 } });
    assert.deepStrictEqual(p.range, { min: 1, max: 10, step: 1 });
  });
  test('range values are capped to currency limit', () => {
    const p = bit.normalizeProduct({ id: 'r', currency: 'SAR', range: { min: 5, max: 100, step: 5 } });
    assert.deepStrictEqual(p.range, { min: 5, max: 40, step: 5 });
  });
  test('valid package selection resolves', () => assert.deepStrictEqual(bit.resolveSelection(product, 'small'), { package_id: 'small', value: 5 }));
  test('unknown package selection is rejected', () => assert.strictEqual(bit.resolveSelection(product, 'missing'), null));
  const ranged = bit.normalizeProduct({ id: 'r', currency: 'USD', range: { min: 2, max: 10, step: 2 } });
  test('valid range step resolves', () => assert.deepStrictEqual(bit.resolveSelection(ranged, null, 6), { value: 6 }));
  test('range value below minimum is rejected', () => assert.strictEqual(bit.resolveSelection(ranged, null, 1), null));
  test('range value above maximum is rejected', () => assert.strictEqual(bit.resolveSelection(ranged, null, 12), null));
  test('range value off step is rejected', () => assert.strictEqual(bit.resolveSelection(ranged, null, 5), null));
  test('NaN selection is rejected', () => assert.strictEqual(bit.resolveSelection(ranged, null, 'nope'), null));

  // URL safety and API path handling.
  test('relative product path resolves under /v2', () => assert.strictEqual(bit.resolveUrl('/products?country=US'), 'https://api.bitrefill.com/v2/products?country=US'));
  test('absolute pagination URL without /v2 is normalized', () => assert.strictEqual(bit.resolveUrl('https://api.bitrefill.com/products?cursor=x'), 'https://api.bitrefill.com/v2/products?cursor=x'));
  test('same-host /v2 pagination URL is preserved', () => assert.strictEqual(bit.resolveUrl('https://api.bitrefill.com/v2/products?cursor=x'), 'https://api.bitrefill.com/v2/products?cursor=x'));
  test('foreign host pagination URL is rejected', () => assert.throws(() => bit.resolveUrl('https://evil.example/v2/products'), /bad_bitrefill_url/));
  test('foreign protocol URL is rejected', () => assert.throws(() => bit.resolveUrl('ftp://api.bitrefill.com/v2/products'), /bad_bitrefill_url/));
  test('path traversal outside API prefix is rejected', () => assert.throws(() => bit.resolveUrl('/../private'), /bad_bitrefill_url/));
  test('query strings are preserved', () => assert.ok(bit.resolveUrl('/products?country=SA&limit=50').includes('country=SA&limit=50')));
  test('redemption failure statuses are classified', () => ['denied','payment_error','expired','refunded','not_delivered'].forEach(s => assert.ok(payout.FAILED.has(s))));
  test('successful status is not classified as failure', () => assert.strictEqual(payout.FAILED.has('complete'), false));
  test('invoice wrapper unwraps data', () => assert.deepStrictEqual(payout.unwrap({ data: { id: 7 } }), { id: 7 }));
  test('empty invoice wrapper is safe', () => assert.deepStrictEqual(payout.unwrap(null), {}));
  await testAsync('redemption code formatting supports code and PIN', async () => {
    // findCode reads the inline redemption_info before any network request.
    const value = await payout.findCode({ orders: [{ redemption_info: { code: 'ABC', pin: '1234' } }] });
    assert.strictEqual(value, 'ABC | PIN 1234');
  });

  // Public status endpoint must disclose only safe, non-operational readiness facts.
  const publicStatus = require('../api/public-status');
  await testAsync('public status endpoint is read-only and GET-only', async () => {
    const r = await invoke(publicStatus, { method: 'GET' });
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual(r.body.product, 'GainDeep');
    assert.strictEqual(r.body.stage, 'prelaunch');
    assert.strictEqual(r.body.features.points_earning, 'not_cleared_for_public_launch');
    assert.strictEqual(r.body.features.buyer_traffic_api, 'not_available');
    assert.ok(!JSON.stringify(r.body).includes('SUPABASE_SERVICE_ROLE_KEY'));
    const denied = await invoke(publicStatus, { method: 'POST' });
    assert.strictEqual(denied.statusCode, 405);
  });
  test('launch website uses local assets and labels legal pages as drafts', () => {
    const html = fs.readFileSync(path.join(__dirname, '../launch/index.html'), 'utf8');
    const legal = fs.readFileSync(path.join(__dirname, '../launch/legal.html'), 'utf8');
    const js = fs.readFileSync(path.join(__dirname, '../launch/site.js'), 'utf8');
    assert.ok(html.includes('/launch/site.css'));
    assert.ok(html.includes('/launch/site.js'));
    assert.ok(legal.includes('pre-launch drafts, not final legal terms'));
    assert.ok(!/<script[^>]+src=["']https?:/i.test(html + legal));
    assert.ok(!js.includes('innerHTML'));
    assert.ok(!js.includes('eval('));
  });
  test('Vercel policy permits only same-origin website assets and API calls', () => {
    const config = JSON.parse(fs.readFileSync(path.join(__dirname, '../vercel.json'), 'utf8'));
    const headers = config.headers[0].headers;
    const csp = headers.find((h) => h.key === 'Content-Security-Policy').value;
    assert.ok(csp.includes("script-src 'self'"));
    assert.ok(csp.includes("style-src 'self'"));
    assert.ok(csp.includes("connect-src 'self'"));
    assert.ok(csp.includes("frame-ancestors 'none'"));
  });

  // API validation paths with a fake authenticated session and mocked database.
  const consent = require('../api/consent');
  const verify = require('../api/verify-bandwidth');
  const catalog = require('../api/get-catalog');
  const redeem = require('../api/redeem');
  const rewards = require('../api/rewards');
  await testAsync('consent rejects a non-boolean preference', async () => {
    const r = await invoke(consent, { body: { opted_in: 'yes' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('consent accepts a boolean and returns saved preference', async () => {
    const r = await invoke(consent, { body: { opted_in: true } });
    assert.strictEqual(r.statusCode, 200); assert.strictEqual(r.body.opted_in, true);
  });
  await testAsync('bandwidth rejects zero MB', async () => {
    const r = await invoke(verify, { body: { mb_shared: 0, report_id: 'report_1234567890' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('bandwidth rejects negative MB', async () => {
    const r = await invoke(verify, { body: { mb_shared: -1, report_id: 'report_1234567890' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('bandwidth rejects reports above per-report cap', async () => {
    const r = await invoke(verify, { body: { mb_shared: 2049, report_id: 'report_1234567890' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('valid client report is rejected as an untrusted source', async () => {
    const r = await invoke(verify, { body: { mb_shared: 1, report_id: 'report_1234567890' } });
    assert.strictEqual(r.statusCode, 409);
    assert.strictEqual(r.body.error, 'untrusted_measurement_source');
    assert.strictEqual(r.body.points_awarded, 0);
  });
  await testAsync('bandwidth rejects malformed report IDs', async () => {
    const r = await invoke(verify, { body: { mb_shared: 1, report_id: 'bad id' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('catalog rejects unsupported country', async () => {
    const r = await invoke(catalog, { method: 'GET', query: { country: 'ZZ' } });
    assert.strictEqual(r.statusCode, 400); assert.strictEqual(r.body.error, 'unsupported_country');
  });
  await testAsync('catalog accepts only GET', async () => {
    const r = await invoke(catalog, { method: 'POST', query: { country: 'US' } });
    assert.strictEqual(r.statusCode, 405);
  });
  await testAsync('redemption rejects missing product ID before external calls', async () => {
    const r = await invoke(redeem, { body: {} });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('redemption rejects unsafe product IDs', async () => {
    const r = await invoke(redeem, { body: { product_id: '../admin' } });
    assert.strictEqual(r.statusCode, 400);
  });
  await testAsync('redemption rejects non-numeric values', async () => {
    const r = await invoke(redeem, { body: { product_id: 'gift-1', value: 'NaN' } });
    assert.strictEqual(r.statusCode, 400);
  });

  test('redemption is manual and does not call a payment provider', () => {
    const redeemSource = fs.readFileSync(path.join(__dirname, '../api/redeem.js'), 'utf8');
    assert.ok(redeemSource.includes('manual_payout: true'));
    assert.ok(redeemSource.includes("status: 'pending'"));
    assert.doesNotMatch(redeemSource, /createOrder|sendPayment|CRYPTOREFILLS_MOCK_MODE/);
  });

  await testAsync('valid redemption reserves 5000 points and creates a pending manual request', async () => {
    rpcCalls.length = 0;
    const r = await invoke(redeem, { body: {
      product_id: 'manual_roblox_US', product_name: 'Roblox Gift Card', currency: 'USD',
      beneficiary_email: 'buyer@example.com', value: 5,
    }});
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual(r.body.manual_payout, true);
    assert.strictEqual(r.body.status, 'pending');
    assert.strictEqual(r.body.points_spent, 5000);
    assert.deepStrictEqual(rpcCalls.map(x => x.name), ['reserve_redemption']);
    assert.strictEqual(rpcCalls[0].args.p_points, 5000);
  });


  // Membership and wheel API use server-side RPCs only.
  await testAsync('rewards endpoint rejects unsupported methods', async () => {
    const r = await invoke(rewards, { method: 'DELETE' });
    assert.strictEqual(r.statusCode, 405);
  });
  await testAsync('membership rejects an unknown plan before database access', async () => {
    rpcCalls.length = 0;
    const r = await invoke(rewards, { body: { action: 'purchase_plan', plan: 'diamond' } });
    assert.strictEqual(r.statusCode, 400);
    assert.strictEqual(r.body.error, 'invalid_plan');
    assert.strictEqual(rpcCalls.length, 0);
  });
  await testAsync('wheel award comes from the atomic server RPC', async () => {
    rpcCalls.length = 0;
    rpcResponse = { status: 'awarded', points_awarded: 25, next_spin_at: '2026-11-08T00:00:00Z' };
    const r = await invoke(rewards, { body: { action: 'spin' } });
    rpcResponse = null;
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual(r.body.points_awarded, 25);
    assert.deepStrictEqual(rpcCalls.map(x => x.name), ['spin_gain_deep_wheel']);
    assert.strictEqual(rpcCalls[0].args.p_device_id, 'test-device-123');
  });
  await testAsync('wheel cooldown is surfaced as HTTP 429', async () => {
    rpcResponse = { status: 'cooldown', next_spin_at: '2026-11-08T00:00:00Z' };
    const r = await invoke(rewards, { body: { action: 'spin' } });
    rpcResponse = null;
    assert.strictEqual(r.statusCode, 429);
    assert.strictEqual(r.body.error, 'wheel_cooldown');
  });
  await testAsync('plan purchase deducts points through the database RPC', async () => {
    rpcCalls.length = 0;
    rpcResponse = { status: 'purchased', plan: 'plus', points_spent: 2500, expires_at: '2026-12-06T00:00:00Z' };
    const r = await invoke(rewards, { body: { action: 'purchase_plan', plan: 'plus' } });
    rpcResponse = null;
    assert.strictEqual(r.statusCode, 200);
    assert.strictEqual(r.body.points_spent, 2500);
    assert.deepStrictEqual(rpcCalls.map(x => x.name), ['purchase_gain_deep_plan']);
    assert.strictEqual(rpcCalls[0].args.p_plan, 'plus');
  });
  await testAsync('insufficient points is not treated as a successful plan purchase', async () => {
    rpcResponse = { status: 'insufficient_points', required: 2500, available: 100 };
    const r = await invoke(rewards, { body: { action: 'purchase_plan', plan: 'plus' } });
    rpcResponse = null;
    assert.strictEqual(r.statusCode, 409);
    assert.strictEqual(r.body.error, 'insufficient_points');
  });

  // Streaming API, moderation and accounting contract checks.
  const streamApiSource = fs.readFileSync(path.join(__dirname, '../api/stream.js'), 'utf8');
  const streamSqlSource = fs.readFileSync(path.join(__dirname, '../supabase/migrations/20261110_gaindeep_streaming.sql'), 'utf8');
  const streamUiSource = fs.readFileSync(path.join(__dirname, '../lib/streaming.dart'), 'utf8');
  test('stream API requires an authenticated session', () => assert.ok(streamApiSource.includes('requireSession(req, res)')));
  test('stream donations use an atomic database RPC', () => assert.ok(streamApiSource.includes("rpc('donate_stream_points'")));
  test('stream donations allocate 70 percent to creator', () => assert.match(streamSqlSource, /floor\(p_points \* 0\.70\)/));
  test('only approved live streams are listed', () => assert.ok(streamApiSource.includes(".eq('moderation_status', 'approved')")));
  test('stream UI includes creator applications and reporting', () => {
    assert.ok(streamUiSource.includes('Apply to become a creator'));
    assert.ok(streamUiSource.includes('Report stream'));
  });
  test('stream UI discloses video provider setup is pending', () => assert.ok(streamUiSource.includes('Video provider setup pending')));

  // CryptoRefills validation-only path must never create orders or reserve points.
  const cryptoValidationSource = fs.readFileSync(path.join(__dirname, '../api/cryptorefills-validate.js'), 'utf8');
  const cryptoClientSource = fs.readFileSync(path.join(__dirname, '../api/_lib/cryptorefills.js'), 'utf8');
  test('CryptoRefills test endpoint is validation-only', () => {
    assert.ok(cryptoValidationSource.includes('validation_only: true'));
    assert.ok(cryptoValidationSource.includes("validateOrder(req, payload)"));
    assert.doesNotMatch(cryptoValidationSource, /reserve_redemption|refund\s*\(/);
    assert.doesNotMatch(cryptoClientSource, /['\"]\/v5\/orders['\"]/);
    assert.ok(cryptoClientSource.includes("'/v5/orders/validations'"));
  });
  test('CryptoRefills validation requires server-side Partner ID', () => {
    assert.ok(cryptoClientSource.includes('CRYPTOREFILLS_PARTNER_ID'));
    assert.ok(cryptoClientSource.includes("'X-Cr-Application'"));
  });


  const rewardsSql = fs.readFileSync(path.join(__dirname, '../supabase/migrations/20261107_gaindeep_rewards.sql'), 'utf8');
  test('wheel uses one server-side random draw with a 24-hour cooldown', () => {
    assert.match(rewardsSql, /v_roll := random\(\)/);
    assert.match(rewardsSql, /interval '24 hours'/);
    assert.match(rewardsSql, /for update/i);
  });
  test('plans are points-only and last 30 days', () => {
    assert.match(rewardsSql, /2500/);
    assert.match(rewardsSql, /7500/);
    assert.match(rewardsSql, /15000/);
    assert.match(rewardsSql, /interval '30 days'/);
    assert.match(rewardsSql, /points_balance = points_balance - v_due/);
  });

  // Keep displayed and awarded points aligned; no AI auditor is implemented.
  const verifySource = fs.readFileSync(path.join(__dirname, '../api/verify-bandwidth.js'), 'utf8');
  const homeSource = fs.readFileSync(path.join(__dirname, '../lib/home.dart'), 'utf8');
  const appConfigSource = fs.readFileSync(path.join(__dirname, '../lib/config.dart'), 'utf8');
  test('bandwidth reward rate comes from backend config', () => assert.ok(verifySource.includes('const POINTS_PER_MB = config.points_per_mb;')));
  test('client reward rate matches backend config', () => assert.ok(appConfigSource.includes('static const double pointsPerMb = 2.0;')));
  test('consent screen does not claim an AI audit', () => assert.doesNotMatch(homeSource, /AI audit|AI auditor/i));
  test('client explains that reported traffic is not independently provider-verified', () => assert.match(homeSource, /does not independently verify that every byte came from that service/i));

  test('client-supplied bandwidth measurements cannot earn points', () => assert.ok(verifySource.includes("untrusted_measurement_source")));
  test('gateway logs server-measured proxy bytes for idempotent crediting', () => { const gateway = fs.readFileSync(path.join(__dirname, '../api/proxy-gateway.js'), 'utf8'); const proxySql = fs.readFileSync(path.join(__dirname, '../supabase/proxy-schema.sql'), 'utf8'); assert.ok(gateway.includes("from('proxy_logs').insert")); assert.ok(gateway.includes('bytes_used: measuredBytes')); assert.ok(proxySql.includes('credit_proxy_log')); assert.ok(proxySql.includes('credited boolean not null default false')); });

  // Check that important SQL invariants are present in the committed schema.
  const sql = fs.readFileSync(path.join(__dirname, '../supabase/schema.sql'), 'utf8');
  for (const [label, pattern] of [
    ['RLS is enabled for devices', /alter table devices enable row level security/i],
    ['RLS is enabled for bandwidth logs', /alter table bandwidth_logs enable row level security/i],
    ['RLS is enabled for redemptions', /alter table redemptions enable row level security/i],
    ['report IDs are unique per device', /unique index if not exists bandwidth_logs_report_uidx/i],
    ['invoice IDs are unique', /unique index if not exists redemptions_invoice_uidx/i],
    ['redemption reserves points atomically', /create or replace function reserve_redemption/i],
    ['refund function is idempotent by status', /r.status not in \('pending', 'processing'\)/i],
    ['settlement awards points only to valid reports', /if coalesce\(p_valid, false\) and found and not d.frozen/i],
    ['public roles cannot execute money functions', /revoke all on function %s from public, anon, authenticated/i],
  ]) test('SQL invariant: ' + label, () => assert.match(sql, pattern));

  console.log('\\nSatsKeeper regression tests: ' + passed + ' passed, ' + failed + ' failed');
  if (failed) process.exitCode = 1;
})().catch((e) => { console.error(e); process.exitCode = 1; });
