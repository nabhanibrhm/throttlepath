import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/duration_format.dart';
import '../core/track_runs.dart';
import '../core/units.dart';
import '../data/models/track_point.dart';
import '../theme/app_theme.dart';
import 'chart_frame.dart';
import 'chart_math.dart';

/// Dual-axis profile over time: a filled **elevation** area in the background
/// with the **speed** line laid over it. Gives the speed data physical context —
/// you can see speed bleed off on a climb and peak on a descent.
///
/// Each axis is coloured to its series (F28): the left ticks are amber like the
/// speed line, the right ticks teal like the elevation fill. Two unlabelled
/// columns of numbers on either side of a two-series chart is a puzzle; colour
/// answers it without spending a word.
///
/// fl_chart shares one y-scale, so elevation is linearly mapped onto the speed
/// axis and the right-hand tick labels are mapped back to real metres. Skipped
/// entirely when the track has no usable altitude or no real elevation change.
class ElevationSpeedChart extends StatefulWidget {
  const ElevationSpeedChart({
    super.key,
    required this.points,
    required this.unit,
  });

  final List<TrackPoint> points;
  final SpeedUnit unit;

  /// Minimum elevation swing (m) for the chart to be worth showing.
  static const double minElevRange = 2.0;

  /// Window (samples) of the centred moving average used to tame raw GNSS
  /// vertical jitter before plotting and summing gain/loss.
  static const int _smoothWindow = 5;

  /// Elevation must move at least this far (m) from the running reference before
  /// it counts as real gain/loss — hysteresis that rejects jitter while still
  /// capturing gradual climbs (which a per-step floor would silently drop).
  static const double _gainThreshold = 3.0;

  @override
  State<ElevationSpeedChart> createState() => _ElevationSpeedChartState();
}

class _ElevationSpeedChartState extends State<ElevationSpeedChart> {
  bool _showSpeed = true;
  bool _showElev = true;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final points = widget.points;
    final unit = widget.unit;
    final start = points.first.timestamp;

    // Raw altitude series (only points that carry altitude), paired with time.
    // `resumed` marks each sample that is the first after a GPS blackout.
    final times = <double>[];
    final rawAlt = <double>[];
    final resumed = <bool>[];
    DateTime? previous;
    for (final p in points) {
      final alt = p.altitude;
      if (alt == null) continue;
      times.add(p.timestamp.difference(start).inMilliseconds / 1000.0);
      rawAlt.add(alt);
      resumed.add(previous != null &&
          p.timestamp.difference(previous).inSeconds.abs() >=
              kSignalLossSeconds);
      previous = p.timestamp;
    }
    if (rawAlt.length < 2) return const SizedBox.shrink();

    // Smooth away raw GNSS vertical jitter before it reaches the plot or the
    // gain/loss sums.
    final alt = _movingAverage(rawAlt, ElevationSpeedChart._smoothWindow);

    final elev = <FlSpot>[]; // (tSec, metres) — real metres for now
    var eMin = alt.first, eMax = alt.first;
    for (var i = 0; i < alt.length; i++) {
      elev.add(FlSpot(times[i], alt[i]));
      if (alt[i] < eMin) eMin = alt[i];
      if (alt[i] > eMax) eMax = alt[i];
    }

    if ((eMax - eMin) < ElevationSpeedChart.minElevRange) {
      return const SizedBox.shrink();
    }

    // Gain/loss by hysteresis: only commit a move once it has drifted at least
    // _gainThreshold from the running reference, then re-anchor. Captures slow
    // climbs (which accumulate against the reference) while ignoring jitter.
    // A blackout re-anchors instead of committing: whatever the rider climbed
    // while GPS was out was not measured, and crediting the whole step to the
    // one fix that ended the dead zone would invent a cliff.
    var gain = 0.0, loss = 0.0;
    var ref = alt.first;
    for (var i = 0; i < alt.length; i++) {
      final a = alt[i];
      if (resumed[i]) {
        ref = a;
        continue;
      }
      final d = a - ref;
      if (d >= ElevationSpeedChart._gainThreshold) {
        gain += d;
        ref = a;
      } else if (d <= -ElevationSpeedChart._gainThreshold) {
        loss += -d;
        ref = a;
      }
    }

