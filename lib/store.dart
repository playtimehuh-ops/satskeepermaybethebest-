import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'services.dart';
import 'theme.dart';

String fmtAmount(double v) => v == v.roundToDouble() ? fmtNum(v) : v.toStringAsFixed(2);

String describeAmounts(Product p) {
  final cur = p.currency ?? '';
  if (p.packages.isNotEmpty) {
    return '${p.packages.map((e) => fmtAmount(e.value)).join(', ')} $cur'.trim();
  }
  if (p.min != null && p.max != null) {
    return 'Any amount from ${fmtAmount(p.min!)} to ${fmtAmount(p.max!)} $cur'.trim();
  }
  return cur;
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

class StoreScreen extends StatefulWidget {
  final double points;
  const StoreScreen({super.key, required this.points});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  int _countryIndex = 0;
  List<Product> _products = <Product>[];
  bool _loading = false;
  String? _error;
  late double _points = widget.points;
  final TextEditingController _search = TextEditingController();
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await Api.catalog(AppConfig.countries[_countryIndex]);
      if (!mounted || token != _loadToken) return;
      setState(() => _products = list);
    } on ApiException catch (e) {
      if (mounted && token == _loadToken) {
        setState(() {
          _products = <Product>[];
          _error = e.message;
        });
      }
    } finally {
      if (mounted && token == _loadToken) setState(() => _loading = false);
    }
  }

  Future<void> _refreshPoints() async {
    try {
      final j = await Api.ledger();
      if (mounted) setState(() => _points = asDouble(j['available'] ?? j['points']));
    } on ApiException {
      // keep the last known balance
    }
  }

  Future<void> _open(Product p) async {
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      enableDrag: false,
      useSafeArea: true,
      builder: (_) => ProductSheet(product: p, points: _points),
    );
    await _refreshPoints();
  }

  List<Product> get _visible {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return _products;
    return _products.where((p) => p.name.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final cost = AppConfig.redeemCost.toDouble();
    final need = cost - _points;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const TopBar(title: 'Store', back: true),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pick a gift card or top-up', style: T.title(c)),
                  const SizedBox(height: 8),
                  Text(
                    need > 0
                        ? 'Each one costs ${fmtNum(cost)} points. You need ${fmtNum(need)} more.'
                        : 'Each one costs ${fmtNum(cost)} points. You have ${fmtNum(_points)}.',
                    style: T.small(c).copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  TextTabs(
                    labels: AppConfig.countries,
                    index: _countryIndex,
                    onChanged: (i) {
                      if (i == _countryIndex) return;
                      setState(() {
                        _countryIndex = i;
                        _products = <Product>[];
                      });
                      _load();
                    },
                  ),
                  const SizedBox(height: 16),
                  FieldLine(
                    label: 'Search',
                    hint: 'Brand name',
                    controller: _search,
                    action: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (_loading && _products.isEmpty) return const _Skeleton();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Message(_error!),
              const SizedBox(height: 8),
              LinkButton(label: 'Try again', onPressed: _load),
            ],
          ),
        ),
      );
    }
    final list = _visible;
    if (list.isEmpty) {
      final q = _search.text.trim();
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            q.isEmpty
                ? 'No cards are available in ${AppConfig.countries[_countryIndex]} right now. Try another country.'
                : 'No brand matches "$q".',
            textAlign: TextAlign.center,
            style: T.small(c).copyWith(fontSize: 15),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      itemCount: list.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: c.rule),
      itemBuilder: (context, i) => _ProductRow(product: list[i], onTap: () => _open(list[i])),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  const _ProductRow({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            BrandTile(product: product),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.name, style: T.strong(c), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(describeAmounts(product), style: T.small(c), maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: c.muted),
          ],
        ),
      ),
    );
  }
}

