import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/ride_stats.dart';
import 'package:throttlepath/ui/week_strip.dart';

/// Phase 5 aggregates and Phase 4 records: the week strip's arithmetic, the
/// lifetime/per-route bests, and the rules that decide when a ride earned a badge.
Ride ride({
  required DateTime start,
  double meters = 10000,
  int duration = 1800,
  int moving = 1500,
  double avg = 20,
  double max = 60,
  int id = 0,
}) {
  return Ride()
    ..id = id
    ..startTime = start
    ..endTime = start.add(Duration(seconds: duration))
    ..totalDistanceMeters = meters
    ..durationSeconds = duration
    ..movingSeconds = moving
    ..averageSpeedKmh = avg
    ..maxSpeedKmh = max;
}

void main() {
  group('weekStartOf', () {
    test('is the local Monday at midnight', () {
      // 2026-07-28 is a Tuesday; its week starts Monday the 27th.
      final start = weekStartOf(DateTime(2026, 7, 28, 15, 42));
      expect(start, DateTime(2026, 7, 27));
      expect(start.weekday, DateTime.monday);
    });

    test('Sunday belongs to the week that began six days earlier', () {
      // The trap: treating Sunday as the start would move every weekend ride
      // into the following week's totals.
      expect(weekStartOf(DateTime(2026, 8, 2, 23, 59)), DateTime(2026, 7, 27));
    });

    test('is idempotent', () {
      final a = weekStartOf(DateTime(2026, 7, 30));
      expect(weekStartOf(a), a);
    });
  });

  group('WeekStats', () {
    final now = DateTime(2026, 7, 28, 12); // Tuesday
    final thisWeek = DateTime(2026, 7, 27);

    test('sums only the current week into the headline figures', () {
      final stats = WeekStats.from([
        ride(start: thisWeek.add(const Duration(days: 1)), meters: 30000),
        ride(start: thisWeek.add(const Duration(hours: 8)), meters: 12000),
        // Last week — counted as the baseline, never in the total.
        ride(start: thisWeek.subtract(const Duration(days: 3)), meters: 50000),
      ], now);

      expect(stats.distanceMeters, 42000);
      expect(stats.rideCount, 2);
      expect(stats.previousDistanceMeters, 50000);
      expect(stats.weekStart, thisWeek);
    });

    test('a ride is filed by the week it started in', () {
      // A Sunday-night ride that rolls past midnight must not be split, or land
      // in the next week entirely.
      final stats = WeekStats.from(
        [ride(start: DateTime(2026, 7, 26, 23, 30), duration: 3600)],
        now,
      );
      expect(stats.rideCount, 0, reason: 'that ride belongs to the prior week');
      expect(stats.previousDistanceMeters, 10000);
    });

    test('delta reads as a fraction, and is null against an empty week', () {
      final up = WeekStats.from([
        ride(start: thisWeek, meters: 22000),
        ride(start: thisWeek.subtract(const Duration(days: 2)), meters: 20000),
      ], now);
      expect(up.deltaMeters, 2000);
      expect(up.deltaFraction, closeTo(0.1, 1e-9));

      // "+∞% vs last week" is not a stat.
      final noBaseline = WeekStats.from([ride(start: thisWeek)], now);
      expect(noBaseline.deltaFraction, isNull);
    });

    test('streak counts consecutive weeks back from this one', () {
      final stats = WeekStats.from([
        ride(start: thisWeek),
        ride(start: thisWeek.subtract(const Duration(days: 7))),
        ride(start: thisWeek.subtract(const Duration(days: 14))),
        // Gap at 3 weeks back, then more rides — which must NOT extend the run.
        ride(start: thisWeek.subtract(const Duration(days: 28))),
      ], now);
      expect(stats.streakWeeks, 3);
    });

    test('an empty current week does not break a real streak', () {
      // Every Monday morning the current week is empty. Resetting the streak
      // there would make it unreachable for anyone who rides on weekends.
      final stats = WeekStats.from([
        ride(start: thisWeek.subtract(const Duration(days: 7))),
        ride(start: thisWeek.subtract(const Duration(days: 14))),
      ], now);
      expect(stats.rideCount, 0);
      expect(stats.isEmpty, isTrue);
      expect(stats.streakWeeks, 2);
    });

    test('no history at all is zero everything, not a crash', () {
      final stats = WeekStats.emptyFor(now);
      expect(stats.rideCount, 0);
      expect(stats.streakWeeks, 0);
      expect(stats.deltaFraction, isNull);
      expect(stats.weekStart, thisWeek);
    });
  });

  group('WeekStrip formatting', () {
    final now = DateTime(2026, 7, 28, 12);
    final thisWeek = DateTime(2026, 7, 27);

    test('drops the decimal once the number gets long', () {
      final small = WeekStats.from([ride(start: thisWeek, meters: 42300)], now);
      expect(WeekStrip.distanceText(small, SpeedUnit.kmh), '42.3 km');
      final big = WeekStats.from([ride(start: thisWeek, meters: 240000)], now);
      expect(WeekStrip.distanceText(big, SpeedUnit.kmh), '240 km');
    });

    test('converts for the active unit', () {
      final stats = WeekStats.from([ride(start: thisWeek, meters: 10000)], now);
      expect(WeekStrip.distanceText(stats, SpeedUnit.mph), '6.2 mi');
    });

    test('the delta is signed with a real minus sign', () {
      final down = WeekStats.from([
        ride(start: thisWeek, meters: 9000),
        ride(start: thisWeek.subtract(const Duration(days: 2)), meters: 10000),
      ], now);
      // A hyphen next to a digit at 12sp reads as part of the number.
      expect(WeekStrip.deltaText(down), '−10% vs last week');

      final up = WeekStats.from([
        ride(start: thisWeek, meters: 11000),
        ride(start: thisWeek.subtract(const Duration(days: 2)), meters: 10000),
      ], now);
      expect(WeekStrip.deltaText(up), '+10% vs last week');
    });

    test('an unchanged week says so instead of "+0%"', () {
      final level = WeekStats.from([
        ride(start: thisWeek, meters: 10000),
        ride(start: thisWeek.subtract(const Duration(days: 2)), meters: 10000),
      ], now);
      expect(WeekStrip.deltaText(level), 'level with last week');
    });

    test('no baseline means no delta line at all', () {
      expect(
        WeekStrip.deltaText(WeekStats.from([ride(start: thisWeek)], now)),
        isNull,
      );
    });
  });

  group('RiderStats', () {
    test('reduces to bests and an average', () {
      final stats = RiderStats.from([
        ride(start: DateTime(2026, 7, 1), meters: 10000, avg: 20, duration: 1800),
        ride(start: DateTime(2026, 7, 2), meters: 30000, avg: 45, duration: 3600),
        ride(start: DateTime(2026, 7, 3), meters: 20000, avg: 30, duration: 2400),
      ]);
      expect(stats.rideCount, 3);
      expect(stats.totalDistanceMeters, 60000);
      expect(stats.longestDistanceMeters, 30000);
      expect(stats.bestAvgSpeedKmh, 45);
      expect(stats.longestDurationSeconds, 3600);
      expect(stats.avgDistanceMeters, 20000);
    });

    test('an empty history has no average to report', () {
      expect(RiderStats.from(const []).avgDistanceMeters, isNull);
      expect(RiderStats.empty.avgDistanceMeters, isNull);
    });
  });

  group('RouteStats', () {
    test('the best time on a route is the shortest moving time', () {
      final stats = RouteStats.from([
        ride(start: DateTime(2026, 7, 1), moving: 1800, avg: 20),
        ride(start: DateTime(2026, 7, 8), moving: 1500, avg: 26),
      ]);
      expect(stats.priorRideCount, 2);
      expect(stats.bestMovingSeconds, 1500);
      expect(stats.bestAvgSpeedKmh, 26);
      expect(stats.isNewRoute, isFalse);
    });

    test('a ride with no moving time cannot hold the record', () {
      // Stationary test recordings would otherwise take every route record at
      // zero seconds and never give it back.
      final stats = RouteStats.from([
        ride(start: DateTime(2026, 7, 1), moving: 0),
        ride(start: DateTime(2026, 7, 8), moving: 1500),
      ]);
      expect(stats.bestMovingSeconds, 1500);
    });

    test('a route nobody has ridden is empty, not zeroed bests', () {
      expect(RouteStats.from(const []).isNewRoute, isTrue);
      expect(RouteStats.empty.priorRideCount, 0);
    });
  });

  group('awardsFor', () {
    final history = RiderStats.from([
      ride(start: DateTime(2026, 7, 1), meters: 30000, avg: 40, duration: 3600),
    ]);

    test('a ride that beats everything sweeps the board', () {
      final awards = awardsFor(
        ride(start: DateTime(2026, 7, 28), meters: 60000, avg: 55, duration: 7200),
        rider: history,
      );
      expect(awards, contains(RideAward.longestDistance));
      expect(awards, contains(RideAward.fastestAverage));
      expect(awards, contains(RideAward.longestTime));
    });

    test('matching a best is not beating it', () {
      // Re-judging a saved ride against a history that (nearly) contains it must
      // not keep re-awarding the same record.
      final awards = awardsFor(
        ride(start: DateTime(2026, 7, 28), meters: 30000, avg: 40, duration: 3600),
        rider: history,
      );
      expect(awards, isEmpty);
    });

    test('a first ride wins nothing — there was nothing to beat', () {
      final awards = awardsFor(
        ride(start: DateTime(2026, 7, 28), meters: 99000, avg: 90, duration: 9000),
        rider: RiderStats.empty,
      );
      expect(awards, isEmpty);
    });

    test('a trivial recording cannot hold a record', () {
      // Otherwise the first 30 m test ride is crowned "longest yet" forever.
      final awards = awardsFor(
        ride(start: DateTime(2026, 7, 28), meters: 30, avg: 200, duration: 20),
        rider: history,
      );
      expect(awards, isEmpty);
    });

    test('the route record needs a route with history and real moving time', () {
      final subject =
          ride(start: DateTime(2026, 7, 28), meters: 30000, moving: 1200);
      expect(
        awardsFor(subject, rider: history, route: RouteStats.empty),
        isNot(contains(RideAward.fastestOnRoute)),
      );
      expect(
        awardsFor(
          subject,
          rider: history,
          route: RouteStats.from([
            ride(start: DateTime(2026, 7, 1), moving: 1500),
          ]),
        ),
        contains(RideAward.fastestOnRoute),
      );
      // Slower than the standing time — no award.
      expect(
        awardsFor(
          ride(start: DateTime(2026, 7, 28), meters: 30000, moving: 1800),
          rider: history,
          route: RouteStats.from([
            ride(start: DateTime(2026, 7, 1), moving: 1500),
          ]),
        ),
        isNot(contains(RideAward.fastestOnRoute)),
      );
    });

    test('every award has text a rider would read as an achievement', () {
      for (final a in RideAward.values) {
        expect(a.label, isNotEmpty);
        expect(a.label, isNot(contains('_')));
      }
    });
  });

  group('distanceVsAverage', () {
    test('reports the signed fraction', () {
      final rider = RiderStats.from([
        ride(start: DateTime(2026, 7, 1), meters: 10000),
        ride(start: DateTime(2026, 7, 2), meters: 20000),
      ]);
      expect(
        distanceVsAverage(ride(start: DateTime(2026, 7, 28), meters: 18000),
            rider),
        closeTo(0.2, 1e-9),
      );
      expect(
        distanceVsAverage(
            ride(start: DateTime(2026, 7, 28), meters: 12000), rider),
        closeTo(-0.2, 1e-9),
      );
    });

    test('no history means no comparison to make', () {
      expect(
        distanceVsAverage(
            ride(start: DateTime(2026, 7, 28)), RiderStats.empty),
        isNull,
      );
    });

    test('a ride too short to compare gets no comparison', () {
      // Caught on the device: 26 m against a 14 km average rendered as "100%
      // shorter than your average", which is arithmetically right and nonsense —
      // 100% shorter is zero distance.
      final rider = RiderStats.from([
        ride(start: DateTime(2026, 7, 1), meters: 14000),
      ]);
      expect(
        distanceVsAverage(
            ride(start: DateTime(2026, 7, 28), meters: 26), rider),
        isNull,
      );
      // Just over the floor still compares, and never reaches 100%.
      final f = distanceVsAverage(
          ride(start: DateTime(2026, 7, 28), meters: 1001), rider);
      expect(f, isNotNull);
      expect(f!.abs(), lessThan(1.0));
    });
  });
}
