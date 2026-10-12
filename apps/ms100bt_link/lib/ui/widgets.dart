import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colors shared with the Mac app (Controls.swift).
abstract final class AppColors {
  static const background = Color(0xFF121214);
  static const panel = Color(0xFF242426);
  static const panelRaised = Color(0xFF2E2E30);
  static const accent = Color(0xFFFF8C26);
  static const dim = Color(0x80FFFFFF);
  static const text = Color(0xEBFFFFFF);
  static const stroke = Color(0x14FFFFFF);

  /// Window background: the Mac app's top-to-bottom gradient.
  static const backgroundGradient = LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF131313), Color(0xFF1F1F1F)]);

  static Color category(String? c) => switch (c) {
        'Dynamics' => const Color(0xFF2EB3B3),
        'Filter' => const Color(0xFF59BF66),
        'Drive' || 'Bass Drive' => const Color(0xFFF2801F),
        'Amp' || 'Bass Amp' || 'Bass Preamp' => const Color(0xFFD93833),
        'Modulation' => const Color(0xFF945CE6),
        'SFX' => const Color(0xFFEB4D99),
        'Delay' => const Color(0xFF3380F2),
        'Reverb' => const Color(0xFF4D59D9),
        _ => const Color(0xFF595959),
      };
}

class Led extends StatelessWidget {
  const Led({super.key, required this.on, this.color = const Color(0xFFFF3326), this.size = 10});
  final bool on;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? color : const Color(0xFF333333),
          boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.9), blurRadius: size * 0.8)] : null,
        ),
      );
}

/// Stompbox enclosure: category-coloured gradient, bevel, screws.
class PedalBody extends StatelessWidget {
  const PedalBody({super.key, required this.color, required this.child, this.radius = 16, this.empty = false});
  final Color color;
  final Widget child;
  final double radius;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    if (empty) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppColors.dim.withValues(alpha: 0.5), width: 1.5),
          color: Colors.white.withValues(alpha: 0.03),
        ),
        child: child,
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: 0.95), color.withValues(alpha: 0.55)]),
        border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 1.2),
        boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 12, offset: Offset(0, 8))],
      ),
      // The content sizes the enclosure (and fills it when the size is fixed); panel and screws are drawn behind.
      child: Stack(fit: StackFit.passthrough, children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: DecoratedBox(
                decoration: BoxDecoration(color: const Color(0x38000000), borderRadius: BorderRadius.circular(math.max(radius - 6, 2)))),
          ),
        ),
        for (final a in const [Alignment.topLeft, Alignment.topRight, Alignment.bottomLeft, Alignment.bottomRight])
          Positioned.fill(
            child: Align(alignment: a, child: Padding(padding: const EdgeInsets.all(7.5),
                child: Container(width: 5, height: 5, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFBFBFBF))))),
          ),
        child,
      ]),
    );
  }
}

class Footswitch extends StatelessWidget {
  const Footswitch({super.key, required this.onTap, this.size = 52});
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(center: Alignment(-0.25, -0.35), colors: [Color(0xFFDDDDDD), Color(0xFF737373)]),
            boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 5, offset: Offset(0, 4))],
          ),
          child: Center(child: Container(width: size * 0.56, height: size * 0.56,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFB3B3B3)))),
        ),
      );
}

/// Rotary knob: drag up/down to change, double-tap for the default value.
class Knob extends StatefulWidget {
  const Knob({super.key, required this.label, required this.display, required this.raw, required this.count,
      required this.defaultRaw, required this.onChanged, this.enabled = true, this.size = 62});
  final String label, display;
  final int raw, count, defaultRaw;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final double size;

  @override
  State<Knob> createState() => _KnobState();
}

class _KnobState extends State<Knob> {
  double? _startY;
  int? _startRaw;

