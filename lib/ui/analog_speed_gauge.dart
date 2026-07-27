import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/units.dart';
import '../theme/app_theme.dart';

/// Half-moon analog speedometer for the Record sheet: a 180° track that fills
/// with amber up to the current speed, a needle at the tip, numbered ticks, and
/// the digital readout kept in the middle (the numeral is still the fastest way
/// to read an exact value — the arc is what makes it glanceable).
///
/// **Fixed scale.** The dial spans 0 to [topFor] the rider's unit — 0–120 km/h
/// or 0–80 mph — with a labelled tick at the midpoint. It deliberately does *not*
/// follow the ride's own peak: a dial that rescales mid-ride points the same
/// speed at a different angle every time, which destroys the one thing an analog
/// readout is for (recognising a speed by needle position without reading it).
/// A rider learns "straight up is half" once and keeps it.
///
/// Above the top of the scale the needle pins, but the numeral in the mouth
/// keeps showing the true speed — the dial is the glanceable layer, the numeral
/// is the authoritative one.
///
/// All speeds in and out are **display-unit** values (already converted by
/// [SpeedUnit]) — the gauge does no unit maths of its own.
class AnalogSpeedGauge extends StatelessWidget {
  const AnalogSpeedGauge({
    super.key,
    required this.speed,
    required this.maxSpeed,
    required this.topOfScale,
    required this.unitLabel,
    this.dimmed = false,
  });

  /// Current speed, in display units.
  final double speed;

  /// The ride's peak speed so far, in display units — marked on the track.
  final double maxSpeed;

  /// Top of the dial, in display units. Use [topFor].
  final double topOfScale;

  /// `km/h` or `mph`, shown under the numeral.
  final String unitLabel;

  /// Greys the sweep out (paused / not recording) while keeping the dial legible.
  final bool dimmed;

  /// Widest the dial gets, whatever the sheet offers.
  static const double _maxWidth = 280;

  /// The fixed top of the dial for [unit]. 120 km/h covers every ride in the
  /// database with headroom; 80 mph (≈129 km/h) is the nearest round imperial
  /// equivalent, and keeps the tick labels whole (0/20/40/60/80).
  static double topFor(SpeedUnit unit) => unit == SpeedUnit.mph ? 80 : 120;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final scale = topOfScale;
    final clamped = speed.clamp(0.0, scale);

