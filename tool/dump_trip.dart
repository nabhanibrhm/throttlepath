// One-off diagnostic: open a pulled Isar DB and analyse every stint of a trip.
//
// Companion to dump_ride.dart, which only ever looks at a single ride. This one
// walks a trip's stints in order, prints per-stint anomaly diagnostics, and
// separates *phantom* distance (straight lines bridged across a GPS blackout)
// from ridden distance — the distinction that tells you whether the tracking
// service's blackout guards actually fired.
//
// Run: dart run tool/dump_trip.dart <dbDir> [tripName]
import 'dart:math' as math;

import 'package:isar_community/isar.dart';
import 'package:throttlepath/core/geo.dart';
import 'package:throttlepath/core/lean.dart';
import 'package:throttlepath/core/route_blob.dart';
// kSignalLossSeconds — the gap at which the engine declares a blackout, freezes
// the clock, and re-anchors instead of bridging. Segments longer than this are
// the ones the guards should have excluded from stored distance. Imported rather
// than redeclared so this tool can never disagree with the app about what counts
// as a blackout.
import 'package:throttlepath/core/track_runs.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/data/models/trip.dart';

String _hms(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = (totalSeconds % 3600) ~/ 60;
  final s = totalSeconds % 60;
  return h > 0
      ? '${h}h${m.toString().padLeft(2, '0')}m${s.toString().padLeft(2, '0')}s'
      : '${m}m${s.toString().padLeft(2, '0')}s';
}

String _clock(DateTime t) => t.toIso8601String().substring(11, 19);

/// Prints a blob's vertex count and geographic extent, flagging the case where
/// the box is wide enough to have swallowed the real ride.
void _printBlob(
  String label,
  List<RoutePoint> blob,
  double phantomMeters,
  double storedMeters,
) {
  if (blob.isEmpty) {
    print('    $label  none');
    return;
  }
  double minLat = blob.first.lat, maxLat = blob.first.lat;
  double minLon = blob.first.lon, maxLon = blob.first.lon;
  for (final v in blob) {
    minLat = math.min(minLat, v.lat);
    maxLat = math.max(maxLat, v.lat);
    minLon = math.min(minLon, v.lon);
    maxLon = math.max(maxLon, v.lon);
  }
  final boxNS = haversineMeters(minLat, minLon, maxLat, minLon);
  final boxEW = haversineMeters(minLat, minLon, minLat, maxLon);
  print('    $label  ${blob.length} vertices'
      '   bbox ${(boxNS / 1000).toStringAsFixed(2)} km N-S'
      ' x ${(boxEW / 1000).toStringAsFixed(2)} km E-W');
  if (phantomMeters > 1000) {
    print('      !! bbox spans the phantom excursion — the real '
        '${(storedMeters / 1000).toStringAsFixed(2)} km ride is a speck inside it');
  }
}

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return 0;
  final idx = ((sorted.length - 1) * p).round();
  return sorted[idx];
}

/// One suspicious inter-fix interval.
typedef Gap = ({
  int index,
  double seconds,
  double bridgedMeters,
  double impliedKmh,
  DateTime from,
  DateTime to,
});

class StintReport {
  StintReport(this.ride, this.points);

  final Ride ride;
  final List<TrackPoint> points;

  double recomputedMeters = 0;
  double phantomMeters = 0; // bridged across >= kSignalLossSeconds gaps
  double maxGapSeconds = 0;
  final List<Gap> gaps = []; // >= 5s
  final List<Gap> blackouts = []; // >= kSignalLossSeconds
  int headingPresent = 0;
  int dupTimestamps = 0;
  double maxSegmentKmh = 0;
  LeanAnalysis lean = LeanAnalysis.empty;

  double get ridenMeters => recomputedMeters - phantomMeters;
  double get spanSeconds => points.length < 2
      ? 0
      : points.last.timestamp.difference(points.first.timestamp).inMilliseconds /
          1000.0;
  double get blackoutSeconds =>
      blackouts.fold(0.0, (sum, g) => sum + g.seconds);
  double get headingCoverage =>
      points.isEmpty ? 0 : headingPresent / points.length;

  void analyse() {
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      if (p.headingDegrees != null) headingPresent++;
      if (i == 0) continue;

      final prev = points[i - 1];
      final dtS =
          p.timestamp.difference(prev.timestamp).inMilliseconds / 1000.0;
      if (dtS <= 0) {
        dupTimestamps++;
        continue;
      }
      if (dtS > maxGapSeconds) maxGapSeconds = dtS;

      final d = haversineMeters(
          prev.latitude, prev.longitude, p.latitude, p.longitude);
      recomputedMeters += d;
      final segKmh = (d / dtS) * 3.6;
      if (segKmh > maxSegmentKmh) maxSegmentKmh = segKmh;

      if (dtS >= 5) {
        final gap = (
          index: i,
          seconds: dtS,
          bridgedMeters: d,
          impliedKmh: segKmh,
          from: prev.timestamp,
          to: p.timestamp,
        );
        gaps.add(gap);
        if (dtS >= kSignalLossSeconds) {
          blackouts.add(gap);
          phantomMeters += d;
        }
      }
    }

