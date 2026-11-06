// Buyer -> Vercel -> Supabase Realtime -> phone -> Supabase Realtime -> Vercel -> buyer.
const crypto = require('crypto');
const net = require('net');
const { createClient } = require('@supabase/supabase-js');
const supabase = require('./_lib/supabase');
const { wrap, bodyOf } = require('./_lib/http');
const { validDeviceId } = require('./_lib/auth');

// Node < 22 has no global WebSocket. If the "ws" package is installed it is used automatically.
let WS;
try {
  WS = require('ws');
} catch (_) {
  WS = undefined;
}

const TIMEOUT_MS = 10_000; // whole request, including the Realtime handshake
const MAX_REQUEST_BODY = 100 * 1024; // bytes, buyer -> phone
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024; // bytes, phone -> buyer
const MAX_CHUNK_CHARS = 200_000; // Base64 characters per chunk (the phone uses the same number)
const MAX_CHUNKS = 16;
const MAX_HEADERS = 40;
const MAX_REQUESTS_PER_DEVICE_PER_MIN = 60;

const ALLOWED_METHODS = new Set(['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD', 'OPTIONS']);
const DROP_REQ = new Set([
  'host', 'connection', 'content-length', 'transfer-encoding', 'te', 'trailer', 'upgrade',
  'keep-alive', 'proxy-authorization', 'proxy-connection', 'accept-encoding', 'expect',
]);
const DROP_RES = new Set([
  'connection', 'keep-alive', 'transfer-encoding', 'content-length', 'content-encoding',
  'upgrade', 'proxy-authenticate', 'te', 'trailer',
]);
// Error codes the phone may report -> what the buyer sees.
const PHONE_ERRORS = {
  blocked_target: [403, 'target_blocked'],
  response_too_large: [502, 'response_too_large'],
  upstream_timeout: [504, 'upstream_timeout'],
  busy: [503, 'device_busy'],
  bad_request: [400, 'bad_request'],
};

function digest(s) {
  return crypto.createHash('sha256').update(String(s)).digest();
}

function safeEqual(a, b) {
  return crypto.timingSafeEqual(digest(a), digest(b));
}

// Buyers authenticate with x-api-key. PROXY_API_KEYS = comma separated list of keys (24+ chars each).
function configuredBuyerKeys() {
  const raw = process.env.PROXY_API_KEYS || process.env.PROXY_API_KEY || '';
  return String(raw)
    .split(',')
    .map((k) => k.trim().replace(/^["']|["']$/g, ''))
    .filter((k) => k.length >= 24);
}

function buyerAllowed(req, keys = configuredBuyerKeys()) {
  const given = String(req.headers['x-api-key'] || '').trim();
  let ok = false;
  for (const k of keys) {
    if (safeEqual(given, k)) ok = true; // no early exit
  }
  return ok;
}

function isPrivateIp(ip) {
  if (net.isIPv4(ip)) {
    const [a, b] = ip.split('.').map(Number);
    return (
      a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) ||
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && (b === 168 || b === 0)) ||
      (a === 198 && (b === 18 || b === 19))
    );
  }
  return /^(::1?$|::ffff:|64:ff9b:|f[cd][0-9a-f]{2}:|fe[89ab][0-9a-f]:|ff[0-9a-f]{2}:)/.test(ip.toLowerCase());
}

// First pass only. The phone repeats these checks (and resolves DNS itself), so it never
// trusts this function.
function checkTarget(raw) {
  if (typeof raw !== 'string' || raw.length > 4096) return null;
  let u;
  try {
    u = new URL(raw);
  } catch (_) {
    return null;
  }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  const port = u.port || (u.protocol === 'https:' ? '443' : '80');
  if (port !== '80' && port !== '443') return null;
  const host = u.hostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (!host || host === 'localhost' || /\.(localhost|local|internal|lan)$/.test(host)) return null;
  if (net.isIP(host) && isPrivateIp(host)) return null;
  return u.toString();
}

// Returns a clean lower-case header map, or null when something looks like header injection.
function cleanHeaders(h) {
  const out = {};
  if (h === undefined || h === null) return out;
  if (typeof h !== 'object' || Array.isArray(h)) return null;
  const entries = Object.entries(h);
  if (entries.length > MAX_HEADERS) return null;
  for (const [k, v] of entries) {
    const name = String(k).toLowerCase();
    const value = String(v);
    if (!/^[a-z0-9!#$%&'*+.^_`|~-]{1,64}$/.test(name)) return null;
    if (value.length > 4096 || /[\r\n\0]/.test(value)) return null;
    if (!DROP_REQ.has(name)) out[name] = value;
  }
  return out;
}

function subscribe(channel, deadline) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('subscribe_timeout')), Math.max(deadline - Date.now(), 1));
    channel.subscribe((status, err) => {
      if (status === 'SUBSCRIBED') {
        clearTimeout(timer);
        resolve();
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT' || status === 'CLOSED') {
        clearTimeout(timer);
        reject(err || new Error(status));
      }
    });
  });
}

