// Shared request helpers: never leak internals, never crash the function.

function wrap(handler) {
  return async (req, res) => {
    try {
      await handler(req, res);
    } catch (err) {
      console.error('handler_error', req.url, err && err.message ? err.message : err);
      if (!res.headersSent) {
        res.status(500).json({ error: 'server_error' });
      }
    }
  };
}

// Body must be a plain JSON object; anything else becomes {}.
function bodyOf(req) {
  const b = req.body;
  return b && typeof b === 'object' && !Array.isArray(b) ? b : {};
}

module.exports = { wrap, bodyOf };
