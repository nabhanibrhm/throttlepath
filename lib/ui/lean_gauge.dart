import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'lean_palette.dart';

/// Half-moon lean dial: a 180° track banded by severity, with a needle at the
/// value and the numeral kept in the dial's mouth.
///
/// Deliberately the same anatomy as [AnalogSpeedGauge] — a fixed scale, banded
/// track, needle, numeral underneath — because the rider has already learned to
/// read that shape on the Record sheet. One idiom, two quantities.
///
/// **Fixed scale, for the same reason the speedo's is fixed.** The dial always
/// spans 0 → [kLeanScaleMaxDegrees]; it does not follow the ride's own peak. A dial
/// that rescales points the same lean at a different angle every ride, which
/// destroys the one thing an analog readout is for.
///
/// Shared by the analysis tab (where [value] is the ride's corroborated peak) and
/// the live Record backdrop (where it is the current estimate), so the two can
/// never disagree about how a lean angle looks.
class LeanGauge extends StatelessWidget {
  const LeanGauge({
    super.key,
    required this.value,
    required this.caption,
    this.live = false,
    this.dimmed = false,
    this.maxWidth = 180,
  });

  /// Lean to point at, in degrees. Sign is ignored — the dial reads magnitude, and
  /// which way the bike leaned is the chart's job.
  final double value;

  /// Small label under the numeral, e.g. `PEAK LEAN THIS RIDE`.
  final String caption;

  /// Softens the animation for a live feed, where the value changes every fix.
  final bool live;

  /// Greys the sweep out (not recording) while keeping the dial legible.
  final bool dimmed;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final magnitude = value.abs();

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, maxWidth);
        final arcHeight = width / 2;
        return SizedBox(
          // Width is fixed (the arc has an aspect ratio) but height deliberately
          // is NOT: the text under the dial grows with the rider's text scale, and
          // a hard-coded height would throw a RenderFlex overflow rather than let
          // it. Phase 5's week strip learned the same lesson.
          width: width,
          child: TweenAnimationBuilder<double>(
            duration: Duration(milliseconds: live ? 320 : 520),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: magnitude),
            builder: (context, shown, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width,
                  height: arcHeight,
                  child: CustomPaint(
                    painter: _LeanDialPainter(
                      degrees: shown,
                      bands: leanBands(cx),
                      trackColor: cx.border,
                      needleColor: dimmed ? cx.textTertiary : cx.textBright,
                      dimmed: dimmed,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${shown.round()}°',
                  style: TextStyle(
                    color: dimmed ? cx.textDim : cx.textBright,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    fontFeatures: kTabularFigures,
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  caption,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cx.textTertiary,
                    fontSize: kMinFontSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Paints the banded half-track, the tick at each band edge, and the needle.
class _LeanDialPainter extends CustomPainter {
  _LeanDialPainter({
    required this.degrees,
    required this.bands,
    required this.trackColor,
    required this.needleColor,
    required this.dimmed,
  });

  final double degrees;
  final List<({int from, int to, Color color})> bands;
  final Color trackColor;
  final Color needleColor;
  final bool dimmed;

  static const double _stroke = 13;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height);
    final radius = size.width / 2 - _stroke / 2;
    final rect = Rect.fromCircle(center: centre, radius: radius);

    // Unfilled track first, so a short needle still reads against a full dial.
    canvas.drawArc(
      rect,
      math.pi,
      math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.butt
        ..color = trackColor.withValues(alpha: 0.5),
    );

    // Severity bands. A 2px surface-coloured gap between segments keeps the edges
    // legible without drawing a divider line for each one.
    const gapRadians = 0.012;
    for (final b in bands) {
      final from = b.from / kLeanScaleMaxDegrees;
      final to = b.to / kLeanScaleMaxDegrees;
      final start = math.pi + from * math.pi + gapRadians;
      final sweep = (to - from) * math.pi - gapRadians * 2;
      if (sweep <= 0) continue;
      // Bands past the needle stay as a faint hint of the scale ahead; bands the
      // rider actually reached are painted at full strength.
      final reached = degrees >= b.from;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = _stroke
          ..strokeCap = StrokeCap.butt
          ..color = b.color.withValues(
            alpha: dimmed ? 0.18 : (reached ? 1.0 : 0.22),
          ),
      );
    }

    // Needle: a tapered wedge, not a uniform round-capped bar. The Record screen
    // learned this the hard way — a uniform bar with a filled hub reads as a
    // slider someone could drag, which is why the speed dial was redrawn.
    final t = (degrees / kLeanScaleMaxDegrees).clamp(0.0, 1.0);
    final angle = math.pi + t * math.pi;
    final tip = Offset(
      centre.dx + math.cos(angle) * (radius - _stroke / 2 - 4),
      centre.dy + math.sin(angle) * (radius - _stroke / 2 - 4),
    );
    final baseHalf = 4.0;
    final perp = angle + math.pi / 2;
    final b1 = Offset(
      centre.dx + math.cos(perp) * baseHalf,
      centre.dy + math.sin(perp) * baseHalf,
    );
    final b2 = Offset(
      centre.dx - math.cos(perp) * baseHalf,
      centre.dy - math.sin(perp) * baseHalf,
    );
    canvas.drawPath(
      Path()
        ..moveTo(b1.dx, b1.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(b2.dx, b2.dy)
        ..close(),
      Paint()..color = needleColor,
    );
    canvas.drawCircle(centre, 4.5, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _LeanDialPainter old) =>
      old.degrees != degrees ||
      old.dimmed != dimmed ||
      old.needleColor != needleColor;
}
