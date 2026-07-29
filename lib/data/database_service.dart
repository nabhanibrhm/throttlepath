import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'models/ride.dart';
import 'models/track_point.dart';
import 'models/trip.dart';
import 'ride_stats.dart';

/// Single owner of the Isar instance for the whole app.
///
/// Call [open] once at startup (before any query). Everything else funnels
/// through the [isar] getter. Kept as a plain singleton — Riverpod wiring lands
/// in Phase 3 when the GPS engine becomes the first real consumer.
class DatabaseService {
  DatabaseService._();

  /// App-wide shared instance.
  static final DatabaseService instance = DatabaseService._();

  Isar? _isar;

  /// The live Isar handle. Throws if [open] hasn't completed yet — fail loud
  /// rather than silently opening a second instance.
  Isar get isar {
    final db = _isar;
    if (db == null || !db.isOpen) {
      throw StateError('DatabaseService.open() must be awaited before use.');
    }
    return db;
  }

  /// Opens (or returns the already-open) Isar instance. Idempotent.
  Future<Isar> open() async {
    final existing = _isar;
    if (existing != null && existing.isOpen) return existing;

    final dir = await getApplicationDocumentsDirectory();
    final db = await Isar.open(
      [RideSchema, TrackPointSchema, TripSchema],
      directory: dir.path,
    );
    _isar = db;
    return db;
  }

  // --- Ride helpers --------------------------------------------------------

  /// Inserts a new ride (or updates an existing one) and returns its id.
  Future<int> saveRide(Ride ride) {
    return isar.writeTxn(() => isar.rides.put(ride));
  }

  /// All rides, newest first.
  Future<List<Ride>> getAllRides() {
    return isar.rides.where().sortByStartTimeDesc().findAll();
  }

  /// Standalone rides only (not a leg of any trip), newest first — the flat
  /// entries in History. Trip legs are shown under their trip instead.
  Future<List<Ride>> getStandaloneRides() {
    return isar.rides
        .filter()
        .tripIdIsNull()
        .sortByStartTimeDesc()
        .findAll();
  }

  Future<Ride?> getRideById(int id) => isar.rides.get(id);

  /// The most recently *finished* ride, standalone or trip leg — the "last ride"
  /// line the Record screen shows while idle. Skips rides with no [Ride.endTime]
  /// (a recording interrupted by a crash), which would otherwise surface as a
  /// zero-distance ghost. Null when the rider has no completed rides yet.
  Future<Ride?> getLatestFinishedRide() {
    return isar.rides
        .filter()
        .endTimeIsNotNull()
        .sortByStartTimeDesc()
        .findFirst();
  }

  /// Rides still missing at least one place name, newest first — the work-list
  /// for the best-effort geocode backfill (rides saved while offline, or where
  /// the platform geocoder dropped one of the pair).
  Future<List<Ride>> getRidesMissingPlaces() {
    return isar.rides
        .filter()
        .startPlaceIsNull()
        .or()
        .endPlaceIsNull()
        .sortByStartTimeDesc()
        .findAll();
  }

  /// Sets the user-given [name] on an existing ride (from the summary screen).
  /// No-op if the ride was already deleted.
  Future<void> setRideName(int rideId, String name) {
    return isar.writeTxn(() async {
      final ride = await isar.rides.get(rideId);
      if (ride == null) return;
      ride.name = name;
      await isar.rides.put(ride);
    });
  }

  /// Sets reverse-geocoded start/end place names on a ride (best-effort — either
  /// may be null). No-op if the ride was deleted before geocoding finished.
  Future<void> setRidePlaces(int rideId,
      {String? startPlace, String? endPlace}) {
    return isar.writeTxn(() async {
      final ride = await isar.rides.get(rideId);
      if (ride == null) return;
      ride.startPlace = startPlace;
      ride.endPlace = endPlace;
      await isar.rides.put(ride);
    });
  }

  /// Stores the fields derived from a ride's track — route identity + shape
  /// (see `route_key.dart` / `route_blob.dart`) and its smoothness score (see
  /// `smoothness.dart`). Written once when the ride finalises, and by the
  /// backfill for rides recorded before these fields existed. No-op if the ride
  /// was deleted in between.
  Future<void> setRideDerived(
    int rideId, {
    String? routeKey,
    List<double>? routeBlob,
    double? smoothness,
  }) {
    return isar.writeTxn(() async {
      final ride = await isar.rides.get(rideId);
      if (ride == null) return;
      ride.routeKey = routeKey;
      ride.routeBlob = routeBlob;
      ride.smoothness = smoothness;
      await isar.rides.put(ride);
    });
  }

