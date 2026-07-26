import 'package:isar_community/isar.dart';
import 'package:path_provider/path_provider.dart';

import 'models/ride.dart';
import 'models/track_point.dart';
import 'models/trip.dart';

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

  /// Deletes a ride and every track point that belongs to it.
  Future<void> deleteRide(int rideId) {
    return isar.writeTxn(() async {
      await isar.trackPoints.filter().rideIdEqualTo(rideId).deleteAll();
      await isar.rides.delete(rideId);
    });
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