  @override
  Widget build(BuildContext context) {
    final frac = widget.count > 1 ? widget.raw / (widget.count - 1) : 0.0;
    return SizedBox(
      width: widget.size + 26,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        GestureDetector(
          onVerticalDragStart: (d) { _startY = d.globalPosition.dy; _startRaw = widget.raw; },
          onVerticalDragUpdate: (d) {
            if (!widget.enabled || widget.count < 2 || _startY == null) return;
            final span = (widget.count - 1).toDouble();
            final v = (_startRaw! + (_startY! - d.globalPosition.dy) / 180 * span).round().clamp(0, widget.count - 1);
            if (v != widget.raw) widget.onChanged(v);
          },
          onDoubleTap: widget.enabled ? () => widget.onChanged(widget.defaultRaw) : null,
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.55,
            child: CustomPaint(size: Size.square(widget.size), painter: _KnobPainter(frac)),
          ),
        ),
        const SizedBox(height: 6),
        Text(widget.display, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: Colors.white)),
        Text(widget.label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 9.5, letterSpacing: 0.8, color: AppColors.dim)),
      ]),
    );
  }
}

class _KnobPainter extends CustomPainter {
  _KnobPainter(this.frac);
  final double frac;
  static const sweep = 270 * math.pi / 180, start = 135 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 3;
    final track = Paint()..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round..color = Colors.white24;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false, track);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep * frac, false, track..color = Colors.white);
    final body = r * 0.72;
    canvas.drawCircle(c, body, Paint()..shader = RadialGradient(center: const Alignment(-0.3, -0.4),
        colors: const [Color(0xFF525252), Color(0xFF1A1A1A)]).createShader(Rect.fromCircle(center: c, radius: body)));
    final a = start + sweep * frac;
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * body * 0.25, c + Offset(math.cos(a), math.sin(a)) * body * 0.85,
        Paint()..color = Colors.white..strokeWidth = 3..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.frac != frac;
}


/// Capsule button from the Mac top bar (PillButtonStyle): accent when active, raised grey otherwise.
class Pill extends StatelessWidget {
  const Pill({super.key, this.icon, this.label, this.active = false, this.onTap, this.tooltip, this.trailing});
  final IconData? icon;
  final String? label;
  final bool active;
  final VoidCallback? onTap;
  final String? tooltip;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final fg = active ? Colors.black : AppColors.text;
    final pill = Material(
      color: active ? AppColors.accent : AppColors.panelRaised,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 7, trailing == null ? 12 : 6, 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) Icon(icon, size: 15, color: fg),
            if (icon != null && label != null) const SizedBox(width: 6),
            if (label != null) Text(label!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ]),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// Two-position switch for on/off style knobs (MiniSwitch in Controls.swift).
class MiniSwitch extends StatelessWidget {
  const MiniSwitch({super.key, required this.label, required this.options, required this.raw, required this.onChanged, this.enabled = true});
  final String label;
  final List<String> options;
  final int raw;
  final ValueChanged<int> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 88,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 64,
            child: Center(
              child: Opacity(
                opacity: enabled ? 1 : 0.55,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: const Color(0x59000000), borderRadius: BorderRadius.circular(7)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < options.length; i++)
                      GestureDetector(
                        onTap: enabled && i != raw ? () => onChanged(i) : null,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 34),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                          decoration: BoxDecoration(color: i == raw ? AppColors.accent : Colors.transparent, borderRadius: BorderRadius.circular(5)),
                          child: Text(options[i], textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: i == raw ? Colors.black : AppColors.dim)),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: AppColors.dim)),
        ]),
      );
}

/// Saturation/brightness filter used for bypassed pedals (SwiftUI .saturation/.brightness).
ColorFilter saturation(double s, {double brightness = 0}) {
  const r = 0.2126, g = 0.7152, b = 0.0722;
  final o = brightness * 255;
  return ColorFilter.matrix(<double>[
    r * (1 - s) + s, g * (1 - s), b * (1 - s), 0, o,
    r * (1 - s), g * (1 - s) + s, b * (1 - s), 0, o,
    r * (1 - s), g * (1 - s), b * (1 - s) + s, 0, o,
    0, 0, 0, 1, 0,
  ]);
}
