import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/units.dart';
import '../theme/app_theme.dart';

/// Half-moon analog speedometer for the Record sheet: a 180° track that fills
/// with amber up to the current speed, a needle at the tip, numbered ticks, and
/// the digital readout kept in the middle (the numeral is still the fastest way
/// to read an exact value — the arc is what makes it glanceable).
///
/// **Adaptive scale.** The top of the dial follows the ride's own peak, rounded
/// up to the next [_scaleStep] with a [_minScale] floor, so a slow city ride uses
/// the whole sweep instead of hugging the left stop. The trade-off is deliberate:
/// the same speed points at different angles on different rides. The scale only
/// ever grows within a ride (it tracks the max, which is monotonic), and both the
/// needle and the scale change are animated so the sweep glides rather than
/// snaps.
///
/// All speeds in and out are **display-unit** values (already converted by
/// [SpeedUnit]) — the gauge does no unit maths of its own.
class AnalogSpeedGauge extends StatelessWidget {
  const AnalogSpeedGauge({
    super.key,
    required this.speed,
    required this.maxSpeed,
    required this.unitLabel,
    this.dimmed = false,
  });

  /// Current speed, in display units.
  final double speed;

  /// The ride's peak speed so far, in display units — drives the dial's range
  /// and is marked on the track.
  final double maxSpeed;

  /// `km/h` or `mph`, shown under the numeral.
  final String unitLabel;

  /// Greys the sweep out (paused / not recording) while keeping the dial legible.
  final bool dimmed;

  /// Smallest top-of-scale, so a standstill or a walking-pace ride still reads
  /// against a sane dial rather than a hair-trigger one.
  static const double _minScale = 60;

  /// The dial's top rounds up to a multiple of this.
  static const double _scaleStep = 20;

  /// Widest the dial gets, whatever the sheet offers.
  static const double _maxWidth = 280;

  /// Top of the dial for a given ride peak.
  static double scaleFor(double maxSpeed) {
    final needed = math.max(maxSpeed, _minScale);
    return (needed / _scaleStep).ceil() * _scaleStep;
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final scale = scaleFor(maxSpeed);
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
                  peak: cx.danger,
                  tickLabel: cx.textDim,
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

    // Ticks + labels just inside the track.
    for (var i = 0; i < _majorTicks; i++) {
      final t = i / (_majorTicks - 1);
      final angle = math.pi + math.pi * t;
      final outer = radius - _stroke / 2 - 2;
      final inner = outer - 8;
      final tickPaint = Paint()
        ..color = tickLabel
        ..strokeWidth = 2
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
            color: tickLabel,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelR = inner - 14;
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

    // Needle: hub at the centre, tip just short of the track.
    final needleAngle = math.pi + math.pi * fraction;
    final needlePaint = Paint()
      ..color = needle
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    final tip = center +
        Offset(math.cos(needleAngle) * (radius - _stroke),
            math.sin(needleAngle) * (radius - _stroke));
    // Counterweight: a stub the other side of the hub, like a real needle.
    final tail = center -
        Offset(math.cos(needleAngle) * 12, math.sin(needleAngle) * 12);
    canvas.drawLine(tail, tip, needlePaint);
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
      old.track != track;
}
