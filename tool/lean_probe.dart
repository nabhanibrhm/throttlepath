// One-off feasibility probe for the LEAN ANGLE feature (brainstorm evidence, not
// app code). Answers one question against real recorded rides: is a GPS-derived
// lean estimate signal or noise, and at what smoothing baseline?
//
// theta = atan(v * omega / g)   [coordinated-turn / no-slip lean]
//   v     = ground speed (m/s)
//   omega = yaw rate (rad/s) = d(heading)/dt
//
// Stored TrackPoints carry NO heading (the field does not exist yet), so heading
// here is the bearing between stored *raw* positions — deliberately the worst
// case, which is exactly what an old-ride backfill would have to use.
//
// Three estimators at widening baselines quantify the noise/lag tradeoff:
//   E1: adjacent fixes            (~1.4 s baseline)  - sharpest, noisiest
//   E2: +/-1 fix                  (~2.8 s baseline)
//   E3: +/-2 fixes                (~5.6 s baseline)  - smoothest, most lag
//
// The key honesty test is the HIGH-SPEED subset: above 70 km/h you are on a road
// whose curves are engineered for a handful of degrees of lean, so any large lean
// reported there is measurement noise, not riding.
//
// Run: dart run tool/lean_probe.dart tool/pulled_db
import 'dart:math' as math;

import 'package:isar_community/isar.dart';
import 'package:throttlepath/core/lean.dart' as prod;
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/data/models/trip.dart';

const double _g = 9.80665;

/// Samples below this speed are dropped: heading between two nearly-coincident
/// fixes is undefined, and a slow paddling U-turn produces a large omega with no
/// real lean behind it.
const double _minSpeedKmh = 20.0;

/// Interval guards, mirroring the smoothness module: sub-second steps are noise
/// and long ones span a pause or a GPS blackout, where the heading discontinuity
/// across the gap would manufacture a yaw rate that never happened.
const double _minDtS = 0.5;
const double _maxDtS = 10.0;

/// A road bike scrapes a footpeg near 45 deg; past this is not riding, it is a
/// bad fix. Rejected rather than clamped - clamping would pile fake mass onto
/// the cap and make the number look confident.
const double _maxPlausibleLeanDeg = 55.0;

double _rad(double d) => d * math.pi / 180.0;
double _deg(double r) => r * 180.0 / math.pi;

double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Initial bearing from 1 to 2, in degrees (0 = north, clockwise).
double _bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final p1 = _rad(lat1);
  final p2 = _rad(lat2);
  final dl = _rad(lon2 - lon1);
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return _deg(math.atan2(y, x));
}

/// Shortest signed turn from a to b, in (-180, 180]. Without this a 359 -> 1
/// crossing reads as a 358 deg swerve instead of a 2 deg correction.
double _signedTurnDeg(double a, double b) {
  var d = (b - a) % 360.0;
  if (d > 180.0) d -= 360.0;
  if (d <= -180.0) d += 360.0;
  return d;
}

/// One lean estimate: signed (negative = left, positive = right) and its speed.
typedef LeanSample = ({double leanDeg, double speedKmh});

/// Where the yaw rate comes from. The whole point of Phase 1 is to measure how
/// much [reported] beats [positionBearing], since only the former can justify a
/// short enough baseline to catch a corner's actual peak.
enum HeadingSource {
  /// Bearing differenced from two stored raw positions. The only option for rides
  /// recorded before `TrackPoint.headingDegrees` existed.
  positionBearing,

  /// The fix's own Doppler course over ground.
  reported,
}

