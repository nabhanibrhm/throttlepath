import 'package:isar_community/isar.dart';

part 'trip.g.dart';

/// A journey made of one or more ordered stints (each stint is a [Ride]).
///
/// A stint links back via [Ride.tripId] == [id]; stints are ordered by their
/// [Ride.startTime]. A standalone ride carries no [Ride.tripId].
///
/// Lifecycle: a trip stays *open* (continuable) until the rider finishes it.
/// [finishedAt] == null means open; setting it back to null reopens the trip.
/// Because each stint is a separate, self-contained recording, the inter-stint gaps
/// (minutes or days) never enter the trip's totals — see [TripStats].
@collection
class Trip {
  /// Auto-incrementing primary key assigned by Isar on first `put`.
  Id id = Isar.autoIncrement;

  /// User-given trip name. Null until named (e.g. a freshly-created open trip).
  String? name;

  /// When the trip was created (its first stint). Indexed for history ordering.
  @Index()
  late DateTime createdAt;

  /// When the rider finished the trip. Null while the trip is still open and
  /// continuable; reopening a finished trip sets this back to null.
  DateTime? finishedAt;

  /// True while the trip is open (continuable). Not persisted.
  @ignore
  bool get isOpen => finishedAt == null;
}
