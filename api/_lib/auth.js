const crypto = require('crypto');
const supabase = require('./supabase');

function safeEqual(a, b) {
  const ba = Buffer.from(String(a || ''));
  const bb = Buffer.from(String(b || ''));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function requireAppKey(req, res) {
  const expected = process.env.APP_KEY;
  if (!expected || !safeEqual(req.headers['x-app-key'], expected)) {
    res.status(401).json({ error: 'unauthorized' });
    return false;
  }
  return true;
}

function requireAdmin(req, res) {
  const user = process.env.ADMIN_USER;
  const pass = process.env.ADMIN_PASS;
  const header = req.headers.authorization || '';
  let ok = false;
  if (user && pass && header.startsWith('Basic ')) {
    const decoded = Buffer.from(header.slice(6), 'base64').toString('utf8');
    const idx = decoded.indexOf(':');
    if (idx >= 0) {
      const userOk = safeEqual(decoded.slice(0, idx), user);
      const passOk = safeEqual(decoded.slice(idx + 1), pass);
      ok = userOk && passOk;
    }
  }
  if (!ok) {
    res.setHeader('WWW-Authenticate', 'Basic realm="admin"');
    res.status(401).json({ error: 'unauthorized' });
    return false;
  }
  return true;
}

// Vercel Cron sends "Authorization: Bearer <CRON_SECRET>".
function isCron(req) {
  const secret = process.env.CRON_SECRET;
  const header = req.headers.authorization || '';
  return Boolean(secret) && secret.length >= 16 && header.startsWith('Bearer ') && safeEqual(header.slice(7), secret);
}

function validDeviceId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{8,128}$/.test(id);
}

// App key + Supabase user token. Returns the user id (used as device_id) or null.
async function requireSession(req, res) {
  if (!requireAppKey(req, res)) return null;
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
  if (!token) {
    res.status(401).json({ error: 'login_required' });
    return null;
  }
  try {
    const { data, error } = await supabase.auth.getUser(token);
    if (error || !data || !data.user) {
      res.status(401).json({ error: 'invalid_session' });
      return null;
    }
    const user = data.user;
    // Only confirmed e-mail addresses may earn or spend (blocks throw-away signups).
    if (!user.email_confirmed_at && !user.confirmed_at) {
      res.status(403).json({ error: 'email_unconfirmed' });
      return null;
    }
    if (user.banned_until && new Date(user.banned_until).getTime() > Date.now()) {
      res.status(403).json({ error: 'account_blocked' });
      return null;
    }
    if (typeof user.id !== 'string' || !validDeviceId(user.id)) {
      res.status(401).json({ error: 'invalid_session' });
      return null;
    }
    return user.id;
  } catch (_) {
    res.status(401).json({ error: 'invalid_session' });
    return null;
  }
}

module.exports = { requireAppKey, requireAdmin, requireSession, validDeviceId, isCron };