// Collects the chunks the phone broadcasts and tells us when the response is complete.
function collector(requestId) {
  const parts = new Map();
  let total = null;
  let status = null;
  let headers = {};
  let phoneError = null;
  let finished = false;
  let onFinish = null;

  const finish = () => {
    finished = true;
    if (onFinish) onFinish();
  };

  return {
    push(p) {
      if (finished || !p || typeof p !== 'object' || p.request_id !== requestId) return;
      if (typeof p.error === 'string') {
        phoneError = p.error.slice(0, 40);
        return finish();
      }
      const seq = p.seq;
      const n = p.total;
      if (!Number.isInteger(seq) || !Number.isInteger(n) || n < 1 || n > MAX_CHUNKS) return;
      if (seq < 0 || seq >= n || typeof p.data !== 'string' || p.data.length > MAX_CHUNK_CHARS) return;
      if (total === null) total = n;
      else if (total !== n) return;
      if (!parts.has(seq)) parts.set(seq, p.data);
      if (seq === 0) {
        status = p.status;
        headers = p.headers && typeof p.headers === 'object' ? p.headers : {};
      }
      if (parts.size === total && parts.has(0)) finish();
    },
    // Resolves true when the time ran out, false when the response is complete.
    wait(ms) {
      return new Promise((resolve) => {
        if (finished) return resolve(false);
        const timer = setTimeout(() => resolve(true), Math.max(ms, 0));
        onFinish = () => {
          clearTimeout(timer);
          resolve(false);
        };
      });
    },
    result() {
      if (phoneError) {
        const [code, name] = PHONE_ERRORS[phoneError] || [502, 'upstream_failed'];
        return { status: code, error: name };
      }
      const b64 = Array.from({ length: total }, (_, i) => parts.get(i)).join('');
      if (!/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) return { status: 502, error: 'bad_upstream_data' };
      const body = Buffer.from(b64, 'base64');
      const st = Number(status);
      if (body.length > MAX_RESPONSE_BYTES) return { status: 502, error: 'response_too_large' };
      if (!Number.isInteger(st) || st < 200 || st > 599) return { status: 502, error: 'bad_upstream_data' };
      return { ok: true, status: st, headers, body };
    },
  };
}

async function relay(client, { deviceId, requestId, payload, deadline }) {
  const got = collector(requestId);
  const responseChannel = client.channel(`proxy_response_${deviceId}_${requestId}`, {
    config: { private: true, broadcast: { self: false } },
  });
  responseChannel.on('broadcast', { event: 'chunk' }, (msg) => got.push(msg && msg.payload));
  const deviceChannel = client.channel(`proxy_device_${deviceId}`, { config: { private: true } });

  // Listen first, then ask the phone, so a fast answer can never be missed.
  try {
    await Promise.all([subscribe(responseChannel, deadline), subscribe(deviceChannel, deadline)]);
  } catch (_) {
    return Date.now() >= deadline
      ? { status: 504, error: 'gateway_timeout' }
      : { status: 502, error: 'realtime_unavailable' };
  }

  const sent = await deviceChannel.send({ type: 'broadcast', event: 'request', payload });
  if (sent !== 'ok') return { status: 502, error: 'device_unreachable' };

  const timedOut = await got.wait(deadline - Date.now());
  if (timedOut) return { status: 504, error: 'gateway_timeout' };
  return got.result();
}

