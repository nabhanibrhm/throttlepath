import '../data/database_service.dart';
import '../data/models/ride.dart';
import 'route_derivation.dart';
import 'tracking_service.dart';

/// Finalises rides the OS killed mid-recording.
///
/// Android will kill a foreground service under memory pressure, and on some OEM
/// builds simply because the screen has been off a long while. When that happens
/// mid-ride the engine never reaches `finalizeAndStop()`, so the ride keeps
/// everything the engine had already written — its running aggregates, saved on
/// every accepted fix, and every track point — but never gets an [Ride.endTime].
///
/// That one null is what strands it. `getStandaloneRides` has no end-time filter,
/// so the ride still shows in History; `getRidesMissingDerived` is gated on
/// `endTimeIsNotNull`, so it can never earn a route key, a shape, a smoothness
/// score or lean figures. The rider sees a real ride that quietly refuses to
/// behave like one, forever.
///
/// Nothing is recomputed here: the aggregates on the row are already the engine's
/// own numbers as of its last fix, and they were produced by the blackout guards
/// this recovery must not second-guess. All that is added is the end stamp and the
/// derived fields.
class RideRecovery {
  RideRecovery._();

  /// Finalises every stranded ride, and returns how many it closed.
  ///
  /// Called from the splash, after `TrackingService.configure()` so the guard below
  /// can be trusted. Best-effort: a failure here must never stop the app from
  /// launching, so the caller is expected to swallow it.
  static Future<int> run() async {
    final db = DatabaseService.instance;
    final stranded = await db.getUnfinishedRides();
    if (stranded.isEmpty) return 0;

    // **The guard.** A ride in progress right now looks exactly like a stranded
    // one — no end time is precisely what "still recording" means — and finalising
    // it would stamp an end on a live ride, derive a route from a half-written
    // track, and leave the engine writing aggregates to a row the app has already
    // filed as finished.
    //
    // Deliberately all-or-nothing rather than "skip the live ride and recover the
    // rest": the service does not publish which ride id it holds until its first
    // telemetry tick, so any attempt to single it out would be a guess. Waiting
    // costs nothing — a stranded ride has been stranded since the last launch, and
    // will still be there on the next one with no ride running.
    if (await TrackingService.instance.isTracking()) return 0;

    var closed = 0;
    for (final ride in stranded) {
      if (await _close(db, ride)) closed++;
    }
    return closed;
  }

  static Future<bool> _close(DatabaseService db, Ride ride) async {
    final points = await db.getTrackPointsForRide(ride.id);

    // The last fix is when the app last knew where the rider was, which is the
    // honest wall-clock end. `startTime + durationSeconds` would be wrong on any
    // ride that paused or lost signal, because the stored duration deliberately
    // excludes both.
    //
    // A ride with no track points at all recorded nothing — a start that died
    // during acquisition. It is closed at its own start rather than deleted:
    // ending up as a visible 0.00 km entry the rider can remove is recoverable,
    // and deleting something that was never inspected is not.
    ride.endTime = points.isEmpty ? ride.startTime : points.last.timestamp;

    await stampDerivedRoute(db, ride);
    await db.saveRide(ride);
    return true;
  }
}
