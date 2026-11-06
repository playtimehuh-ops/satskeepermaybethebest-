import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'services.dart';
import 'store.dart';
import 'rewards.dart';
import 'theme.dart';

/// Stops sharing, tells the server, clears local flags and logs out.
Future<void> signOutAndReset(NavigatorState nav) async {
  // Stop local sharing first; a network outage must not keep the node running.
  try {
    await NodeChannel.stop();
  } catch (_) {
    // best effort
  }
  try {
    await Api.consent(false);
  } catch (_) {
    // best effort; the local services are already stopped.
  }
  await LocalState.setOptedIn(false);
  nav.popUntil((route) => route.isFirst);
  await AuthService.signOut();
}

// ---------------------------------------------------------------------------
// Consent
// ---------------------------------------------------------------------------

class ConsentScreen extends StatefulWidget {
  final VoidCallback onEnabled;
  const ConsentScreen({super.key, required this.onEnabled});

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  bool _on = false;
  bool _busy = false;
  String? _error;

  Future<void> _toggle(bool value) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.consent(value);
      if (value) {
        try {
          final ok = await NodeChannel.start();
          if (!ok) throw ApiException(0, 'The sharing service didn\'t start. Try again.');
        } catch (_) {
          try {
            await Api.consent(false);
          } catch (_) {
            // best effort
          }
          rethrow;
        }
      } else {
        await NodeChannel.stop();
      }
      await LocalState.setOptedIn(value);
      if (mounted) setState(() => _on = value);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'The sharing service failed to start.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopBar(
              trailing: LinkButton(
                label: 'Log out',
                color: c.muted,
                onPressed: _busy ? null : () => signOutAndReset(Navigator.of(context)),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Before you start sharing', style: T.title(c)),
                    const SizedBox(height: 12),
                    Text(
                      'GainDeep runs a Mysterium node on your phone. Here is what that means.',
                      style: T.body(c).copyWith(color: c.muted),
                    ),
                    const SizedBox(height: 32),
                    const _Fact(
                      'It runs in the background.',
                      'A foreground service keeps the node alive and shows a notification while it works.',
                    ),
                    const _Fact(
                      'Other people\'s traffic uses your connection.',
                      'Encrypted traffic from Mysterium users leaves through your IP address and counts against your data plan.',
                    ),
                    const _Fact(
                      'You earn 2 points per megabyte.',
                      'The app reports bytes sent by its Android process. Server-side timing and volume rules check each report. This does not independently verify Mysterium-only traffic.',
                    ),
                    const _Fact(
                      'You can stop any time.',
                      'Turn sharing off here, or pause it from your account page.',
                    ),
                    const SizedBox(height: 4),
                    Divider(height: 1, color: c.rule),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Share my bandwidth', style: T.strong(c)),
                                Text(_on ? 'Sharing is on' : 'Sharing is off', style: T.small(c)),
                              ],
                            ),
                          ),
                          if (_busy)
                            const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            )
                          else
                            Switch(value: _on, onChanged: _toggle),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: c.rule),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 14),
                        child: Message(_error!),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: PrimaryButton(
                label: 'Continue',
                onPressed: (_on && !_busy) ? widget.onEnabled : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String lead;
  final String detail;
  const _Fact(this.lead, this.detail);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(lead, style: T.strong(c)),
          const SizedBox(height: 4),
          Text(detail, style: T.small(c).copyWith(fontSize: 15)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dashboard
// ---------------------------------------------------------------------------

class DashboardScreen extends StatefulWidget {
  final String email;
  final VoidCallback onStopped;
  const DashboardScreen({super.key, required this.email, required this.onStopped});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _timer;
  bool _busy = false;
  double _points = 0;
  double _available = 0;
  double _threshold = AppConfig.redeemCost.toDouble();
  int _streak = 0;
  double _acceptedMb = 0;
  final List<double> _history = <double>[];
  String? _lastReport;
  String? _error;
  Map<String, dynamic> _node = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _timer = Timer.periodic(
      const Duration(seconds: AppConfig.reportIntervalSeconds),
      (_) => _tick(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      // Always invoke start(): the Mysterium service may survive a UI restart while
      // the non-sticky Realtime proxy service does not. start() safely reuses a live node.
      final started = await NodeChannel.start();
      if (!started) throw ApiException(0, 'The sharing service did not start.');
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Couldn\'t start the sharing service.');
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    await _refreshNode();
    await _refreshLedger();
  }

  Future<void> _refreshNode() async {
    try {
      final s = await NodeChannel.status();
      if (mounted) setState(() => _node = s);
    } on PlatformException {
      // ignore
    }
  }

  Future<void> _refreshLedger() async {
    try {
      final j = await Api.ledger();
      if (!mounted) return;
      setState(() {
        _points = asDouble(j['points']);
        _available = j['available'] == null ? _points : asDouble(j['available']);
        final t = asDouble(j['threshold']);
        if (t > 0) _threshold = t;
        _streak = asDouble(j['streak']).toInt();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  // Largest slice sent in one report; the rest carries over to the next minute.
  static const int _maxReportBytes = 2000 * 1000 * 1000;

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final current = await NodeChannel.getBytesShared();
      var last = LocalState.lastBytes;
      if (current < last) {
        // The node restarted, so its counter began again from zero.
        last = 0;
        await LocalState.setLastBytes(0);
      }

      // Reuse an unanswered report (same id, so it can never count twice) or start a new one.
      var reportId = LocalState.pendingId;
      var mb = LocalState.pendingMb;
      var fresh = 0.0;
      if (reportId == null) {
        var bytes = current - last;
        if (bytes > _maxReportBytes) bytes = _maxReportBytes;
        if (bytes >= 10000) {
          reportId = LocalState.newReportId();
          mb = bytes / 1000000.0;
          fresh = mb;
          await LocalState.setPending(reportId, mb);
          await LocalState.setLastBytes(last + bytes);
        }
      }

      try {
        await Api.heartbeat();
      } on ApiException {
        // not fatal
      }

      if (reportId != null) {
        try {
          final r = await Api.verifyBandwidth(mb, reportId);
          await LocalState.clearPending();
          final valid = r['valid'] == true;
          if (valid && r['duplicate'] != true) _acceptedMb += mb;
          if (mounted) {
            setState(() {
              _lastReport = valid
                  ? '+${fmtNum(asDouble(r['points_awarded']), decimals: 2)} points for ${mb.toStringAsFixed(2)} MB'
                  : 'Not accepted, ${mb.toStringAsFixed(2)} MB';
            });
          }
        } on ApiException catch (e) {
          // Refusals (400/403) are final, so drop the report. Anything else keeps it and
          // retries with the same id on the next tick.
          if (e.status == 400 || e.status == 403 || e.status == 409) await LocalState.clearPending();
          if (mounted) setState(() => _lastReport = e.message);
        }
      }

      if (mounted) {
        setState(() {
          _history.add(fresh > 0 ? fresh : 0.0);
          if (_history.length > 24) _history.removeAt(0);
        });
      }
      await _refresh();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'Sharing service error.');
    } finally {
      _busy = false;
    }
  }

  String get _status {
    if (_node['error'] != null) {
      final detail = _node['error'].toString().trim();
      return detail.isEmpty ? 'Error' : 'Error: ${detail.length > 34 ? '${detail.substring(0, 34)}…' : detail}';
    }
    if (_node['running'] == true) return 'Sharing';
    if (_node['starting'] == true) return 'Starting';
    return 'Not running';
  }

  Future<void> _openStore() async {
    await Navigator.of(context).push(fadeRoute<void>(StoreScreen(points: _available)));
    await _refreshLedger();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final left = _threshold - _points;
    final ready = _available >= _threshold;
    final holding = _points >= _threshold && !ready;
    final initial = widget.email.isEmpty ? '?' : widget.email.substring(0, 1).toUpperCase();
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopBar(
              title: 'GainDeep',
              trailing: Semantics(
                button: true,
                label: 'Account',
                child: Material(
                  color: c.ink,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(context).push(
                      fadeRoute<void>(AccountScreen(email: widget.email, onStopped: widget.onStopped)),
                    ),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: Center(
                        child: Text(initial, style: T.strong(c).copyWith(color: c.ground)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refresh,
                color: c.cobalt,
                backgroundColor: c.surface,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: [
                    StampCard(
                      points: _points,
                      threshold: _threshold,
                      active: _node['running'] == true,
                      status: _status,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      ready
                          ? 'Your card is full. Pick any gift card or top-up in the store.'
                          : holding
                              ? 'Your card is full. New points unlock 24 hours after they\'re earned.'
                              : '${fmtNum(left)} points to go. Each reported megabyte earns ${AppConfig.pointsPerMb} point after server checks.',
                      style: T.small(c).copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 32),
                    Text('Recent reports', style: T.heading(c)),
                    const SizedBox(height: 4),
                    Text('App network megabytes reported per minute, newest on the right.', style: T.small(c)),
                    const SizedBox(height: 14),
                    ThroughputBars(values: List<double>.of(_history)),
                    const SizedBox(height: 20),
                    Material(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () async {
                          await Navigator.of(context).push(fadeRoute<void>(const RewardsScreen()));
                          await _refreshLedger();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(color: c.punch, borderRadius: BorderRadius.circular(12)),
                                child: Icon(Icons.casino_outlined, color: c.ink),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Rewards & plans', style: T.strong(c)),
                                    Text('Daily points wheel · memberships', style: T.small(c)),
                                  ],
                                ),
                              ),
                              Icon(Icons.arrow_forward_ios, size: 16, color: c.muted),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Divider(height: 1, color: c.rule),
                    _InfoRow('Streak', '$_streak ${_streak == 1 ? 'day' : 'days'}'),
                    _InfoRow('Accepted reports this session', '${_acceptedMb.toStringAsFixed(2)} MB'),
                    _InfoRow('Last report', _lastReport ?? 'The first one is due within a minute.'),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Message(_error!),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: PrimaryButton(
                label: ready ? 'Choose a gift card' : 'Browse the store',
                onPressed: _openStore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: T.small(c).copyWith(fontSize: 15)),
              const SizedBox(width: 16),
              Expanded(child: Text(value, textAlign: TextAlign.right, style: T.strong(c))),
            ],
          ),
        ),
        Divider(height: 1, color: c.rule),
      ],
    );
  }
}

/// A prepaid-style card: one stamp for every 250 points, twenty stamps to a gift card.
class StampCard extends StatelessWidget {
  final double points;
  final double threshold;
  final bool active;
  final String status;

  const StampCard({
    super.key,
    required this.points,
    required this.threshold,
    required this.active,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final onCard = c.onCobalt;
    final progress = threshold > 0 ? (points / threshold).clamp(0.0, 1.0).toDouble() : 0.0;
    return Semantics(
      label: 'Balance ${fmtNum(points, decimals: 2)} of ${fmtNum(threshold)} points. $status.',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: c.cobalt,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Next gift card', style: T.strong(c).copyWith(color: onCard)),
                  const Spacer(),
                  PulseDot(color: active ? c.punch : onCard.withAlpha(130), active: active, size: 8),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: T.small(c).copyWith(color: onCard.withAlpha(225)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: points),
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) {
                  final whole = v.floor();
                  final cents = ((v - whole) * 100 + 1e-6).floor();
                  return FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: fmtNum(whole.toDouble()),
                            style: T.hero(c).copyWith(color: onCard),
                          ),
                          TextSpan(
                            text: '.${cents.toString().padLeft(2, '0')}',
                            style: T.number(c, 24).copyWith(color: onCard.withAlpha(185)),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                'of ${fmtNum(threshold)} points',
                style: T.small(c).copyWith(color: onCard.withAlpha(225)),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, box) {
                  const gap = 6.0;
                  const rowGap = 8.0;
                  final d = (box.maxWidth - gap * 9) / 10;
                  return TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: progress),
                    duration: const Duration(milliseconds: 900),
                    curve: Curves.easeOutCubic,
                    builder: (context, p, _) => SizedBox(
                      width: box.maxWidth,
                      height: d * 2 + rowGap,
                      child: CustomPaint(
                        painter: _StampPainter(p, d, gap, rowGap, c.punch, onCard),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StampPainter extends CustomPainter {
  final double progress;
  final double d;
  final double gap;
  final double rowGap;
  final Color fill;
  final Color ring;

  _StampPainter(this.progress, this.d, this.gap, this.rowGap, this.fill, this.ring);

  @override
  void paint(Canvas canvas, Size size) {
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = ring.withAlpha(110);
    final fillPaint = Paint()..color = fill;
    for (var i = 0; i < AppConfig.stampCount; i++) {
      final row = i ~/ 10;
      final col = i % 10;
      final center = Offset(col * (d + gap) + d / 2, row * (d + rowGap) + d / 2);
      final amount = (progress * AppConfig.stampCount - i).clamp(0.0, 1.0).toDouble();
      canvas.drawCircle(center, d / 2 - 0.8, ringPaint);
      if (amount > 0) {
        canvas.drawCircle(center, (d / 2 - 2.4) * amount, fillPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_StampPainter old) =>
      old.progress != progress || old.d != d || old.fill != fill || old.ring != ring;
}

// ---------------------------------------------------------------------------
// Account
// ---------------------------------------------------------------------------

class AccountScreen extends StatefulWidget {
  final String email;
  final VoidCallback onStopped;
  const AccountScreen({super.key, required this.email, required this.onStopped});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _cards = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadCards();
  }

  Future<void> _loadCards() async {
    try {
      final j = await Api.ledger();
      final raw = j['redemptions'];
      if (!mounted || raw is! List) return;
      setState(() => _cards = raw.whereType<Map<String, dynamic>>().toList());
    } on ApiException {
      // The list is a convenience; the rest of the screen still works.
    }
  }

  Future<void> _copyCode(String code) async {
    await SecretClipboard.copy(code);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied. The clipboard clears in a minute.')),
      );
    }
  }

  Future<void> _pause() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    String? syncWarning;
    try {
      // Immediately stop the local node/proxy, even when the network is unavailable.
      try {
        await NodeChannel.stop();
      } catch (e) {
        syncWarning = 'Local stop reported an error: $e';
      }
      try {
        await Api.consent(false);
      } on ApiException {
        syncWarning = 'Sharing stopped on this phone, but the server could not be updated. Reconnect to sync consent.';
      }
      await LocalState.setOptedIn(false);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      widget.onStopped();
      if (syncWarning != null) {
        messenger.showSnackBar(SnackBar(content: Text(syncWarning)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final id = AuthService.session.value?.userId ?? '';
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TopBar(title: 'Account', back: true),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                children: [
                  Text('Signed in as', style: T.small(c)),
                  const SizedBox(height: 2),
                  Text(widget.email, style: T.heading(c), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 32),
                  Text('Sharing is on', style: T.strong(c)),
                  const SizedBox(height: 4),
                  Text(
                    'Pausing stops the node and the notification. Your points stay in your account.',
                    style: T.small(c).copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 16),
                  SecondaryButton(label: _busy ? 'Pausing…' : 'Pause sharing', onPressed: _busy ? null : _pause),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Message(_error!),
                    ),
                  if (_cards.isNotEmpty) ...[
                    const SizedBox(height: 40),
                    Text('Your gift cards', style: T.heading(c)),
                    const SizedBox(height: 8),
                    for (final card in _cards) _CardRow(card: card, onCopy: _copyCode),
                  ],
                  const SizedBox(height: 40),
                  Text('Account ID', style: T.small(c)),
                  const SizedBox(height: 2),
                  SelectableText(id, style: T.small(c).copyWith(color: c.ink)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: SecondaryButton(
                label: 'Log out',
                onPressed: _busy ? null : () => signOutAndReset(Navigator.of(context)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class _CardRow extends StatelessWidget {
  final Map<String, dynamic> card;
  final void Function(String code) onCopy;
  const _CardRow({required this.card, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final status = '${card['status'] ?? ''}';
    final code = card['code'] == null ? null : '${card['code']}';
    final name = '${card['product_id'] ?? 'Gift card'}';
    final note = status == 'completed'
        ? 'Delivered'
        : status == 'failed'
            ? 'Failed, points returned'
            : 'Being delivered. Check back soon.';
    final showCode = code != null && status == 'completed';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: T.strong(c), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(note, style: T.small(c)),
                    if (showCode) ...[
                      const SizedBox(height: 6),
                      SelectableText(code!, style: T.small(c).copyWith(color: c.ink)),
                    ],
                  ],
                ),
              ),
              if (showCode) LinkButton(label: 'Copy', onPressed: () => onCopy(code!)),
            ],
          ),
        ),
        Divider(height: 1, color: c.rule),
      ],
    );
  }
}
