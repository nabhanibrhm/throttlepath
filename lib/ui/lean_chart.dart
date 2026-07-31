import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/lean.dart';
import '../core/units.dart';
import '../data/models/track_point.dart';
import '../theme/app_theme.dart';
import 'chart_frame.dart';
import 'chart_math.dart';
import 'lean_gauge.dart';
import 'lean_palette.dart';

/// How far the bike leaned through corners, estimated from how fast its heading
/// turned: `θ = atan(v · ω / g)`.
///
/// The headline is the **95th percentile**, not the maximum, and that is the whole
/// design. Measured across the entire recorded history, the two largest raw maxima
/// belonged to the GPS-blackout train rides, where the heading discontinuity across
/// a dead zone fabricates a corner that never happened. A percentile cannot be
/// captured by one bad fix; a maximum is defined by it.
///
/// Nothing here is called a measurement, because it is not one. Two biases both run
/// the same way — the estimator needs a multi-second window to be trustworthy (a
/// corner at 60 km/h is over in about that long, so what comes out is the corner's
/// *average*), and a yaw rate past the aliasing limit is under-read. So the true
/// peak is always at least what is shown, which is the honest direction to err and
/// is what the takeaway says out loud.
///
/// There is deliberately **no score**. Smoothness scores 0–100 because smooth beats
/// rough; leaning further is not better riding, it is a fact about the road.
class LeanChart extends StatelessWidget {
  const LeanChart({
    super.key,
    required this.analysis,
    required this.unit,
  });

  /// Passed in already computed rather than derived here: the tab bar has to know
  /// whether this tab exists *before* it can be built, and running the estimator
  /// twice per frame (once to decide, once to draw) would put a full pass over
  /// every track point on the swipe path.
  final LeanAnalysis analysis;

  final SpeedUnit unit;

  /// Runs the estimator over a stored track. The single place a `TrackPoint` list
  /// is turned into readings, so the tab bar's check and the chart's data can
  /// never disagree about what the ride contains.
  static LeanAnalysis analyse(List<TrackPoint> points) => analyseLean([
        for (final p in points)
          (
            time: p.timestamp,
            speedMps: p.speedMps,
            headingDegrees: p.headingDegrees,
            latitude: p.latitude,
            longitude: p.longitude,
          ),
      ]);

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final a = analysis;
    if (!a.hasEstimate) return const SizedBox.shrink();

    // Smooth for drawing only — the numbers above come from the raw samples. At
    // ~1 Hz an unsmoothed trace is a hairball of jitter that buries the handful of
    // real corners; this is a picture problem, fixed at the picture layer.
    final drawn =
        downsample(smoothLeanForDisplay(a.samples), kChartMaxPoints);
    final maxAbs = a.samples
        .map((s) => s.leanDegrees.abs())
        .fold(0.0, (m, v) => v > m ? v : m);
    // Round the scale out to a sensible band so the axis reads 10/20/30 rather
    // than 23.4, and never collapses to zero on an upright ride.
    final maxY = maxAbs <= 5 ? 5.0 : ((maxAbs / 5).ceil() * 5).toDouble();
    final maxDistance = unit.distanceMeters(
      a.samples.last.distanceMeters <= 0 ? 1.0 : a.samples.last.distanceMeters,
    );
    final xInterval = niceInterval(maxDistance, 4);
    final peak = a.peakDegrees;
    final peakAt = a.peakAtDistanceMeters;
    // [LeanAnalysis.peakDegrees] is a magnitude, but the dial is centre-zero and
    // points the way the bike leaned — so recover the side from the sample the
    // peak was attributed to. Same instant by construction: peakAtSeconds *is*
    // that sample's tSec.
    final signedPeak = peak == null ? null : _peakSigned(a, peak);

