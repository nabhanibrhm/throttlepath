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
                          fontSize: 54,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          fontFeatures: kTabularFigures,
                        ),
                      ),
                      Text(
                        unitLabel,
                        style: TextStyle(
                          color: cx.textTertiary,
                          fontSize: kMinFontSize,
                          letterSpacing: 0.4,
                        ),
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

  // The painter used to take the top-of-scale so it could print a number under
  // each tick. With the tick labels gone it draws ticks at fractions of the arc
  // and never needs to know what those fractions mean.

  /// The ride's peak as 0..1 of the dial.
  final double maxFraction;

  final Color track;
  final Color sweep;
  final Color needle;
  final Color peak;
  final Color tickLabel;

  /// The midpoint tick + label, drawn brighter than the rest.
  final Color anchorTick;

  /// Track/sweep thickness. Was 14 — a band wide enough to be the loudest thing
  /// on the sheet (spec 3.3). At 2 the sweep *underlines* the speed instead of
  /// competing with it, and the numeral inside becomes the reading.
  static const double _stroke = 2;

  /// Just the two stops and the midpoint (spec 3.1). Was five, each with a
  /// printed number — a third encoding of a value the numeral already states
  /// exactly. What the ticks are for is the landmark that turns the sweep into
  /// "a bit past half"; three do that, and the quarter ticks only added ink.
  static const int _majorTicks = 3; // 0, ½, max

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

    // Three ticks just outside the track, no printed numbers. The midpoint
    // (straight up) stays the landmark a rider learns; the two stops say where
    // the scale begins and ends. Drawn outward from the track now rather than
    // inward: at stroke 2 there is no band left to sit inside.
    for (var i = 0; i < _majorTicks; i++) {
      final t = i / (_majorTicks - 1);
      final midpoint = i == _majorTicks ~/ 2;
      final angle = math.pi + math.pi * t;
      final inner = radius + _stroke / 2 + 2;
      final outer = inner + (midpoint ? 8 : 5);
      final tickPaint = Paint()
        ..color = midpoint ? anchorTick : tickLabel
        ..strokeWidth = midpoint ? 2 : 1.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center + Offset(math.cos(angle) * inner, math.sin(angle) * inner),
        center + Offset(math.cos(angle) * outer, math.sin(angle) * outer),
        tickPaint,
      );
    }

    // Peak-so-far marker: a short neutral tick crossing the track.
    //
    // Kept, though the spec's tick list doesn't mention it — it is the only place
    // the ride's peak appears on this backdrop, and it costs one stroke. Its
    // length is no longer measured off the track's thickness: at stroke 2 that
    // would have made it a 4px dash nobody could see.
    if (maxFraction > 0.01) {
      final angle = math.pi + math.pi * maxFraction;
      final peakPaint = Paint()
        ..color = peak
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        center + Offset(math.cos(angle) * (radius - 5), math.sin(angle) * (radius - 5)),
        center + Offset(math.cos(angle) * (radius + 5), math.sin(angle) * (radius + 5)),
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
