const supabase = require('./supabase');
const { bitrefill } = require('./bitrefill');

const FAILED = new Set(['denied', 'payment_error', 'expired', 'refunded', 'not_delivered']);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const unwrap = (json) => (json && json.data ? json.data : json) || {};

function formatRedemption(order) {
  const info = order && order.redemption_info;
  if (!info) return null;
  const parts = [];
  if (info.code) parts.push(String(info.code));
  if (info.pin) parts.push('PIN ' + info.pin);
  if (!info.code && info.link) parts.push(String(info.link));
  return parts.length ? parts.join(' | ') : null;
}

async function findCode(invoice) {
  const orders = Array.isArray(invoice.orders) ? invoice.orders : [];
  for (const order of orders) {
    const inline = formatRedemption(order);
    if (inline) return inline;
    if (order && order.id) {
      try {
        const full = unwrap(await bitrefill('/orders/' + encodeURIComponent(order.id)));
        const fetched = formatRedemption(full);
        if (fetched) return fetched;
      } catch (_) {
        // try the next order / report as processing
      }
    }
  }
  return null;
}

// Give the points back exactly once (the SQL function refuses a second refund).
async function refund(redemptionId, note) {
  const { data, error } = await supabase.rpc('refund_redemption', { p_id: redemptionId, p_note: note || null });
  if (error) throw new Error('refund_failed');
  return data === true;
}

async function advance(redemptionId, status, fields) {
  const { data, error } = await supabase.rpc('update_redemption', {
    p_id: redemptionId,
    p_status: status,
    p_invoice_id: (fields && fields.invoiceId) || null,
    p_code: (fields && fields.code) || null,
  });
  if (error) throw new Error('update_failed');
  return data === true;
}

// Re-check redemptions stuck in 'processing' against Bitrefill (admin / cron).
async function reconcile(limit) {
  const cutoff = new Date(Date.now() - 2 * 60 * 1000).toISOString();
  const { data: rows, error } = await supabase
    .from('redemptions')
    .select('id, invoice_id')
    .eq('status', 'processing')
    .not('invoice_id', 'is', null)
    .lt('updated_at', cutoff)
    .order('id', { ascending: true })
    .limit(limit || 20);
  if (error) throw new Error('db_error');

  const results = [];
  for (const row of rows || []) {
    try {
      const invoice = unwrap(await bitrefill('/invoices/' + encodeURIComponent(row.invoice_id)));
      if (FAILED.has(invoice.status)) {
        const done = await refund(row.id, 'reconcile:' + invoice.status);
        results.push({ id: row.id, result: done ? 'refunded' : 'unchanged' });
      } else if (invoice.status === 'complete') {
        const code = await findCode(invoice);
        if (code) {
          await advance(row.id, 'completed', { code });
          results.push({ id: row.id, result: 'completed' });
        } else {
          results.push({ id: row.id, result: 'waiting_for_code' });
        }
      } else {
        results.push({ id: row.id, result: 'waiting' });
      }
    } catch (_) {
      results.push({ id: row.id, result: 'error' });
    }
  }
  return results;
}

module.exports = { FAILED, sleep, unwrap, findCode, refund, advance, reconcile };