    return LayoutBuilder(
      builder: (context, constraints) {
        // The arc is a half-disc: half as tall as it is wide, plus room under it
        // for the numeral in the dial's mouth. Capped so the sheet stays short
        // enough on a small screen — the gauge is a readout, not the whole view.
        final width = math.min(constraints.maxWidth, _maxWidth);
        final arcHeight = width / 2;
        return SizedBox(
          width: width,
          height: arcHeight + 34,
          child: TweenAnimationBuilder<double>(
            // Glide to the new needle position (and absorb scale jumps) instead
            // of snapping on every GPS fix.
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: scale == 0 ? 0 : clamped / scale),
            builder: (context, fraction, _) {
              return CustomPaint(
                painter: _GaugePainter(
                  fraction: fraction,
                  scale: scale,
                  maxFraction: scale == 0
                      ? 0
                      : (maxSpeed.clamp(0.0, scale)) / scale,
                  track: cx.border,
                  sweep: dimmed ? cx.textDim : cx.accentInk,
                  needle: dimmed ? cx.textDim : cx.textBright,
                  // Neutral, not red: red is reserved for irreversible actions.
                  peak: cx.peak,
                  tickLabel: cx.textTertiary,
                  anchorTick: cx.textDim,
                ),
                child: Padding(
                  // Numeral sits inside the arc's mouth.
                  padding: EdgeInsets.only(top: arcHeight * 0.42),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        speed.toStringAsFixed(0),
                        style: TextStyle(
                          color: cx.textBright,
                          fontSize: 52,
                          height: 1,
                          fontWeight: FontWeight.w800,
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        unitLabel,
                        style: TextStyle(color: cx.textDim, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Paints the track, the filled sweep, the ticks with their labels, the ride's
/// peak marker and the needle. Angles run from π (left stop) to 2π (right stop).
class _GaugePainter extends CustomPainter {
  _GaugePainter({
    required this.fraction,
    required this.scale,
    required this.maxFraction,
    required this.track,
    required this.sweep,
    required this.needle,
    required this.peak,
    required this.tickLabel,
    required this.anchorTick,
  });

  /// Current speed as 0..1 of the dial.
  final double fraction;

  /// Top-of-scale, in display units — only used to label the ticks.
  final double scale;

  /// The ride's peak as 0..1 of the dial.
  final double maxFraction;

  final Color track;
  final Color sweep;
  final Color needle;
  final Color peak;
  final Color tickLabel;

  /// The midpoint tick + label, drawn brighter than the rest.
  final Color anchorTick;

  static const double _stroke = 14;
  static const int _majorTicks = 5; // 0, ¼, ½, ¾, max

  @override
  void paint(Canvas canvas, Size size) {
    // Centre of the half-disc: bottom-middle of the arc box.
    final radius = size.width / 2 - _stroke / 2 - 12;
    final center = Offset(size.width / 2, size.width / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, trackPaint);

    if (fraction > 0) {
      final sweepPaint = Paint()
        ..color = sweep
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, math.pi, math.pi * fraction, false, sweepPaint);
    }

    // Ticks + labels just inside the track. The midpoint (straight up) is drawn
    // longer and brighter: on a fixed dial it is the landmark the rider learns,
    // and it turns "roughly two thirds" into "a bit past half" at a glance.
    for (var i = 0; i < _majorTicks; i++) {
      final t = i / (_majorTicks - 1);
      final midpoint = i == _majorTicks ~/ 2;
      final angle = math.pi + math.pi * t;
      final outer = radius - _stroke / 2 - 2;
      final inner = outer - (midpoint ? 13 : 8);
      final tickPaint = Paint()
        ..color = midpoint ? anchorTick : tickLabel
        ..strokeWidth = midpoint ? 3 : 2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        tickPaint,
      );

      final label = (scale * t).toStringAsFixed(0);
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: midpoint ? anchorTick : tickLabel,
            fontSize: 12,
            fontWeight: midpoint ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // Measured off the standard tick length, not [inner] — otherwise the
      // longer midpoint tick would drag its own label out of line with the rest.
      final labelR = outer - 8 - 14;
      final lp = center +
          Offset(math.cos(angle) * labelR, math.sin(angle) * labelR) -
          Offset(tp.width / 2, tp.height / 2);
      tp.paint(canvas, lp);
    }

    // Peak-so-far marker: a short red tick sitting on the track.
    if (maxFraction > 0.01) {
      final angle = math.pi + math.pi * maxFraction;
      final peakPaint = Paint()
        ..color = peak
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center +
            Offset(math.cos(angle) * (radius - _stroke / 2 - 1),
                math.sin(angle) * (radius - _stroke / 2 - 1)),
        center +
            Offset(math.cos(angle) * (radius + _stroke / 2 + 1),
                math.sin(angle) * (radius + _stroke / 2 + 1)),
        peakPaint,
      );
    }

    // Needle: a tapered wedge from the hub to a point, not a stroked line.
    //
    // This is the audit's "redundant horizontal slider under the dial" (F4) —
    // except there was never a slider. It was the needle parked at zero: a
    // uniform-width, round-capped bar lying flat across the mouth of the dial
    // with a filled dot at one end, which is precisely the anatomy of a track
    // and thumb. Shortening it doesn't help; the giveaway is the constant width.
    // A wedge that starts wide at the hub and narrows to a point can only be
    // read as a pointer, at any angle.
    final needleAngle = math.pi + math.pi * fraction;
    final needleLength = radius - _stroke - 20;
    final tip = center +
        Offset(math.cos(needleAngle) * needleLength,
            math.sin(needleAngle) * needleLength);
    final perpendicular = needleAngle + math.pi / 2;
    const baseHalfWidth = 5.0;
    final baseOffset = Offset(math.cos(perpendicular) * baseHalfWidth,
        math.sin(perpendicular) * baseHalfWidth);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(center.dx + baseOffset.dx, center.dy + baseOffset.dy)
        ..lineTo(center.dx - baseOffset.dx, center.dy - baseOffset.dy)
        ..close(),
      Paint()
        ..color = needle
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(center, 6, Paint()..color = needle);
    canvas.drawCircle(
      center,
      2.5,
      Paint()..color = sweep,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction ||
      old.scale != scale ||
      old.maxFraction != maxFraction ||
      old.sweep != sweep ||
      old.needle != needle ||
      old.track != track ||
      // A theme flip changes only the colours; without these the dial keeps
      // painting the old palette until the next fix moves the needle.
      old.peak != peak ||
      old.tickLabel != tickLabel ||
      old.anchorTick != anchorTick;
}