    // Speed series (all points), in the display unit.
    final speed = <FlSpot>[
      for (final p in points)
        FlSpot(
          p.timestamp.difference(start).inMilliseconds / 1000.0,
          unit.speed(p.speedMps * 3.6),
        ),
    ];

    final maxSpeed = speed.fold(0.0, (m, s) => s.y > m ? s.y : m);
    final maxY = maxSpeed <= 0 ? 1.0 : maxSpeed;
    final eRange = eMax - eMin;
    // Map real metres onto the shared speed axis.
    double ePlot(double metres) => (metres - eMin) / eRange * maxY;
    double eUnplot(double plotted) => eMin + (plotted / maxY) * eRange;
    final elevScaled = [for (final s in elev) FlSpot(s.x, ePlot(s.y))];

    final totalSec =
        points.last.timestamp.difference(start).inMilliseconds / 1000.0;
    final maxX = totalSec <= 0 ? 1.0 : totalSec;

    // Bars are built conditionally, so remember what each index *is* — the
    // tooltip has to un-map elevation back to metres and must not do that to the
    // speed line when only one series is showing.
    final bars = <LineChartBarData>[];
    final isElevBar = <bool>[];
    if (_showElev) {
      bars.add(
        LineChartBarData(
          spots: downsampleSpots(elevScaled, kChartMaxPoints),
          isCurved: true,
          curveSmoothness: 0.2,
          preventCurveOverShooting: true,
          color: cx.positive.withValues(alpha: 0.85),
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            color: cx.positive.withValues(alpha: 0.20),
          ),
        ),
      );
      isElevBar.add(true);
    }
    if (_showSpeed) {
      bars.add(
        LineChartBarData(
          spots: downsampleSpots(speed, kChartMaxPoints),
          isCurved: true,
          curveSmoothness: 0.2,
          preventCurveOverShooting: true,
          color: cx.accent,
          barWidth: 2,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: false),
        ),
      );
      isElevBar.add(false);
    }

    return ChartFrame(
      title: 'ELEVATION VS. SPEED',
      takeaway: _takeaway(gain, loss, eMax - eMin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              LegendToggle(
                color: cx.accent,
                label: 'Speed (${unit.speedLabel})',
                enabled: _showSpeed,
                // Never let both go dark: an empty plot area reads as a bug, and
                // there is no affordance left on the chart itself to recover.
                onTap: () => setState(() {
                  if (_showSpeed && !_showElev) return;
                  _showSpeed = !_showSpeed;
                }),
              ),
              const SizedBox(width: 12),
              LegendToggle(
                color: cx.positive,
                label: 'Elevation (m)',
                enabled: _showElev,
                onTap: () => setState(() {
                  if (_showElev && !_showSpeed) return;
                  _showElev = !_showElev;
                }),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: maxX,
                minY: 0,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: maxY / 2,
                  getDrawingHorizontalLine: (_) => FlLine(
                      color: cx.border.withValues(alpha: 0.4), strokeWidth: 1),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    left: BorderSide(color: cx.border),
                    right: BorderSide(color: cx.border),
                    bottom: BorderSide(color: cx.border),
                  ),
                ),
                // Drag-to-scrub with a value bubble (F26).
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
                    getTooltipItems: (touched) => [
                      for (final s in touched)
                        if (isElevBar[s.barIndex])
                          LineTooltipItem(
                            '${eUnplot(s.y).round()} m',
                            TextStyle(
                              color: cx.positiveInk,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              fontFeatures: kTabularFigures,
                            ),
                          )
                        else
                          LineTooltipItem(
                            '${s.y.toStringAsFixed(0)} ${unit.speedLabel}',
                            TextStyle(
                              color: cx.accentInk,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              fontFeatures: kTabularFigures,
                            ),
                          ),
                    ],
                  ),
                  getTouchedSpotIndicator: (bar, indices) => [
                    for (final _ in indices)
                      TouchedSpotIndicatorData(
                        FlLine(color: bar.color ?? cx.border, strokeWidth: 1.5),
                        FlDotData(
                          show: true,
                          getDotPainter: (spot, a, b, c) => FlDotCirclePainter(
                            radius: 4,
                            color: bar.color ?? cx.accent,
                            strokeWidth: 2,
                            strokeColor: cx.canvas,
                          ),
                        ),
                      ),
                  ],
                ),
                titlesData: FlTitlesData(
                  show: true,
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: _showSpeed,
                      reservedSize: 40,
                      interval: maxY / 2,
                      getTitlesWidget: (v, meta) => Text(
                        v.toStringAsFixed(0),
                        style: _tick(cx.accentInk),
                      ),
                    ),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: _showElev,
                      reservedSize: 46,
                      interval: maxY / 2,
                      getTitlesWidget: (v, meta) => Text(
                        eUnplot(v).toStringAsFixed(0),
                        style: _tick(cx.positiveInk),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 28,
                      interval: maxX / 4,
                      getTitlesWidget: (v, meta) =>
                          Text(formatClock(v.round()), style: _tick(cx.textTertiary)),
                    ),
                  ),
                ),
                lineBarsData: bars,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // The unit on each axis, stated once, in that axis's colour.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (_showSpeed)
                AxisCaption(unit.speedLabel.toUpperCase(), color: cx.accentInk)
              else
                const SizedBox.shrink(),
              const AxisCaption('TIME INTO RIDE'),
              if (_showElev)
                AxisCaption('METRES', color: cx.positiveInk)
              else
                const SizedBox.shrink(),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _ElevStat(label: 'ELEV GAIN', value: '${gain.round()} m'),
              _ElevStat(label: 'ELEV LOSS', value: '${loss.round()} m'),
              _ElevStat(label: 'MAX ELEV', value: '${eMax.round()} m'),
            ],
          ),
        ],
      ),
    );
  }

  /// Plain-language reading of the climb.
  String _takeaway(double gain, double loss, double range) {
    if (gain < 10 && loss < 10) {
      return 'Essentially flat — under ${range.round()} m between the lowest '
          'and highest point.';
    }
    if (gain > loss * 1.5) {
      return 'A net climb: ${gain.round()} m gained against ${loss.round()} m '
          'lost.';
    }
    if (loss > gain * 1.5) {
      return 'A net descent: ${loss.round()} m lost against ${gain.round()} m '
          'gained.';
    }
    return 'Rolling terrain — ${gain.round()} m climbed and ${loss.round()} m '
        'descended, roughly balancing out.';
  }

  TextStyle _tick(Color color) => TextStyle(
        color: color,
        fontSize: kMinFontSize,
        fontWeight: FontWeight.w600,
        fontFeatures: kTabularFigures,
      );

  /// Centred moving average over [window] samples, clamped at the ends. Returns
  /// the input unchanged when there's too little to smooth.
  static List<double> _movingAverage(List<double> xs, int window) {
    if (window <= 1 || xs.length <= 2) return xs;
    final half = window ~/ 2;
    final out = List<double>.filled(xs.length, 0);
    for (var i = 0; i < xs.length; i++) {
      final lo = i - half < 0 ? 0 : i - half;
      final hi = i + half >= xs.length ? xs.length - 1 : i + half;
      var sum = 0.0;
      for (var j = lo; j <= hi; j++) {
        sum += xs[j];
      }
      out[i] = sum / (hi - lo + 1);
    }
    return out;
  }
}

class _ElevStat extends StatelessWidget {
  const _ElevStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: cx.textBright,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              fontFeatures: kTabularFigures,
            ),
          ),
        ],
      ),
    );
  }
}

