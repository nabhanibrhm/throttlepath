import 'dart:math' as math;

import 'geo.dart';

/// Estimated cornering lean angle, derived from how fast the bike's heading turns.
///
/// For a motorcycle in a no-slip coordinated turn:
///
/// ```
/// θ = atan(v · ω / g)
/// ```
///
/// where `v` is ground speed and `ω` the yaw rate. This is the lean the corner
/// *requires*, not the lean the bike *had* — they agree for normal road riding,
/// which is what makes the estimate legitimate, and the difference is why nothing
/// here is ever presented as a measurement.
///
/// Pure and model-free (this is `core/`): callers hand in readings rather than
/// `TrackPoint`s, the same contract `core/smoothness.dart` uses.
///
/// Every guard below was forced by measuring real rides — see
/// `docs/lean-angle-design.md` and `tool/lean_probe.dart`. The headline number is
/// deliberately a percentile and not a maximum: the two largest raw maxima across
/// the whole recorded history belong to GPS-blackout train rides.

/// Standard gravity, m/s².
const double kGravity = 9.80665;

/// One GPS sample to analyse. [headingDegrees] is the fix's own Doppler course
/// when the platform reported one, null otherwise.
typedef LeanReading = ({
  DateTime time,
  double speedMps,
  double? headingDegrees,
  double latitude,
  double longitude,
});

/// One lean estimate along the ride. [leanDegrees] is signed: negative leans
/// left, positive leans right.
typedef LeanSample = ({
  double tSec,
  double distanceMeters,
  double leanDegrees,
  double speedKmh,
});

/// Seconds spent within one 5° band of lean.
typedef LeanBand = ({int fromDegrees, int toDegrees, double seconds});

/// Where the yaw rate came from. Surfaced so the UI can be honest about which
/// rides carry the better estimate, and so a future upgrade is observable.
enum LeanHeadingSource {
  /// Bearing differenced between stored positions. The only option for rides
  /// recorded before `TrackPoint.headingDegrees` existed.
  positionBearing,

  /// The fix's own Doppler course over ground — far less noisy, because it does
  /// not inherit position error over a short baseline.
  reportedCourse,
}

/// Below this speed a lean estimate is meaningless: heading between two
/// near-coincident fixes is undefined, and paddling a slow U-turn produces a
/// large `ω` with no lean whatsoever behind it.
const double kMinLeanSpeedKmh = 20.0;

/// Per-leg interval window. Sub-second steps are noise; longer ones span a pause
/// or a GPS blackout, where the heading discontinuity across the dead zone would
/// manufacture a corner that never happened.
const double kMinLeanDtSeconds = 0.5;
const double kMaxLeanDtSeconds = 10.0;

/// A road bike scrapes a footpeg near 45°. Past this it is a bad fix, and such a
/// sample is **rejected rather than clamped** — clamping piles fabricated mass
/// onto the cap and makes a noisy number look confident.
const double kMaxPlausibleLeanDegrees = 55.0;

/// ALIASING, and why it is safe.
///
/// The turn across a window is only unambiguous up to ±180°: beyond that,
/// [signedTurnDegrees] necessarily reports the short way round. So a yaw rate
/// above `180° / span` — about 30°/s at the default width — is under-read, and a
/// rate past 360°/span can even come back with the wrong sign.
///
/// This is left unguarded on purpose. Aliasing always maps a large true rate onto
/// a *smaller* apparent one, so its only effect on the headline is to miss an
/// extreme corner, never to invent one — the same direction as the estimator's
/// other biases. A guard that rejected large turns instead would throw away
/// genuine slow hairpins, which sit at a legitimately high yaw rate (a 12 m radius
/// at 20 km/h is 26°/s and only ~14° of lean).
///
/// The one real cost is that a rare aliased hairpin can be attributed to the wrong
/// side, which is why [LeanAnalysis.balance] refuses to speak below a 2° gap.

/// Fewer usable samples than this and no percentile means anything, so the whole
/// analysis reports null rather than inventing a headline from a handful of
/// samples. Real rides in the recorded history yield 40–1600.
const int kMinLeanSamples = 30;