  /// Finished rides still missing any track-derived field, newest first — the
  /// work-list for the backfill. Rides still recording are skipped: their track
  /// isn't final yet.
  Future<List<Ride>> getRidesMissingDerived() {
    return isar.rides
        .filter()
        .endTimeIsNotNull()
        .group((q) => q
            .routeKeyIsNull()
            .or()
            .routeBlobIsNull()
            .or()
            .smoothnessIsNull())
        .sortByStartTimeDesc()
        .findAll();
  }

  /// Smoothness scores of the [limit] most recent finished rides that have one,
  /// excluding [excludeRideId] — the sample the analysis screen phrases
  /// "smoother than 8 of your last 10 rides" against.
  ///
  /// Excluding the ride being judged matters for the same reason it does in
  /// [getRiderStats]: by the time the screen asks, the ride is already on disk and
  /// would otherwise be compared against itself.
  Future<List<double>> getRecentSmoothnessScores({
    int limit = 10,
    int excludeRideId = -1,
  }) async {
    final scores = await isar.rides
        .filter()
        .endTimeIsNotNull()
        .and()
        .smoothnessIsNotNull()
        .and()
        .not()
        .idEqualTo(excludeRideId)
        .sortByStartTimeDesc()
        .limit(limit)
        .smoothnessProperty()
        .findAll();
    return [for (final s in scores) ?s];
  }

  /// Deletes a ride and every track point that belongs to it.
  Future<void> deleteRide(int rideId) {
    return isar.writeTxn(() async {
      await isar.trackPoints.filter().rideIdEqualTo(rideId).deleteAll();
      await isar.rides.delete(rideId);
    });
  }

  // --- Aggregates ----------------------------------------------------------
  //
  // Everything below reduces in the DB rather than in Dart: `count()`, `sum()`,
  // `max()` on a property query never materialise a Ride, and the `startTime`
  // range walks the existing index. That matters because these run on every
  // History entry and on every ride save.

  /// Finished rides that started at or after [from], newest first.
  ///
  /// Uses the `startTime` index directly (a where-clause, not a filter), so a
  /// four-week window stays cheap however long the history gets. Trip legs are
  /// included — a week's distance is a week's distance regardless of how the ride
  /// was filed.
  Future<List<Ride>> getRidesStartedSince(DateTime from) {
    return isar.rides
        .where()
        .startTimeGreaterThan(from, include: true)
        .filter()
        .endTimeIsNotNull()
        .sortByStartTimeDesc()
        .findAll();
  }

  /// Lifetime bests and totals across every finished ride *except* [excludeRideId]
  /// (pass a negative id to include everything).
  ///
  /// Excluding one ride is the point: a just-finished ride is already persisted by
  /// the time the summary screen asks "is this a record?", so comparing against
  /// the unfiltered history would have every ride tie its own best.
  Future<RiderStats> getRiderStats({int excludeRideId = -1}) async {
    QueryBuilder<Ride, Ride, QAfterFilterCondition> base() => isar.rides
        .filter()
        .endTimeIsNotNull()
        .and()
        .not()
        .idEqualTo(excludeRideId);

    final count = await base().count();
    if (count == 0) return RiderStats.empty;
    final total = await base().totalDistanceMetersProperty().sum();
    final longest = await base().totalDistanceMetersProperty().max();
    final bestAvg = await base().averageSpeedKmhProperty().max();
    final longestDuration = await base().durationSecondsProperty().max();

    return RiderStats(
      rideCount: count,
      totalDistanceMeters: total,
      longestDistanceMeters: longest ?? 0,
      bestAvgSpeedKmh: bestAvg ?? 0,
      longestDurationSeconds: longestDuration ?? 0,
    );
  }

  /// Bests on one route, across every finished ride carrying [routeKey] except
  /// [excludeRideId].
  ///
  /// Returns [RouteStats.empty] for a null/blank key rather than treating "unknown
  /// route" as a route — otherwise every pre-migration ride would share one giant
  /// bucket and compete for its records.
  Future<RouteStats> getRouteStats(String? routeKey,
      {int excludeRideId = -1}) async {
    if (routeKey == null || routeKey.isEmpty) return RouteStats.empty;
    // One route holds a handful of rides, so reducing these in Dart costs less
    // than four round-trips through the query engine.
    final rides = await isar.rides
        .where()
        .routeKeyEqualTo(routeKey)
        .filter()
        .endTimeIsNotNull()
        .and()
        .not()
        .idEqualTo(excludeRideId)
        .findAll();
    return RouteStats.from(rides);
  }

  /// How many finished rides already share [routeKey], not counting
  /// [excludeRideId] — what decides whether a route is routine enough to be named
  /// a "commute".
  Future<int> countRidesOnRoute(String? routeKey,
      {int excludeRideId = -1}) async {
    if (routeKey == null || routeKey.isEmpty) return 0;
    return isar.rides
        .where()
        .routeKeyEqualTo(routeKey)
        .filter()
        .endTimeIsNotNull()
        .and()
        .not()
        .idEqualTo(excludeRideId)
        .count();
  }

