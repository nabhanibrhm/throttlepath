import 'package:flutter/material.dart';

import '../core/units.dart';
import '../data/models/track_point.dart';
import '../theme/app_theme.dart';
import 'chart_frame.dart';

/// How a ride's time splits across speed ranges — a quick read on the trip's
/// nature (slow commute vs highway run).
///
/// Drawn as **one stacked bar ordered slow → fast**, over a table of the same
/// four numbers. The donut this replaced (F27) forced two comparisons the eye is
/// bad at: judging angles, and matching a wedge to a legend entry. A single bar
/// is read left-to-right in the same order as the table beneath it, the segments
/// are labelled in place, and the bar's own length carries the "share of total"
/// meaning without a centre annotation explaining it.
///
/// Time is attributed by summing the interval between consecutive [points] into
/// the bucket of that interval's mean speed. Each interval is capped at
/// [_maxSegmentSeconds] so a pause or GPS blackout gap can't dump minutes of
/// phantom time into the slowest zone. Zone edges are unit-aware (round numbers
/// in km/h or mph); speeds convert to the display unit before bucketing.
class SpeedZoneChart extends StatefulWidget {
  const SpeedZoneChart({super.key, required this.points, required this.unit});

  final List<TrackPoint> points;
  final SpeedUnit unit;

  /// Cap on a single inter-fix interval (seconds) — longer gaps are pauses or
  /// blackouts, not steady riding, so they're clamped to not skew the mix.
  static const double _maxSegmentSeconds = 10.0;

  /// Zone colours, slowest → fastest (blue → green → amber → red). Fixed hues so
  /// the meaning stays stable across the light/dark themes.
  static const List<Color> zoneColors = [
    Color(0xFF3B82F6), // blue
    Color(0xFF22C55E), // green
    Color(0xFFF59E0B), // amber
    Color(0xFFEF4444), // red
  ];

  @override
  State<SpeedZoneChart> createState() => _SpeedZoneChartState();
}

class _SpeedZoneChartState extends State<SpeedZoneChart> {
  /// Zone the rider tapped, highlighted in both the bar and the table. Null is
  /// the resting state — nothing is preselected, so the chart doesn't imply one
  /// zone matters more than the others.
  int? _selected;

  /// Upper edges of the first three zones, in the display unit (the 4th is
  /// open-ended above the last edge).
  List<double> get _edges =>
      widget.unit == SpeedUnit.mph ? const [20, 40, 60] : const [30, 60, 90];

  List<String> get _labels => widget.unit == SpeedUnit.mph
      ? const ['0 – 20', '20 – 40', '40 – 60', '60+']
      : const ['0 – 30', '30 – 60', '60 – 90', '90+'];

  /// Seconds spent in each of the four zones.
  List<double> _computeSeconds() {
    final points = widget.points;
    final secs = <double>[0, 0, 0, 0];
    for (var i = 1; i < points.length; i++) {
      var dt = points[i]
              .timestamp
              .difference(points[i - 1].timestamp)
              .inMilliseconds /
          1000.0;
      if (dt <= 0) continue;
      if (dt > SpeedZoneChart._maxSegmentSeconds) {
        dt = SpeedZoneChart._maxSegmentSeconds;
      }
      final meanKmh = (points[i - 1].speedMps + points[i].speedMps) / 2 * 3.6;
      final v = widget.unit.speed(meanKmh);
      final zone = v < _edges[0]
          ? 0
          : v < _edges[1]
              ? 1
              : v < _edges[2]
                  ? 2
                  : 3;
      secs[zone] += dt;
    }
    return secs;
  }

