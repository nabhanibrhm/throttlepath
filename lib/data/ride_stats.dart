import 'models/ride.dart';

/// Aggregates over a rider's own history — the numbers that turn a ride into
/// "your longest yet" or "12% above your average".
///
/// Pure: every class here is built from a list of [Ride]s (or from figures a
/// query already reduced), never from Isar directly, so all of it is unit-testable
/// and none of it can accidentally hit the DB from a widget build.

/// Start of the week (local Monday, 00:00) that [when] falls in.
DateTime weekStartOf(DateTime when) {
  final local = when.toLocal();
  final midnight = DateTime(local.year, local.month, local.day);
  return midnight.subtract(Duration(days: local.weekday - 1));
}

/// This-week totals plus the two things that make them mean something: how last
/// week compared, and how many weeks the rider has kept it up (F22).
class WeekStats {
  const WeekStats({
    required this.weekStart,
    required this.distanceMeters,
    required this.rideCount,
    required this.movingSeconds,
    required this.previousDistanceMeters,
    required this.streakWeeks,
  });

  /// Local Monday 00:00 of the week these totals cover.
  final DateTime weekStart;
  final double distanceMeters;
  final int rideCount;
  final int movingSeconds;

  /// The same week a week earlier — the baseline for [deltaMeters].
  final double previousDistanceMeters;

  /// Consecutive weeks with at least one ride.
  ///
  /// Counted back from *last* week when the current week is still empty, so the
  /// streak doesn't read as broken every Monday morning before the first ride.
  final int streakWeeks;

  /// Change in distance against last week, in meters. Positive is an increase.
  double get deltaMeters => distanceMeters - previousDistanceMeters;

  /// Change against last week as a fraction (0.12 = +12%), or null when last week
  /// was empty — there is no percentage against zero, and "+∞%" is not a stat.
  double? get deltaFraction => previousDistanceMeters <= 0
      ? null
      : (distanceMeters - previousDistanceMeters) / previousDistanceMeters;

  bool get isEmpty => rideCount == 0;

  /// A zeroed week for [now]. There is no `const empty` because `weekStart` is a
  /// `DateTime`, which can never be a compile-time constant.
  static WeekStats emptyFor(DateTime now) => WeekStats.from(const [], now);

  /// Buckets [rides] into weeks relative to [now] and reduces the current one.
  ///
  /// [rides] may contain any window of history; only rides inside the relevant
  /// weeks are read, so callers can pass a capped lookback.
  factory WeekStats.from(Iterable<Ride> rides, DateTime now) {
    final thisWeek = weekStartOf(now);
    final byWeek = <DateTime, ({double meters, int count, int moving})>{};
    for (final r in rides) {
      // A ride belongs to the week it *started* in, so one that rolls past
      // midnight on Sunday isn't split in half.
      final key = weekStartOf(r.startTime);
      final acc = byWeek[key];
      byWeek[key] = (
        meters: (acc?.meters ?? 0) + r.totalDistanceMeters,
        count: (acc?.count ?? 0) + 1,
        moving: (acc?.moving ?? 0) + r.movingSeconds,
      );
    }

    final current = byWeek[thisWeek];
    final lastWeek = thisWeek.subtract(const Duration(days: 7));
    final previous = byWeek[lastWeek];

    // Walk back week by week while each has a ride. Start at last week when this
    // week is still empty — a fresh Monday must not reset a real streak.
    var cursor = current != null ? thisWeek : lastWeek;
    var streak = 0;
    while (byWeek[cursor] != null) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 7));
    }

    return WeekStats(
      weekStart: thisWeek,
      distanceMeters: current?.meters ?? 0,
      rideCount: current?.count ?? 0,
      movingSeconds: current?.moving ?? 0,
      previousDistanceMeters: previous?.meters ?? 0,
      streakWeeks: streak,
    );
  }
}

/// Lifetime bests and averages across a rider's finished rides, used to place a
/// just-finished ride in context (F17).
///
/// Always built *excluding* the ride being judged, so a ride is never compared
/// against a history that already contains it — otherwise a first ride would be
/// "0% above average" and every ride would tie its own record.
class RiderStats {
  const RiderStats({
    required this.rideCount,
    required this.totalDistanceMeters,
    required this.longestDistanceMeters,
    required this.bestAvgSpeedKmh,
    required this.longestDurationSeconds,
  });

  final int rideCount;
  final double totalDistanceMeters;
  final double longestDistanceMeters;
  final double bestAvgSpeedKmh;
  final int longestDurationSeconds;

  static const empty = RiderStats(
    rideCount: 0,
    totalDistanceMeters: 0,
    longestDistanceMeters: 0,
    bestAvgSpeedKmh: 0,
    longestDurationSeconds: 0,
  );

  /// Mean ride distance in meters, or null with no rides to average.
  double? get avgDistanceMeters =>
      rideCount == 0 ? null : totalDistanceMeters / rideCount;

