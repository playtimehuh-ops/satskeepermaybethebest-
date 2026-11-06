import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'services.dart';
import 'theme.dart';

class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});
  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> with SingleTickerProviderStateMixin {
  static const List<int> prizes = [0, 5, 10, 15, 25, 50];
  late final AnimationController _wheelController;
  Map<String, dynamic> _data = {};
  bool _loading = true;
  bool _busy = false;
  String? _message;
  int? _lastPrize;

  @override
  void initState() {
    super.initState();
    _wheelController = AnimationController(vsync: this, duration: const Duration(milliseconds: 4200));
    _load();
  }

  @override
  void dispose() {
    _wheelController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await Api.rewards();
      if (mounted) setState(() { _data = result; _loading = false; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _message = e.message; _loading = false; });
    }
  }

  Future<void> _buy(String plan) async {
    setState(() { _busy = true; _message = null; });
    try {
      final result = await Api.purchasePlan(plan);
      if (mounted) {
        setState(() {
          _message = '${plan[0].toUpperCase()}${plan.substring(1)} activated. ${fmtNum(asDouble(result['points_spent']))} points spent.';
        });
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _message = e.code == 'insufficient_points'
          ? 'Not enough spendable points for this plan.'
          : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _spin() async {
    if (_busy || !_canSpin) return;
    setState(() { _busy = true; _message = null; _lastPrize = null; });
    try {
      // The server decides and records the result before the animation reveals it.
      final result = await Api.spinWheel();
      final prize = asDouble(result['points_awarded']).round();
      final index = prizes.indexOf(prize);
      final segment = index < 0 ? 0 : index;
      final anglePer = 2 * math.pi / prizes.length;
      final desired = -(segment + 0.5) * anglePer;
      final target = (2 * math.pi * 5) + ((desired - _wheelAngle) % (2 * math.pi) + 2 * math.pi) % (2 * math.pi);
      _spinDelta = target;
      await _wheelController.forward(from: 0);
      if (mounted) {
        setState(() {
          _lastPrize = prize;
          _data['wheel_available'] = false;
          _data['wheel_next_spin_at'] = result['next_spin_at'];
          _message = prize == 0 ? 'No points this time. Your next spin is in 24 hours.' : 'You won $prize points!';
        });
      }
      // Reset after the result is visible; the next spin starts from zero.
      _wheelAngle += target;
      _wheelController.value = 0;
    } on ApiException catch (e) {
      if (mounted) setState(() => _message = e.code == 'wheel_cooldown'
          ? 'Your next free spin is not ready yet.'
          : e.message);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  double _wheelAngle = 0;
  double _spinDelta = 0;
  bool get _canSpin => _data['wheel_available'] == true && !_busy;
  String get _activePlan => (_data['plan'] ?? 'free').toString();

  String _date(dynamic value) {
    if (value == null) return 'Not active';
    final d = DateTime.tryParse(value.toString())?.toLocal();
    if (d == null) return 'Not active';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    if (_loading) return Scaffold(body: SafeArea(child: Column(children: [const TopBar(title: 'Rewards'), const Expanded(child: Center(child: CircularProgressIndicator()))])));
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TopBar(title: 'Rewards', back: true),
            Expanded(child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                Text('Your membership', style: T.title(c)),
                const SizedBox(height: 6),
                Text('Current plan: ${_activePlan.toUpperCase()}${_data['expires_at'] == null ? '' : ' · until ${_date(_data['expires_at'])}'}', style: T.body(c)),
                const SizedBox(height: 18),
                _planCard(c, 'Plus', 2500, '30-day activity history', 'plus'),
                _planCard(c, 'Pro', 7500, '90-day activity history', 'pro'),
                _planCard(c, 'Elite', 15000, '365-day activity history', 'elite'),
                const SizedBox(height: 30),
                Divider(color: c.rule),
                const SizedBox(height: 16),
                Text('Daily points wheel', style: T.heading(c)),
                const SizedBox(height: 5),
                Text('One free spin every 24 hours. Server-selected odds: 0 points 10% · 5 points 30% · 10 points 30% · 15 points 20% · 25 points 8% · 50 points 2%.', style: T.small(c)),
                const SizedBox(height: 22),
                Center(child: SizedBox(
                  width: 284, height: 284,
                  child: Stack(alignment: Alignment.center, children: [
                    AnimatedBuilder(
                      animation: _wheelController,
                      builder: (context, child) => Transform.rotate(
                        angle: _wheelAngle + (_spinDelta * _wheelController.value),
                        child: child,
                      ),
                      child: CustomPaint(size: const Size(280, 280), painter: _WheelPainter(c, prizes)),
                    ),
                    Positioned(top: 0, child: Icon(Icons.arrow_drop_down, size: 42, color: c.ink)),
                    Container(width: 58, height: 58, decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle, border: Border.all(color: c.ink, width: 2)), child: Center(child: Text('GD', style: T.strong(c)))),
                  ]),
                )),
                const SizedBox(height: 14),
                if (_lastPrize != null) Center(child: Text(_lastPrize == 0 ? '0 points' : '+$_lastPrize points', style: T.title(c))),
                PrimaryButton(label: _busy ? 'Spinning…' : _canSpin ? 'Spin for points' : 'Spin available in 24 hours', onPressed: _canSpin ? _spin : null, busy: _busy),
                if (_message != null) Padding(padding: const EdgeInsets.only(top: 14), child: Message(_message!)),
                if ((_data['history'] as List?)?.isNotEmpty == true) ...[
                  const SizedBox(height: 28),
                  Text('Activity history · ${_data['history_days']} days', style: T.heading(c)),
                  const SizedBox(height: 8),
                  for (final item in (_data['history'] as List).take(30))
                    _historyRow(c, item as Map),
                ] else if (_activePlan == 'free') ...[
                  const SizedBox(height: 16),
                  Text('Activity history is included with Plus, Pro and Elite.', style: T.small(c)),
                ],
              ],
            )),
          ],
        ),
      ),
    );
  }

  Widget _planCard(AppColors c, String name, int cost, String benefit, String id) {
    final active = _activePlan == id;
    final rank = const {'free': 0, 'plus': 1, 'pro': 2, 'elite': 3};
    final currentRank = rank[_activePlan] ?? 0;
    final thisRank = rank[id] ?? 0;
    final disabled = _busy || active || currentRank > thisRank;
    final currentCost = const {'free': 0, 'plus': 2500, 'pro': 7500, 'elite': 15000}[_activePlan] ?? 0;
    final due = cost - (currentRank < thisRank ? currentCost : 0);
    final label = active ? 'Current plan' : currentRank > thisRank ? 'Higher plan active' : '${currentRank == 0 ? 'Unlock' : 'Upgrade'} · $due points';
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: c.surface, border: Border.all(color: c.rule), borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(name, style: T.heading(c))), Text('$cost pts', style: T.number(c, 18))]),
        const SizedBox(height: 4),
        Text(benefit, style: T.small(c)),
        const SizedBox(height: 12),
        SecondaryButton(label: label, onPressed: disabled ? null : () => _buy(id)),
      ]),
    );
  }

  Widget _historyRow(AppColors c, Map item) {
    final date = DateTime.tryParse('${item['created_at']}')?.toLocal();
    final label = date == null ? 'Activity' : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Expanded(child: Text('$label · ${asDouble(item['mb_shared']).toStringAsFixed(2)} MB', style: T.small(c))),
        Text('${asDouble(item['points_awarded']).toStringAsFixed(2)} pts', style: T.strong(c)),
      ]),
    );
  }
}

class _WheelPainter extends CustomPainter {
  final AppColors colors;
  final List<int> prizes;
  _WheelPainter(this.colors, this.prizes);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;
    final sweep = 2 * math.pi / prizes.length;
    final fills = [colors.rule, colors.cobalt, colors.punch, colors.ok, colors.danger, const Color(0xFF8055D8)];
    for (var i = 0; i < prizes.length; i++) {
      final start = -math.pi / 2 + i * sweep;
      final paint = Paint()..color = fills[i % fills.length];
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), start, sweep, true, paint);
      final angle = start + sweep / 2;
      final tp = TextPainter(
        text: TextSpan(text: prizes[i] == 0 ? '0' : '+${prizes[i]}', style: TextStyle(color: i == 0 || i == 2 ? colors.ink : Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = Offset(center.dx + math.cos(angle) * radius * 0.65 - tp.width / 2, center.dy + math.sin(angle) * radius * 0.65 - tp.height / 2);
      tp.paint(canvas, pos);
    }
    canvas.drawCircle(center, radius, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = colors.ink);
  }
  @override
  bool shouldRepaint(covariant _WheelPainter old) => old.prizes != prizes || old.colors != colors;
}
