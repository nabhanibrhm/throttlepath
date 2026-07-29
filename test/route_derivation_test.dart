import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/route_blob.dart';
import 'package:throttlepath/core/route_key.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/services/route_derivation.dart';

/// What gets stamped on a ride at the moment its track is complete. Pure geometry
/// over (ride, points), so no DB is involved.
TrackPoint point(double lat, double lon, {DateTime? at}) => TrackPoint()
  ..rideId = 1
  ..latitude = lat
  ..longitude = lon
  ..speedMps = 10
  ..timestamp = at ?? DateTime(2026, 7, 28, 7, 30);

Ride ride({double meters = 15000, DateTime? start}) => Ride()
  ..id = 1
  ..startTime = start ?? DateTime(2026, 7, 28, 7, 30)
  ..endTime = (start ?? DateTime(2026, 7, 28, 7, 30))
      .add(const Duration(minutes: 30))
  ..totalDistanceMeters = meters;

void main() {
  final commute = [
    point(-6.3130, 106.9906),
    point(-6.2800, 106.9900),
    point(-6.2313, 106.9850),
  ];

  test('a real ride gets both a key and a shape', () {
    final d = deriveRoute(ride(), commute);
    expect(d.key, isNotNull);
    expect(parseRouteKey(d.key)!.period, RidePeriod.morning);
    expect(decodeRouteBlob(d.blob).length, greaterThanOrEqualTo(2));
  });

  test('a ride under the route floor gets a shape but no key', () {
    // Caught on the device: a 26 m stationary recording was stamped with a key
    // (start and end in the same coarse cell), joined that route's history, and
    // the summary announced "ridden this route once before".
    final d = deriveRoute(ride(meters: 26), commute);
    expect(d.key, isNull, reason: 'standing still is not a route');
    expect(d.blob, isNotNull, reason: 'the shape is free to keep');
  });

  test('the floor is exactly kRouteMinDistanceMeters', () {
    expect(deriveRoute(ride(meters: kRouteMinDistanceMeters - 1), commute).key,
        isNull);
    expect(
        deriveRoute(ride(meters: kRouteMinDistanceMeters), commute).key,
        isNotNull);
  });

  test('a track with fewer than two fixes derives nothing at all', () {
    expect(deriveRoute(ride(), const []).key, isNull);
    expect(deriveRoute(ride(), const []).blob, isNull);
    expect(deriveRoute(ride(), [point(-6.3, 106.9)]).blob, isNull);
  });

  test('the key follows the ride start time, not the fix timestamps', () {
    // A stint recorded across a band boundary must be filed by when it *started* —
    // otherwise the same commute lands in two different route buckets.
    final evening = deriveRoute(
      ride(start: DateTime(2026, 7, 28, 19)),
      commute,
    );
    expect(parseRouteKey(evening.key)!.period, RidePeriod.evening);
  });
}
