import 'dart:math' as math;

/// Longitudinal ride smoothness, derived from how hard the speed trace changes.
///
/// One definition, two consumers: the analysis chart draws [AccelAnalysis.samples]
/// and shows [AccelAnalysis.score], and the ride finaliser persists that same
/// score to `Ride.smoothness`. Keeping them on one function is the point — a
/// chart that scored a ride differently from the number in the database would be
/// impossible to reason about.
///
/// Pure and model-free (this is `core/`): callers hand in `(time, speedMps)`
/// pairs rather than `TrackPoint`s.

/// One usable acceleration sample: seconds since the ride start, and the mean
/// longitudinal acceleration over the interval ending there.
typedef AccelSample = ({double tSec, double aMps2});

/// A speed reading to analyse.
typedef SpeedReading = ({DateTime time, double speedMps});

/// |a| beyond this (m/s²) is a hard event — a stab of throttle or of brake.
const double kHardEventMps2 = 1.5;

/// Intervals shorter than this are sub-second noise, and longer ones span a
/// pause or a GPS blackout. Either would manufacture an acceleration that never
/// happened, so both are dropped before anything is computed.
const double kMinAccelDtSeconds = 0.5;
const double kMaxAccelDtSeconds = 10.0;

/// Below this many usable intervals there is no riding style to speak of, so
/// [AccelAnalysis.score] stays null rather than inventing a number from three
/// samples of a driveway wiggle.
const int kMinSmoothnessSamples = 10;

/// The RMS acceleration (m/s²) that scores zero. Steady riding sits near
/// 0.3–0.6; sustained 2.0 is being ridden like it was stolen.
const double kZeroScoreRms = 2.0;

/// The acceleration/braking profile of one ride.
class AccelAnalysis {
  const AccelAnalysis({
    required this.samples,
    required this.accelEvents,
    required this.brakeEvents,
    required this.rmsMps2,
    required this.maxAbsMps2,
    required this.score,
  });

  /// Every usable interval, in ride order.
  final List<AccelSample> samples;

  /// Intervals past +[kHardEventMps2] (throttle) and past −[kHardEventMps2]
  /// (brake).
  final int accelEvents;
  final int brakeEvents;

  /// Root-mean-square acceleration across [samples] — the figure the score is
  /// built from. Squaring is deliberate: it lets a handful of violent stabs
  /// register instead of being averaged away by a long calm cruise.
  final double rmsMps2;

  /// Largest |a| seen, for the chart's y-scale.
  final double maxAbsMps2;

  /// 0–100, higher is smoother. Null when there were fewer than
  /// [kMinSmoothnessSamples] usable intervals.
  final double? score;

  static const empty = AccelAnalysis(
    samples: [],
    accelEvents: 0,
    brakeEvents: 0,
    rmsMps2: 0,
    maxAbsMps2: 0,
    score: null,
  );

  bool get hasScore => score != null;

  /// The score as a whole number, for display.
  int? get scoreRounded => score?.round();

  /// A one-word read on the score, for the plain-language takeaway.
  String get band {
    final s = score;
    if (s == null) return 'unrated';
    if (s >= 85) return 'very smooth';
    if (s >= 70) return 'smooth';
    if (s >= 50) return 'mixed';
    if (s >= 30) return 'busy';
    return 'aggressive';
  }
}

/// Analyses [readings] (a ride's speed trace, in order) into its acceleration
/// profile and smoothness score.
AccelAnalysis analyseSmoothness(List<SpeedReading> readings) {
  if (readings.length < 2) return AccelAnalysis.empty;

  final start = readings.first.time;
  final samples = <AccelSample>[];
  var accelEvents = 0;
  var brakeEvents = 0;
  var sumSquares = 0.0;
  var maxAbs = 0.0;

  for (var i = 1; i < readings.length; i++) {
    final dt =
        readings[i].time.difference(readings[i - 1].time).inMilliseconds /
            1000.0;
    if (dt < kMinAccelDtSeconds || dt > kMaxAccelDtSeconds) continue;
    final a = (readings[i].speedMps - readings[i - 1].speedMps) / dt;
    final tSec =
        readings[i].time.difference(start).inMilliseconds / 1000.0;
    samples.add((tSec: tSec, aMps2: a));
    if (a > kHardEventMps2) accelEvents++;
    if (a < -kHardEventMps2) brakeEvents++;
    sumSquares += a * a;
    final abs = a.abs();
    if (abs > maxAbs) maxAbs = abs;
  }

  if (samples.isEmpty) return AccelAnalysis.empty;

  final rms = math.sqrt(sumSquares / samples.length);
  final score = samples.length < kMinSmoothnessSamples
      ? null
      : (100 * (1 - (rms / kZeroScoreRms))).clamp(0.0, 100.0);

  return AccelAnalysis(
    samples: samples,
    accelEvents: accelEvents,
    brakeEvents: brakeEvents,
    rmsMps2: rms,
    maxAbsMps2: maxAbs,
    score: score,
  );
}

/// Where [score] places among [previousScores] (the rider's recent rides),
/// phrased for the takeaway line — e.g. "smoother than 8 of your last 10 rides".
///
/// Returns null when there is nothing to compare against, so the caller can drop
/// the clause entirely rather than print "smoother than 0 of your last 0 rides".
String? smoothnessComparison(double score, List<double> previousScores) {
  if (previousScores.isEmpty) return null;
  final beaten = previousScores.where((s) => score > s).length;
  final n = previousScores.length;
  final rides = n == 1 ? 'ride' : 'rides';
  if (beaten == 0) {
    return n == 1
        ? 'rougher than your previous ride'
        : 'rougher than all of your last $n $rides';
  }
  if (beaten == n) {
    return n == 1
        ? 'smoother than your previous ride'
        : 'your smoothest of the last ${n + 1} rides';
  }
  return 'smoother than $beaten of your last $n $rides';
}
