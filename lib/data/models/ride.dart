import 'package:isar_community/isar.dart';

part 'ride.g.dart';

/// A single completed (or in-progress) ride session.
///
/// One [Ride] owns many [TrackPoint]s, linked by [TrackPoint.rideId] == [id].
/// Aggregate stats are denormalised onto the ride so the summary UI never has
/// to scan the full point set.
@collection
class Ride {
  /// Auto-incrementing primary key assigned by Isar on first `put`.
  Id id = Isar.autoIncrement;

  /// When the ride started. Indexed for chronological "ride history" queries.
  @Index()
  late DateTime startTime;

  /// When the ride ended. Null while the ride is still being recorded.
  DateTime? endTime;

  /// User-given trip name, set when the rider saves the ride from the summary
  /// screen. Null until named (an unnamed, freshly-recorded ride). A discarded
  /// ride is deleted outright rather than left unnamed.
  String? name;

  /// Total distance travelled, in meters (Haversine-summed in the GPS engine).
  double totalDistanceMeters = 0;

  /// Total elapsed riding time (start→stop wall clock), in whole seconds.
  /// Strava's "Elapsed time".
  int durationSeconds = 0;

  /// Time spent actually moving (speed above the stop threshold), in whole
  /// seconds. Strava's "Moving time" — excludes stops at lights, breaks, etc.
  int movingSeconds = 0;

  /// Mean speed across the ride, in km/h.
  double averageSpeedKmh = 0;

  /// Peak speed reached during the ride, in km/h.
  double maxSpeedKmh = 0;

  /// Which GPS pipeline recorded this ride. New rides record with raw GNSS and
  /// stamp 'raw'; the field is retained mainly for diagnostics and history. Old
  /// rides may carry the retired 'fused' / 'fused_fast' tags (from the finished
  /// A/B test) or null (recorded before the tag existed).
  String? gpsSource;

  /// Human-readable place name reverse-geocoded from the ride's first GPS fix
  /// (e.g. "Bandung"). Null when geocoding hasn't run — old rides, or rides
  /// saved while offline (best-effort, online-only lookup).
  String? startPlace;

  /// Human-readable place name reverse-geocoded from the ride's last GPS fix
  /// (e.g. "Lembang"). Null under the same conditions as [startPlace].
  String? endPlace;

  /// Links this ride to a [Trip] as one of its stints, by [Trip.id]. Null for a
  /// standalone ride (the default). Indexed so a trip's stints can be fetched
  /// cheaply by trip id. Additive — old rides read as null.
  @Index()
  int? tripId;

  /// Coarse identity of "this route at this time of day" — a deliberately fuzzy
  /// key that groups repeats of the same journey. Built by `buildRouteKey` from a
  /// 5-character geohash of the start and end fixes (~±2.4 km, so parking in a
  /// different spot still matches) plus a time-of-day bucket, e.g.
  /// `qqguw>qqgv2@morning`.
  ///
  /// Indexed because it is the join key for everything route-aware: auto-naming
  /// ("Morning commute" once a route repeats), personal bests scoped to a route,
  /// and "your fastest on this route". Null for rides recorded before the key
  /// existed and for rides with no usable fixes — always treat null as "unknown
  /// route", never as a route in its own right.
  @Index()
  String? routeKey;

  /// The ride's shape, downsampled to at most `kRouteBlobMaxPoints` fixes and
  /// stored as a flat interleaved `[lat, lon, lat, lon, …]` list — the sparkline
  /// a History card draws without touching the (potentially thousands of rows)
  /// `TrackPoint` collection.
  ///
  /// Denormalised on purpose: a list row must not cost a query. Null for old
  /// rides until the route backfill fills it in, and for rides with fewer than
  /// two fixes (nothing to draw).
  List<double>? routeBlob;

  /// Ride smoothness on a 0–100 scale, derived from acceleration/braking
  /// variance. Reserved by the Phase 4 migration and **written by Phase 6** — the
  /// alternative was loading ten full tracks every time the analysis screen
  /// opened. Null on every ride until then.
  double? smoothness;

  /// Typical cornering lean, in degrees — the 95th percentile of the ride's
  /// estimated lean samples.
  ///
  /// A percentile rather than the maximum on purpose: the two largest raw maxima
  /// in the whole recorded history belong to the GPS-blackout train rides, where
  /// the heading discontinuity across the dead zone manufactures a corner that
  /// never happened. See `docs/lean-angle-design.md`. Null until Phase 2 writes
  /// it, and on any ride whose track is too sparse or too slow to estimate from.
  double? leanP95Degrees;

  /// The largest lean the ride can actually support, in degrees — a peak
  /// corroborated by consecutive samples, with blackout-adjacent ones excluded.
  ///
  /// Stored alongside [leanP95Degrees] because these are the two numbers worth
  /// comparing *across* rides; the band histogram the analysis tab draws is
  /// recomputed from the track it has already loaded rather than persisted.
  double? leanPeakDegrees;

  /// Which revision of the derivation rules produced the fields above.
  ///
  /// Null on every ride written before this existed. The backfill re-derives
  /// anything below `kDerivedVersion`, which is the only way a ride whose fields
  /// are *present but stale* ever gets revisited — the work-list used to ask
  /// "is anything null", and a wrong blob is not null. Bump the constant
  /// whenever a change to `route_derivation.dart` would produce different
  /// output for the same track.
  int? derivedVersion;
}
