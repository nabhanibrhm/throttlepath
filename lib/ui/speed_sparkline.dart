/// The live speed trend that sits beside the numeral while recording.
library;

import 'package:flutter/material.dart';

import '../core/units.dart';
import '../providers/tracking_providers.dart' show SpeedSample;
import '../theme/app_theme.dart';
import 'chart_math.dart';

/// How far back the trend reaches, in the rider's own distance unit.
///
/// Five *units*, not a fixed 5 km converted to 3.1 mi. Every span in this app
/// works in display units already (`LiveSpeedChart.windowSpan`, the chart tick
/// intervals), and at 52dp tall the difference between 5 km and 5 mi of shape is
/// invisible — whereas a caption reading "LAST 3.1 MI" would not be.
const double kSpeedTrendWindow = 5.0;

/// The samples within [window] display-units of the latest one, as
/// (x: distance in display units, y: km/h), oldest first.
///
/// A render-time filter over the ride's full sample list rather than a trimmed
/// buffer kept alongside it. `LiveSpeedChart` already does exactly this over the
/// same list at a smaller window, so the cost is known; and the alternative means
/// adding state to `TrackingController`, whose blackout and jump-gate accounting
/// is the last thing in this app that should grow a second bookkeeping job for a
/// cosmetic readout.
List<({double x, double y})> windowedSpeedTrend(
  List<SpeedSample> samples,
  SpeedUnit unit, {
  double window = kSpeedTrendWindow,
}) {
  if (samples.isEmpty) return const [];
  final now = unit.distanceMeters(samples.last.distanceMeters);
  final from = now - window;
  return [
    for (final s in samples)
      if (unit.distanceMeters(s.distanceMeters) >= from)
        (x: unit.distanceMeters(s.distanceMeters), y: s.speedKmh),
  ];
}

/// The last few kilometres of speed as one bare line, with the window's peak.
///
/// Answers "what has the road been doing" — the question the big numeral cannot,
/// because it only ever shows the instant. No axis, no grid, no fill and no dots:
/// this is read on its shape, and every piece of chrome would cost shape.
///
/// Built as a `CustomPainter` in the mould of `route_sparkline.dart` rather than
/// an `fl_chart` line, because with fl_chart most of the code would be switching
/// off machinery — grid, titles, touch, legend — to arrive back at one stroke.
class SpeedSparkline extends StatelessWidget {
  const SpeedSparkline({
    super.key,
    required this.samples,
    required this.unit,
    this.window = kSpeedTrendWindow,
    this.height = 46,
    this.dimmed = false,
  });

  final List<SpeedSample> samples;
  final SpeedUnit unit;
  final double window;
  final double height;

  /// Drains the line's contrast while the ride clock is frozen, matching the
  /// treatment the numeral and the stats beside it already get.
  final bool dimmed;

  /// Whether there is enough of a window to draw a trend rather than a dot.
  ///
  /// Public and checked by the caller, not just used to self-hide: the sparkline
  /// lives in a `Row` behind an `Expanded`, which reserves its width whether or
  /// not anything is painted — so the *layout* decision (a centred numeral alone
  /// versus a two-up row) has to be made outside. Mirrors
  /// `RouteSparkline.canDraw`'s contract for the same reason.
  static bool canDraw(
    List<SpeedSample> samples,
    SpeedUnit unit, {
    double window = kSpeedTrendWindow,
  }) =>
      windowedSpeedTrend(samples, unit, window: window).length >= 2;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final trend = windowedSpeedTrend(samples, unit, window: window);
    if (trend.length < 2) return SizedBox(height: height);

    // Thinned with the same helper the analysis charts use — a two-hour ride is
    // a few thousand samples and this repaints on every GPS tick.
    final thinned = downsample(trend, kChartMaxPoints);

    var peak = 0.0;
    var minX = thinned.first.x;
    var maxX = thinned.first.x;
    for (final p in thinned) {
      if (p.y > peak) peak = p.y;
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
    }

    // Normalised against the window's own extent, and against zero speed rather
    // than the window's minimum: a flat stretch at 60 and a flat stretch at 5
    // must not both draw as a line through the middle. 10% headroom keeps the
    // peak off the top edge.
    final spanX = maxX - minX;
    final top = peak <= 0 ? 1.0 : peak * 1.1;
    final points = [
      for (final p in thinned)
        (
          x: spanX <= 0 ? 0.0 : (p.x - minX) / spanX,
          // Flipped: y runs down the canvas, speed runs up the page.
          y: 1.0 - (p.y / top).clamp(0.0, 1.0),
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // Expanded, not a Spacer between two fixed texts: this caption shares
            // its line with a 74sp numeral, so it can be handed as little as
            // ~150dp. With a Spacer the two labels simply overflowed — caught by
            // the widget test at a width the sheet really does produce.
            Expanded(
              child: Text(
                'LAST ${window.toStringAsFixed(0)} '
                '${unit.distanceLabel.toUpperCase()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // Tracking tightened from the section-label default: that 1.7 is
                // for a heading with a row to itself, and here it costs ~15dp of
                // a line that has none to spare.
                style: t.labelSmall!.copyWith(letterSpacing: 0.8),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'peak ${unit.speed(peak).toStringAsFixed(0)}',
              maxLines: 1,
              style: t.bodySmall!.copyWith(color: cx.textDim),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: height,
          child: CustomPaint(
            painter: _SpeedTrendPainter(
              points: points,
              color: dimmed ? cx.textDim : cx.accentInk,
            ),
          ),
        ),
      ],
    );
  }
}

/// One stroked path through pre-normalised points. No dots at either end, unlike
/// `RouteSparkline` — a route needs its direction of travel shown, a time series
/// already reads left to right.
class _SpeedTrendPainter extends CustomPainter {
  _SpeedTrendPainter({required this.points, required this.color});

  /// Points in the unit square, y already flipped for canvas coordinates.
  final List<({double x, double y})> points;
  final Color color;

  static const double _strokeWidth = 1.6;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by the cap radius so a peak touching the top of the window isn't
    // shaved in half — the normalisation puts it exactly on the edge.
    const inset = _strokeWidth;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;
    if (w <= 0 || h <= 0 || points.length < 2) return;

    Offset at(({double x, double y}) p) =>
        Offset(inset + p.x * w, inset + p.y * h);

    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        // A plain logical-pixel width on an untransformed canvas — there is no
        // scale for the stroke to be immune to, which is what the spec's
        // `non-scaling-stroke` was asking for in SVG terms.
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SpeedTrendPainter old) =>
      old.color != color || old.points != points;
}
