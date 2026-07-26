import 'models/ride.dart';

/// Combined + per-leg aggregate stats for a multi-leg trip, computed purely
/// from its leg [Ride]s. Pure (no Isar / IO) so it is trivially unit-testable
/// and reusable by the summary UI and the share card.
///
/// **Core guarantee:** the reported trip time is the SUM of each leg's own
/// recorded time. Every inter-leg gap (minutes or days between legs) is excluded
/// by construction, because legs are separate recordings — nothing is ever
/// counted between the end of one leg and the start of the next.
class TripStats {
  /// The trip's legs, ordered by [Ride.startTime] (oldest first). Unmodifiable.
  final List<Ride> legs;

  /// Summed distance across all legs, in meters.
  final double totalDistanceMeters;

  /// Summed elapsed-minus-paused time across all legs, in whole seconds.
  /// Mirrors each leg's [Ride.durationSeconds].
  final int durationSeconds;

  /// Summed moving time across all legs, in whole seconds.
  /// Mirrors each leg's [Ride.movingSeconds].
  final int movingSeconds;

  /// Combined average speed, in km/h: total distance ÷ total duration — NOT the
  /// mean of the per-leg averages. Uses [durationSeconds] to match exactly how a
  /// single ride's average is computed (see `tracking_service.dart`).
  final double averageSpeedKmh;

  /// Peak speed across all legs (the max of each leg's max), in km/h.
  final double maxSpeedKmh;

  const TripStats._({
    required this.legs,
    required this.totalDistanceMeters,
    required this.durationSeconds,
    required this.movingSeconds,
    required this.averageSpeedKmh,
    required this.maxSpeedKmh,
  });

  /// Number of legs in the trip.
  int get legCount => legs.length;

  /// True when the trip has no legs.
  bool get isEmpty => legs.isEmpty;

  /// Start of the first leg, or null if the trip has no legs.
  DateTime? get startTime => legs.isEmpty ? null : legs.first.startTime;

  /// End of the last leg, or null if the trip has no legs or that leg is still
  /// recording (its [Ride.endTime] is null).
  DateTime? get endTime => legs.isEmpty ? null : legs.last.endTime;

  /// Computes combined stats from [rides] (a trip's legs, in any order — they
  /// are sorted by [Ride.startTime] internally).
  factory TripStats.fromLegs(Iterable<Ride> rides) {
    final legs = rides.toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    var distance = 0.0;
    var duration = 0;
    var moving = 0;
    var maxSpeed = 0.0;
    for (final r in legs) {
      distance += r.totalDistanceMeters;
      duration += r.durationSeconds;
      moving += r.movingSeconds;
      if (r.maxSpeedKmh > maxSpeed) maxSpeed = r.maxSpeedKmh;
    }

    return TripStats._(
      legs: List.unmodifiable(legs),
      totalDistanceMeters: distance,
      durationSeconds: duration,
      movingSeconds: moving,
      averageSpeedKmh: duration > 0 ? (distance / duration) * 3.6 : 0.0,
      maxSpeedKmh: maxSpeed,
    );
  }

  /// Synthesises an in-memory combined [Ride] spanning all legs, so the existing
  /// summary / share-card widgets (which read stats straight off a `Ride`) can
  /// render a whole trip unchanged. Not persisted — it has no assigned id and is
  /// never `put`. [tripId] and [name] come from the owning [Trip].
  Ride toCombinedRide({int? tripId, String? name}) {
    return Ride()
      ..startTime = startTime ?? DateTime.fromMillisecondsSinceEpoch(0)
      ..endTime = endTime
      ..name = name
      ..tripId = tripId
      ..totalDistanceMeters = totalDistanceMeters
      ..durationSeconds = durationSeconds
      ..movingSeconds = movingSeconds
      ..averageSpeedKmh = averageSpeedKmh
      ..maxSpeedKmh = maxSpeedKmh
      ..gpsSource = 'trip'
      ..startPlace = legs.isEmpty ? null : legs.first.startPlace
      ..endPlace = legs.isEmpty ? null : legs.last.endPlace;
  }
}
