import 'dart:ui' show FontVariation;

import 'package:flutter/material.dart';

/// Declared in pubspec.yaml; the CI workflow downloads the variable font file.
const String kFont = 'Bricolage';

class AppColors {
  final Color ground;
  final Color surface;
  final Color ink;
  final Color muted;
  final Color rule;
  final Color cobalt;
  final Color onCobalt;
  final Color punch;
  final Color danger;
  final Color ok;

  const AppColors({
    required this.ground,
    required this.surface,
    required this.ink,
    required this.muted,
    required this.rule,
    required this.cobalt,
    required this.onCobalt,
    required this.punch,
    required this.danger,
    required this.ok,
  });

  static const AppColors light = AppColors(
    ground: Color(0xFFEBEEF4),
    surface: Color(0xFFF8F9FC),
    ink: Color(0xFF111A33),
    muted: Color(0xFF5C6784),
    rule: Color(0xFFCDD4E3),
    cobalt: Color(0xFF2A3BF0),
    onCobalt: Color(0xFFFFFFFF),
    punch: Color(0xFFFFD43B),
    danger: Color(0xFFC62F3B),
    ok: Color(0xFF15805A),
  );

  static const AppColors dark = AppColors(
    ground: Color(0xFF0A0F1E),
    surface: Color(0xFF131A30),
    ink: Color(0xFFE9EDF8),
    muted: Color(0xFF8D99B8),
    rule: Color(0xFF263050),
    cobalt: Color(0xFF3647F5),
    onCobalt: Color(0xFFFFFFFF),
    punch: Color(0xFFFFD43B),
    danger: Color(0xFFFF8A92),
    ok: Color(0xFF5FD3A3),
  );
}

extension AppColorsX on BuildContext {
  AppColors get c => Theme.of(this).brightness == Brightness.dark ? AppColors.dark : AppColors.light;
}

FontWeight _fw(double w) {
  final i = ((w / 100).round() - 1).clamp(0, 8).toInt();
  return FontWeight.values[i];
}

TextStyle _t(
  Color color,
  double size, {
  double w = 400,
  double opsz = 14,
  double height = 1.3,
  double ls = 0,
  bool tabular = false,
}) {
  return TextStyle(
    fontFamily: kFont,
    fontSize: size,
    color: color,
    height: height,
    letterSpacing: ls,
    fontWeight: _fw(w),
    fontVariations: [
      FontVariation('wght', w),
      FontVariation('opsz', opsz.clamp(12.0, 96.0).toDouble()),
    ],
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  );
}

class T {
  static TextStyle hero(AppColors c) => _t(c.ink, 64, w: 600, opsz: 96, height: 0.95, ls: -2.4, tabular: true);
  static TextStyle title(AppColors c) => _t(c.ink, 30, w: 600, opsz: 48, height: 1.1, ls: -0.9);
  static TextStyle heading(AppColors c) => _t(c.ink, 20, w: 600, opsz: 24, height: 1.2, ls: -0.3);
  static TextStyle body(AppColors c) => _t(c.ink, 16, w: 400, height: 1.45);
  static TextStyle strong(AppColors c) => _t(c.ink, 16, w: 600, height: 1.45);
  static TextStyle small(AppColors c) => _t(c.muted, 14, w: 400, height: 1.4);
  static TextStyle button(AppColors c) => _t(c.ink, 16, w: 600, height: 1.2, ls: -0.1);
  static TextStyle number(AppColors c, double size) =>
      _t(c.ink, size, w: 600, opsz: size, height: 1.0, ls: -size * 0.03, tabular: true);
}

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? AppColors.dark : AppColors.light;
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    fontFamily: kFont,
    scaffoldBackgroundColor: c.ground,
    colorScheme: ColorScheme(
      brightness: b,
      primary: c.cobalt,
      onPrimary: c.onCobalt,
      secondary: c.punch,
      onSecondary: const Color(0xFF111A33),
      error: c.danger,
      onError: c.ground,
      surface: c.surface,
      onSurface: c.ink,
    ),
    dividerColor: c.rule,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.cobalt,
      selectionColor: c.cobalt.withAlpha(70),
      selectionHandleColor: c.cobalt,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: c.surface,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll<Color>(Colors.white),
      trackColor: WidgetStateProperty.resolveWith<Color>(
        (states) => states.contains(WidgetState.selected) ? c.cobalt : c.rule,
      ),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.cobalt),
  );
}

Route<T> fadeRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    pageBuilder: (_, __, ___) => page,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  const PrimaryButton({super.key, required this.label, required this.onPressed, this.busy = false});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final disabled = onPressed == null && !busy;
    final bg = disabled ? c.rule : c.cobalt;
    final fg = disabled ? c.muted : c.onCobalt;
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: (disabled || busy) ? null : onPressed,
          child: Center(
            child: busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
                  )
                : Text(label, style: T.button(c).copyWith(color: fg)),
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const SecondaryButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.rule, width: 1.5),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(child: Text(label, style: T.button(c))),
        ),
      ),
    );
  }
}

class LinkButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  const LinkButton({super.key, required this.label, required this.onPressed, this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Text(
          label,
          style: T.body(c).copyWith(
                color: color ?? c.cobalt,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }
}

class FieldLine extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? action;
  final Iterable<String>? autofillHints;
  final String? error;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final String? hint;

  const FieldLine({
    super.key,
    required this.label,
    required this.controller,
    this.obscure = false,
    this.keyboardType,
    this.action,
    this.autofillHints,
    this.error,
    this.suffix,
    this.onSubmitted,
    this.onChanged,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    UnderlineInputBorder line(Color color, double width) =>
        UnderlineInputBorder(borderSide: BorderSide(color: color, width: width));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: T.small(c)),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textInputAction: action,
          autofillHints: autofillHints,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          autocorrect: false,
          enableSuggestions: !obscure,
          style: T.body(c).copyWith(fontSize: 18),
          cursorColor: c.cobalt,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: T.body(c).copyWith(fontSize: 18, color: c.muted.withAlpha(150)),
            contentPadding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
            border: line(c.rule, 1.5),
            enabledBorder: line(c.rule, 1.5),
            focusedBorder: line(c.cobalt, 2),
            errorBorder: line(c.danger, 1.5),
            focusedErrorBorder: line(c.danger, 2),
            errorText: error,
            errorStyle: T.small(c).copyWith(color: c.danger),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(minHeight: 0, minWidth: 0),
          ),
        ),
      ],
    );
  }
}

class TopBar extends StatelessWidget {
  final String? title;
  final Widget? trailing;
  final bool back;

  const TopBar({super.key, this.title, this.trailing, this.back = false});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: EdgeInsets.fromLTRB(back ? 8 : 24, 8, 16, 0),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            if (back)
              IconButton(
                tooltip: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
              ),
            if (title != null) Expanded(child: Text(title!, style: T.heading(c))) else const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

enum MessageKind { error, info }

class Message extends StatelessWidget {
  final String text;
  final MessageKind kind;

  const Message(this.text, {super.key, this.kind = MessageKind.error});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: T.small(c).copyWith(
              color: kind == MessageKind.error ? c.danger : c.ok,
              fontWeight: FontWeight.w500,
            ),
      ),
    );
  }
}

class TextTabs extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  const TextTabs({super.key, required this.labels, required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 22),
            child: Semantics(
              button: true,
              selected: i == index,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        labels[i],
                        style: i == index ? T.heading(c) : T.heading(c).copyWith(color: c.muted),
                      ),
                      const SizedBox(height: 6),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        height: 3,
                        width: i == index ? 28 : 0,
                        decoration: BoxDecoration(
                          color: c.cobalt,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Status and data marks
// ---------------------------------------------------------------------------

class PulseDot extends StatefulWidget {
  final Color color;
  final bool active;
  final double size;

  const PulseDot({super.key, required this.color, required this.active, this.size = 9});

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.active) _ctl.repeat();
  }

  @override
  void didUpdateWidget(PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_ctl.isAnimating) _ctl.repeat();
    if (!widget.active && _ctl.isAnimating) _ctl.stop();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context) || !widget.active;
    final box = widget.size * 2.6;
    return SizedBox(
      width: box,
      height: box,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) => CustomPaint(
          painter: _DotPainter(widget.color, widget.size, still ? 0.0 : _ctl.value),
        ),
      ),
    );
  }
}

class _DotPainter extends CustomPainter {
  final Color color;
  final double size;
  final double t;

  _DotPainter(this.color, this.size, this.t);

  @override
  void paint(Canvas canvas, Size box) {
    final center = Offset(box.width / 2, box.height / 2);
    if (t > 0) {
      final ring = Paint()
        ..color = color.withAlpha(((1 - t) * 110).round())
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6;
      canvas.drawCircle(center, size / 2 + t * size * 0.8, ring);
    }
    canvas.drawCircle(center, size / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.t != t || old.color != color || old.size != size;
}

/// Recent report sizes, newest on the right.
class ThroughputBars extends StatelessWidget {
  final List<double> values;
  final int slots;

  const ThroughputBars({super.key, required this.values, this.slots = 24});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 56,
      width: double.infinity,
      child: CustomPaint(painter: _BarsPainter(values, slots, c.cobalt, c.rule)),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> values;
  final int slots;
  final Color active;
  final Color idle;

  _BarsPainter(this.values, this.slots, this.active, this.idle);

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 4.0;
    final w = (size.width - gap * (slots - 1)) / slots;
    final peak = values.fold<double>(0, (m, v) => v > m ? v : m);
    final start = slots - values.length;
    for (var i = 0; i < slots; i++) {
      final idx = i - start;
      final has = idx >= 0 && idx < values.length;
      final v = has ? values[idx] : 0.0;
      final lit = has && v > 0 && peak > 0;
      final h = lit ? (v / peak).clamp(0.0, 1.0) * (size.height - 8) + 8 : 4.0;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (w + gap), size.height - h, w, h),
          const Radius.circular(2),
        ),
        Paint()..color = lit ? active : idle,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values != values || old.active != active || old.idle != idle || old.slots != slots;
}