    return ChartFrame(
      title: 'LEAN',
      takeaway: _takeaway(a),
      trailing: _LeanBadge(degrees: a.p95Degrees!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (peak != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: cx.surfaceRaised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: cx.border),
              ),
              child: Center(
                child: LeanGauge(
                  value: signedPeak,
                  caption: 'PEAK LEAN THIS RIDE',
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AxisCaption('RIGHT ▲', color: cx.accentInk),
              const AxisCaption('DEGREES'),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: maxDistance,
                minY: -maxY,
                maxY: maxY,
                lineBarsData: [
                  LineChartBarData(
                    spots: [
                      for (final s in drawn)
                        FlSpot(
                          unit.distanceMeters(s.distanceMeters),
                          s.leanDegrees,
                        ),
                    ],
                    isCurved: true,
                    curveSmoothness: 0.2,
                    preventCurveOverShooting: true,
                    barWidth: 2,
                    color: cx.textBright.withValues(alpha: 0.85),
                    dotData: const FlDotData(show: false),
                    // Fill from the trace back to the upright line, graded by the
                    // severity ramp, so magnitude is readable as colour while the
                    // side of the axis still carries direction (audit finding 2:
                    // colour should encode severity, not which way you leaned).
                    aboveBarData: _severityArea(cx, maxY, above: true),
                    belowBarData: _severityArea(cx, maxY, above: false),
                  ),
                  // The peak, marked where it happened rather than left for the
                  // rider to find by eye.
                  if (peak != null && peakAt != null)
                    LineChartBarData(
                      spots: [
                        FlSpot(
                          unit.distanceMeters(peakAt),
                          // Signed back onto whichever side the apex was on.
                          _peakSigned(a, peak),
                        ),
                      ],
                      barWidth: 0,
                      color: Colors.transparent,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (_, _, _, _) =>
                            FlDotCirclePainter(
                          radius: 5,
                          color: leanSeverityColor(cx, peak),
                          strokeWidth: 2,
                          strokeColor: cx.textBright,
                        ),
                      ),
                    ),
                ],
                lineTouchData: LineTouchData(
                  enabled: true,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => cx.surfaceRaised,
                    tooltipRoundedRadius: 8,
                    tooltipBorder: BorderSide(color: cx.border),
                    tooltipPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => [
                      for (final s in spots)
                        LineTooltipItem(
                          // Name the side in words — a signed number leaves the
                          // rider decoding which way the minus means.
                          '${s.y.abs().toStringAsFixed(0)}° '
                              '${s.y < 0 ? 'left' : 'right'}',
                          TextStyle(
                            color: cx.textBright,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            fontFeatures: kTabularFigures,
                          ),
                          children: [
                            TextSpan(
                              text: '\nat ${s.x.toStringAsFixed(1)} '
                                  '${unit.distanceLabel}',
                              style:
                                  TextStyle(color: cx.textDim, fontSize: 12),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  // Every 5°, so the eye can count a 10° lean apart from a 15° one
                  // (audit finding 3 — the chart previously ruled only 0 and the
                  // outer edge, which made every magnitude a guess).
                  horizontalInterval: 5,
                  // The upright line is the one that matters — everything is read
                  // as a departure from it.
                  getDrawingHorizontalLine: (v) => v.abs() < 0.001
                      ? FlLine(color: cx.textDim, strokeWidth: 1.5)
                      : FlLine(
                          color: cx.border.withValues(alpha: 0.5),
                          strokeWidth: 1),
                  checkToShowHorizontalLine: (v) => true,
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    left: BorderSide(color: cx.border),
                    bottom: BorderSide(color: cx.border),
                  ),
                ),
                titlesData: FlTitlesData(
                  show: true,
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 30,
                      // Gridlines every 5° but a label only every 10°, so the
                      // scale is countable without the axis becoming a wall of
                      // numbers on a 200dp-tall plot.
                      interval: 5,
                      getTitlesWidget: (v, meta) {
                        if (v.abs() < 0.001) return Text('0', style: _tick(cx));
                        if ((v.abs() % 10).round() != 0) {
                          return const SizedBox.shrink();
                        }
                        return Text(v.abs().toStringAsFixed(0), style: _tick(cx));
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: xInterval,
                      getTitlesWidget: (v, meta) =>
                          Text(fmtTick(v, xInterval), style: _tick(cx)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AxisCaption('LEFT ▼', color: cx.accentInk),
              AxisCaption('DISTANCE (${unit.distanceLabel.toUpperCase()})'),
            ],
          ),
          const SizedBox(height: 20),
          _BandHistogram(analysis: a),
          if (a.balance != null) ...[
            const SizedBox(height: 16),
            Text(
              // Capitalised in place rather than stored capitalised, so the same
              // phrase can be reused mid-sentence elsewhere.
              '${a.balance![0].toUpperCase()}${a.balance!.substring(1)}.',
              style: TextStyle(color: cx.textDim, fontSize: 13, height: 1.35),
            ),
          ],
        ],
      ),
    );
  }

  /// The sentence under the title: the typical lean in words, how long was spent
  /// past a meaningful angle, and — always — that this is an estimate biased low.
  String _takeaway(LeanAnalysis a) {
    final p95 = a.p95Degrees!.round();
    final peak = a.peakDegrees?.round();
    final beyond = a.secondsBeyond(15);
    final parts = <String>['Typically $p95° through corners — ${a.band}'];
    if (peak != null && peak > p95) parts.add('peaking near $peak°');
    final head = '${parts.join(', ')}.';
    final spent = beyond >= 5
        ? ' Spent ${_fmtDuration(beyond)} past 15°.'
        : '';
    // The caveat is not optional. The estimate is a corner's average, and a very
    // fast turn is under-read, so the real peak is always at least this.
    return '$head$spent Estimated from GPS turn rate, so true peaks run higher.';
  }

  /// Puts [peak] (a magnitude) back on the side the apex actually happened, so the
  /// marker lands on the drawn curve rather than mirrored across the axis — and so
  /// the centre-zero dial points the way the bike leaned instead of always right.
  static double _peakSigned(LeanAnalysis a, double peak) {
    final at = a.peakAtSeconds;
    if (at == null) return peak;
    for (final s in a.samples) {
      if (s.tSec == at) return s.leanDegrees.isNegative ? -peak : peak;
    }
    return peak;
  }

  /// The graded fill between the trace and the upright line.
  ///
  /// `cutOffY: 0` is what makes this read correctly: fl_chart's area fills default
  /// to the edge of the plot, which on a signed axis would flood half the chart.
  /// The gradient runs along the *axis*, so a given height is always the same
  /// colour whichever side of upright it is on.
  static BarAreaData _severityArea(AppPalette cx, double maxY,
      {required bool above}) {
    final stops = <double>[0, 0.25, 0.5, 0.75, 1.0];
    final colors = [
      for (final s in stops)
        leanSeverityColor(cx, s * maxY).withValues(alpha: 0.30 + 0.35 * s),
    ];
    return BarAreaData(
      show: true,
      applyCutOffY: true,
      cutOffY: 0,
      gradient: LinearGradient(
        // Above the axis the ramp deepens upward; below, downward.
        begin: above ? Alignment.topCenter : Alignment.bottomCenter,
        end: above ? Alignment.bottomCenter : Alignment.topCenter,
        colors: colors.reversed.toList(),
        stops: stops,
      ),
    );
  }

  static TextStyle _tick(AppPalette cx) => TextStyle(
        color: cx.textTertiary,
        fontSize: kMinFontSize,
        fontFeatures: kTabularFigures,
      );
}

/// The typical-lean figure, as the thing the tab is actually about.
class _LeanBadge extends StatelessWidget {
  const _LeanBadge({required this.degrees});

  final double degrees;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      label: 'Typical cornering lean ${degrees.round()} degrees, estimated',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: cx.accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: cx.accentInk.withValues(alpha: 0.4)),
          ),
          child: RichText(
            text: TextSpan(
              text: '${degrees.round()}°',
              style: TextStyle(
                color: cx.accentInk,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                fontFeatures: kTabularFigures,
              ),
              children: [
                TextSpan(
                  text: ' typical',
                  style: TextStyle(
                    color: cx.textDim,
                    fontSize: kMinFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Time spent in each 5° band — the whole distribution, which is the most honest
/// way to present a soft estimate: a rider can see that the deep bands are a
/// handful of seconds rather than a character trait.
class _BandHistogram extends StatelessWidget {
  const _BandHistogram({required this.analysis});

  final LeanAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final bands = analysis.histogram;
    if (bands.isEmpty) return const SizedBox.shrink();
    final longest =
        bands.map((b) => b.seconds).fold(0.0, (m, v) => v > m ? v : m);
    final total = bands.fold(0.0, (sum, b) => sum + b.seconds);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AxisCaption('TIME SPENT LEANING'),
        const SizedBox(height: 10),
        for (final b in bands) ...[
          Semantics(
            label: '${b.fromDegrees} to ${b.toDegrees} degrees, '
                '${_fmtDuration(b.seconds)}',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      '${b.fromDegrees}–${b.toDegrees}°',
                      style: TextStyle(
                        color: cx.textDim,
                        fontSize: kMinFontSize,
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ClipRRect(
                      // 4px rounded data-end, anchored square at the baseline.
                      borderRadius: const BorderRadius.horizontal(
                        left: Radius.circular(2),
                        right: Radius.circular(4),
                      ),
                      child: LinearProgressIndicator(
                        value: longest <= 0 ? 0 : b.seconds / longest,
                        minHeight: 8,
                        backgroundColor: cx.border.withValues(alpha: 0.35),
                        // Graded by the same ramp the chart fill and the dial use,
                        // so one band means one colour everywhere in the tab. The
                        // previous version varied only alpha (0.45→0.78), which
                        // was too subtle to read as a difference at all.
                        valueColor: AlwaysStoppedAnimation(
                          leanSeverityColor(
                              cx, b.fromDegrees + (b.toDegrees - b.fromDegrees) / 2),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 54,
                    child: Text(
                      _fmtDuration(b.seconds),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: cx.textBright,
                        fontSize: kMinFontSize,
                        fontWeight: FontWeight.w700,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          '${_fmtDuration(total)} of cornering measured above '
          '${kMinLeanSpeedKmh.round()} km/h.',
          style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
        ),
      ],
    );
  }
}

/// Seconds → a compact human duration (`8s`, `1m 20s`, `1h 04m`).
String _fmtDuration(double seconds) {
  final s = seconds.round();
  if (s < 60) return '${s}s';
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
  return '${m}m ${(s % 60).toString().padLeft(2, '0')}s';
}
