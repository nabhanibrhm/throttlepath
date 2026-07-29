import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/smoothness.dart';
import '../core/units.dart';
import '../data/models/track_point.dart';
import '../providers/stats_providers.dart';
import '../theme/app_theme.dart';
import 'chart_frame.dart';
import 'chart_math.dart';

/// How smoothly the ride was ridden: a **0–100 score** over the scatter of
/// longitudinal acceleration it was computed from.
///
/// The score leads (F28). A scatter of a few hundred dots tells a rider that
/// *something* happened but not whether it was good; "82 / 100, smoother than 8
/// of your last 10 rides" is the same data as an answer. The dots stay underneath
/// as the evidence, with the bands named in words — **accelerating** above the
/// line, **braking** below — instead of leaving a signed number to be decoded.
///
/// The score is not recomputed here for the comparison set: it is read off
/// `Ride.smoothness`, persisted at ride end by `route_derivation.dart` from this
/// same [analyseSmoothness]. That is exactly what the Phase 4 migration reserved
/// the field for — the alternative is loading ten full tracks to draw one
/// sentence.
class SmoothnessChart extends ConsumerWidget {
  const SmoothnessChart({
    super.key,
    required this.rideId,
    required this.points,
    required this.unit,
  });

  /// The ride being shown — excluded from its own comparison set.
  final int rideId;

  final List<TrackPoint> points;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final analysis = analyseSmoothness([
      for (final p in points) (time: p.timestamp, speedMps: p.speedMps),
    ]);
    if (analysis.samples.isEmpty) return const SizedBox.shrink();

    // Display-unit acceleration: m/s² → km/h per second → the rider's unit.
    // "1.5 m/s²" means nothing on a handlebar; "5 km/h every second" does.
    double toDisplay(double mps2) => unit.speed(mps2 * 3.6);
    final accelLabel = '${unit.speedLabel} per second';

    final drawn = downsample(analysis.samples, kChartMaxPoints);
    final spots = <ScatterSpot>[
      for (final s in drawn)
        ScatterSpot(
          s.tSec,
          toDisplay(s.aMps2),
          dotPainter: FlDotCirclePainter(
            radius: 2.5,
            color: s.aMps2 >= 0 ? _accelColor : _brakeColor,
          ),
        ),
    ];

    // A ride held at a genuinely constant speed has a max |a| of zero, and
    // fl_chart asserts on a zero grid interval. The old chart seeded its running
    // maximum at 1.0, which hid the case; the analysis reports the truth, so the
    // floor belongs here, at the point where it is a *drawing* concern.
    final peak = toDisplay(analysis.maxAbsMps2);
    final maxY = peak <= 0 ? 1.0 : peak * 1.15;
    final start = points.first.timestamp;
    final totalSec =
        points.last.timestamp.difference(start).inMilliseconds / 1000.0;
    final maxX = totalSec <= 0 ? 1.0 : totalSec;
    final gridStyle =
        FlLine(color: cx.border.withValues(alpha: 0.4), strokeWidth: 1);

    final previous = ref.watch(recentSmoothnessProvider(rideId)).valueOrNull;
    final score = analysis.score;