/// A peak must be sustained across this many consecutive samples to count.
///
/// Three, not two, and that was measured rather than guessed. Two is worth almost
/// nothing against scatter: if noise throws lean either side at random, half of all
/// neighbouring pairs already agree on direction by chance, and seeded random
/// scatter duly corroborated a 33° corner. Three consecutive same-side samples is
/// far harder to fake and costs real cornering nothing — a corner takes several
/// seconds to go through, so a genuine one is sampled repeatedly at ~1 Hz.
const int kPeakCorroborationSamples = 3;

/// Corroborating samples must be this close in time to count as consecutive —
/// otherwise samples either side of a dropped stretch would vouch for each other.
const double kCorroborationMaxGapSeconds = 3.0;

/// A window must trace a smooth arc: its straight-line chord has to be at least
/// this fraction of the distance actually walked through it.
///
/// This is the guard that catches multipath, and it exists because corroboration
/// alone provably did not. Measured on the two train rides, a GPS blackout inside
/// a metal carriage does not produce *one* junk fix — it produces a run of them,
/// so consecutive samples cheerfully vouched for each other and a fabricated 36°
/// corner survived into the peak.
///
/// Geometry makes the threshold easy to justify: for a genuine circular arc turning
/// θ across the window, chord ÷ path is exactly `cos(θ/4)`. At 0.80 the estimator
/// still accepts a 147° turn inside one window — far more than road riding asks
/// for — while a scattered zigzag, whose path is far longer than its chord, fails.
const double kMinChordRatio = 0.80;

/// Half-window, in fixes, used to difference heading for each source.
///
/// Widening the window trades corner resolution for noise: measured over 26.5k
/// samples, differencing *adjacent* positions claimed 54° of lean at highway
/// speed on 2.7% of samples — noise, not riding — while a ±2 window reported 0%
/// past 20°. A corner at 60 km/h is over in roughly that same span, so this
/// estimate is a corner's *average*, biased below its peak.
///
/// [LeanHeadingSource.reportedCourse] is held at the same conservative width
/// until the probe proves a shorter one is clean on real Doppler data; shortening
/// it is then a one-line change here.
const Map<LeanHeadingSource, int> kLeanHalfWindow = {
  LeanHeadingSource.positionBearing: 2,
  LeanHeadingSource.reportedCourse: 2,
};

/// Window, in samples, of the centred moving average used to draw the trace. See
/// [smoothLeanForDisplay] — this affects the picture only, never a reported number.
const int kLeanDisplaySmoothWindow = 5;

/// Fraction of a track that must carry a reported course before it is preferred
/// over position-bearing. A handful of stray headings should not switch the
/// estimator for the whole ride.
const double kReportedCourseMinCoverage = 0.8;

/// The cornering profile of one ride.
class LeanAnalysis {
  const LeanAnalysis({
    required this.samples,
    required this.p95Degrees,
    required this.peakDegrees,
    required this.histogram,
    required this.leftSamples,
    required this.rightSamples,
    required this.leftP95Degrees,
    required this.rightP95Degrees,
    required this.source,
    this.peakAtDistanceMeters,
    this.peakAtSeconds,
  });

  /// Every usable estimate, in ride order.
  final List<LeanSample> samples;

  /// Typical cornering lean — the 95th percentile of |lean|. The headline number.
  /// Null when there were fewer than [kMinLeanSamples] usable samples.
  final double? p95Degrees;

  /// The largest lean corroborated by [kPeakCorroborationSamples] consecutive
  /// samples. Null under the same condition as [p95Degrees].
  final double? peakDegrees;

  /// Where along the ride [peakDegrees] happened, so the chart can point at it
  /// instead of leaving the rider to hunt for the tallest spike themselves.
  final double? peakAtDistanceMeters;
  final double? peakAtSeconds;

  /// Seconds spent in each 5° band, ascending. Time-weighted rather than
  /// sample-counted, because fixes are not evenly spaced and "time spent past
  /// 15°" is the question a rider actually has.
  final List<LeanBand> histogram;

  final int leftSamples;
  final int rightSamples;

  /// Per-side 95th percentiles, for the left/right balance read. Null when that
  /// side has too few samples to characterise.
  final double? leftP95Degrees;
  final double? rightP95Degrees;

  /// Which heading source produced [samples].
  final LeanHeadingSource source;

