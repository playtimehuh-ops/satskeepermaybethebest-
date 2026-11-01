const { requireSession } = require('./_lib/auth');
const { wrap } = require('./_lib/http');
const { COUNTRY_MAP, bitrefill, normalizeProduct } = require('./_lib/bitrefill');

const MAX_PAGES = 6;
// Bitrefill limits /products to 1000 requests an hour, so each country is cached.
const CACHE_MS = 15 * 60 * 1000;
// Set BITREFILL_INCLUDE_TEST=true to list the free test products while developing.
const INCLUDE_TEST = process.env.BITREFILL_INCLUDE_TEST === 'true';

const cache = new Map();

async function loadCatalog(country) {
  const hit = cache.get(country);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.products;

  const products = [];
  let next =
    '/products?country=' + encodeURIComponent(country) + '&limit=50' +
    (INCLUDE_TEST ? '&include_test_products=true' : '');
  for (let page = 0; next && page < MAX_PAGES; page += 1) {
    const body = await bitrefill(next);
    const items = body && Array.isArray(body.data) ? body.data : [];
    for (const item of items) {
      const product = normalizeProduct(item);
      if (product) products.push(product);
    }
    next = body && body.meta && body.meta._next ? body.meta._next : null;
  }
  products.sort((a, b) => a.name.localeCompare(b.name));
  cache.set(country, { at: Date.now(), products });
  return products;
}

module.exports = wrap(async (req, res) => {
  if (req.method !== 'GET') {
    return res.status(405).json({ error: 'method_not_allowed' });
  }
  if (!(await requireSession(req, res))) return;

  const requested = String((req.query && req.query.country) || '').toUpperCase();
  const country = COUNTRY_MAP[requested];
  if (!country) {
    return res.status(400).json({ error: 'unsupported_country' });
  }

  try {
    const products = await loadCatalog(country);
    return res.status(200).json({ country: requested, products });
  } catch (err) {
    const stale = cache.get(country);
    if (stale) return res.status(200).json({ country: requested, products: stale.products, stale: true });
    return res.status(502).json({ error: 'catalog_unavailable' });
  }
});