  // --- Trip helpers --------------------------------------------------------

  /// Inserts a new trip (or updates an existing one) and returns its id.
  Future<int> createTrip(Trip trip) {
    return isar.writeTxn(() => isar.trips.put(trip));
  }

  Future<Trip?> getTripById(int id) => isar.trips.get(id);

  /// Renames a trip. A trip's name is its own — independent of its legs' names —
  /// so this never touches the legs. No-op if the trip was deleted.
  Future<void> setTripName(int tripId, String name) {
    return isar.writeTxn(() async {
      final trip = await isar.trips.get(tripId);
      if (trip == null) return;
      trip.name = name;
      await isar.trips.put(trip);
    });
  }

  /// All trips, newest first.
  Future<List<Trip>> getAllTrips() {
    return isar.trips.where().sortByCreatedAtDesc().findAll();
  }

  /// Open (still-continuable) trips — those with no [Trip.finishedAt] — newest
  /// first. The work-list for the History "Continue" affordance.
  Future<List<Trip>> getOpenTrips() {
    return isar.trips
        .filter()
        .finishedAtIsNull()
        .sortByCreatedAtDesc()
        .findAll();
  }

  /// Finished (closed) trips — those with a [Trip.finishedAt] — newest first.
  /// Rendered as trip entries in History.
  Future<List<Trip>> getFinishedTrips() {
    return isar.trips
        .filter()
        .finishedAtIsNotNull()
        .sortByCreatedAtDesc()
        .findAll();
  }

  /// A trip's legs (rides), ordered oldest-first by start time.
  Future<List<Ride>> getLegsForTrip(int tripId) {
    return isar.rides
        .filter()
        .tripIdEqualTo(tripId)
        .sortByStartTime()
        .findAll();
  }

  /// Links (or unlinks, with null) a ride to a trip as one of its legs. No-op if
  /// the ride was deleted before this ran.
  Future<void> setRideTrip(int rideId, int? tripId) {
    return isar.writeTxn(() async {
      final ride = await isar.rides.get(rideId);
      if (ride == null) return;
      ride.tripId = tripId;
      await isar.rides.put(ride);
    });
  }

  /// Closes a trip (stamps [Trip.finishedAt]); it no longer accepts new legs
  /// until reopened. No-op if the trip was deleted.
  Future<void> finishTrip(int tripId, {DateTime? finishedAt}) {
    return isar.writeTxn(() async {
      final trip = await isar.trips.get(tripId);
      if (trip == null) return;
      trip.finishedAt = finishedAt ?? DateTime.now();
      await isar.trips.put(trip);
    });
  }

  /// Reopens a finished trip (clears [Trip.finishedAt]) so more legs can be
  /// added. No-op if the trip was deleted.
  Future<void> reopenTrip(int tripId) {
    return isar.writeTxn(() async {
      final trip = await isar.trips.get(tripId);
      if (trip == null) return;
      trip.finishedAt = null;
      await isar.trips.put(trip);
    });
  }

  // --- TrackPoint helpers --------------------------------------------------

  /// Appends a single GPS sample; returns its id.
  Future<int> addTrackPoint(TrackPoint point) {
    return isar.writeTxn(() => isar.trackPoints.put(point));
  }

  /// Appends a batch of GPS samples in one transaction.
  Future<List<int>> addTrackPoints(List<TrackPoint> points) {
    return isar.writeTxn(() => isar.trackPoints.putAll(points));
  }

  /// All points for a ride, in capture order.
  Future<List<TrackPoint>> getTrackPointsForRide(int rideId) {
    return isar.trackPoints
        .filter()
        .rideIdEqualTo(rideId)
        .sortByTimestamp()
        .findAll();
  }

  /// The ride's first captured point (its origin), or null if it has none.
  /// Cheaper than loading the whole track just to geocode the endpoints.
  Future<TrackPoint?> getFirstTrackPoint(int rideId) {
    return isar.trackPoints
        .filter()
        .rideIdEqualTo(rideId)
        .sortByTimestamp()
        .findFirst();
  }

  /// The ride's last captured point (its destination), or null if it has none.
  Future<TrackPoint?> getLastTrackPoint(int rideId) {
    return isar.trackPoints
        .filter()
        .rideIdEqualTo(rideId)
        .sortByTimestampDesc()
        .findFirst();
  }

  // --- Maintenance ---------------------------------------------------------

  /// Wipes all rides and track points. Primarily for tests / "reset" actions.
  Future<void> clearAll() {
    return isar.writeTxn(() async {
      await isar.rides.clear();
      await isar.trackPoints.clear();
    });
  }
}