  static const empty = LeanAnalysis(
    samples: [],
    p95Degrees: null,
    peakDegrees: null,
    histogram: [],
    leftSamples: 0,
    rightSamples: 0,
    leftP95Degrees: null,
    rightP95Degrees: null,
    source: LeanHeadingSource.positionBearing,
  );

  bool get hasEstimate => p95Degrees != null;

  /// Total seconds spent leaning past [degrees] — the histogram's tail.
  double secondsBeyond(double degrees) => histogram
      .where((b) => b.fromDegrees >= degrees)
      .fold(0.0, (sum, b) => sum + b.seconds);

  /// A one-word read on [p95Degrees], for the plain-language takeaway. Bands are
  /// set against what the estimator actually resolves on road riding, not against
  /// a racetrack.
  String get band {
    final p = p95Degrees;
    if (p == null) return 'unrated';
    if (p >= 25) return 'committed';
    if (p >= 18) return 'brisk';
    if (p >= 11) return 'flowing';
    if (p >= 6) return 'relaxed';
    return 'upright';
  }

  /// How the ride's lean splits left versus right, or null when one side is
  /// missing or the two are close enough that the difference is noise.
  ///
  /// Road riding comes out near-symmetric — measured across the whole history,
  /// 13,605 left samples against 12,920 right — so this only speaks up when a
  /// ride genuinely favours one side.
  String? get balance {
    final l = leftP95Degrees;
    final r = rightP95Degrees;
    if (l == null || r == null) return null;
    final diff = (l - r).abs();
    if (diff < 2.0) return 'evenly balanced left and right';
    final side = l > r ? 'left' : 'right';
    return 'leans ${diff.toStringAsFixed(0)}° further $side';
  }
}

/// Shortest signed turn from [a] to [b], in (−180°, 180°].
///
/// Without this a 359° → 1° crossing reads as a 358° swerve instead of the 2°
/// correction it is — and at 60 km/h that single sign error fabricates a
/// physically impossible corner.
double signedTurnDegrees(double a, double b) {
  var d = (b - a) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

/// Initial bearing from point 1 to point 2, in degrees (0 = north, clockwise).
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  const toRad = math.pi / 180.0;
  final p1 = lat1 * toRad;
  final p2 = lat2 * toRad;
  final dl = (lon2 - lon1) * toRad;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return math.atan2(y, x) * 180.0 / math.pi;
}

/// Picks the heading source [readings] can support.
LeanHeadingSource chooseHeadingSource(List<LeanReading> readings) {
  if (readings.isEmpty) return LeanHeadingSource.positionBearing;
  var withCourse = 0;
  for (final r in readings) {
    if (r.headingDegrees != null) withCourse++;
  }
  return withCourse / readings.length >= kReportedCourseMinCoverage
      ? LeanHeadingSource.reportedCourse
      : LeanHeadingSource.positionBearing;
}

