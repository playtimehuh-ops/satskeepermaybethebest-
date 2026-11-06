const config = require('./config');

const COUNTRY_CODES = new Set(["AD","AE","AF","AG","AI","AL","AM","AO","AQ","AR","AS","AT","AU","AW","AX","AZ","BA","BB","BD","BE","BF","BG","BH","BI","BJ","BL","BM","BN","BO","BQ","BR","BS","BT","BV","BW","BY","BZ","CA","CC","CD","CF","CG","CH","CI","CK","CL","CM","CN","CO","CR","CU","CV","CW","CX","CY","CZ","DE","DJ","DK","DM","DO","DZ","EC","EE","EG","EH","ER","ES","ET","FI","FJ","FK","FM","FO","FR","GA","GB","GD","GE","GF","GG","GH","GI","GL","GM","GN","GP","GQ","GR","GS","GT","GU","GW","GY","HK","HM","HN","HR","HT","HU","ID","IE","IL","IM","IN","IO","IQ","IR","IS","IT","JE","JM","JO","JP","KE","KG","KH","KI","KM","KN","KP","KR","KW","KY","KZ","LA","LB","LC","LI","LK","LR","LS","LT","LU","LV","LY","MA","MC","MD","ME","MF","MG","MH","MK","ML","MM","MN","MO","MP","MQ","MR","MS","MT","MU","MV","MW","MX","MY","MZ","NA","NC","NE","NF","NG","NI","NL","NO","NP","NR","NU","NZ","OM","PA","PE","PF","PG","PH","PK","PL","PM","PN","PR","PS","PT","PW","PY","QA","RE","RO","RS","RU","RW","SA","SB","SC","SD","SE","SG","SH","SI","SJ","SK","SL","SM","SN","SO","SR","SS","ST","SV","SX","SY","SZ","TC","TD","TF","TG","TH","TJ","TK","TL","TM","TN","TO","TR","TT","TV","TW","TZ","UA","UG","UM","US","UY","UZ","VA","VC","VE","VG","VI","VN","VU","WF","WS","YE","YT","ZA","ZM","ZW"]);
const COUNTRY_MAP = Object.fromEntries([...COUNTRY_CODES].map((code) => [code, code]));
COUNTRY_MAP.UK = 'GB';

function resolveUrl(pathOrUrl) {
  const base = new URL(config.bitrefill_base);
  let target;

  if (/^https?:\/\//i.test(pathOrUrl)) {
    target = new URL(pathOrUrl);
    // Pagination links must stay on the configured Bitrefill API host.
    if (target.origin !== base.origin) throw new Error('bad_bitrefill_url');

    // Some API pagination links omit the configured /v2 prefix.
    const basePath = base.pathname.replace(/\/+$/, '');
    if (basePath && target.pathname !== basePath && !target.pathname.startsWith(basePath + '/')) {
      target.pathname = basePath + (target.pathname.startsWith('/') ? target.pathname : '/' + target.pathname);
    }
  } else {
    const path = String(pathOrUrl || '');
    if (path.startsWith('/v2/')) {
      target = new URL(path, base.origin);
    } else {
      target = new URL(path.replace(/^\/+/, ''), base.href.replace(/\/?$/, '/'));
    }
  }

  const basePath = base.pathname.replace(/\/+$/, '');
  if (target.origin !== base.origin ||
      (basePath && target.pathname !== basePath && !target.pathname.startsWith(basePath + '/'))) {
    throw new Error('bad_bitrefill_url');
  }
  return target.toString();
}

async function bitrefill(pathOrUrl, opts) {
  const options = opts || {};
  const key = process.env.BITREFILL_API_KEY;
  if (!key) {
    const err = new Error('bitrefill_not_configured');
    err.status = 500;
    throw err;
  }
  const url = resolveUrl(pathOrUrl);
  if (!url.startsWith(config.bitrefill_base)) {
    throw new Error('bad_bitrefill_url');
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs || 20000);
  try {
    const resp = await fetch(url, {
      method: options.method || 'GET',
      headers: {
        Authorization: 'Bearer ' + key,
        'Content-Type': 'application/json',
        Accept: 'application/json',
      },
      body: options.body ? JSON.stringify(options.body) : undefined,
      signal: controller.signal,
    });
    let json = null;
    try {
      json = await resp.json();
    } catch (_) {
      json = null;
    }
    if (!resp.ok) {
      const detail = json && (json.message || json.error);
      const err = new Error(detail ? String(detail) : 'bitrefill_http_' + resp.status);
      err.status = resp.status;
      err.http = true;
      throw err;
    }
    return json;
  } finally {
    clearTimeout(timer);
  }
}

function toNumber(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function normalizePackage(p) {
  if (p === null || p === undefined) return null;
  let id = null;
  let raw = p;
  if (typeof p === 'object') {
    id = p.id || p.package_id || null;
    raw = p.value !== undefined ? p.value : p.amount;
  }
  let value = toNumber(raw);
  if (value === null && typeof id === 'string' && id.includes('<&>')) {
    value = toNumber(id.split('<&>')[1]);
  }
  if (value === null || value <= 0) return null;
  return { package_id: id ? String(id) : null, value };
}

// Returns a trimmed product limited to what a redemption may actually buy.
function normalizeProduct(p) {
  if (!p || !p.id || p.in_stock === false) return null;
  // Catalog browsing is not a purchase. Keep valid provider denominations visible;\n  // the manual redemption request applies its own hard amount ceiling.\n  const cap = 10000;

  const packages = (Array.isArray(p.packages) ? p.packages : [])
    .map(normalizePackage)
    .filter((x) => x && x.value <= cap);

  let range = null;
  if (p.range && typeof p.range === 'object') {
    const min = toNumber(p.range.min);
    const rawMax = toNumber(p.range.max);
    const rawStep = toNumber(p.range.step);
    const step = rawStep !== null && rawStep > 0 ? rawStep : 1;
    if (min !== null && rawMax !== null) {
      const max = Math.min(rawMax, cap);
      if (min > 0 && min <= max) range = { min, max, step };
    }
  }

  if (packages.length === 0 && !range) return null;
  return {
    id: String(p.id),
    name: String(p.name || p.id),
    image: p.image || p.logo || p.icon || null,
    country: p.country || null,
    currency: p.currency || null,
    packages,
    range,
  };
}

// Validates the client's choice against the real product. Returns
// { package_id?, value } or null.
function resolveSelection(product, packageId, value) {
  if (packageId) {
    const pkg = product.packages.find((p) => p.package_id === packageId);
    return pkg ? { package_id: pkg.package_id, value: pkg.value } : null;
  }
  const v = Number(value);
  if (!Number.isFinite(v) || v <= 0) return null;
  if (product.range) {
    const { min, max, step } = product.range;
    if (v < min || v > max) return null;
    const steps = (v - min) / step;
    if (Math.abs(steps - Math.round(steps)) > 1e-6) return null;
    return { value: v };
  }
  const byValue = product.packages.find((p) => p.value === v);
  return byValue ? { package_id: byValue.package_id, value: byValue.value } : null;
}

module.exports = { COUNTRY_MAP, bitrefill, normalizeProduct, resolveSelection, resolveUrl };
