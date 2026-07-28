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
    final fraction = stats.deltaFraction ?? 0;
    final up = fraction > 0;
    // Three-way, not up-or-flat: a week down 58% drawn with `trending_flat`
    // says "level", which is the opposite of what happened. Down stays neutral
    // ink — red means irreversible, and riding less is not an error.
    final trendIcon = fraction > 0
        ? Icons.trending_up
        : (fraction < 0 ? Icons.trending_down : Icons.trending_flat);

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

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cx.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'THIS WEEK',
                style: TextStyle(
                  color: cx.textTertiary,
                  fontSize: kMinFontSize,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              // Expanded + right-align rather than Spacer + intrinsic width:
              // every trailing element here is text of unknown length, and on a
              // 353dp phone the strip has ~287dp to play with.
              if (stats.streakWeeks >= 2)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _StreakPill(weeks: stats.streakWeeks),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
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
                      fontSize: 34,
                      height: 1,
                      fontWeight: FontWeight.w700,
                      fontFeatures: kTabularFigures,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    unit.distanceLabel,
                    style: TextStyle(color: cx.textDim, fontSize: 14),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              if (delta != null)
                Expanded(
                  child: Row(
                    // Without `min` the nested Row claims the parent's whole
                    // width and pushes itself off the right edge.
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(
                        trendIcon,
                        size: 15,
                        color: up ? cx.positiveInk : cx.textDim,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          delta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: up ? cx.positiveInk : cx.textDim,
                            fontSize: kMinFontSize,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stats.isEmpty
                // An empty week is the one that most needs a sentence rather than
                // a row of zeros — that was F5's lesson on the idle screen.
                ? 'No rides yet this week.'
                : '${_ridesLabel(stats.rideCount)} · '
                    '${_fmtHours(stats.movingSeconds)} moving',
            style: TextStyle(color: cx.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _StreakPill extends StatelessWidget {
  const _StreakPill({required this.weeks});

  final int weeks;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cx.positive.withValues(alpha: cx.isDark ? 0.16 : 0.20),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department, size: 13, color: cx.positiveInk),
          const SizedBox(width: 4),
          // "wk", not "week": the pill shares a 287dp line with the section
          // label, and the full word is what pushed it off the edge.
          Text(
            '$weeks wk streak',
            style: TextStyle(
              color: cx.positiveInk,
              fontSize: kMinFontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
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
