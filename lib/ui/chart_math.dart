import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';

/// Shared axis/plot helpers for the speed charts (full-ride overview + live
/// follow-cam), so both draw gridlines on the same "nice" round numbers and
/// thin long series the same way.

/// A "nice" round step (1/2/5 × 10ⁿ) that splits [range] into roughly [target]
/// intervals — so gridlines and labels land on readable numbers.
double niceInterval(double range, int target) {
  if (range <= 0) return 1;
  final raw = range / target;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final double nice = norm < 1.5
      ? 1
      : norm < 3
          ? 2
          : norm < 7
              ? 5
              : 10;
  return nice * mag;
}

/// Axis tick label: one decimal when the step is sub-unit, else whole numbers.
String fmtTick(double v, double interval) =>
    interval < 1 ? v.toStringAsFixed(1) : v.toStringAsFixed(0);

/// Target point count for a painted series.
///
/// A 1 Hz trace over an hour is 3600 samples; fl_chart lays out and paints every
/// one of them on every frame, which is what made the chart pager sticky to swipe
/// (F26). At 300 points a full-width chart still has ~1 sample per device pixel,
/// so the drawn shape is indistinguishable.
const int kChartMaxPoints = 300;

/// Uniformly thins [spots] to at most [max] points, always keeping the first
/// and last, so a long series stays cheap to redraw without changing its shape.
List<FlSpot> downsampleSpots(List<FlSpot> spots, int max) =>
    downsample(spots, max);

/// Uniformly thins [xs] to at most [max] entries, always keeping the first and
/// last. Type-agnostic so the scatter and line series thin identically.
List<T> downsample<T>(List<T> xs, int max) {
  if (xs.length <= max) return xs;
  final stride = xs.length / max;
  final out = <T>[];
  for (var i = 0; i < max; i++) {
    out.add(xs[(i * stride).floor()]);
  }
  out.add(xs.last);
  return out;
}

/// Cuts [spots] at each index in [breaks] and thins each piece, so a series that
/// spans a GPS blackout can be drawn as several lines instead of one.
///
/// A single `LineChartBarData` has no notion of a discontinuity: fl_chart joins
/// consecutive spots, and on a **time** axis a dead zone is a long horizontal
/// stretch the line slopes straight across — asserting a climb and a speed the
/// rider was never measured at. Only one bar per contiguous run avoids that.
///
/// [max] is the budget for the whole series, split between the pieces in
/// proportion to their length rather than handed to each: [kChartMaxPoints] exists
/// to cap the work fl_chart does per frame, and a per-piece cap would quietly
/// multiply that by the number of blackouts. Two points is the floor, since a
/// single-point run cannot be drawn as a line but also must not be dropped.
List<List<FlSpot>> splitAndDownsample(
  List<FlSpot> spots,
  List<int> breaks,
  int max,
) {
  if (spots.isEmpty) return const [];
  if (breaks.isEmpty) return [downsampleSpots(spots, max)];

  final pieces = <List<FlSpot>>[];
  var from = 0;
  for (final at in [...breaks, spots.length]) {
    if (at > from) pieces.add(spots.sublist(from, at));
    from = at;
  }

  final total = spots.length;
  return [
    for (final piece in pieces)
      downsampleSpots(
        piece,
        math.max(2, (max * piece.length / total).round()),
      ),
  ];
}