class BrandTile extends StatelessWidget {
  final Product product;
  final double size;
  const BrandTile({super.key, required this.product, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final initial = product.name.isEmpty ? '?' : product.name.substring(0, 1).toUpperCase();
    Widget fallback() => Center(child: Text(initial, style: T.heading(c)));
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.rule),
      ),
      child: product.image == null
          ? fallback()
          : Padding(
              padding: const EdgeInsets.all(6),
              child: Image.network(
                product.image!,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => fallback(),
              ),
            ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final block = c.rule.withAlpha(140);
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        for (var i = 0; i < 7; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(12)),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 140,
                        height: 14,
                        decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(4)),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 96,
                        height: 12,
                        decoration: BoxDecoration(color: block, borderRadius: BorderRadius.circular(4)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Product sheet: choose an amount, redeem, reveal the code
// ---------------------------------------------------------------------------

enum _Phase { choose, working, receipt, pending }

class ProductSheet extends StatefulWidget {
  final Product product;
  final double points;
  const ProductSheet({super.key, required this.product, required this.points});

  @override
  State<ProductSheet> createState() => _ProductSheetState();
}

class _ProductSheetState extends State<ProductSheet> {
  _Phase _phase = _Phase.choose;
  int _selected = 0;
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _payoutEmail = TextEditingController();
  String? _amountError;
  String? _error;
  String? _code;
  String? _reference;
  bool _revealed = false;
  bool _copied = false;
  bool _redeemed = false;

  double get _cost => AppConfig.redeemCost.toDouble();
  bool get _affordable => widget.points >= _cost;

  @override
  void dispose() {
    _amount.dispose();
    _payoutEmail.dispose();
    super.dispose();
  }

  void _confirm() {
    final p = widget.product;
    if (p.packages.isNotEmpty) {
      final pkg = p.packages[_selected];
      _redeem(pkg.id, pkg.value);
      return;
    }
    final v = double.tryParse(_amount.text.trim().replaceAll(',', '.'));
    final mn = p.min ?? 0;
    final mx = p.max ?? 0;
    final st = p.step ?? 1;
    String? err;
    if (v == null) {
      err = 'Enter an amount.';
    } else if (v < mn || v > mx) {
      err = 'Choose between ${fmtAmount(mn)} and ${fmtAmount(mx)}.';
    } else {
      final steps = (v - mn) / st;
      if ((steps - steps.roundToDouble()).abs() > 1e-6) {
        err = 'Amounts go up in steps of ${fmtAmount(st)}.';
      }
    }
    if (err != null) {
      setState(() => _amountError = err);
      return;
    }
    setState(() => _amountError = null);
    _redeem(null, v!);
  }

  Future<void> _redeem(String? packageId, double value) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _phase = _Phase.working;
      _error = null;
    });
    try {
      final r = await Api.redeem(widget.product.id, widget.product.name, widget.product.currency ?? 'USD', _payoutEmail.text.trim(), packageId, value);
      _redeemed = true;
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      final code = r['code']?.toString();
      if (code != null && code.isNotEmpty) {
        setState(() {
          _code = code;
          _phase = _Phase.receipt;
        });
      } else {
        setState(() {
          _reference = r['redemption_id']?.toString();
          _phase = _Phase.pending;
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.choose;
        _error = e.message;
      });
    }
  }

  Future<void> _copy() async {
    await SecretClipboard.copy(_code ?? '');
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return PopScope(
      canPop: _phase != _Phase.working,
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 28, 24, 20 + bottom),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: KeyedSubtree(key: ValueKey<_Phase>(_phase), child: _body(context)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final c = context.c;
    final p = widget.product;
    switch (_phase) {
      case _Phase.choose:
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  BrandTile(product: p, size: 56),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name, style: T.heading(c), maxLines: 2, overflow: TextOverflow.ellipsis),
                        Text(p.currency ?? 'Gift card', style: T.small(c)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (p.packages.isNotEmpty) ...[
                Text(p.packages.length == 1 ? 'This card' : 'Choose an amount', style: T.small(c)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < p.packages.length; i++)
                      _AmountChip(
                        label: fmtAmount(p.packages[i].value),
                        selected: i == _selected,
                        onTap: () => setState(() => _selected = i),
                      ),
                  ],
                ),
              ] else
                FieldLine(
                  label: 'Amount${p.currency == null ? '' : ' in ${p.currency}'}',
                  hint: 'From ${fmtAmount(p.min ?? 0)} to ${fmtAmount(p.max ?? 0)}',
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  error: _amountError,
                ),
              const SizedBox(height: 20),
              Text('Where should we send your reward?', style: T.small(c)),
              const SizedBox(height: 8),
              TextField(
                controller: _payoutEmail,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'Your payout email address',
                  filled: true,
                  fillColor: c.ground,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 20),
              Divider(height: 1, color: c.rule),
              _SummaryRow('Cost', '${fmtNum(_cost)} points'),
              _SummaryRow(
                'Balance after',
                _affordable ? '${fmtNum(widget.points - _cost)} points' : 'Not enough points',
              ),
              Divider(height: 1, color: c.rule),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Message(_error!),
                ),
              const SizedBox(height: 20),
              PrimaryButton(
                label: _affordable
                    ? 'Redeem ${fmtNum(_cost)} points'
                    : 'You need ${fmtNum(_cost - widget.points)} more points',
                onPressed: _affordable ? _confirm : null,
              ),
            ],
          ),
        );
      case _Phase.working:
        return SizedBox(
          height: 220,
          width: double.infinity,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 18),
                Text(
                  'Submitting your manual payout request…',
                  textAlign: TextAlign.center,
                  style: T.small(c).copyWith(fontSize: 15),
                ),
              ],
            ),
          ),
        );
      case _Phase.receipt:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your code is ready', style: T.title(c)),
            const SizedBox(height: 8),
            Text(
              _revealed ? 'Keep it private. It works like cash.' : 'Scratch the panel to reveal it.',
              style: T.small(c).copyWith(fontSize: 15),
            ),
            const SizedBox(height: 20),
            ScratchReveal(
              code: _code ?? '',
              revealed: _revealed,
              onRevealed: () {
                HapticFeedback.lightImpact();
                setState(() => _revealed = true);
              },
            ),
            const SizedBox(height: 8),
            if (!_revealed)
              Align(
                alignment: Alignment.centerLeft,
                child: LinkButton(
                  label: 'Reveal without scratching',
                  onPressed: () => setState(() => _revealed = true),
                ),
              ),
            const SizedBox(height: 12),
            PrimaryButton(label: _copied ? 'Copied' : 'Copy code', onPressed: _revealed ? _copy : null),
            const SizedBox(height: 10),
            SecondaryButton(label: 'Done', onPressed: () => Navigator.of(context).pop(_redeemed)),
          ],
        );
      case _Phase.pending:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Request submitted', style: T.title(c)),
            const SizedBox(height: 10),
            Text(
              'Your points are spent and the order is paid, but the code hasn\'t arrived yet. '
              "You'll find it under Your gift cards in Account once it arrives. Reference #${_reference ?? 'unknown'}.",
              style: T.body(c).copyWith(color: c.muted),
            ),
            const SizedBox(height: 24),
            PrimaryButton(label: 'Done', onPressed: () => Navigator.of(context).pop(_redeemed)),
          ],
        );
    }
  }
}