/// Estimate lean across [pts] using a half-window of [half] fixes either side.
/// half=0 compares adjacent fixes; half=1 spans 2 intervals; half=2 spans 4.
///
/// Returns an empty list when [source] is [HeadingSource.reported] but the track
/// carries no heading, so an old ride reads as "no data" instead of silently
/// falling back and flattering the comparison.
List<LeanSample> _estimate(
  List<TrackPoint> pts,
  int half, {
  HeadingSource source = HeadingSource.positionBearing,
}) {
  final out = <LeanSample>[];
  final step = half + 1;
  for (var i = step; i + step < pts.length; i++) {
    final a = pts[i - step];
    final b = pts[i];
    final c = pts[i + step];

    final dtS = c.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
    if (dtS <= 0) continue;
    // Guards are applied per leg, so a blackout inside the window is caught even
    // when the total span still looks reasonable.
    final dt1 = b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
    final dt2 = c.timestamp.difference(b.timestamp).inMilliseconds / 1000.0;
    if (dt1 < _minDtS || dt2 < _minDtS) continue;
    if (dt1 > _maxDtS || dt2 > _maxDtS) continue;

    // Heading in, heading out, and the turn between them.
    final double h1;
    final double h2;
    if (source == HeadingSource.reported) {
      // Straddle the same span the position bearings do: the course reported at
      // the window's ends, so the two estimators differ only in heading source.
      final ha = a.headingDegrees;
      final hc = c.headingDegrees;
      if (ha == null || hc == null) continue;
      h1 = ha;
      h2 = hc;
    } else {
      h1 = _bearingDeg(a.latitude, a.longitude, b.latitude, b.longitude);
      h2 = _bearingDeg(b.latitude, b.longitude, c.latitude, c.longitude);
    }
    final turnDeg = _signedTurnDeg(h1, h2);

    // Yaw rate over the span the two headings straddle.
    final omega = _rad(turnDeg) /
        (source == HeadingSource.reported ? dtS : (dt1 + dt2) / 2.0);

    // Prefer the fix's own Doppler speed (accurate even where position is noisy)
    // and fall back to displacement when it is missing.
    var vMps = b.speedMps;
    if (!vMps.isFinite || vMps <= 0) {
      final d = _haversineMeters(a.latitude, a.longitude, c.latitude, c.longitude);
      vMps = d / dtS;
    }
    final speedKmh = vMps * 3.6;
    if (speedKmh < _minSpeedKmh) continue;

    final leanDeg = _deg(math.atan((vMps * omega.abs()) / _g)) * (omega < 0 ? -1 : 1);
    if (leanDeg.abs() > _maxPlausibleLeanDeg) continue;
    out.add((leanDeg: leanDeg, speedKmh: speedKmh));
  }
  return out;
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}

String _f(double v, [int d = 1]) => v.toStringAsFixed(d);

/// Distribution of |lean| plus the left/right split.
({
  int n,
  double p50,
  double p95,
  double p99,
  double max,
  double leftMax,
  double rightMax,
  int leftN,
  int rightN,
}) _stats(List<LeanSample> s) {
  final abs = s.map((e) => e.leanDeg.abs()).toList()..sort();
  final left = s.where((e) => e.leanDeg < 0).toList();
  final right = s.where((e) => e.leanDeg > 0).toList();
  return (
    n: s.length,
    p50: _percentile(abs, 0.50),
    p95: _percentile(abs, 0.95),
    p99: _percentile(abs, 0.99),
    max: abs.isEmpty ? 0.0 : abs.last,
    leftMax: left.isEmpty
        ? 0.0
        : left.map((e) => e.leanDeg.abs()).reduce(math.max),
    rightMax: right.isEmpty
        ? 0.0
        : right.map((e) => e.leanDeg).reduce(math.max),
    leftN: left.length,
    rightN: right.length,
  );
}

