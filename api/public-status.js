// Public, read-only product status. Never expose environment values or account data here.
module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');

  if (req.method !== 'GET') {
    res.setHeader('Allow', 'GET');
    return res.status(405).json({ error: 'method_not_allowed' });
  }

  return res.status(200).json({
    product: 'GainDeep',
    stage: 'prelaunch',
    api: 'reachable',
    checked_at: new Date().toISOString(),
    features: {
      accounts: 'authentication_required',
      points_earning: 'not_cleared_for_public_launch',
      memberships_and_wheel: 'database_backed_end_to_end_test_pending',
      gift_cards: 'manual_review_only_availability_not_guaranteed',
      network_sharing: 'provider_and_legal_clearance_required',
      buyer_traffic_api: 'not_available'
    },
    launch_gates: [
      'Confirm an eligible adult legal operator and publish operator details.',
      'Complete independent security and privacy review.',
      'Verify trustworthy traffic measurement and provider authorization.',
      'Configure and verify a permanent Android release signing key.',
      'Complete real-device account, points, reward, and redemption tests.'
    ]
  });
};