  factory RiderStats.from(Iterable<Ride> rides) {
    var count = 0;
    var total = 0.0;
    var longest = 0.0;
    var bestAvg = 0.0;
    var longestDuration = 0;
    for (final r in rides) {
      count++;
      total += r.totalDistanceMeters;
      if (r.totalDistanceMeters > longest) longest = r.totalDistanceMeters;
      if (r.averageSpeedKmh > bestAvg) bestAvg = r.averageSpeedKmh;
      if (r.durationSeconds > longestDuration) {
        longestDuration = r.durationSeconds;
      }
    }
    return RiderStats(
      rideCount: count,
      totalDistanceMeters: total,
      longestDistanceMeters: longest,
      bestAvgSpeedKmh: bestAvg,
      longestDurationSeconds: longestDuration,
    );
  }
}

/// The same idea scoped to one `Ride.routeKey`: how often this route has been
/// ridden before and the best it has been ridden in.
class RouteStats {
  const RouteStats({
    required this.priorRideCount,
    required this.bestAvgSpeedKmh,
    required this.bestMovingSeconds,
  });

  /// Earlier rides sharing this route key (never counting the subject ride).
  final int priorRideCount;
  final double bestAvgSpeedKmh;

  /// Shortest moving time recorded on this route, or 0 when it is new. Moving
  /// time rather than elapsed, so a coffee stop doesn't decide the record.
  final int bestMovingSeconds;

  static const empty =
      RouteStats(priorRideCount: 0, bestAvgSpeedKmh: 0, bestMovingSeconds: 0);

  bool get isNewRoute => priorRideCount == 0;

  factory RouteStats.from(Iterable<Ride> priorRides) {
    var count = 0;
    var bestAvg = 0.0;
    var bestMoving = 0;
    for (final r in priorRides) {
      count++;
      if (r.averageSpeedKmh > bestAvg) bestAvg = r.averageSpeedKmh;
      if (r.movingSeconds > 0 &&
          (bestMoving == 0 || r.movingSeconds < bestMoving)) {
        bestMoving = r.movingSeconds;
      }
    }
    return RouteStats(
      priorRideCount: count,
      bestAvgSpeedKmh: bestAvg,
      bestMovingSeconds: bestMoving,
    );
  }
}

/// A record the just-finished ride broke.
enum RideAward {
  /// Furthest the rider has ever gone in one ride.
  longestDistance('Longest ride yet'),

  /// Highest average speed across a whole ride.
  fastestAverage('Fastest average yet'),

  /// Most time in the saddle in one ride.
  longestTime('Longest time out yet'),

  /// Quickest this particular route has been ridden.
  fastestOnRoute('Fastest on this route');

  const RideAward(this.label);

  /// Short badge text — written as an achievement, not a metric name.
  final String label;
}

/// Below this a ride is too small to hold a record. Without it, the very first
/// 30 m test recording is crowned "longest ride yet" and the badge means nothing
/// forever after.
const double kAwardMinDistanceMeters = 1000;

/// Which records [ride] broke, given the rider's history *excluding* it.
///
/// Ties do not count: matching a previous best is not beating it, and a ride
/// re-judged after being saved (same numbers, now inside the history) would
/// otherwise keep announcing the same record.
List<RideAward> awardsFor(
  Ride ride, {
  required RiderStats rider,
  RouteStats route = RouteStats.empty,
}) {
  if (ride.totalDistanceMeters < kAwardMinDistanceMeters) return const [];
  final out = <RideAward>[];
  // Nothing to beat on a first ride — "longest yet" out of one is noise.
  if (rider.rideCount > 0) {
    if (ride.totalDistanceMeters > rider.longestDistanceMeters) {
      out.add(RideAward.longestDistance);
    }
    if (ride.averageSpeedKmh > rider.bestAvgSpeedKmh) {
      out.add(RideAward.fastestAverage);
    }
    if (ride.durationSeconds > rider.longestDurationSeconds) {
      out.add(RideAward.longestTime);
    }
  }
  if (route.priorRideCount > 0 &&
      route.bestMovingSeconds > 0 &&
      ride.movingSeconds > 0 &&
      ride.movingSeconds < route.bestMovingSeconds) {
    out.add(RideAward.fastestOnRoute);
  }
  return out;
}

/// How this ride's distance compares to the rider's average, as a fraction
/// (0.12 = 12% further). Null when there is no history to compare against, the
/// average is zero, or the ride is too short to be worth comparing.
///
/// The last case is the one found on the device: a 26 m recording against a 14 km
/// average produced "100% shorter than your average", which is arithmetically
/// right and semantically nonsense — 100% shorter is zero. A recording that didn't
/// go anywhere gets no comparison at all; the short-ride prompt already says the
/// only useful thing about it.
double? distanceVsAverage(Ride ride, RiderStats rider) {
  final avg = rider.avgDistanceMeters;
  if (avg == null || avg <= 0) return null;
  if (ride.totalDistanceMeters < kAwardMinDistanceMeters) return null;
  return (ride.totalDistanceMeters - avg) / avg;
}