    return ChartFrame(
      title: 'SMOOTHNESS',
      takeaway: _takeaway(analysis, previous),
      trailing: score == null ? null : _ScoreBadge(score: score),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              AxisCaption('ACCELERATING ▲', color: _accelInk(cx)),
              AxisCaption(accelLabel.toUpperCase()),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 220,
            child: ScatterChart(
              ScatterChartData(
                scatterSpots: spots,
                minX: 0,
                maxX: maxX,
                minY: -maxY,
                maxY: maxY,
                // Drag-to-scrub with a value bubble (F26): the scatter was inert
                // before, so a rider could see a spike and had no way to ask when
                // it happened or how hard it was.
                scatterTouchData: ScatterTouchData(
                  enabled: true,
                  handleBuiltInTouches: true,
                  touchSpotThreshold: 12,
                  touchTooltipData: ScatterTouchTooltipData(
                    getTooltipColor: (_) => cx.surfaceRaised,
                    tooltipRoundedRadius: 8,
                    tooltipBorder: BorderSide(color: cx.border),
                    tooltipPadding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spot) => ScatterTooltipItem(
                      _fmtClock(spot.x.round()),
                      textStyle: TextStyle(
                        color: cx.textDim,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        fontFeatures: kTabularFigures,
                      ),
                      children: [
                        TextSpan(
                          text: '\n${spot.y >= 0 ? '+' : ''}'
                              '${spot.y.toStringAsFixed(1)}',
                          style: TextStyle(
                            color: cx.textBright,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            fontFeatures: kTabularFigures,
                          ),
                        ),
                        TextSpan(
                          text: ' ${unit.speedLabel}/s',
                          style: TextStyle(color: cx.textDim, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxY,
                  // Emphasise the y = 0 baseline; other lines stay faint.
                  getDrawingHorizontalLine: (v) => v.abs() < 0.001
                      ? FlLine(color: cx.textDim, strokeWidth: 1)
                      : gridStyle,
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
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      interval: maxY,
                      getTitlesWidget: (v, meta) => Text(
                        v.abs() < 0.001 ? '0' : v.abs().toStringAsFixed(0),
                        style: _tick(cx),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: maxX / 4,
                      getTitlesWidget: (v, meta) =>
                          Text(_fmtClock(v.round()), style: _tick(cx)),
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
              AxisCaption('BRAKING ▼', color: _brakeInk(cx)),
              const AxisCaption('TIME INTO RIDE'),
            ],
          ),
          const SizedBox(height: 18),
          _EventLine(
            color: _accelColor,
            title: 'Rapid acceleration',
            detail: 'over ${toDisplay(kHardEventMps2).toStringAsFixed(0)} '
                '$accelLabel',
            events: analysis.accelEvents,
          ),
          const SizedBox(height: 12),
          _EventLine(
            color: _brakeColor,
            title: 'Hard braking',
            detail: 'over ${toDisplay(kHardEventMps2).toStringAsFixed(0)} '
                '$accelLabel shed',
            events: analysis.brakeEvents,
          ),
        ],
      ),
    );
  }

  /// The sentence under the title: the score in words, plus where it sits against
  /// the rider's recent rides when there are any to compare with.
  String _takeaway(AccelAnalysis analysis, List<double>? previous) {
    final score = analysis.score;
    if (score == null) {
      return 'Too few usable GPS intervals in this ride to score how smoothly '
          'it was ridden.';
    }
    final band = analysis.band;
    final comparison = smoothnessComparison(score, previous ?? const []);
    final head = 'Scored ${score.round()} out of 100 — $band';
    return comparison == null ? '$head.' : '$head, $comparison.';
  }

  static const Color _accelColor = Color(0xFF3B82F6); // blue
  static const Color _brakeColor = Color(0xFFEF4444); // red

  /// Legible variants of the two band hues for *text*, per the palette's rule
  /// that a fill colour never goes straight into a `TextStyle`.
  static Color _accelInk(AppPalette cx) =>
      cx.isDark ? const Color(0xFF7FB0FF) : const Color(0xFF1D4ED8);
  static Color _brakeInk(AppPalette cx) => cx.dangerInk;

  TextStyle _tick(AppPalette cx) => TextStyle(
        color: cx.textTertiary,
        fontSize: kMinFontSize,
        fontFeatures: kTabularFigures,
      );
}

/// The score, as the thing the tab is actually about.
class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      label: 'Smoothness score ${score.round()} out of 100',
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
              text: '${score.round()}',
              style: TextStyle(
                color: cx.accentInk,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                fontFeatures: kTabularFigures,
              ),
              children: [
                TextSpan(
                  text: ' / 100',
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

/// One summary line under the scatter: colour dot + label + threshold + count.
class _EventLine extends StatelessWidget {
  const _EventLine({
    required this.color,
    required this.title,
    required this.detail,
    required this.events,
  });

  final Color color;
  final String title;
  final String detail;
  final int events;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(
              text: title,
              style: TextStyle(
                color: cx.textBright,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(
                  text: '  $detail',
                  style: TextStyle(
                    color: cx.textDim,
                    fontSize: kMinFontSize,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$events',
          style: TextStyle(
            color: cx.textBright,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            fontFeatures: kTabularFigures,
          ),
        ),
      ],
    );
  }
}

/// Seconds → `m:ss` (or `h:mm:ss`) for the time axis.
String _fmtClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$m:$ss';
}
