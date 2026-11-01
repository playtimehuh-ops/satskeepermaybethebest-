// Offline smoke test: every endpoint must refuse unauthenticated or wrongly-shaped calls.
// Run with: npm test
const path = require('path');

process.env.APP_KEY = 'test-app-key-1234567890';
const stub = { auth: { getUser: async () => ({ data: null, error: { message: 'bad' } }) }, rpc: async () => ({ data: null, error: { message: 'x' } }) };
const supPath = require.resolve(path.join(__dirname, '../api/_lib/supabase.js'));
require.cache[supPath] = { id: supPath, filename: supPath, loaded: true, exports: stub };

const names = ['consent', 'heartbeat', 'ledger', 'verify-bandwidth', 'get-catalog', 'redeem', 'admin'];
let failed = 0;

function run(handler, req) {
  return new Promise((resolve) => {
    const res = {
      statusCode: 200,
      headersSent: false,
      setHeader() {},
      status(c) { this.statusCode = c; return this; },
      json(o) { this.headersSent = true; resolve({ status: this.statusCode, body: o }); return this; },
    };
    handler({ headers: {}, query: {}, body: {}, url: '/x', ...req }, res);
  });
}

(async () => {
  for (const n of names) {
    const handler = require(path.join(__dirname, '../api', n + '.js'));
    const noKey = await run(handler, { method: n === 'ledger' || n === 'get-catalog' ? 'GET' : 'POST', query: { action: 'overview' } });
    const ok = noKey.status === 401;
    console.log((ok ? 'PASS ' : 'FAIL ') + n + ' refuses unauthenticated calls (' + noKey.status + ')');
    if (!ok) failed += 1;
    const wrongMethod = await run(handler, { method: 'DELETE', headers: { 'x-app-key': process.env.APP_KEY } });
    const ok2 = n === 'admin' ? wrongMethod.status === 401 : wrongMethod.status === 405;
    console.log((ok2 ? 'PASS ' : 'FAIL ') + n + ' rejects odd HTTP methods (' + wrongMethod.status + ')');
    if (!ok2) failed += 1;
  }
  process.exit(failed ? 1 : 0);
})();
