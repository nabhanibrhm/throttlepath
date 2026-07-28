import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/route_blob.dart';
import 'package:throttlepath/core/route_key.dart';

/// Phase 4 route identity: the geohash + time-of-day key that groups repeats of a
/// journey, the names that read off it, and the downsampled shape a History card
/// draws.
void main() {
  group('geohash', () {
    test('matches the reference encoding', () {
      // The canonical worked example (Wikipedia / geohash.org): this coordinate
      // encodes to u4pruydqqvj, so any prefix of it must match too.
      expect(geohash(57.64911, 10.40744, precision: 11), 'u4pruydqqvj');
      expect(geohash(57.64911, 10.40744, precision: 5), 'u4pru');
      expect(geohash(0, 0, precision: 4), 's000');
    });

    test('defaults to the route-key precision', () {
      expect(geohash(57.64911, 10.40744).length, kRouteKeyPrecision);
    });

    test('two ends of the same street land in the same cell', () {
      // The whole point of 5 characters: parking 300 m away must not look like a
      // different route.
      final a = geohash(-6.9147, 107.6098); // Bandung city square
      final b = geohash(-6.9130, 107.6075); // ~300 m away
      expect(a, b);
    });

    test('different cities do not', () {
      expect(geohash(-6.9147, 107.6098), isNot(geohash(-6.2088, 106.8456)));
    });
  });

  group('RidePeriod', () {
    test('bands split at the hours a rider would name', () {
      RidePeriod at(int hour) => RidePeriod.of(DateTime(2026, 7, 28, hour));
      expect(at(0), RidePeriod.night);
      expect(at(4), RidePeriod.night);
      expect(at(5), RidePeriod.morning);
      expect(at(10), RidePeriod.morning);
      expect(at(11), RidePeriod.midday);
      expect(at(14), RidePeriod.midday);
      expect(at(15), RidePeriod.afternoon);
      expect(at(17), RidePeriod.afternoon);
      expect(at(18), RidePeriod.evening);
      expect(at(22), RidePeriod.evening);
      // Late evening wraps back to night, not forward past the end of the enum.
      expect(at(23), RidePeriod.night);
    });

    test('tags round-trip, and an unknown tag is null not a default', () {
      for (final p in RidePeriod.values) {
        expect(RidePeriod.fromTag(p.tag), p);
      }
      expect(RidePeriod.fromTag('brunch'), isNull);
      expect(RidePeriod.fromTag(null), isNull);
    });
  });

  group('buildRouteKey / parseRouteKey', () {
    final morning = DateTime(2026, 7, 28, 7, 30);

    test('encodes both endpoints and the period', () {
      final key = buildRouteKey(
        startTime: morning,
        startLat: -6.9147,
        startLon: 107.6098,
        endLat: -6.8160,
        endLon: 107.6170,
      );
      final parts = parseRouteKey(key)!;
      expect(parts.from, geohash(-6.9147, 107.6098));
      expect(parts.to, geohash(-6.8160, 107.6170));
      expect(parts.period, RidePeriod.morning);
    });

    test('the same journey at a different hour is a different route', () {
      String keyAt(DateTime t) => buildRouteKey(
            startTime: t,
            startLat: -6.9147,
            startLon: 107.6098,
            endLat: -6.8160,
            endLon: 107.6170,
          );
      expect(keyAt(morning), isNot(keyAt(DateTime(2026, 7, 28, 21))));
    });

    test('direction matters — the ride home is not the ride out', () {
      final out = buildRouteKey(
          startTime: morning,
          startLat: -6.9147,
          startLon: 107.6098,
          endLat: -6.8160,
          endLon: 107.6170);
      final back = buildRouteKey(
          startTime: morning,
          startLat: -6.8160,
          startLon: 107.6170,
          endLat: -6.9147,
          endLon: 107.6098);
      expect(out, isNot(back));
    });

    test('unparseable input yields null rather than a partial key', () {
      // A key read off a ride recorded by an older build is untrusted input.
      for (final junk in [null, '', 'nonsense', 'a>b', 'x@morning', '@']) {
        expect(parseRouteKey(junk), isNull, reason: 'for "$junk"');
      }
    });

    test('a loop is start cell == end cell', () {
      final loop = buildRouteKey(
          startTime: morning,
          startLat: -6.9147,
          startLon: 107.6098,
          endLat: -6.9130,
          endLon: 107.6075);
      expect(isLoopRoute(loop), isTrue);
      expect(isLoopRoute(null), isFalse);
      expect(
        isLoopRoute(buildRouteKey(
            startTime: morning,
            startLat: -6.9147,
            startLon: 107.6098,
            endLat: -6.8160,
            endLon: 107.6170)),
        isFalse,
      );
    });
  });

  group('rideNameSuggestions', () {
    final morning = DateTime(2026, 7, 28, 7, 30);

    test('always offers at least one usable name', () {
      final s = rideNameSuggestions(startTime: morning);
      expect(s, isNotEmpty);
      expect(s.first, 'Morning ride');
    });

    test('names the destination when it is known', () {
      final s = rideNameSuggestions(
          startTime: morning, startPlace: 'Bandung', endPlace: 'Lembang');
      expect(s.first, 'Morning ride to Lembang');
      expect(s, contains('Bandung → Lembang'));
    });

    test('a repeated route becomes a commute', () {
      final s = rideNameSuggestions(
        startTime: morning,
        startPlace: 'Bandung',
        endPlace: 'Cimahi',
        priorRidesOnRoute: kCommuteThreshold,
      );
      expect(s.first, 'Morning commute');
      // The plainer name stays available — not every repeat is a commute.
      expect(s, contains('Morning ride to Cimahi'));
    });

    test('one prior ride is not yet a routine', () {
      final s = rideNameSuggestions(
          startTime: morning, endPlace: 'Cimahi', priorRidesOnRoute: 1);
      expect(s.first, isNot('Morning commute'));
    });

    test('a loop is called a loop, by geometry or by name', () {
      expect(
        rideNameSuggestions(startTime: morning, isLoop: true).first,
        'Morning loop',
      );
      // Same locality at both ends means a loop even without the route key.
      expect(
        rideNameSuggestions(
                startTime: morning, startPlace: 'Dago', endPlace: 'dago')
            .first,
        'Morning loop from Dago',
      );
    });

    test('never repeats itself and never suggests blanks', () {
      final s = rideNameSuggestions(
        startTime: DateTime(2026, 7, 28, 19),
        startPlace: '  ',
        endPlace: '',
        priorRidesOnRoute: 5,
      );
      expect(s.toSet().length, s.length);
      expect(s.where((e) => e.trim().isEmpty), isEmpty);
      expect(s, contains('Evening ride'));
    });
  });

  group('encodeRouteBlob', () {
    List<RoutePoint> line(int n) =>
        [for (var i = 0; i < n; i++) (lat: -6.9 + i * 0.001, lon: 107.6)];

    test('nothing to draw returns null, not an empty list', () {
      expect(encodeRouteBlob(const []), isNull);
      expect(encodeRouteBlob([(lat: 1.0, lon: 2.0)]), isNull);
    });

    test('a short track is kept verbatim, interleaved', () {
      final blob = encodeRouteBlob([
        (lat: 1.5, lon: 2.5),
        (lat: 3.5, lon: 4.5),
      ]);
      expect(blob, [1.5, 2.5, 3.5, 4.5]);
    });

    test('respects the point budget on a long track', () {
      final blob = encodeRouteBlob(line(4000))!;
      expect(blob.length, lessThanOrEqualTo(kRouteBlobMaxPoints * 2));
      expect(blob.length.isEven, isTrue);
    });

    test('a straight line collapses to its endpoints', () {
      // The whole reason for RDP over a stride: redundant middles cost nothing.
      final blob = encodeRouteBlob(line(500))!;
      expect(blob.length, 4);
    });

    test('keeps the true first and last fix', () {
      final points = line(3000);
      final blob = encodeRouteBlob(points)!;
      expect(blob.first, points.first.lat);
      expect(blob[1], points.first.lon);
      expect(blob[blob.length - 2], points.last.lat);
      expect(blob.last, points.last.lon);
    });

    test('keeps a corner a uniform stride would drop', () {
      // 200 points north, one sharp jog east, 200 more north. A stride sampling
      // every 20th point has a good chance of stepping straight over the jog.
      final points = <RoutePoint>[
        for (var i = 0; i < 200; i++) (lat: -6.9 + i * 0.0001, lon: 107.6),
        (lat: -6.88, lon: 107.65),
        for (var i = 0; i < 200; i++)
          (lat: -6.88 + i * 0.0001, lon: 107.6),
      ];
      final decoded = decodeRouteBlob(encodeRouteBlob(points));
      expect(
        decoded.any((p) => (p.lon - 107.65).abs() < 1e-9),
        isTrue,
        reason: 'the corner should survive simplification',
      );
    });
  });

  group('decodeRouteBlob', () {
    test('treats missing or unusable blobs as nothing to draw', () {
      expect(decodeRouteBlob(null), isEmpty);
      expect(decodeRouteBlob(const []), isEmpty);
      // One pair is a dot, not a line.
      expect(decodeRouteBlob(const [1, 2]), isEmpty);
    });

    test('drops a trailing half-pair rather than throwing', () {
      // Defensive: a blob written by a future/older build is untrusted input.
      final points = decodeRouteBlob(const [1, 2, 3, 4, 5]);
      expect(points.length, 2);
      expect(points.last, (lat: 3.0, lon: 4.0));
    });
  });

  group('normalizeRoute', () {
    test('fits inside the unit square', () {
      final points = normalizeRoute([
        (lat: -6.90, lon: 107.60),
        (lat: -6.85, lon: 107.66),
        (lat: -6.88, lon: 107.62),
      ]);
      for (final p in points) {
        expect(p.x, inInclusiveRange(0, 1));
        expect(p.y, inInclusiveRange(0, 1));
      }
    });

    test('flips y so north is up on screen', () {
      final points = normalizeRoute([
        (lat: -7.0, lon: 107.6), // south
        (lat: -6.0, lon: 107.6), // north
      ]);
      expect(points.first.y, greaterThan(points.last.y));
    });

    test('a ride that never left one spot lands in the middle', () {
      final points = normalizeRoute([
        (lat: -6.9, lon: 107.6),
        (lat: -6.9, lon: 107.6),
      ]);
      expect(points.every((p) => p.x == 0.5 && p.y == 0.5), isTrue);
    });

    test('fills both axes, so a north-south ride still spans the box', () {
      // Aspect ratio is deliberately NOT preserved. In a ~290 × 44 dp card
      // sparkline, preserving it left a real Bekasi commute using a third of the
      // width; a sparkline is read on its pattern of turns, not its proportions.
      final points = normalizeRoute([
        (lat: -6.95, lon: 107.600),
        (lat: -6.90, lon: 107.601),
        (lat: -6.85, lon: 107.602),
      ]);
      expect(points.first.x, 0.0);
      expect(points.last.x, 1.0);
      expect(points.first.y, 1.0);
      expect(points.last.y, 0.0);
    });

    test('an axis with no extent is centred, not divided by zero', () {
      // A dead-straight due-east run has zero latitude span.
      final points = normalizeRoute([
        (lat: -6.9, lon: 107.60),
        (lat: -6.9, lon: 107.70),
      ]);
      expect(points.every((p) => p.y == 0.5), isTrue);
      expect(points.first.x, 0.0);
      expect(points.last.x, 1.0);
    });

    test('under two points there is nothing to normalize', () {
      expect(normalizeRoute(const []), isEmpty);
      expect(normalizeRoute([(lat: 1.0, lon: 2.0)]), isEmpty);
    });
  });
}