    lean = analyseLean([
      for (final p in points)
        (
          time: p.timestamp,
          speedMps: p.speedMps,
          headingDegrees: p.headingDegrees,
          latitude: p.latitude,
          longitude: p.longitude,
        )
    ]);
  }

  void printSummary(int ordinal) {
    print('');
    print('=' * 78);
    print('STINT $ordinal — id=${ride.id}  "${ride.name}"  [${ride.gpsSource ?? '?'}]');
    print('=' * 78);
    print('  start ${ride.startTime.toIso8601String().substring(0, 19)}'
        '   end ${ride.endTime?.toIso8601String().substring(11, 19) ?? '—'}');
    print('  place  ${ride.startPlace ?? '?'} -> ${ride.endPlace ?? '?'}');
    print('  fixes  ${points.length}'
        '   avg interval ${points.length < 2 ? '—' : (spanSeconds / (points.length - 1)).toStringAsFixed(2)}s'
        '   heading ${(headingCoverage * 100).toStringAsFixed(1)}%');

    print('  --- distance ---');
    print('    stored      ${(ride.totalDistanceMeters / 1000).toStringAsFixed(3)} km   (what the app shows)');
    print('    raw sum     ${(recomputedMeters / 1000).toStringAsFixed(3)} km   (haversine over all fixes)');
    if (phantomMeters > 1) {
      print('    phantom     ${(phantomMeters / 1000).toStringAsFixed(3)} km   '
          '<- straight lines across ${blackouts.length} blackout(s)');
      print('    ridden      ${(ridenMeters / 1000).toStringAsFixed(3)} km   (raw sum minus phantom)');
      final delta = ride.totalDistanceMeters - ridenMeters;
      print('    stored - ridden = ${delta.toStringAsFixed(0)} m'
          '  ${delta.abs() < 300 ? '(guards excluded the phantom: OK)' : '(!! mismatch)'}');
    }

    print('  --- time ---');
    print('    elapsed(stored) ${_hms(ride.durationSeconds)}'
        '   moving ${_hms(ride.movingSeconds)}'
        '   stopped ${_hms(ride.durationSeconds - ride.movingSeconds)}');
    print('    fix span        ${_hms(spanSeconds.round())}'
        '   (span - elapsed = ${(spanSeconds - ride.durationSeconds).toStringAsFixed(0)}s'
        '${blackoutSeconds > 0 ? ', blackout total ${blackoutSeconds.toStringAsFixed(0)}s' : ''})');

    print('  --- speed ---');
    print('    stored avg ${ride.averageSpeedKmh.toStringAsFixed(1)}'
        '   stored max ${ride.maxSpeedKmh.toStringAsFixed(1)}'
        '   max segment(calc) ${maxSegmentKmh.toStringAsFixed(1)} km/h');

    print('  --- gaps ---');
    print('    max ${maxGapSeconds.toStringAsFixed(1)}s'
        '   >=5s: ${gaps.length}'
        '   >=${kSignalLossSeconds}s (blackout): ${blackouts.length}'
        '   dup timestamps: $dupTimestamps');
    for (final g in blackouts.take(20)) {
      print('      BLACKOUT ${g.seconds.toStringAsFixed(1).padLeft(7)}s '
          'at #${g.index}  ${_clock(g.from)} -> ${_clock(g.to)}  '
          'bridged ${g.bridgedMeters.toStringAsFixed(0).padLeft(5)}m '
          '=> ${g.impliedKmh.toStringAsFixed(0)} km/h implied');
    }
    if (blackouts.length > 20) {
      print('      ... ${blackouts.length - 20} more blackouts');
    }

    // What the History sparkline and share card will actually draw. Compared
    // against the *ridden* extent, because a phantom excursion inflates the
    // blob's bounding box and squashes the real ride into a corner of it.
    print('  --- routeBlob (what the sparkline draws) ---');
    _printBlob(
      'stored  ',
      decodeRouteBlob(ride.routeBlob),
      phantomMeters,
      ride.totalDistanceMeters,
    );
    // What the current derivation rules would produce from this same track.
    // Mirrors `deriveRoute` (which can't be imported here — it reaches
    // DatabaseService, and so Flutter, which `dart run` cannot compile): segment
    // the track, then encode. Lets a re-derive be checked before reinstalling.
    _printBlob(
      're-derived',
      decodeRouteBlob(encodeRouteBlob([
        for (final p in segmentTrackPoints(points).points)
          (lat: p.latitude, lon: p.longitude),
      ])),
      0,
      ride.totalDistanceMeters,
    );
    print('    stored blob was written by derivation '
        'v${ride.derivedVersion ?? 1}');

    print('  --- lean ---');
    if (!lean.hasEstimate) {
      print('    no estimate (samples too few/slow)');
    } else {
      print('    source ${lean.source.name}'
          '   p95 ${lean.p95Degrees!.toStringAsFixed(1)}°'
          '   peak ${lean.peakDegrees!.toStringAsFixed(1)}°'
          '   band ${lean.band}');
      print('    samples ${lean.samples.length}'
          ' (L ${lean.leftSamples} / R ${lean.rightSamples})'
          '   ${lean.balance ?? 'balance n/a'}');
      final peakT = lean.peakAtSeconds;
      if (peakT != null) {
        final peakAt = points.first.timestamp
            .add(Duration(milliseconds: (peakT * 1000).round()));
        // Was the peak manufactured by a heading discontinuity across a dead
        // zone? If it sits inside a blackout window, distrust it.
        final near = blackouts.where((g) =>
            peakAt.isAfter(g.from.subtract(const Duration(seconds: 10))) &&
            peakAt.isBefore(g.to.add(const Duration(seconds: 10))));
        print('    peak at ${_clock(peakAt)} (t+${peakT.toStringAsFixed(0)}s)'
            '${near.isEmpty ? '  — clear of blackouts' : '  !! adjacent to a blackout'}');
      }
    }
  }

  /// Per-fix detail around each blackout boundary, plus a displacement profile
  /// against the ride's first fix. This is what tells a genuine dead-zone
  /// (GPS returns near where it left) from a position excursion (GPS returns
  /// kilometres away, reports coherent motion there, then snaps back).
  void printDrill() {
    if (points.isEmpty) return;
    final lat0 = points.first.latitude;
    final lon0 = points.first.longitude;
    double fromStart(TrackPoint p) =>
        haversineMeters(lat0, lon0, p.latitude, p.longitude);

    print('');
    print('-' * 78);
    print('DRILL — stint id=${ride.id} "${ride.name}"');
    print('-' * 78);
    print('  displacement from first fix (metres), sampled every 50 fixes:');
    final buf = StringBuffer('   ');
    for (var i = 0; i < points.length; i += 50) {
      buf.write(fromStart(points[i]).toStringAsFixed(0).padLeft(7));
      if ((i ~/ 50) % 10 == 9) {
        print(buf.toString());
        buf.clear();
        buf.write('   ');
      }
    }
    if (buf.length > 3) print(buf.toString());

    void dumpFix(int i, String tag) {
      if (i < 0 || i >= points.length) return;
      final p = points[i];
      print('    $tag #${i.toString().padLeft(4)} ${_clock(p.timestamp)}  '
          '${p.latitude.toStringAsFixed(5)},${p.longitude.toStringAsFixed(5)}  '
          'spd ${(p.speedMps * 3.6).toStringAsFixed(1).padLeft(5)} km/h  '
          'hdg ${p.headingDegrees?.toStringAsFixed(0).padLeft(3) ?? ' — '}  '
          'from-start ${fromStart(p).toStringAsFixed(0).padLeft(6)}m');
    }

    for (final g in blackouts) {
      print('');
      print('  BLACKOUT at #${g.index}  ${g.seconds.toStringAsFixed(1)}s  '
          'bridged ${g.bridgedMeters.toStringAsFixed(0)}m:');
      for (var k = 3; k >= 1; k--) {
        dumpFix(g.index - k, 'before');
      }
      dumpFix(g.index - 1, 'LAST  ');
      dumpFix(g.index, 'FIRST ');
      for (var k = 1; k <= 3; k++) {
        dumpFix(g.index + k, 'after ');
      }
    }
  }
}

