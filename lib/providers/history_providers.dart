import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../core/geo.dart';
import '../core/track_runs.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../data/models/trip.dart';
import '../data/trip_stats.dart';
import '../services/geocode_backfill.dart';
import '../services/permission_service.dart';
import '../services/route_derivation.dart';

/// Standalone rides (not part of any trip), newest first — the flat entries in
/// History. Trip stints render under their trip instead. Auto-disposes so
/// re-entering History always refetches (picking up rides saved since, dropping
/// any deleted in-screen via `ref.invalidate`).
final rideHistoryProvider = FutureProvider.autoDispose<List<Ride>>((ref) {
  return DatabaseService.instance.getStandaloneRides();
});

/// The single most recent finished ride — the "last ride" context line the
/// Record screen shows in place of four zeroed stats before a ride starts.
/// Auto-disposes, so it refetches every time the Record screen returns to idle
/// and picks up the ride just saved.
final latestRideProvider = FutureProvider.autoDispose<Ride?>((ref) {
  return DatabaseService.instance.getLatestFinishedRide();
});

/// Fires the best-effort geocode backfill when watched (i.e. when the History
/// screen builds). Re-attempts rides that still lack place names and refreshes
/// the list as they fill in. Invalidated alongside [rideHistoryProvider] on
/// each History-tab entry so a newly-online session gets another pass.
final geocodeBackfillProvider = FutureProvider.autoDispose<void>((ref) async {
  await GeocodeBackfill.instance.run(
    onUpdated: () => ref.invalidate(rideHistoryProvider),
  );
});

/// Derives `routeKey` / `routeBlob` for rides recorded before those fields
/// existed, so their History cards get a sparkline and they join the route-history
/// pool. Fired on each History entry like [geocodeBackfillProvider], but unlike
/// that one it needs no network, so it converges after a few visits and then costs
/// one empty query.
final routeBackfillProvider = FutureProvider.autoDispose<void>((ref) async {
  await RouteBackfill.instance.run(
    onUpdated: () => ref.invalidate(rideHistoryProvider),
  );
});

/// The recorded track for a single ride (in capture order), keyed by ride id —
/// used to replay the route polyline on the detail screen.
///
/// Segmented on the way out, so every consumer sees the same track the ride's
/// stored distance was measured against: cut at blackouts, with any displaced
/// excursion dropped (see `core/track_runs.dart`). Reading the raw rows here was
/// how a 3.8 km ride came to draw an 18 km box.
final rideTrackProvider = FutureProvider.autoDispose
    .family<SegmentedTrack<TrackPoint>, int>((ref, rideId) async {
      return segmentTrackPoints(
        await DatabaseService.instance.getTrackPointsForRide(rideId),
      );
    });

/// A trip paired with its combined stats — what a History trip entry needs to
/// render (name, stint count, distance/time). Used for both open and finished
/// trips.
class TripSummary {
  const TripSummary(this.trip, this.stats);
  final Trip trip;
  final TripStats stats;
}

Future<List<TripSummary>> _summarise(List<Trip> trips) async {
  final db = DatabaseService.instance;
  final summaries = <TripSummary>[];
  for (final trip in trips) {
    final stints = await db.getStintsForTrip(trip.id);
    summaries.add(TripSummary(trip, TripStats.fromStints(stints)));
  }
  return summaries;
}

/// Open (continuable) trips with combined stats, newest first. Backs the
/// History open-trips banner. Auto-disposes so it refetches on each History
/// entry (invalidated alongside [rideHistoryProvider]).
final openTripsProvider =
    FutureProvider.autoDispose<List<TripSummary>>((ref) async {
  return _summarise(await DatabaseService.instance.getOpenTrips());
});

/// Finished (closed) trips with combined stats, newest first — rendered as trip
/// cards in the History list.
final finishedTripsProvider =
    FutureProvider.autoDispose<List<TripSummary>>((ref) async {
  return _summarise(await DatabaseService.instance.getFinishedTrips());
});

/// One stint (ride) paired with its recorded track — the unit the combined
/// trip-detail map draws (each stint its own colored polyline).
class StintTrack {
  const StintTrack(this.stint, this.segmented);
  final Ride stint;

  /// Segmented like [rideTrackProvider]: blackout-cut, excursions dropped.
  final SegmentedTrack<TrackPoint> segmented;

  /// The stint's kept fixes, flattened — for callers that don't draw the joins.
  List<TrackPoint> get track => segmented.points;
}

/// A trip's stints (oldest-first) each with its recorded track, keyed by trip id.
/// Powers the trip-detail combined map and per-stint list.
final tripStintsProvider = FutureProvider.autoDispose
    .family<List<StintTrack>, int>((ref, tripId) async {
  final db = DatabaseService.instance;
  final stints = await db.getStintsForTrip(tripId);
  final out = <StintTrack>[];
  for (final stint in stints) {
    out.add(StintTrack(
      stint,
      segmentTrackPoints(await db.getTrackPointsForRide(stint.id)),
    ));
  }
  return out;
});

/// How close (meters) the rider must be to an open trip's last-known end point
/// for the Record screen to nudge "continue this trip?".
const double _nudgeRadiusMeters = 300;

/// The nearest open trip whose last stint ended within [_nudgeRadiusMeters] of the
/// rider's current position, or null (no open trip nearby, location denied, or
/// no fix). Best-effort and read-only — powers the Record-screen proximity
/// nudge. Returns the newest match when several qualify.
final nearbyOpenTripProvider =
    FutureProvider.autoDispose<TripSummary?>((ref) async {
  final perm = await PermissionService.ensureForegroundLocation();
  if (!perm.granted) return null;

  final Position pos;
  try {
    pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
  } catch (_) {
    return null; // no fix — silently skip the nudge
  }

  final db = DatabaseService.instance;
  for (final trip in await db.getOpenTrips()) {
    final stints = await db.getStintsForTrip(trip.id);
    if (stints.isEmpty) continue;
    // Where the last stint really ended, not its stored last fix: a phantom tail
    // survives segmentation by design, and one kilometres away would either offer
    // to continue a trip the rider is nowhere near, or fail to offer the one they
    // are standing at the end of. See [rideEndpoints].
    final end =
        rideEndpoints(await db.getTrackPointsForRide(stints.last.id)).end;
    if (end == null) continue;
    final meters = haversineMeters(
        pos.latitude, pos.longitude, end.latitude, end.longitude);
    if (meters <= _nudgeRadiusMeters) {
      return TripSummary(trip, TripStats.fromStints(stints));
    }
  }
  return null;
});
