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