async function closeClient(client) {
  try {
    await Promise.race([client.removeAllChannels(), new Promise((r) => setTimeout(r, 500))]);
  } catch (_) {
    // ignore
  }
  try {
    client.realtime.disconnect();
  } catch (_) {
    // ignore
  }
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  const buyerKeys = configuredBuyerKeys();
  if (buyerKeys.length === 0) {
    console.error('proxy_gateway_key_not_configured');
    return res.status(503).json({ error: 'gateway_not_configured' });
  }
  if (!buyerAllowed(req, buyerKeys)) return res.status(401).json({ error: 'unauthorized' });

  const deadline = Date.now() + TIMEOUT_MS;
  const b = bodyOf(req);
  const deviceId = b.device_id;
  const method = String(b.method || 'GET').toUpperCase();
  const target = checkTarget(b.target_url);
  const headers = cleanHeaders(b.headers);
  if (!validDeviceId(deviceId) || !target || !ALLOWED_METHODS.has(method) || headers === null) {
    return res.status(400).json({ error: 'bad_request' });
  }

  let bodyBytes = Buffer.alloc(0);
  if (b.body !== undefined && b.body !== null && b.body !== '') {
    if (method === 'GET' || method === 'HEAD') return res.status(400).json({ error: 'bad_request' });
    if (typeof b.body !== 'string' && !headers['content-type']) headers['content-type'] = 'application/json';
    bodyBytes = Buffer.from(typeof b.body === 'string' ? b.body : JSON.stringify(b.body), 'utf8');
    if (bodyBytes.length > MAX_REQUEST_BODY) return res.status(413).json({ error: 'body_too_large' });
  }

  // Only opted-in, unfrozen devices receive traffic.
  const dev = await supabase.from('devices').select('opted_in, frozen').eq('device_id', deviceId).maybeSingle();
  if (dev.error) return res.status(500).json({ error: 'db_error' });
  if (!dev.data || !dev.data.opted_in) return res.status(404).json({ error: 'device_unavailable' });
  if (dev.data.frozen) return res.status(403).json({ error: 'device_blocked' });

  const since = new Date(Date.now() - 60_000).toISOString();
  const recent = await supabase
    .from('proxy_logs')
    .select('id', { count: 'exact', head: true })
    .eq('device_id', deviceId)
    .gte('created_at', since);
  if (recent.error) return res.status(500).json({ error: 'db_error' });
  if ((recent.count || 0) >= MAX_REQUESTS_PER_DEVICE_PER_MIN) {
    return res.status(429).json({ error: 'rate_limited' });
  }

  const requestId = crypto.randomBytes(16).toString('hex');
  const payload = {
    request_id: requestId,
    target_url: target,
    method,
    headers,
    body_b64: bodyBytes.length ? bodyBytes.toString('base64') : null,
    max_bytes: MAX_RESPONSE_BYTES,
  };

  const client = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    realtime: WS ? { transport: WS } : {},
  });

  let outcome;
  try {
    outcome = await relay(client, { deviceId, requestId, payload, deadline });
  } finally {
    await closeClient(client);
  }

  if (!outcome.ok) return res.status(outcome.status).json({ error: outcome.error, request_id: requestId });

  // Usage is measured here, from what was really delivered, not from what the phone claims.
  const measuredBytes = bodyBytes.length + outcome.body.length;
  const logged = await supabase.from('proxy_logs').insert({
    device_id: deviceId,
    request_id: requestId,
    bytes_used: measuredBytes,
    credited: false,
  });
  if (logged.error) {
    // Fail closed: never deliver buyer traffic that cannot be accounted for.
    console.error('proxy_usage_log_failed', logged.error.message);
    return res.status(503).json({ error: 'usage_recording_unavailable', request_id: requestId });
  }

  for (const [k, v] of Object.entries(outcome.headers).slice(0, 50)) {
    const name = String(k).toLowerCase();
    if (DROP_RES.has(name) || !/^[a-z0-9-]{1,64}$/.test(name)) continue;
    try {
      res.setHeader(name, Array.isArray(v) ? v.map(String) : String(v));
    } catch (_) {
      // skip a header Node refuses
    }
  }
  res.setHeader('x-proxy-request-id', requestId);
  res.setHeader('content-length', outcome.body.length);
  res.status(outcome.status);
  return res.end(outcome.body);
});
