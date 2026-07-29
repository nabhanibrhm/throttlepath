import '../core/route_blob.dart';
import '../core/route_key.dart';
import '../core/smoothness.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';

/// Derives a ride's `routeKey` + `routeBlob` + `smoothness` from its track, and
/// backfills the rides that predate those fields.
///
/// All three live here rather than on the engine so the backfill doesn't have to
/// import `flutter_background_service`, and so the actual derivation stays a pure
/// function of (ride, points) that a test can call without a DB.

/// Below this a recording has no route to speak of, so it gets no `routeKey`.
///
/// Found on the device: a 26 m stationary test was stamped with a key (start and
/// end land in the same coarse cell), joined that "route"'s history, and the
/// summary then told the rider they had "ridden this route once before". A key is
/// a claim about where you went; standing still is not a place you went. The
/// *shape* is still stored — a blob costs nothing and is simply too small to draw.
const double kRouteMinDistanceMeters = 200;

/// Smoothness scored from [points]' speed trace, or null when the track is too
/// sparse to say anything (see `kMinSmoothnessSamples`).
double? deriveSmoothness(List<TrackPoint> points) =>
    analyseSmoothness([
      for (final p in points) (time: p.timestamp, speedMps: p.speedMps),
    ]).score;

/// The derived fields for a ride with [points] as its track.
///
/// Returns a null key for a track too short to have a shape or a ride too short
/// to have a route — a degenerate key would let a driveway wiggle compete for a
/// real route's records. [smoothness] is independent of that floor: it is a claim
/// about *how* you rode, not *where*, so a short but real ride can still score.
({String? key, List<double>? blob, double? smoothness}) deriveRoute(
  Ride ride,
  List<TrackPoint> points,
) {
  if (points.length < 2) return (key: null, blob: null, smoothness: null);
  final first = points.first;
  final last = points.last;
  final blob = encodeRouteBlob([
    for (final p in points) (lat: p.latitude, lon: p.longitude),
  ]);
  final smoothness = deriveSmoothness(points);
  if (ride.totalDistanceMeters < kRouteMinDistanceMeters) {
    return (key: null, blob: blob, smoothness: smoothness);
  }
  return (
    key: buildRouteKey(
      startTime: ride.startTime,
      startLat: first.latitude,
      startLon: first.longitude,
      endLat: last.latitude,
      endLon: last.longitude,
    ),
    blob: blob,
    smoothness: smoothness,
  );
}

/// Loads [ride]'s track and assigns the derived fields **on the passed instance**
/// without saving — for the engine, which is about to `put` the ride anyway.
Future<void> stampDerivedRoute(DatabaseService db, Ride ride) async {
  final derived = deriveRoute(ride, await db.getTrackPointsForRide(ride.id));
  ride
    ..routeKey = derived.key
    ..routeBlob = derived.blob
    ..smoothness = derived.smoothness;
}

/// Fills in `routeKey` / `routeBlob` / `smoothness` for finished rides recorded
/// before the migrations that added them.
///
/// Unlike the geocode backfill this needs no network and cannot fail
/// transiently — it is pure geometry over data already on disk — so it converges
/// in a bounded number of History visits and then costs one empty query.
class RouteBackfill {
  RouteBackfill._();
  static final RouteBackfill instance = RouteBackfill._();

  /// Rides processed per invocation. Each one reads a whole track, so a long
  /// history is spread across visits rather than stalling the first frame of the
  /// list. Newest rides go first — those are the ones on screen.
  static const int _maxPerRun = 12;

  bool _running = false;

  /// Rides already tried this session. Not every ride *can* derive every field —
  /// a track too sparse to score scores null however often it is re-read — so the
  /// work-list query alone never empties for them. Remembering the attempt caps
  /// the waste at one pass per app launch instead of one per History visit, and
  /// costs nothing on disk (the alternative, a stored "unscoreable" sentinel,
  /// would have to be understood by every future reader of the field).
  final _attempted = <int>{};

  /// Derives the missing fields for up to [_maxPerRun] rides. Calls [onUpdated]
  /// once if anything actually changed, so the caller can refresh.
  Future<void> run({required void Function() onUpdated}) async {
    if (_running) return;
    _running = true;
    try {
      final db = DatabaseService.instance;
      final missing = await db.getRidesMissingDerived();
      var updated = 0;
      final todo = missing.where((r) => !_attempted.contains(r.id));
      for (final ride in todo.take(_maxPerRun)) {
        _attempted.add(ride.id);
        final derived =
            deriveRoute(ride, await db.getTrackPointsForRide(ride.id));
        // A ride with no usable track derives to all-null — nothing to write.
        if (derived.key == null &&
            derived.blob == null &&
            derived.smoothness == null) {
          continue;
        }
        await db.setRideDerived(
          ride.id,
          routeKey: derived.key,
          routeBlob: derived.blob,
          smoothness: derived.smoothness,
        );
        updated++;
      }
      if (updated > 0) onUpdated();
    } finally {
      _running = false;
    }
  }
}
