import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/trip_stats.dart';

/// Builds a completed stint with denormalised stats (as `tracking_service` would
/// have written them). [start] fixes ordering; [durationS] is elapsed-minus-
/// paused seconds, matching how a real ride's average is derived.
Ride _leg({
  required DateTime start,
  DateTime? end,
  double distanceM = 0,
  int durationS = 0,
  int movingS = 0,
  double avgKmh = 0,
  double maxKmh = 0,
  String? startPlace,
  String? endPlace,
}) {
  return Ride()
    ..startTime = start
    ..endTime = end ?? start.add(Duration(seconds: durationS))
    ..totalDistanceMeters = distanceM
    ..durationSeconds = durationS
    ..movingSeconds = movingS
    ..averageSpeedKmh = avgKmh
    ..maxSpeedKmh = maxKmh
    ..startPlace = startPlace
    ..endPlace = endPlace;
}

void main() {
  final t0 = DateTime(2026, 7, 25, 8);

  group('TripStats.fromStints', () {
    test('empty trip is empty with zeroed totals', () {
      final s = TripStats.fromStints(const []);
      expect(s.isEmpty, isTrue);
      expect(s.stintCount, 0);
      expect(s.totalDistanceMeters, 0);
      expect(s.durationSeconds, 0);
      expect(s.movingSeconds, 0);
      expect(s.averageSpeedKmh, 0);
      expect(s.maxSpeedKmh, 0);
      expect(s.startTime, isNull);
      expect(s.endTime, isNull);
    });

    test('sums distance, duration and moving time across stints', () {
      final s = TripStats.fromStints([
        _leg(start: t0, distanceM: 10000, durationS: 1200, movingS: 1000),
        _leg(
          start: t0.add(const Duration(hours: 4)),
          distanceM: 5000,
          durationS: 600,
          movingS: 550,
        ),
      ]);
      expect(s.stintCount, 2);
      expect(s.totalDistanceMeters, 15000);
      expect(s.durationSeconds, 1800);
      expect(s.movingSeconds, 1550);
    });

    test('the 4-hour gap between stints never enters the total time', () {
      // Two 10-minute stints 4 hours apart: trip time must be 20 min, not 4h20.
      final s = TripStats.fromStints([
        _leg(
          start: t0,
          end: t0.add(const Duration(minutes: 10)),
          durationS: 600,
          movingS: 600,
        ),
        _leg(
          start: t0.add(const Duration(hours: 4)),
          end: t0.add(const Duration(hours: 4, minutes: 10)),
          durationS: 600,
          movingS: 600,
        ),
      ]);
      expect(s.durationSeconds, 1200); // 20 minutes, gap excluded by construction
    });

    test('average is combined distance ÷ combined duration, not mean of avgs', () {
      // Stint A: 3600 m in 3600 s -> 3.6 km/h. Stint B: 36000 m in 3600 s -> 36 km/h.
      // Mean of per-stint avgs would be 19.8; correct combined = 39600m/7200s*3.6.
      final s = TripStats.fromStints([
        _leg(start: t0, distanceM: 3600, durationS: 3600, avgKmh: 3.6),
        _leg(
          start: t0.add(const Duration(hours: 2)),
          distanceM: 36000,
          durationS: 3600,
          avgKmh: 36,
        ),
      ]);
      expect(s.averageSpeedKmh, closeTo(19.8, 1e-9));
      // Same formula the tracking service uses for a single ride.
      expect(s.averageSpeedKmh, closeTo((39600 / 7200) * 3.6, 1e-9));
    });

    test('max speed is the max of per-stint maxima', () {
      final s = TripStats.fromStints([
        _leg(start: t0, maxKmh: 88),
        _leg(start: t0.add(const Duration(hours: 1)), maxKmh: 142),
        _leg(start: t0.add(const Duration(hours: 2)), maxKmh: 97),
      ]);
      expect(s.maxSpeedKmh, 142);
    });

    test('stints are ordered by start time regardless of input order', () {
      final first = _leg(start: t0, startPlace: 'Bandung');
      final middle = _leg(start: t0.add(const Duration(hours: 3)));
      final last = _leg(
        start: t0.add(const Duration(hours: 6)),
        end: t0.add(const Duration(hours: 6, minutes: 30)),
        endPlace: 'Lembang',
      );
      final s = TripStats.fromStints([last, first, middle]);
      expect(s.stints.map((r) => r.startTime).toList(),
          [first.startTime, middle.startTime, last.startTime]);
      expect(s.startTime, first.startTime);
      expect(s.endTime, last.endTime);
    });

    test('endTime is null when the last stint is still recording', () {
      final s = TripStats.fromStints([
        _leg(
          start: t0,
          end: t0.add(const Duration(minutes: 10)),
          durationS: 600,
        ),
        Ride()..startTime = t0.add(const Duration(hours: 1)), // endTime null
      ]);
      expect(s.endTime, isNull);
      expect(s.startTime, t0);
    });

    test('stints list is unmodifiable', () {
      final s = TripStats.fromStints([_leg(start: t0)]);
      expect(() => s.stints.add(_leg(start: t0)), throwsUnsupportedError);
    });
  });

  group('TripStats.toCombinedRide', () {
    test('carries summed stats, span, endpoints and trip identity', () {
      final s = TripStats.fromStints([
        _leg(
          start: t0,
          end: t0.add(const Duration(minutes: 10)),
          distanceM: 3600,
          durationS: 600,
          movingS: 550,
          maxKmh: 60,
          startPlace: 'Bandung',
        ),
        _leg(
          start: t0.add(const Duration(hours: 4)),
          end: t0.add(const Duration(hours: 4, minutes: 10)),
          distanceM: 3600,
          durationS: 600,
          movingS: 500,
          maxKmh: 80,
          endPlace: 'Lembang',
        ),
      ]);
      final combined = s.toCombinedRide(tripId: 7, name: 'Weekend loop');

      expect(combined.tripId, 7);
      expect(combined.name, 'Weekend loop');
      expect(combined.totalDistanceMeters, 7200);
      expect(combined.durationSeconds, 1200);
      expect(combined.movingSeconds, 1050);
      expect(combined.maxSpeedKmh, 80);
      expect(combined.averageSpeedKmh, closeTo((7200 / 1200) * 3.6, 1e-9));
      expect(combined.startTime, t0);
      expect(combined.endTime, t0.add(const Duration(hours: 4, minutes: 10)));
      expect(combined.startPlace, 'Bandung'); // first stint's origin
      expect(combined.endPlace, 'Lembang'); // last stint's destination
      expect(combined.gpsSource, 'trip');
    });
  });
}