Future<void> main(List<String> args) async {
  final dbDir = args.isNotEmpty ? args[0] : 'tool/pulled_db';
  final wantTrip = args.length > 1 ? args[1] : null;
  // Optional: 1-based stint ordinal to dump per-fix detail for.
  final drillStint = args.length > 2 ? int.tryParse(args[2]) : null;

  await Isar.initializeIsarCore(download: true);
  // Every collection in the file MUST be listed: Isar DROPS any collection
  // missing from the schema list on open.
  final isar = await Isar.open(
    [RideSchema, TrackPointSchema, TripSchema],
    directory: dbDir,
    name: 'default',
    inspector: false,
  );

  final trips = await isar.trips.where().findAll();
  print('=== TRIPS IN DB (${trips.length}) ===');
  for (final t in trips) {
    final stintCount =
        await isar.rides.filter().tripIdEqualTo(t.id).count();
    print('  id=${t.id}  "${t.name ?? '(unnamed)'}"  '
        '${t.isOpen ? 'OPEN' : 'finished ${t.finishedAt!.toIso8601String().substring(0, 19)}'}  '
        'created ${t.createdAt.toIso8601String().substring(0, 19)}  '
        'stints=$stintCount');
  }

  final trip = wantTrip == null
      ? trips.last
      : trips.firstWhere(
          (t) => (t.name ?? '').toLowerCase().contains(wantTrip.toLowerCase()),
          orElse: () => trips.last,
        );

  final stints = await isar.rides
      .filter()
      .tripIdEqualTo(trip.id)
      .sortByStartTime()
      .findAll();

  print('');
  print('#' * 78);
  print('TRIP id=${trip.id} "${trip.name ?? '(unnamed)'}" — ${stints.length} stints');
  print('#' * 78);

  final reports = <StintReport>[];
  for (final s in stints) {
    final pts = await isar.trackPoints
        .filter()
        .rideIdEqualTo(s.id)
        .sortByTimestamp()
        .findAll();
    final r = StintReport(s, pts)..analyse();
    reports.add(r);
  }

  for (var i = 0; i < reports.length; i++) {
    reports[i].printSummary(i + 1);
    if (drillStint == i + 1) reports[i].printDrill();
  }

  // ---- trip roll-up ----
  print('');
  print('#' * 78);
  print('TRIP TOTALS');
  print('#' * 78);
  final storedKm =
      reports.fold(0.0, (s, r) => s + r.ride.totalDistanceMeters) / 1000;
  final rawKm = reports.fold(0.0, (s, r) => s + r.recomputedMeters) / 1000;
  final phantomKm = reports.fold(0.0, (s, r) => s + r.phantomMeters) / 1000;
  final elapsed = reports.fold(0, (s, r) => s + r.ride.durationSeconds);
  final moving = reports.fold(0, (s, r) => s + r.ride.movingSeconds);
  final fixes = reports.fold(0, (s, r) => s + r.points.length);
  final blackoutCount = reports.fold(0, (s, r) => s + r.blackouts.length);
  final blackoutSec = reports.fold(0.0, (s, r) => s + r.blackoutSeconds);
  final maxSpeed = reports.fold(0.0, (s, r) => math.max(s, r.ride.maxSpeedKmh));

  print('  distance   stored ${storedKm.toStringAsFixed(2)} km'
      '   raw sum ${rawKm.toStringAsFixed(2)} km'
      '   phantom ${phantomKm.toStringAsFixed(2)} km');
  print('  time       elapsed ${_hms(elapsed)}   moving ${_hms(moving)}');
  print('  fixes      $fixes'
      '   blackouts $blackoutCount totalling ${blackoutSec.toStringAsFixed(0)}s');
  print('  max speed  ${maxSpeed.toStringAsFixed(1)} km/h');
  print('  avg speed  ${(storedKm / (moving / 3600)).toStringAsFixed(1)} km/h (moving)');

  print('');
  print('  per-stint one-liners:');
  for (var i = 0; i < reports.length; i++) {
    final r = reports[i];
    final leanTxt = r.lean.hasEstimate
        ? 'lean p95 ${r.lean.p95Degrees!.toStringAsFixed(0)}°/peak ${r.lean.peakDegrees!.toStringAsFixed(0)}°'
        : 'lean n/a';
    print('    ${(i + 1).toString().padLeft(2)}. ${(r.ride.name ?? '?').padRight(20)}'
        ' ${(r.ride.totalDistanceMeters / 1000).toStringAsFixed(2).padLeft(6)} km'
        '  ${_hms(r.ride.durationSeconds).padLeft(9)}'
        '  ${r.blackouts.length} blackout(s)'
        '  ${r.phantomMeters > 1 ? '${(r.phantomMeters / 1000).toStringAsFixed(2)} km phantom' : 'clean'}'
        '  $leanTxt');
  }

  // ---- global percentile context for the lean numbers ----
  final allLean = <double>[];
  for (final r in reports) {
    allLean.addAll(r.lean.samples.map((s) => s.leanDegrees.abs()));
  }
  allLean.sort();
  if (allLean.isNotEmpty) {
    print('');
    print('  trip-wide lean: n=${allLean.length}'
        '  p50 ${_percentile(allLean, 0.50).toStringAsFixed(1)}°'
        '  p95 ${_percentile(allLean, 0.95).toStringAsFixed(1)}°'
        '  p99 ${_percentile(allLean, 0.99).toStringAsFixed(1)}°'
        '  max ${allLean.last.toStringAsFixed(1)}°');
  }

  await isar.close();
}
