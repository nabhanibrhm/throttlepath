/// Splitting a recorded track into the stretches GPS was actually watching, and
/// throwing away the stretches it only thought it was.
///
/// The engine's blackout guards (`tracking_service.dart`) protect the *aggregates*
/// on the ride row: distance, duration and max speed all correctly skip a dead
/// zone. They do not protect the track, because the fix that ends a blackout is
/// still persisted — it is, after all, a real reading. Everything downstream that
/// re-derives geometry from `TrackPoint` therefore has to do its own skipping, and
/// before this module each of them either did it differently or not at all.
///
/// Two distinct failures, and they need different answers:
///
/// 1. **A gap.** No fixes for a while, then the track resumes. Joining the two
///    ends draws a straight line down roads nobody rode. The answer is to split
///    the track and let the caller decide how to render the join (the maps draw a
///    dimmed dash; distance accumulators add nothing).
/// 2. **A displaced excursion.** Fixes come back, internally coherent — plausible
///    speeds, consistent headings, sane spacing — but kilometres from where the
///    rider is. Stale ephemeris after a cold reacquisition will do this. Splitting
///    alone does not help: the excursion is contiguous, so it survives as a
///    perfectly valid run sitting 18 km away, and the camera still frames it.
///    Only recognising it as a cluster and dropping it helps.
///
/// Pure — no Isar, no Flutter, no plugins. Generic over the fix type via [fixOf]
/// so the engine's models, the lean estimator's records and the exporters can all
/// share one definition of "the same stretch of riding".
library;

import 'dart:math' as math;

import 'geo.dart';

/// The gap (seconds) at which a track is cut into separate runs.
///
/// This is the engine's own blackout threshold, and it lives here rather than in
/// `tracking_service.dart` so the read path cannot drift from the rule the data
/// was recorded under. If they ever disagree, every consumer silently re-bridges
/// exactly the segments the engine refused to count.
///
/// Must sit well above the normal fix cadence (raw GNSS lands roughly every
/// 1.4 s, and ordinary urban degradation stretches that to 5-6 s) or a healthy
/// ride would arrive pre-shredded.
const int kSignalLossSeconds = 12;

/// How close two runs must come before they count as the same place.
///
/// Deliberately coarse. This is not asking "did the rider stay put" — it is
/// asking "is this the same ride or a different continent", and the failure it
/// guards against (a stale-ephemeris excursion) misses by kilometres, never by
/// hundreds of metres. A tight radius would start carving up legitimate rides.
const double kTrackClusterLinkMeters = 1000;

/// Ceiling on how much of a ride's recorded time may be discarded as displaced —
/// **summed across every excursion**, not per excursion. Past it, what is being
/// thrown away is too much of the ride to be an artefact.
///
/// The distinction is the whole point: applied per cluster, four separate
/// excursions at 14% each all cleared a 15% cap and between them deleted 56% of the
/// ride. `segmentTrack` spends this as one budget, smallest excursion first.
const double kMaxDisplacedShare = 0.15;

/// The minimum of a fix this module needs. Callers adapt their own types to it.
typedef TrackFix = ({DateTime time, double lat, double lon});

/// A track cut into runs, with any displaced excursions set aside.
///
/// [runs] are in capture order and each is internally contiguous — the gaps live
/// *between* them. [discarded] holds what was dropped, so a caller can tell the
/// rider their track was edited instead of quietly editing it.
class SegmentedTrack<T> {
  const SegmentedTrack({
    required this.runs,
    required this.discarded,
    this.mainStart,
    this.mainEnd,
  });

  /// An empty track — no runs, nothing discarded.
  static SegmentedTrack<T> empty<T>() =>
      SegmentedTrack<T>(runs: const [], discarded: const []);

  final List<List<T>> runs;
  final List<List<T>> discarded;

  /// First and last fix of the ride's **main cluster** — where the rider actually
  /// started and finished, as opposed to where the track happens to begin and end.
  ///
  /// These exist because [segmentTrack]'s bracketing rule *structurally cannot*
  /// drop a displaced excursion at the head or the tail of a track, and that is on
  /// purpose: a ride that legitimately relocates and carries on (a long tunnel, a
  /// ferry) has nothing after the displacement to bracket it, and amputating its
  /// tail would delete real riding. The cost is that a phantom first or last fix
  /// survives into [runs] — and anything that reads `points.first` / `points.last`
  /// to answer *where was this ride* then answers with the phantom: the route key,
  /// the start/end place names, and the "continue a nearby trip?" nudge.
  ///
  /// So the geometry keeps the phantom (dropping it is not safe) and the
  /// *endpoints* skip it (trusting it is not honest) — but only while the cluster
  /// holding that endpoint is small enough to be an artefact, by the same
  /// [kMaxDisplacedShare] budget. A rider who legitimately relocates and then rides
  /// for forty minutes keeps their real endpoint; a brief spray of fixes 18 km away
  /// does not. Null only for an empty track.
  final T? mainStart;
  final T? mainEnd;