/// Analyses [readings] (a ride's track, in order) into its cornering profile.
///
/// Pass [source] to force a heading source; by default the better one the data
/// supports is chosen. Rides recorded before headings were stored fall back to
/// position-bearing automatically.
LeanAnalysis analyseLean(
  List<LeanReading> readings, {
  LeanHeadingSource? source,
}) {
  final chosen = source ?? chooseHeadingSource(readings);
  final half = kLeanHalfWindow[chosen]!;
  final step = half + 1;
  if (readings.length < 2 * step + 1) return LeanAnalysis.empty;

  final start = readings.first.time;

  // Cumulative distance along the track, so a sample can be placed on the same
  // x-axis the speed chart uses.
  final cumulative = List<double>.filled(readings.length, 0.0);
  for (var i = 1; i < readings.length; i++) {
    cumulative[i] = cumulative[i - 1] +
        haversineMeters(
          readings[i - 1].latitude,
          readings[i - 1].longitude,
          readings[i].latitude,
          readings[i].longitude,
        );
  }

  final samples = <LeanSample>[];
  // Index of the centre reading each sample came from, so corroboration can tell
  // genuinely consecutive samples from ones straddling a dropped stretch.
  final centreIndex = <int>[];
  final bandSeconds = <int, double>{};

  for (var i = step; i + step < readings.length; i++) {
    final a = readings[i - step];
    final b = readings[i];
    final c = readings[i + step];

    final dt1 = b.time.difference(a.time).inMilliseconds / 1000.0;
    final dt2 = c.time.difference(b.time).inMilliseconds / 1000.0;
    // Guarded per leg, so a blackout inside the window is caught even when the
    // total span still looks reasonable.
    if (dt1 < kMinLeanDtSeconds || dt2 < kMinLeanDtSeconds) continue;
    if (dt1 > kMaxLeanDtSeconds || dt2 > kMaxLeanDtSeconds) continue;

    // Heading into and out of the window, and the turn between them.
    final double h1;
    final double h2;
    final double omegaSpan;
    if (chosen == LeanHeadingSource.reportedCourse) {
      final ha = a.headingDegrees;
      final hc = c.headingDegrees;
      if (ha == null || hc == null) continue;
      h1 = ha;
      h2 = hc;
      omegaSpan = dt1 + dt2;
    } else {
      h1 = bearingDegrees(a.latitude, a.longitude, b.latitude, b.longitude);
      h2 = bearingDegrees(b.latitude, b.longitude, c.latitude, c.longitude);
      // Two bearings measured over adjacent legs are separated by the mean of
      // those legs, not their sum — each bearing sits at its own leg's midpoint.
      omegaSpan = (dt1 + dt2) / 2.0;
    }
    if (omegaSpan <= 0) continue;

    // Smooth-arc check. Applies whichever heading source is in play, because it
    // asks a question about the positions rather than the heading: did the bike
    // actually sweep through this window, or did the fixes scatter?
    final legA =
        haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude);
    final legB =
        haversineMeters(b.latitude, b.longitude, c.latitude, c.longitude);
    final chord =
        haversineMeters(a.latitude, a.longitude, c.latitude, c.longitude);
    final path = legA + legB;
    if (path <= 0) continue;
    if (chord / path < kMinChordRatio) continue;

    final omega = signedTurnDegrees(h1, h2) * (math.pi / 180.0) / omegaSpan;

    // Prefer the fix's own Doppler speed — accurate even where position is
    // noisy — and fall back to displacement across the window.
    var vMps = b.speedMps;
    if (!vMps.isFinite || vMps <= 0) {
      final span = dt1 + dt2;
      vMps = span > 0
          ? haversineMeters(a.latitude, a.longitude, c.latitude, c.longitude) /
              span
          : 0.0;
    }
    if (vMps * 3.6 < kMinLeanSpeedKmh) continue;

    final magnitude = math.atan((vMps * omega.abs()) / kGravity) * 180.0 / math.pi;
    if (magnitude > kMaxPlausibleLeanDegrees) continue;
    final leanDegrees = omega < 0 ? -magnitude : magnitude;

    samples.add((
      tSec: b.time.difference(start).inMilliseconds / 1000.0,
      distanceMeters: cumulative[i],
      leanDegrees: leanDegrees,
      speedKmh: vMps * 3.6,
    ));
    centreIndex.add(i);

    // Time-weight the band by the interval this sample stands for.
    final bandFrom = (magnitude ~/ 5) * 5;
    bandSeconds[bandFrom] = (bandSeconds[bandFrom] ?? 0) + (dt1 + dt2) / 2.0;
  }

  if (samples.length < kMinLeanSamples) return LeanAnalysis.empty;

  final abs = [for (final s in samples) s.leanDegrees.abs()]..sort();
  final left = [
    for (final s in samples)
      if (s.leanDegrees < 0) -s.leanDegrees,
  ]..sort();
  final right = [
    for (final s in samples)
      if (s.leanDegrees > 0) s.leanDegrees,
  ]..sort();

  final histogram = <LeanBand>[
    for (final from in bandSeconds.keys.toList()..sort())
      (fromDegrees: from, toDegrees: from + 5, seconds: bandSeconds[from]!),
  ];

  final peak = _corroboratedPeak(samples, centreIndex);

  return LeanAnalysis(
    samples: samples,
    p95Degrees: _percentile(abs, 0.95),
    peakDegrees: peak?.value,
    peakAtDistanceMeters:
        peak == null ? null : samples[peak.atIndex].distanceMeters,
    peakAtSeconds: peak == null ? null : samples[peak.atIndex].tSec,
    histogram: histogram,
    leftSamples: left.length,
    rightSamples: right.length,
    // A side needs enough of its own samples before its percentile means
    // anything; a third of the overall floor is the smallest defensible share.
    leftP95Degrees:
        left.length >= kMinLeanSamples ~/ 3 ? _percentile(left, 0.95) : null,
    rightP95Degrees:
        right.length >= kMinLeanSamples ~/ 3 ? _percentile(right, 0.95) : null,
    source: chosen,
  );
}