class _AmountChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _AmountChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? c.cobalt : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? c.cobalt : c.rule, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Text(label, style: T.strong(c).copyWith(color: selected ? c.onCobalt : c.ink)),
          ),
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  const _SummaryRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: T.small(c).copyWith(fontSize: 15)),
          Text(value, style: T.strong(c)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scratch panel
// ---------------------------------------------------------------------------

class ScratchReveal extends StatefulWidget {
  final String code;
  final bool revealed;
  final VoidCallback onRevealed;

  const ScratchReveal({super.key, required this.code, required this.revealed, required this.onRevealed});

  @override
  State<ScratchReveal> createState() => _ScratchRevealState();
}

class _ScratchRevealState extends State<ScratchReveal> {
  static const int _cols = 12;
  static const int _rows = 4;
  static const double _height = 96;

  final List<Offset> _points = <Offset>[];
  final Set<int> _cells = <int>{};

  void _scratch(Offset p, double width) {
    if (widget.revealed) return;
    final cx = (p.dx / width * _cols).floor().clamp(0, _cols - 1).toInt();
    final cy = (p.dy / _height * _rows).floor().clamp(0, _rows - 1).toInt();
    setState(() {
      _points.add(p);
      _cells.add(cy * _cols + cx);
    });
    if (_cells.length >= (_cols * _rows * 0.6).round()) widget.onRevealed();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return SizedBox(
          width: width,
          height: _height,
          child: Stack(
            children: [
              Container(
                width: width,
                height: _height,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: c.ground,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.rule),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    widget.code,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: c.ink,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: widget.revealed,
                  child: AnimatedOpacity(
                    opacity: widget.revealed ? 0 : 1,
                    duration: const Duration(milliseconds: 300),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (d) => _scratch(d.localPosition, width),
                      onPanUpdate: (d) => _scratch(d.localPosition, width),
                      child: CustomPaint(
                        painter: _ScratchPainter(
                          List<Offset>.of(_points),
                          c.rule,
                          c.ink.withAlpha(22),
                          c.muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ScratchPainter extends CustomPainter {
  final List<Offset> points;
  final Color base;
  final Color sheen;
  final Color label;

  _ScratchPainter(this.points, this.base, this.sheen, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(14));
    canvas.saveLayer(rect, Paint());
    canvas.clipRRect(shape);
    canvas.drawRRect(shape, Paint()..color = base);

    final stripe = Paint()
      ..color = sheen
      ..strokeWidth = 10;
    for (double x = -size.height; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), stripe);
    }

    final text = TextPainter(
      text: TextSpan(
        text: 'Scratch here',
        style: TextStyle(fontFamily: kFont, fontSize: 16, fontWeight: FontWeight.w600, color: label),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    text.paint(canvas, Offset((size.width - text.width) / 2, (size.height - text.height) / 2));

    final clear = Paint()..blendMode = BlendMode.clear;
    for (final p in points) {
      canvas.drawCircle(p, 22, clear);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScratchPainter old) => old.points.length != points.length || old.base != base;
}
