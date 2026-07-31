import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'analog_speed_gauge.dart' show AnalogSpeedGauge;
import 'lean_palette.dart';

/// Straight up, in canvas angles (x right, y down, so this is a quarter turn
/// anticlockwise from +x). Every lean on this dial is measured from here.
const double _up = -math.pi / 2;

const double _toRad = math.pi / 180.0;

/// Centre-zero lean dial: a 180° arc whose needle *is* the bike's lean line.
///
/// **The needle maps 1:1 to the angle.** Upright points at 12 o'clock, 90° left at
/// 9 o'clock, 90° right at 3 o'clock — so a rider leaning 12° sees the needle 12°
/// off vertical. Nothing is scaled, which is the whole point: the gauge is read as
/// an attitude indicator (what the bike is doing right now) rather than as a
/// progress bar toward some maximum. It also means the dial can never exaggerate,
/// because there is no gain to exaggerate with.
///
/// A consequence worth stating plainly: real road riding lives in the middle of
/// this dial. Measured over this rider's history the 95th percentile is ~10° and
/// the largest corroborated corner ~19°, so the needle spends the whole ride within
/// a hand's width of vertical. That is honest, not broken — the digital read-out and
/// the max-hold marks carry the detail the needle deliberately does not amplify.
///
/// Severity bands stop at [kLeanScaleMaxDegrees]; past there a road bike is
/// scraping hard parts, so the outer thirds stay bare track rather than being
/// painted in a colour the ramp was never calibrated for.
///
/// Shared by the analysis tab (where [value] is the ride's corroborated peak) and
/// the live Record backdrop (where it is the current estimate), so the two can
/// never disagree about how a lean angle looks.
class LeanGauge extends StatelessWidget {
  const LeanGauge({
    super.key,
    required this.value,
    required this.caption,
    this.maxLeftDegrees,
    this.maxRightDegrees,
    this.live = false,
    this.dimmed = false,
    this.maxWidth = 180,
  });

  /// Lean to point at, in degrees: negative leans left, positive leans right.
  /// Null when there is no estimate — the needle rests upright and the read-out
  /// says so, rather than claiming a confident 0°.
  final double? value;

  /// Small label under the read-out, e.g. `PEAK LEAN THIS RIDE`.
  final String caption;

  /// Furthest lean reached each way, as magnitudes, drawn as max-hold marks on the
  /// track the way a speedometer keeps its peak needle. Null (or under a degree)
  /// draws nothing — an idle dial should not be littered with marks at zero.
  final double? maxLeftDegrees;
  final double? maxRightDegrees;

  /// Softens the animation for a live feed, where the value changes every fix.
  final bool live;

  /// Greys the sweep out (not recording) while keeping the dial legible.
  final bool dimmed;

  final double maxWidth;

  /// Room reserved above the arc for the `0` numeral.
  static const double _topPad = 16;

  /// Full deflection each way, in degrees — the value the arc's ends are labelled
  /// with. Fixed, like [AnalogSpeedGauge.topFor]: the same lean must sit at the
  /// same angle on every ride or the needle position is not learnable.
  static const double scaleDegrees = 90;