/// Largest |lean| sustained across [kPeakCorroborationSamples] consecutive
/// samples — i.e. the greatest value `v` for which that many samples in a row all
/// reach `v`, **leaning the same way**.
///
/// Computed as the maximum over sliding windows of each window's minimum, which is
/// exactly "the level all of them clear". Three things must hold for a window to
/// count, and each one exists because something got through without it:
///
///  - adjacent in the track, and close in time, so estimates either side of a
///    dropped stretch cannot vouch for each other;
///  - the same sign, because a real corner leans one way. Scatter that happens to
///    alternate left-right-left otherwise corroborates itself perfectly — which is
///    how a periodic zigzag can slip past even the smooth-arc check when its period
///    lines up with the window spacing.
({double value, int atIndex})? _corroboratedPeak(
    List<LeanSample> samples, List<int> centreIndex) {
  const k = kPeakCorroborationSamples;
  if (samples.length < k) return null;
  double? best;
  var bestAt = 0;
  for (var i = 0; i + k - 1 < samples.length; i++) {
    var windowMin = double.infinity;
    var usable = true;
    for (var j = i; j < i + k; j++) {
      if (j > i) {
        final sameSide = samples[j].leanDegrees.isNegative ==
            samples[j - 1].leanDegrees.isNegative;
        if (!sameSide ||
            centreIndex[j] != centreIndex[j - 1] + 1 ||
            samples[j].tSec - samples[j - 1].tSec > kCorroborationMaxGapSeconds) {
          usable = false;
          break;
        }
      }
      final m = samples[j].leanDegrees.abs();
      if (m < windowMin) windowMin = m;
    }
    if (!usable) continue;
    if (best == null || windowMin > best) {
      best = windowMin;
      // Report the window's strongest sample as the peak's location — that is the
      // apex the rider would point at, and it is inside the corroborated run.
      var apex = i;
      for (var j = i; j < i + k; j++) {
        if (samples[j].leanDegrees.abs() > samples[apex].leanDegrees.abs()) {
          apex = j;
        }
      }
      bestAt = apex;
    }
  }
  return best == null ? null : (value: best, atIndex: bestAt);
}

/// Smooths [samples] for **drawing only**, with a centred moving average.
///
/// Never feeds the numbers: [analyseLean]'s percentile and peak come from the raw
/// samples, because a smoothed trace has had exactly the extremes removed that the
/// peak is asking about. This is the same division the smoothness chart draws — the
/// analysis reports the truth and the *drawing* concern lives at the drawing layer.
///
/// It exists because the unsmoothed line was unreadable: at ~1 Hz, plotting every
/// sample renders a hairball of jitter in which the handful of real corners
/// disappear. A five-sample window is about the length of a corner at road speed,
/// so it removes single-sample noise while leaving the shape a corner makes.
List<LeanSample> smoothLeanForDisplay(
  List<LeanSample> samples, {
  int window = kLeanDisplaySmoothWindow,
}) {
  if (samples.length < 3 || window < 3) return samples;
  final half = window ~/ 2;
  final out = <LeanSample>[];
  for (var i = 0; i < samples.length; i++) {
    final from = (i - half).clamp(0, samples.length - 1);
    final to = (i + half).clamp(0, samples.length - 1);
    var sum = 0.0;
    for (var j = from; j <= to; j++) {
      sum += samples[j].leanDegrees;
    }
    out.add((
      tSec: samples[i].tSec,
      distanceMeters: samples[i].distanceMeters,
      leanDegrees: sum / (to - from + 1),
      speedKmh: samples[i].speedKmh,
    ));
  }
  return out;
}

/// Linear-index percentile of an already-ascending [sorted] list.
double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}