Future<void> main(List<String> args) async {
  final dbDir = args.isNotEmpty ? args[0] : 'tool/pulled_db';

  await Isar.initializeIsarCore(download: true);
  // Every collection in the file MUST be listed - Isar DROPS any collection
  // missing from the schema list on open. Point this at a PULLED COPY only.
  final isar = await Isar.open(
    [RideSchema, TrackPointSchema, TripSchema],
    directory: dbDir,
    name: 'default',
    inspector: false,
  );

  final rides = await isar.rides.where().sortByStartTime().findAll();
  print('=== LEAN FEASIBILITY PROBE over ${rides.length} rides ===');
  print('speed floor ${_f(_minSpeedKmh, 0)} km/h  '
      'reject |lean| > ${_f(_maxPlausibleLeanDeg, 0)} deg  '
      'dt in [$_minDtS, $_maxDtS] s\n');

  // Per-ride table for the three estimators.
  print('ride                                  pts  intvl |  '
      'E1 p95/max     E2 p95/max     E3 p95/max   | E3 n');
  print('-' * 104);

  final allE1 = <LeanSample>[];
  final allE2 = <LeanSample>[];
  final allE3 = <LeanSample>[];
  var analysed = 0;

  for (final ride in rides) {
    final pts = await isar.trackPoints
        .filter()
        .rideIdEqualTo(ride.id)
        .sortByTimestamp()
        .findAll();
    if (pts.length < 60) continue;
    analysed++;

    final spanS =
        pts.last.timestamp.difference(pts.first.timestamp).inMilliseconds /
            1000.0;
    final intvl = spanS / (pts.length - 1);

    final e1 = _estimate(pts, 0);
    final e2 = _estimate(pts, 1);
    final e3 = _estimate(pts, 2);
    allE1.addAll(e1);
    allE2.addAll(e2);
    allE3.addAll(e3);

    final s1 = _stats(e1);
    final s2 = _stats(e2);
    final s3 = _stats(e3);
    final label = 'id=${ride.id} "${ride.name ?? '?'}"';
    print('${label.padRight(36).substring(0, 36)} '
        '${pts.length.toString().padLeft(5)} '
        '${_f(intvl, 2).padLeft(5)}s | '
        '${_f(s1.p95).padLeft(5)}/${_f(s1.max).padLeft(5)}  '
        '${_f(s2.p95).padLeft(5)}/${_f(s2.max).padLeft(5)}  '
        '${_f(s3.p95).padLeft(5)}/${_f(s3.max).padLeft(5)}  | '
        '${s3.n.toString().padLeft(5)}');
  }

  print('\n=== AGGREGATE over $analysed rides ===');
  for (final (name, baseline, s) in [
    ('E1 adjacent  ', '~1 interval ', _stats(allE1)),
    ('E2 +/-1 fix  ', '~2 intervals', _stats(allE2)),
    ('E3 +/-2 fixes', '~4 intervals', _stats(allE3)),
  ]) {
    print('$name ($baseline)  n=${s.n.toString().padLeft(6)}  '
        'p50=${_f(s.p50).padLeft(5)}  p95=${_f(s.p95).padLeft(5)}  '
        'p99=${_f(s.p99).padLeft(5)}  max=${_f(s.max).padLeft(5)}  '
        'L/R n=${s.leftN}/${s.rightN}  Lmax=${_f(s.leftMax)} Rmax=${_f(s.rightMax)}');
  }

  // THE NOISE TEST. Highway curves are engineered for single-digit lean, so the
  // lean an estimator reports at speed is dominated by its own error. Whichever
  // estimator collapses toward small angles here is the trustworthy one.
  print('\n=== NOISE TEST: samples above 70 km/h (real lean should be small) ===');
  for (final (name, all) in [('E1', allE1), ('E2', allE2), ('E3', allE3)]) {
    final fast = all.where((e) => e.speedKmh >= 70).toList();
    if (fast.isEmpty) {
      print('$name  no samples above 70 km/h');
      continue;
    }
    final s = _stats(fast);
    final over20 = fast.where((e) => e.leanDeg.abs() > 20).length;
    print('$name  n=${s.n.toString().padLeft(5)}  p50=${_f(s.p50).padLeft(5)}  '
        'p95=${_f(s.p95).padLeft(5)}  max=${_f(s.max).padLeft(5)}  '
        '|lean|>20deg: $over20 (${_f(100 * over20 / fast.length)}%)');
  }

  // PHASE 1'S DELIVERABLE. Doppler course is expected to beat position-bearing
  // badly enough to justify a shorter baseline — which is the difference between
  // reporting a corner's average lean and its peak. Only rides recorded after
  // TrackPoint.headingDegrees shipped can answer this, so on an old DB this
  // section correctly reports that it has nothing to compare.
  print('\n=== HEADING SOURCE COMPARISON (Phase 1 decision) ===');
  var ridesWithHeading = 0;
  var pointsWithHeading = 0;
  final reportedByBaseline = <int, List<LeanSample>>{0: [], 1: [], 2: []};
  final bearingByBaseline = <int, List<LeanSample>>{0: [], 1: [], 2: []};

  for (final ride in rides) {
    final pts = await isar.trackPoints
        .filter()
        .rideIdEqualTo(ride.id)
        .sortByTimestamp()
        .findAll();
    if (pts.length < 60) continue;
    final withHeading = pts.where((p) => p.headingDegrees != null).length;
    if (withHeading == 0) continue;
    ridesWithHeading++;
    pointsWithHeading += withHeading;
    for (final half in [0, 1, 2]) {
      reportedByBaseline[half]!
          .addAll(_estimate(pts, half, source: HeadingSource.reported));
      bearingByBaseline[half]!.addAll(_estimate(pts, half));
    }
  }

  if (ridesWithHeading == 0) {
    print('No stored headings yet — every ride in this DB predates '
        'TrackPoint.headingDegrees.');
    print('Record one ride on a build that stamps it, re-pull the DB (app '
        'force-stopped!), and re-run.');
  } else {
    print('$ridesWithHeading ride(s) carry heading, $pointsWithHeading points.\n');
    print('baseline  source            n      p50    p95    max   | >70km/h p95  max  >20deg');
    print('-' * 92);
    for (final half in [0, 1, 2]) {
      for (final (label, samples) in [
        ('doppler ', reportedByBaseline[half]!),
        ('bearing ', bearingByBaseline[half]!),
      ]) {
        if (samples.isEmpty) continue;
        final s = _stats(samples);
        final fast = samples.where((e) => e.speedKmh >= 70).toList();
        final fs = fast.isEmpty ? null : _stats(fast);
        final over20 = fast.where((e) => e.leanDeg.abs() > 20).length;
        final fastCol = fs == null
            ? '     n/a   n/a      n/a'
            : '${_f(fs.p95).padLeft(9)}${_f(fs.max).padLeft(6)}  '
                '$over20 (${_f(100 * over20 / fast.length)}%)';
        print('E${half + 1} ~${(half + 1) * 2 - 1}intv  $label'
            '${s.n.toString().padLeft(6)} '
            '${_f(s.p50).padLeft(6)} ${_f(s.p95).padLeft(6)} '
            '${_f(s.max).padLeft(6)}  |$fastCol');
      }
    }
    print('\nRead it this way: the winning combination is the SHORTEST baseline '
        'whose\n>70 km/h column stays in single digits with ~0% of samples past '
        '20deg.\nA shorter baseline that stays clean is strictly better — it '
        'resolves corners\nthe wider windows smear away.');
  }

  // Run the SHIPPED module over the same rides. The tables above come from this
  // file's own copy of the maths, which is the wrong thing to trust once real code
  // exists — this section is what confirms `core/lean.dart` produces the numbers
  // the rider will actually see, and that its guards fire on the train rides.
  print('\n=== PRODUCTION core/lean.dart OVER EVERY RIDE ===');
  print('ride                                  n      p95    peak  band'
      '          source');
  print('-' * 92);
  var scored = 0;
  var unscored = 0;
  for (final ride in rides) {
    final pts = await isar.trackPoints
        .filter()
        .rideIdEqualTo(ride.id)
        .sortByTimestamp()
        .findAll();
    if (pts.length < 60) continue;
    final a = prod.analyseLean([
      for (final p in pts)
        (
          time: p.timestamp,
          speedMps: p.speedMps,
          headingDegrees: p.headingDegrees,
          latitude: p.latitude,
          longitude: p.longitude,
        ),
    ]);
    final label = 'id=${ride.id} "${ride.name ?? '?'}"';
    if (!a.hasEstimate) {
      unscored++;
      print('${label.padRight(36).substring(0, 36)} '
          '${a.samples.length.toString().padLeft(5)}   '
          '(no estimate — too few usable samples)');
      continue;
    }
    scored++;
    print('${label.padRight(36).substring(0, 36)} '
        '${a.samples.length.toString().padLeft(5)} '
        '${_f(a.p95Degrees!).padLeft(6)} '
        '${_f(a.peakDegrees!).padLeft(6)}  '
        '${a.band.padRight(12)}  '
        '${a.source == prod.LeanHeadingSource.reportedCourse ? 'doppler' : 'bearing'}');
  }
  print('\n$scored ride(s) scored, $unscored without an estimate.');

  // How much of the distribution sits in each band, for the histogram the UI
  // would draw and to sanity-check that ordinary riding is mostly upright.
  print('\n=== |LEAN| HISTOGRAM (E3, the smoothest estimator) ===');
  final buckets = <int, int>{};
  for (final e in allE3) {
    buckets[(e.leanDeg.abs() ~/ 5) * 5] = (buckets[(e.leanDeg.abs() ~/ 5) * 5] ?? 0) + 1;
  }
  final keys = buckets.keys.toList()..sort();
  final total = allE3.length;
  for (final k in keys) {
    final n = buckets[k]!;
    final pct = total == 0 ? 0.0 : 100 * n / total;
    print('  ${k.toString().padLeft(2)}-${(k + 4).toString().padLeft(2)} deg: '
        '${'#' * (pct * 1.2).round().clamp(0, 60)} ${_f(pct)}% ($n)');
  }

  await isar.close();
}