  /// The kept fixes, flattened back into one list in capture order. What every
  /// consumer that doesn't care about the joins should be reading.
  List<T> get points => [for (final run in runs) ...run];

  /// True when the track has at least one break in it — i.e. drawing it as a
  /// single unbroken polyline would invent geometry.
  bool get hasBreaks => runs.length > 1;

  /// How many fixes were thrown out as displaced.
  int get discardedCount =>
      discarded.fold(0, (sum, run) => sum + run.length);

  /// Indices *into [points]* at which each run after the first begins. The form
  /// the GPX writer and the flat-list chart builders want.
  List<int> get breakIndices {
    final out = <int>[];
    var at = 0;
    for (var i = 0; i < runs.length; i++) {
      if (i > 0) out.add(at);
      at += runs[i].length;
    }
    return out;
  }
}

/// Cuts [points] wherever more than [gapSeconds] passed between consecutive
/// fixes. Does not judge *where* the fixes are — see [segmentTrack] for that.
List<List<T>> splitIntoRuns<T>(
  List<T> points, {
  required TrackFix Function(T) fixOf,
  int gapSeconds = kSignalLossSeconds,
}) {
  if (points.isEmpty) return const [];
  final runs = <List<T>>[];
  var current = <T>[points.first];
  var previous = fixOf(points.first).time;
  for (var i = 1; i < points.length; i++) {
    final time = fixOf(points[i]).time;
    if (time.difference(previous).inSeconds.abs() >= gapSeconds) {
      runs.add(current);
      current = <T>[];
    }
    current.add(points[i]);
    previous = time;
  }
  runs.add(current);
  return runs;
}

/// Indices into [points] at which recording resumed after a gap — i.e. where
/// each run after the first begins.
///
/// The flat-list form of [splitIntoRuns], for the consumers that keep the track
/// as one list and only need to know where not to join it: the GPX writer's
/// `<trkseg>` boundaries, and the share card's polyline. Both had grown their
/// own timestamp loop, which is how one of them came to be right and the other
/// to draw a straight line across a dead zone.
///
/// Note this reads *timestamps only*, so it stays correct on an already
/// segmented track: dropping a displaced excursion leaves a gap at the seam,
/// and that seam is exactly a place the line must not be joined either.
List<int> runStartIndices<T>(
  List<T> points, {
  required TrackFix Function(T) fixOf,
  int gapSeconds = kSignalLossSeconds,
}) =>
    [
      for (var i = 1; i < points.length; i++)
        if (fixOf(points[i])
                .time
                .difference(fixOf(points[i - 1]).time)
                .inSeconds
                .abs() >=
            gapSeconds)
          i,
    ];