  /// Canvas angle, in radians, the needle points at for a lean of [degrees].
  ///
  /// The dial's whole contract, in one line: **1:1, measured from straight up**.
  /// Canvas angles run x-right / y-down, so upright is a quarter turn
  /// anticlockwise from +x, left lean goes anticlockwise from there and right lean
  /// clockwise. Beyond full deflection the needle pins rather than wrapping around
  /// the bottom of the dial.
  static double needleAngle(double degrees) =>
      _up + degrees.clamp(-scaleDegrees, scaleDegrees) * _toRad;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final lean = value;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth, maxWidth);
        return SizedBox(
          // Width is fixed (the arc has an aspect ratio) but height deliberately
          // is NOT: the text under the dial grows with the rider's text scale, and
          // a hard-coded height would throw a RenderFlex overflow rather than let
          // it. Phase 5's week strip learned the same lesson.
          width: width,
          child: TweenAnimationBuilder<double>(
            duration: Duration(milliseconds: live ? 320 : 520),
            curve: Curves.easeOutCubic,
            // Tweens the *signed* value, so reversing through a corner sweeps the
            // needle across upright instead of jumping the zero.
            tween: Tween(begin: 0, end: lean ?? 0),
            builder: (context, shown, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: width,
                  height: width / 2 + _topPad,
                  child: CustomPaint(
                    painter: _LeanDialPainter(
                      degrees: shown,
                      bands: leanBands(cx),
                      trackColor: cx.border,
                      needleColor: dimmed ? cx.textTertiary : cx.textBright,
                      labelColor: cx.textTertiary,
                      maxHoldColor: cx.accentInk,
                      casingColor: cx.canvas,
                      maxLeftDegrees: maxLeftDegrees,
                      maxRightDegrees: maxRightDegrees,
                      topPad: _topPad,
                      dimmed: dimmed,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                _Readout(shown: shown, hasValue: lean != null, dimmed: dimmed),
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

/// Below this the bike is upright for reading purposes, and naming a side would be
/// noise — a degree either way is well inside what the estimate can resolve.
const double _uprightDegrees = 1.0;

/// `35° LEFT` — magnitude and side, never a signed numeral. A minus sign is one
/// more thing to decode at a glance, and the rider already knows which way they
/// are leaning; what they want confirmed is how far.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.shown,
    required this.hasValue,
    required this.dimmed,
  });

  final double shown;
  final bool hasValue;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final magnitude = shown.abs();
    final String side;
    if (!hasValue) {
      side = '';
    } else if (magnitude < _uprightDegrees) {
      side = 'UPRIGHT';
    } else {
      side = shown < 0 ? 'LEFT' : 'RIGHT';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          hasValue ? '${magnitude.round()}°' : '—',
          style: TextStyle(
            color: dimmed ? cx.textDim : cx.textBright,
            fontSize: 26,
            fontWeight: FontWeight.w800,
            fontFeatures: kTabularFigures,
            height: 1.0,
          ),
        ),
        if (side.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            side,
            style: TextStyle(
              color: dimmed ? cx.textDim : cx.accentInk,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ],
    );
  }
}

/// Paints the mirrored banded arc, its scale marks, the max-hold marks and the
/// needle. Zero is straight up and every angle below is measured from there.
class _LeanDialPainter extends CustomPainter {
  _LeanDialPainter({
    required this.degrees,
    required this.bands,
    required this.trackColor,
    required this.needleColor,
    required this.labelColor,
    required this.maxHoldColor,
    required this.casingColor,
    required this.maxLeftDegrees,
    required this.maxRightDegrees,
    required this.topPad,
    required this.dimmed,
  });

  final double degrees;
  final List<({int from, int to, Color color})> bands;
  final Color trackColor;
  final Color needleColor;
  final Color labelColor;
  final Color maxHoldColor;

  /// Painted under a max-hold mark so it separates from whatever it crosses.
  final Color casingColor;
  final double? maxLeftDegrees;
  final double? maxRightDegrees;
  final double topPad;
  final bool dimmed;

  static const double _stroke = 13;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, size.height);
    final radius = size.width / 2 - _stroke / 2;
    final rect = Rect.fromCircle(center: centre, radius: radius);

    _paintTrack(canvas, rect);
    _paintBands(canvas, rect);
    _paintScaleMarks(canvas, centre, radius);
    _paintMaxHold(canvas, centre, radius);
    _paintNeedle(canvas, centre, radius);
    _paintNumerals(canvas, centre, radius, size);
  }

  /// Unfilled track first, so a needle near upright still reads against a full
  /// dial rather than floating in space.
  void _paintTrack(Canvas canvas, Rect rect) {
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
  }

  /// Severity bands, mirrored either side of upright. The gap the two innermost
  /// bands leave at 12 o'clock is the dial's zero datum — widened a little so it
  /// reads as a deliberate mark rather than a seam.
  void _paintBands(Canvas canvas, Rect rect) {
    const gap = 0.012;
    const centreGap = 0.03;
    for (final b in bands) {
      final span = (b.to - b.from) * _toRad;
      if (span <= gap * 2) continue;
      final inner = b.from == 0 ? centreGap : gap;
      final sweep = span - inner - gap;
      // Bands past the needle stay a faint hint of the scale ahead; bands the
      // rider actually reached are painted at full strength — but only on the side
      // they leaned. Lighting a band's mirror too makes the fill symmetrical
      // decoration, when the thing it is for is showing how far *this way* you went.
      final reached = degrees.abs() >= b.from;
      _paintBand(
        canvas,
        rect,
        _up + b.from * _toRad + inner,
        sweep,
        b.color,
        reached && degrees > 0,
      );
      _paintBand(
        canvas,
        rect,
        _up - b.to * _toRad + gap,
        sweep,
        b.color,
        reached && degrees < 0,
      );
    }
  }

  void _paintBand(
    Canvas canvas,
    Rect rect,
    double start,
    double sweep,
    Color color,
    bool reached,
  ) {
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.butt
        ..color = color.withValues(
          alpha: dimmed ? 0.18 : (reached ? 1.0 : 0.22),
        ),
    );
  }

  /// Short marks just outside the track at each band edge, mirrored, with a longer
  /// one where the bands stop — the point a road bike is scraping hard parts, and
  /// the only place on this dial worth calling out.
  void _paintScaleMarks(Canvas canvas, Offset centre, double radius) {
    final limit = kLeanScaleMaxDegrees;
    for (final b in bands) {
      for (final m in {b.from.toDouble(), b.to.toDouble()}) {
        if (m == 0) continue;
        final atLimit = m >= limit;
        for (final signed in [m, -m]) {
          _radialLine(
            canvas,
            centre,
            _up + signed * _toRad,
            radius + _stroke / 2 + 1,
            radius + _stroke / 2 + (atLimit ? 7 : 4),
            atLimit ? 2 : 1.2,
            labelColor.withValues(alpha: atLimit ? 0.9 : 0.5),
          );
        }
      }
    }
  }

  /// Max-hold: the furthest the needle went each way, kept on the track the way a
  /// speedometer keeps its peak needle. Drawn across the full stroke so it reads
  /// as a mark *on the scale*, not as a second needle from the hub.
  ///
  /// It deliberately overshoots the rim. The max is usually close to the current
  /// lean, which is exactly where the bands are lit at full strength — an amber
  /// mark confined to the track would vanish into them. The tail that protrudes
  /// onto bare canvas is what keeps it findable, and the dark casing under it
  /// separates it from a lit band even where the two do overlap.
  ///
  /// Kept at full strength even while [dimmed]. Dimmed does not only mean "not
  /// recording" — it is also a rider mid-ride who has dropped below the speed floor,
  /// i.e. sitting at a light, which is the one moment they can actually study this
  /// screen. The ride's peaks are history and do not stop being true because there
  /// is no current estimate; when there genuinely are none the magnitudes are zero
  /// and nothing is drawn anyway.
  void _paintMaxHold(Canvas canvas, Offset centre, double radius) {
    for (final (magnitude, sign) in [
      (maxLeftDegrees, -1.0),
      (maxRightDegrees, 1.0),
    ]) {
      if (magnitude == null || magnitude < _uprightDegrees) continue;
      final angle = LeanGauge.needleAngle(sign * magnitude);
      final from = radius - _stroke / 2 - 1;
      final to = radius + _stroke / 2 + 6;
      _radialLine(canvas, centre, angle, from, to, 5, casingColor);
      _radialLine(canvas, centre, angle, from, to, 2.5, maxHoldColor);
    }
  }

  /// Needle: a tapered wedge, not a uniform round-capped bar. The Record screen
  /// learned this the hard way — a uniform bar with a filled hub reads as a
  /// slider someone could drag, which is why the speed dial was redrawn.
  void _paintNeedle(Canvas canvas, Offset centre, double radius) {
    final angle = LeanGauge.needleAngle(degrees);
    final length = radius - _stroke / 2 - 4;
    final tip = centre + Offset(math.cos(angle), math.sin(angle)) * length;
    const baseHalf = 4.0;
    final perp = Offset(math.cos(angle + math.pi / 2), math.sin(angle + math.pi / 2)) *
        baseHalf;
    canvas.drawPath(
      Path()
        ..moveTo(centre.dx + perp.dx, centre.dy + perp.dy)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(centre.dx - perp.dx, centre.dy - perp.dy)
        ..close(),
      Paint()..color = needleColor,
    );
    canvas.drawCircle(centre, 4.5, Paint()..color = needleColor);
  }

  /// The three numerals the dial is read by: full deflection either side, and zero
  /// at the top. The side pair sits inside the dial's bottom corners (where a
  /// speedometer puts its end numerals, and where the needle never reaches);
  /// `0` sits in the headroom above the arc, clear of the needle at upright.
  void _paintNumerals(
    Canvas canvas,
    Offset centre,
    double radius,
    Size size,
  ) {
    final end = LeanGauge.scaleDegrees.round();
    final left = _label('$end° L');
    final right = _label('$end° R');
    final zero = _label('0°');

    final inset = _stroke / 2 + 4;
    final baseline = size.height - left.height - 3;
    left.paint(canvas, Offset(centre.dx - radius + inset, baseline));
    right.paint(
      canvas,
      Offset(centre.dx + radius - inset - right.width, baseline),
    );
    zero.paint(
      canvas,
      Offset(centre.dx - zero.width / 2, (topPad - zero.height) / 2),
    );
  }

  TextPainter _label(String text) => TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: labelColor,
            // Named explicitly: a painter gets no inherited text style, so without
            // this the dial's numerals fall back to the platform face while every
            // other glyph on screen is the bundled Inter.
            fontFamily: 'Inter',
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  /// A line along [angle] between two radii — every mark on this dial is one.
  void _radialLine(
    Canvas canvas,
    Offset centre,
    double angle,
    double fromRadius,
    double toRadius,
    double width,
    Color color,
  ) {
    final dir = Offset(math.cos(angle), math.sin(angle));
    canvas.drawLine(
      centre + dir * fromRadius,
      centre + dir * toRadius,
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _LeanDialPainter old) =>
      old.degrees != degrees ||
      old.dimmed != dimmed ||
      old.needleColor != needleColor ||
      old.maxLeftDegrees != maxLeftDegrees ||
      old.maxRightDegrees != maxRightDegrees;
}