  /// The plain-language reading of the distribution.
  String _takeaway(List<double> secs, double total) {
    var top = 0;
    for (var i = 1; i < 4; i++) {
      if (secs[i] > secs[top]) top = i;
    }
    final pct = (secs[top] / total * 100).round();
    final label = _labels[top];
    final unitName = widget.unit.speedLabel;
    // "60+" reads badly inside "between 60+ …", so the open-ended top zone gets
    // its own phrasing.
    final where = top == 3
        ? 'above ${_edges[2].toStringAsFixed(0)} $unitName'
        : 'between $label $unitName';
    return 'Most of the ride — $pct% of it — was spent $where.';
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final secs = _computeSeconds();
    final total = secs.fold(0.0, (a, b) => a + b);
    if (total <= 0) return const SizedBox.shrink();

    return ChartFrame(
      title: 'SPEED ZONES',
      takeaway: _takeaway(secs, total),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StackedBar(
            seconds: secs,
            total: total,
            selected: _selected,
            onTap: (i) => setState(() => _selected = _selected == i ? null : i),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const AxisCaption('SLOWEST'),
              AxisCaption('SPEED ZONE (${widget.unit.speedLabel})'),
              const AxisCaption('FASTEST'),
            ],
          ),
          const SizedBox(height: 22),
          // Table: zone · time · %.
          Row(
            children: [
              Expanded(
                child: Text(
                  'Zone (${widget.unit.speedLabel})',
                  style: TextStyle(color: cx.textDim, fontSize: 12),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  'Time',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: cx.textDim, fontSize: 12),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '%',
                  textAlign: TextAlign.right,
                  style: TextStyle(color: cx.textDim, fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < 4; i++)
            _LegendRow(
              color: SpeedZoneChart.zoneColors[i],
              label: _labels[i],
              seconds: secs[i].round(),
              pct: secs[i] / total * 100,
              selected: _selected == i,
              onTap: () =>
                  setState(() => _selected = _selected == i ? null : i),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Container(height: 1, color: cx.border),
          ),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total',
                  style: TextStyle(
                    color: cx.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  _fmtDuration(total.round()),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: cx.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '100%',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: cx.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The one stacked bar, slowest zone at the left. Segments carry their own
/// percentage when they're wide enough to hold it; narrower ones stay bare
/// rather than shrinking the label below the 12sp floor.
class _StackedBar extends StatelessWidget {
  const _StackedBar({
    required this.seconds,
    required this.total,
    required this.selected,
    required this.onTap,
  });

  final List<double> seconds;
  final double total;
  final int? selected;
  final ValueChanged<int> onTap;

  /// A segment narrower than this share of the bar has no room for "12%" at the
  /// 12sp floor, so it goes unlabelled.
  static const double _labelFloor = 0.13;

  @override
  Widget build(BuildContext context) {
    final present = [
      for (var i = 0; i < 4; i++)
        if (seconds[i] > 0) i,
    ];
    if (present.isEmpty) return const SizedBox.shrink();

    // 44dp with the percentages inside it. The minimal pass took this to a bare
    // 10dp strip on the argument that the table below says the same thing in
    // words — but on the phone that strip read as a decoration under the
    // heading rather than as the chart, and the tab's whole answer moved into a
    // list of numbers. Height is what makes it a chart: at 44 the four shares
    // are comparable by eye and the table becomes the precise reading, which is
    // the split the two are supposed to have.
    return Semantics(
      label: 'Speed zone distribution',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              for (final i in present)
                Expanded(
                  // Sub-percent slivers would round to a flex of 0 and vanish
                  // from a bar whose whole job is to account for the total.
                  flex: (seconds[i] / total * 10000).round().clamp(1, 10000),
                  child: _Segment(
                    index: i,
                    fraction: seconds[i] / total,
                    dimmed: selected != null && selected != i,
                    labelled: seconds[i] / total >= _labelFloor,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One band of the bar: its colour, its share written inside it when it is wide
/// enough, and a tap that highlights its row in the table below.
class _Segment extends StatelessWidget {
  const _Segment({
    required this.index,
    required this.fraction,
    required this.dimmed,
    required this.labelled,
    required this.onTap,
  });

  final int index;
  final double fraction;
  final bool dimmed;
  final bool labelled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = SpeedZoneChart.zoneColors[index];
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: dimmed ? 0.32 : 1,
        child: Container(
          color: color,
          alignment: Alignment.center,
          child: labelled
              // Silent to a screen reader: the table underneath reads out the
              // same four shares to one decimal, and without this the bar
              // announces "Speed zone distribution, 22%, 51%, 27%" first — the
              // same numbers twice, the rounder pass first.
              ? ExcludeSemantics(
                  child: Text(
                    '${(fraction * 100).round()}%',
                    style: const TextStyle(
                      // Fixed white: these four hues are theme-independent, so
                      // the ink on top of them has to be too.
                      color: Colors.white,
                      fontSize: kMinFontSize,
                      fontWeight: FontWeight.w800,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// One table line: a colour dot + zone label, its time, and its share.
class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.seconds,
    required this.pct,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final String label;
  final int seconds;
  final double pct;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        // 44dp of row keeps the tap target honest against the 48dp guidance
        // without opening gaps between four consecutive rows.
        constraints: const BoxConstraints(minHeight: 44),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration:
                        BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: cx.textBright,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                _fmtDuration(seconds),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: cx.textBright,
                  fontSize: 13,
                  fontFeatures: kTabularFigures,
                ),
              ),
            ),
            SizedBox(
              width: 52,
              child: Text(
                '${pct.toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: cx.textDim,
                  fontSize: 13,
                  fontFeatures: kTabularFigures,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