/// Splits [points] into runs and discards displaced excursions.
///
/// An excursion is only dropped when all three hold, and the conjunction is the
/// whole safety argument:
///
/// - it is **kilometres** from the body of the ride ([kTrackClusterLinkMeters]),
///   so ordinary GPS scatter can never qualify;
/// - it is **bracketed in time** by the main cluster — there is recorded track
///   both before and after it. A ride that legitimately relocates and carries on
///   from the new place (a long tunnel, a ferry, a dead zone crossed at speed)
///   has nothing after the displacement to bracket it, so its tail can never be
///   amputated. Coming back to where you left is what makes an excursion an
///   excursion;
/// - it is **small** relative to the ride ([kMaxDisplacedShare]).
///
/// Anything that fails one of those is kept, and shows up as an ordinary break.
/// The bias is deliberate: drawing a phantom is a cosmetic bug, deleting real
/// riding is not.
SegmentedTrack<T> segmentTrack<T>(
  List<T> points, {
  required TrackFix Function(T) fixOf,
  int gapSeconds = kSignalLossSeconds,
}) {
  final runs = splitIntoRuns(points, fixOf: fixOf, gapSeconds: gapSeconds);
  if (runs.isEmpty) return SegmentedTrack.empty<T>();

  // With one cluster there is no displacement anywhere, so the track's own ends
  // *are* the main cluster's ends. Stated once here rather than left null, so no
  // consumer has to carry a "if the endpoints are missing, fall back to first/last"
  // branch — which is the very code that had the bug.
  SegmentedTrack<T> undisplaced() => SegmentedTrack(
        runs: runs,
        discarded: const [],
        mainStart: runs.first.first,
        mainEnd: runs.last.last,
      );

  if (runs.length < 2) return undisplaced();

  final boxes = [for (final run in runs) _Box.of(run, fixOf)];
  final clusters = _clusterRuns(boxes);
  if (clusters.length < 2) return undisplaced();

  double durationOf(Iterable<int> runIndices) => runIndices.fold(0.0, (sum, i) {
        final run = runs[i];
        return sum +
            fixOf(run.last)
                .time
                .difference(fixOf(run.first).time)
                .inMilliseconds /
                1000.0;
      });

  // The main cluster is the one holding the most recorded time. Fix count would
  // be the obvious alternative and is worse: a dense stationary stretch can
  // out-count a whole hour of riding at a sparse cadence.
  var main = clusters.first;
  var mainDuration = durationOf(main);
  for (final cluster in clusters.skip(1)) {
    final d = durationOf(cluster);
    if (d > mainDuration) {
      main = cluster;
      mainDuration = d;
    }
  }

  final totalDuration = durationOf([for (var i = 0; i < runs.length; i++) i]);
  final mainFirst = fixOf(runs[main.reduce(math.min)].first).time;
  final mainLast = fixOf(runs[main.reduce(math.max)].last).time;

  double shareOf(Set<int> cluster) =>
      totalDuration <= 0 ? 1.0 : durationOf(cluster) / totalDuration;

  // Which run the reported endpoints come from.
  //
  // A displaced cluster at the head or tail cannot be *dropped* — see
  // [SegmentedTrack.mainStart] — but that is not the same as trusting it to say
  // where the ride began and ended. The complication is that one data shape means
  // two different things: a stale-ephemeris phantom, and a rider who genuinely
  // relocated (a long tunnel, a ferry) and carried on from the new place.
  //
  // So the endpoint is only disowned while the cluster holding it is small enough
  // to be an artefact — the same [kMaxDisplacedShare] budget the drop decision
  // spends. A brief spray of fixes 18 km away loses its claim on the ride's
  // endpoints; forty minutes of riding after a tunnel keeps it, because at that
  // size it is the ride, whatever else the coordinates suggest.
  //
  // When the head or tail cluster *is* the main cluster these both collapse to
  // `runs.first` / `runs.last` anyway, so there is one rule, not a special case.
  Set<int> clusterOf(int runIndex) =>
      clusters.firstWhere((c) => c.contains(runIndex));

  final headCluster = clusterOf(0);
  final tailCluster = clusterOf(runs.length - 1);
  final mainStartRun =
      !identical(headCluster, main) && shareOf(headCluster) <= kMaxDisplacedShare
          ? runs[main.reduce(math.min)]
          : runs.first;
  final mainEndRun =
      !identical(tailCluster, main) && shareOf(tailCluster) <= kMaxDisplacedShare
          ? runs[main.reduce(math.max)]
          : runs.last;

  // Every cluster that clears the two per-cluster tests, with its share of the
  // ride's recorded time, smallest first.
  final candidates = <({Set<int> cluster, double share})>[];
  for (final cluster in clusters) {
    if (identical(cluster, main)) continue;
    final first = fixOf(runs[cluster.reduce(math.min)].first).time;
    final last = fixOf(runs[cluster.reduce(math.max)].last).time;
    if (!first.isAfter(mainFirst) || !last.isBefore(mainLast)) continue;
    candidates.add((cluster: cluster, share: shareOf(cluster)));
  }
  candidates.sort((a, b) => a.share.compareTo(b.share));

  // [kMaxDisplacedShare] is a budget for the whole ride, not an allowance each
  // excursion gets to spend separately. Tested per cluster, four excursions at 14%
  // apiece each passed a 15% cap and took away 56% of the ride between them — the
  // one thing the cap exists to prevent.
  //
  // Smallest first, and stop at the first that doesn't fit rather than skipping it
  // to try the next: the list is sorted ascending, so nothing after it fits either.
  // What that leaves is the safe failure — an excursion too big for the budget is
  // *kept*, and renders as an ordinary break, because drawing a phantom is cosmetic
  // and deleting real riding is not.
  final drop = <int>{};
  var droppedShare = 0.0;
  for (final candidate in candidates) {
    if (droppedShare + candidate.share > kMaxDisplacedShare) break;
    drop.addAll(candidate.cluster);
    droppedShare += candidate.share;
  }

  // Note the endpoints are the main cluster's either way, including when nothing
  // was dropped — that case is precisely the head/tail phantom, where the geometry
  // is deliberately left intact and only the endpoints move.
  return SegmentedTrack(
    runs: [
      for (var i = 0; i < runs.length; i++)
        if (!drop.contains(i)) runs[i],
    ],
    discarded: [
      for (var i = 0; i < runs.length; i++)
        if (drop.contains(i)) runs[i],
    ],
    mainStart: mainStartRun.first,
    mainEnd: mainEndRun.last,
  );
}

/// Below this, a dark end is the receiver warming up or a thumb hovering over
/// the stop button, and saying so would be noise on nearly every ride. The ones
/// worth a word ran to minutes.
const int kDarkEndNoticeSeconds = 60;

