import 'package:flutter/material.dart';

import '../core/units.dart';
import '../data/ride_stats.dart';
import '../theme/app_theme.dart';

/// This week at a glance: distance, rides, streak, and how it compares to last
/// week (F22).
///
/// The retention answer the app had no way to give. A rides list sorted by date
/// tells a rider what they did; it never tells them whether they are riding more
/// or less than they were, which is the only question that brings anyone back to a
/// tracker.
class WeekStrip extends StatelessWidget {
  const WeekStrip({
    super.key,
    required this.stats,
    required this.unit,
    this.compact = false,
  });

  final WeekStats stats;
  final SpeedUnit unit;

  /// A single line for the Record screen's idle sheet, where the full card would
  /// crowd out the GPS-readiness row it sits beside.
  final bool compact;

  /// The distance figure, formatted for the active unit. Public so the collapsed
  /// History app bar can echo it without duplicating the rounding rule: below
  /// 100 km/mi one decimal reads as progress, above it the decimal is noise.
  static String distanceText(WeekStats stats, SpeedUnit unit) {
    final d = unit.distanceMeters(stats.distanceMeters);
    final digits = d >= 100 ? 0 : 1;
    return '${d.toStringAsFixed(digits)} ${unit.distanceLabel}';
  }

  /// "+12% vs last week" / "−8% vs last week" / null when there is no baseline.
  static String? deltaText(WeekStats stats) {
    final f = stats.deltaFraction;
    if (f == null) return null;
    final pct = (f.abs() * 100).round();
    if (pct == 0) return 'level with last week';
    // A true minus sign, not a hyphen — at 12sp a hyphen next to a digit reads as
    // part of the number.
    return '${f > 0 ? '+' : '−'}$pct% vs last week';
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final delta = deltaText(stats);
    final up = (stats.deltaFraction ?? 0) > 0;

    if (compact) {
      return Row(
        children: [
          Icon(Icons.calendar_today_outlined, size: 14, color: cx.textDim),
          const SizedBox(width: 7),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'This week ',
                    style: TextStyle(color: cx.textTertiary),
                  ),
                  TextSpan(
                    text: distanceText(stats, unit),
                    style: TextStyle(
                      color: cx.textBright,
                      fontWeight: FontWeight.w700,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                  TextSpan(
                    text: ' · ${_ridesLabel(stats.rideCount)}',
                    style: TextStyle(color: cx.textTertiary),
                  ),
                  if (delta != null)
                    TextSpan(
                      text: ' · $delta',
                      style: TextStyle(
                          color: up ? cx.positiveInk : cx.textTertiary),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      );
    }

    // Two plain lines, no card (spec 5.1). The old version wrapped this in a
    // filled 16dp-radius card *and* labelled it THIS WEEK *and* repeated the
    // unit — three layers of chrome around two facts. The unit now rides along
    // with the number ("42.3 km this week"), which retires the label, and the
    // trend arrow goes with it: the delta sentence already says which way.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Nested min-width Row so the number and its unit share a baseline;
            // the streak can't join that baseline group because the Expanded
            // between them has none.
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  unit
                      .distanceMeters(stats.distanceMeters)
                      .toStringAsFixed(stats.distanceMeters >= 100000 ? 0 : 1),
                  style: TextStyle(
                    color: cx.accentInk,
                    fontSize: 30,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    fontFeatures: kTabularFigures,
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  '${unit.distanceLabel} this week',
                  style: TextStyle(color: cx.textDim, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(width: 10),
            // Expanded + right-align rather than Spacer + intrinsic width:
            // every trailing element here is text of unknown length, and on a
            // 353dp phone the strip has ~287dp to play with.
            if (stats.streakWeeks >= 2)
              Expanded(
                child: Text(
                  '${stats.streakWeeks} wk streak',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cx.positiveInk,
                    fontSize: kMinFontSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 7),
        Text(
          stats.isEmpty
              // An empty week is the one that most needs a sentence rather than
              // a row of zeros — that was F5's lesson on the idle screen.
              ? 'No rides yet this week.'
              : [
                  _ridesLabel(stats.rideCount),
                  '${_fmtHours(stats.movingSeconds)} moving',
                  ?delta,
                ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            // One neutral colour for the whole line, including the delta (G2).
            // The screen's single amber emphasis is the distance above; tinting
            // the delta teal as well would make two things claim to be the
            // point. The streak keeps its teal because it is the only *state*
            // on the strip, not a restatement of the number.
            color: cx.textDim,
            fontSize: kMinFontSize,
            fontWeight: FontWeight.w500,
            fontFeatures: kTabularFigures,
          ),
        ),
      ],
    );
  }
}

String _ridesLabel(int count) => count == 1 ? '1 ride' : '$count rides';

/// `2h 40m`, or `40m` under an hour. Whole minutes: nobody reads seconds of
/// moving time across a week.
String _fmtHours(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}
