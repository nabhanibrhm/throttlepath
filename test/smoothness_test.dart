import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/smoothness.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/services/route_derivation.dart';

/// Phase 6 — the smoothness score is the first *judgement* the app makes about
/// how someone rides, and it is persisted, so it has to be stable and explicable.
/// These pin the arithmetic, the gates that keep GPS artefacts out of it, and the
/// phrasing of the comparison sentence.

final _t0 = DateTime(2026, 7, 29, 8);

/// [count] readings [dtSeconds] apart, with speed produced by [speedAt].
List<SpeedReading> readings(
  int count, {
  double dtSeconds = 1.0,
  required double Function(int i) speedAt,
}) {
  return [
    for (var i = 0; i < count; i++)
      (
        time: _t0.add(
            Duration(milliseconds: (i * dtSeconds * 1000).round())),
        speedMps: speedAt(i),
      ),
  ];
}

TrackPoint point(int i, double speedMps, {double dtSeconds = 1.0}) => TrackPoint()
  ..rideId = 1
  ..latitude = -6.2 - i * 0.002
  ..longitude = 106.9
  ..speedMps = speedMps
  ..timestamp =
      _t0.add(Duration(milliseconds: (i * dtSeconds * 1000).round()));

void main() {
  group('scoring', () {
    test('a perfectly steady speed scores 100', () {
      final a = analyseSmoothness(readings(20, speedAt: (_) => 10));
      expect(a.samples, hasLength(19));
      expect(a.rmsMps2, closeTo(0, 1e-9));
      expect(a.score, 100);
      expect(a.band, 'very smooth');
    });

    test('a ±1 m/s per second oscillation lands mid-scale', () {
      // Alternating 10 / 11 m/s at 1 Hz is |a| = 1 every interval, so rms = 1,
      // which is half of kZeroScoreRms.
      final a = analyseSmoothness(
          readings(21, speedAt: (i) => i.isEven ? 10 : 11));
      expect(a.rmsMps2, closeTo(1.0, 1e-9));
      expect(a.score, closeTo(50, 1e-9));
      expect(a.band, 'mixed');
    });

    test('violent oscillation clamps at zero rather than going negative', () {
      final a = analyseSmoothness(
          readings(21, speedAt: (i) => i.isEven ? 0 : 20));
      expect(a.rmsMps2, greaterThan(kZeroScoreRms));
      expect(a.score, 0);
      expect(a.band, 'aggressive');
    });

    test('hard events are counted on both sides of the line', () {
      // +2 m/s² then −2 m/s², repeatedly: both past kHardEventMps2.
      final a = analyseSmoothness(
          readings(21, speedAt: (i) => i.isEven ? 10 : 12));
      expect(a.accelEvents, 10);
      expect(a.brakeEvents, 10);
      expect(a.maxAbsMps2, closeTo(2, 1e-9));
    });
  });

  group('gates', () {
    test('too few usable intervals scores null rather than guessing', () {
      final a = analyseSmoothness(readings(5, speedAt: (_) => 10));
      expect(a.samples, hasLength(4));
      expect(a.samples.length, lessThan(kMinSmoothnessSamples));
      expect(a.score, isNull);
      expect(a.band, 'unrated');
    });

    test('sub-half-second intervals are dropped as noise', () {
      // 0.2 s apart: a 1 m/s wobble here would read as 5 m/s² of "braking".
      final a = analyseSmoothness(
          readings(40, dtSeconds: 0.2, speedAt: (i) => i.isEven ? 10 : 11));
      expect(a.samples, isEmpty);
      expect(a.score, isNull);
    });

    test('gaps longer than ten seconds are dropped as pauses or blackouts', () {
      final a = analyseSmoothness(
          readings(20, dtSeconds: 30, speedAt: (i) => i * 1.0));
      expect(a.samples, isEmpty);
    });

    test('a single reading has nothing to compare against', () {
      expect(analyseSmoothness(readings(1, speedAt: (_) => 10)).score, isNull);
      expect(analyseSmoothness(const []).score, isNull);
    });
  });

  group('comparison phrasing', () {
    test('no history means no clause at all', () {
      // Rather than "smoother than 0 of your last 0 rides".
      expect(smoothnessComparison(80, const []), isNull);
    });

    test('a partial win counts the rides it beat', () {
      expect(
        smoothnessComparison(80, const [70, 60, 90]),
        'smoother than 2 of your last 3 rides',
      );
    });

    test('beating everything is phrased as a personal best', () {
      expect(
        smoothnessComparison(95, const [70, 60, 90]),
        'your smoothest of the last 4 rides',
      );
    });

    test('losing to everything says so plainly', () {
      expect(
        smoothnessComparison(50, const [70, 60, 90]),
        'rougher than all of your last 3 rides',
      );
    });

    test('a single prior ride is singular, not "1 of your last 1 rides"', () {
      expect(smoothnessComparison(80, const [70]),
          'smoother than your previous ride');
      expect(smoothnessComparison(60, const [70]),
          'rougher than your previous ride');
    });
  });

  group('what gets persisted', () {
    Ride ride({double meters = 15000}) => Ride()
      ..id = 1
      ..startTime = _t0
      ..endTime = _t0.add(const Duration(minutes: 30))
      ..totalDistanceMeters = meters;

    test('deriveRoute now carries a smoothness score', () {
      final points = [
        for (var i = 0; i < 20; i++) point(i, 10),
      ];
      final d = deriveRoute(ride(), points);
      expect(d.smoothness, 100);
      expect(d.key, isNotNull);
    });

    test('a ride under the route floor still gets scored', () {
      // The 200 m floor is about *where* you went, which a stationary wiggle
      // cannot claim. How smoothly you rode is a separate question, and a short
      // real ride can still answer it.
      final points = [for (var i = 0; i < 20; i++) point(i, 10)];
      final d = deriveRoute(ride(meters: 120), points);
      expect(d.key, isNull);
      expect(d.smoothness, 100);
    });

    test('a track too sparse to score derives a null, not a zero', () {
      // Zero would mean "ridden appallingly"; null means "we do not know". They
      // must not collapse into each other, because the score is compared against.
      final points = [for (var i = 0; i < 4; i++) point(i, 10)];
      expect(deriveRoute(ride(), points).smoothness, isNull);
    });
  });
}