/// Recording time at each end of a track during which no fix ever landed.
///
/// Not a gap *within* the track — [splitIntoRuns] owns those, and they are
/// visible precisely because there is a fix on either side to bound them. These
/// are the outer edges: from the rider pressing record to the first fix arriving,
/// and from the last fix to the rider pressing stop. Nothing bounds them from
/// outside, so no amount of segmenting reveals them; only the ride's own start
/// and end times do.
///
/// They matter for the same reason a blackout does, and more permanently: any
/// distance covered in them was never recorded and cannot be recovered. On a real
/// ride the head ran 6m19s, and the bike had moved 441 m by the time the first fix
/// arrived — a stretch no consumer of this track can ever account for.
///
/// Clamped at zero: a ride's stored end time can land a second or two *before*
/// its final fix, and a negative "dark" period is not a thing to report.
({Duration head, Duration tail}) darkEnds<T>(
  List<T> points, {
  required TrackFix Function(T) fixOf,
  required DateTime startedAt,
  DateTime? endedAt,
}) {
  if (points.isEmpty) return (head: Duration.zero, tail: Duration.zero);
  final head = fixOf(points.first).time.difference(startedAt);
  final tail = endedAt == null
      ? Duration.zero
      : endedAt.difference(fixOf(points.last).time);
  return (
    head: head.isNegative ? Duration.zero : head,
    tail: tail.isNegative ? Duration.zero : tail,
  );
}

/// Cumulative along-track distance (metres) for each fix in [points], frozen
/// across gaps.
///
/// A chart's distance axis has to agree with the odometer above it, and the
/// odometer never counted the dead zone. Returns a list the same length as
/// [points], starting at zero.
List<double> cumulativeMeters<T>(
  List<T> points, {
  required TrackFix Function(T) fixOf,
  int gapSeconds = kSignalLossSeconds,
}) {
  final out = List<double>.filled(points.length, 0.0);
  if (points.length < 2) return out;
  var previous = fixOf(points.first);
  for (var i = 1; i < points.length; i++) {
    final fix = fixOf(points[i]);
    final gapped =
        fix.time.difference(previous.time).inSeconds.abs() >= gapSeconds;
    out[i] = out[i - 1] +
        (gapped
            ? 0.0
            : haversineMeters(previous.lat, previous.lon, fix.lat, fix.lon));
    previous = fix;
  }
  return out;
}

/// Single-link clustering of runs by proximity: two runs join the same cluster
/// when their bounding boxes come within [kTrackClusterLinkMeters].
///
/// Bounding boxes rather than true point-to-point minimums — that would be
/// quadratic in fixes, and a box gap only ever *under*-states the real
/// separation, so the error is on the side of linking more and dropping less.
List<Set<int>> _clusterRuns(List<_Box> boxes) {
  final parent = List<int>.generate(boxes.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < boxes.length; i++) {
    for (var j = i + 1; j < boxes.length; j++) {
      if (boxes[i].gapMetersTo(boxes[j]) <= kTrackClusterLinkMeters) {
        final a = find(i), b = find(j);
        if (a != b) parent[a] = b;
      }
    }
  }

  final byRoot = <int, Set<int>>{};
  for (var i = 0; i < boxes.length; i++) {
    byRoot.putIfAbsent(find(i), () => <int>{}).add(i);
  }
  return byRoot.values.toList();
}

/// A run's lat/lon bounding box.
class _Box {
  const _Box(this.minLat, this.maxLat, this.minLon, this.maxLon);

  static _Box of<T>(List<T> run, TrackFix Function(T) fixOf) {
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (final point in run) {
      final f = fixOf(point);
      if (f.lat < minLat) minLat = f.lat;
      if (f.lat > maxLat) maxLat = f.lat;
      if (f.lon < minLon) minLon = f.lon;
      if (f.lon > maxLon) maxLon = f.lon;
    }
    return _Box(minLat, maxLat, minLon, maxLon);
  }

  final double minLat, maxLat, minLon, maxLon;

  /// Shortest distance (metres) between this box and [other]; zero if they touch.
  double gapMetersTo(_Box other) {
    final dLat = math.max(
        0.0, math.max(minLat - other.maxLat, other.minLat - maxLat));
    final dLon = math.max(
        0.0, math.max(minLon - other.maxLon, other.minLon - maxLon));
    if (dLat == 0 && dLon == 0) return 0;
    // A degree of longitude shrinks with latitude, so measure both legs on the
    // sphere at the latitude the two boxes share rather than scaling by hand.
    final lat = (minLat + maxLat + other.minLat + other.maxLat) / 4;
    final y = haversineMeters(lat, 0, lat + dLat, 0);
    final x = haversineMeters(lat, 0, lat, dLon);
    return math.sqrt(x * x + y * y);
  }
}
