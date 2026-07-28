import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/route_key.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/ride_stats.dart';

/// How far back the week strip looks when counting a streak.
///
/// A year is enough to show any streak a rider will read as impressive, and it
/// keeps the query to one bounded index range. A streak longer than this reports
/// as 52 — the alternative is scanning the entire history on every History entry
/// to make a number nobody is checking one week more precise.
const int kWeekLookback = 52;

/// This week's totals, last week's baseline and the current streak (F22).
///
/// Auto-disposes so entering History (or returning the Record screen to idle)
/// always reflects the ride just saved.
final weekStatsProvider = FutureProvider.autoDispose<WeekStats>((ref) async {
  final now = DateTime.now();
  final from = weekStartOf(now)
      .subtract(const Duration(days: 7 * kWeekLookback));
  final rides = await DatabaseService.instance.getRidesStartedSince(from);
  return WeekStats.from(rides, now);
});

/// Everything the post-ride summary needs to place a ride in context: the rider's
/// own history, this route's history, the records the ride broke, and the names
/// worth suggesting for it.
///
/// Bundled into one provider on purpose — the summary screen would otherwise open
/// on four separate loading states that resolve at four different moments, which
/// reads as a screen still assembling itself.
class RideInsight {
  const RideInsight({
    required this.ride,
    required this.rider,
    required this.route,
    required this.awards,
    required this.nameSuggestions,
    required this.distanceVsAvgFraction,
  });

  final Ride ride;

  /// The rider's lifetime figures, excluding [ride].
  final RiderStats rider;

  /// This route's figures, excluding [ride].
  final RouteStats route;

  /// Records [ride] broke, best first. Empty is the common case.
  final List<RideAward> awards;

  /// One-tap name suggestions, best first; the first is pre-filled (F16).
  final List<String> nameSuggestions;

  /// This ride's distance against the rider's average, as a fraction
  /// (0.12 = 12% further). Null when there is no history to compare against.
  final double? distanceVsAvgFraction;

  /// True when the rider has ridden this route before — the summary says so
  /// instead of implying every ride is new ground.
  bool get isRepeatRoute => route.priorRideCount > 0;
}

/// [RideInsight] for one ride id. Keyed by id rather than taking a [Ride] so it
/// re-reads the persisted row (the engine writes the final aggregates) instead of
/// trusting whatever snapshot the caller happened to be holding.
final rideInsightProvider =
    FutureProvider.autoDispose.family<RideInsight?, int>((ref, rideId) async {
  final db = DatabaseService.instance;
  final ride = await db.getRideById(rideId);
  if (ride == null) return null;

  // Every lookup excludes this ride: it is already persisted by the time the
  // summary opens, so including it would have the ride tie its own records and
  // compare its distance against an average it is part of.
  final rider = await db.getRiderStats(excludeRideId: rideId);
  final route = await db.getRouteStats(ride.routeKey, excludeRideId: rideId);

  return RideInsight(
    ride: ride,
    rider: rider,
    route: route,
    awards: awardsFor(ride, rider: rider, route: route),
    nameSuggestions: rideNameSuggestions(
      startTime: ride.startTime,
      startPlace: ride.startPlace,
      endPlace: ride.endPlace,
      isLoop: isLoopRoute(ride.routeKey),
      priorRidesOnRoute: route.priorRideCount,
    ),
    distanceVsAvgFraction: distanceVsAverage(ride, rider),
  );
});
