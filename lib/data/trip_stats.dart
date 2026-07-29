import 'models/ride.dart';

/// Combined + per-stint aggregate stats for a multi-stint trip, computed purely
/// from its stint [Ride]s. Pure (no Isar / IO) so it is trivially unit-testable
/// and reusable by the summary UI and the share card.
///
/// **Core guarantee:** the reported trip time is the SUM of each stint's own
/// recorded time. Every inter-stint gap (minutes or days between stints) is excluded
/// by construction, because stints are separate recordings — nothing is ever
/// counted between the end of one stint and the start of the next.
class TripStats {
  /// The trip's stints, ordered by [Ride.startTime] (oldest first). Unmodifiable.
  final List<Ride> stints;

  /// Summed distance across all stints, in meters.
  final double totalDistanceMeters;

  /// Summed elapsed-minus-paused time across all stints, in whole seconds.
  /// Mirrors each stint's [Ride.durationSeconds].
  final int durationSeconds;

  /// Summed moving time across all stints, in whole seconds.
  /// Mirrors each stint's [Ride.movingSeconds].
  final int movingSeconds;

  /// Combined average speed, in km/h: total distance ÷ total duration — NOT the
  /// mean of the per-stint averages. Uses [durationSeconds] to match exactly how a
  /// single ride's average is computed (see `tracking_service.dart`).
  final double averageSpeedKmh;

  /// Peak speed across all stints (the max of each stint's max), in km/h.
  final double maxSpeedKmh;

  const TripStats._({
    required this.stints,
    required this.totalDistanceMeters,
    required this.durationSeconds,
    required this.movingSeconds,
    required this.averageSpeedKmh,
    required this.maxSpeedKmh,
  });

  /// Number of stints in the trip.
  int get stintCount => stints.length;

  /// True when the trip has no stints.
  bool get isEmpty => stints.isEmpty;

  /// Start of the first stint, or null if the trip has no stints.
  DateTime? get startTime => stints.isEmpty ? null : stints.first.startTime;

  /// End of the last stint, or null if the trip has no stints or that stint is still
  /// recording (its [Ride.endTime] is null).
  DateTime? get endTime => stints.isEmpty ? null : stints.last.endTime;

  /// Computes combined stats from [rides] (a trip's stints, in any order — they
  /// are sorted by [Ride.startTime] internally).
  factory TripStats.fromStints(Iterable<Ride> rides) {
    final stints = rides.toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    var distance = 0.0;
    var duration = 0;
    var moving = 0;
    var maxSpeed = 0.0;
    for (final r in stints) {
      distance += r.totalDistanceMeters;
      duration += r.durationSeconds;
      moving += r.movingSeconds;
      if (r.maxSpeedKmh > maxSpeed) maxSpeed = r.maxSpeedKmh;
    }

    return TripStats._(
      stints: List.unmodifiable(stints),
      totalDistanceMeters: distance,
      durationSeconds: duration,
      movingSeconds: moving,
      averageSpeedKmh: duration > 0 ? (distance / duration) * 3.6 : 0.0,
      maxSpeedKmh: maxSpeed,
    );
  }

  /// Synthesises an in-memory combined [Ride] spanning all stints, so the existing
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
      ..startPlace = stints.isEmpty ? null : stints.first.startPlace
      ..endPlace = stints.isEmpty ? null : stints.last.endPlace;
  }
}
