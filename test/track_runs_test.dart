import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/track_runs.dart';

/// A fix, as the module wants it.
typedef Fix = ({DateTime time, double lat, double lon});

Fix fixOf(Fix f) => f;

final _epoch = DateTime.utc(2026, 7, 31, 17, 0);

/// [count] fixes one second apart starting at [atSecond], walking north from
/// ([lat], [lon]) at roughly 20 km/h.
List<Fix> leg(int atSecond, int count, double lat, double lon) => [
      for (var i = 0; i < count; i++)
        (
          time: _epoch.add(Duration(seconds: atSecond + i)),
          lat: lat + i * 0.00005,
          lon: lon,
        ),
    ];

void main() {
  // The real ride area and the stale-ephemeris excursion from ride 44
  // ("Friday Trip" stint 2) — 17.9 km apart.
  const homeLat = -6.20027, homeLon = 106.82248;
  const driftLat = -6.25415, driftLon = 106.96199;

  group('splitIntoRuns', () {
    test('leaves a healthy track whole', () {
      final runs = splitIntoRuns(leg(0, 60, homeLat, homeLon), fixOf: fixOf);
      expect(runs, hasLength(1));
      expect(runs.single, hasLength(60));
    });

    test('cuts at the blackout threshold but not below it', () {
      final justUnder = [
        ...leg(0, 5, homeLat, homeLon),
        ...leg(4 + kSignalLossSeconds - 1, 5, homeLat, homeLon),
      ];
      expect(splitIntoRuns(justUnder, fixOf: fixOf), hasLength(1));

      final atThreshold = [
        ...leg(0, 5, homeLat, homeLon),
        ...leg(4 + kSignalLossSeconds, 5, homeLat, homeLon),
      ];
      expect(splitIntoRuns(atThreshold, fixOf: fixOf), hasLength(2));
    });

    test('handles an empty and a single-fix track', () {
      expect(splitIntoRuns(<Fix>[], fixOf: fixOf), isEmpty);
      expect(splitIntoRuns(leg(0, 1, homeLat, homeLon), fixOf: fixOf),
          hasLength(1));
    });
  });

  group('runStartIndices', () {
    test('agrees with splitIntoRuns about where the breaks are', () {
      final track = [
        ...leg(0, 120, homeLat, homeLon),
        ...leg(600, 120, homeLat, homeLon),
        ...leg(900, 120, homeLat, homeLon),
      ];
      expect(runStartIndices(track, fixOf: fixOf), [120, 240]);
      expect(splitIntoRuns(track, fixOf: fixOf).map((r) => r.length), [
        120,
        120,
        120,
      ]);
    });

    test('reproduces breakIndices on an already-segmented track', () {
      // The invariant the share card leans on. It is handed the *flattened* kept
      // fixes and no break list, and re-derives the joins from timestamps alone.
      // That is only safe if removing an excursion leaves a gap at the seam —
      // which it does, because the excursion was bracketed by two gaps of its own.
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(1500, 49, driftLat, driftLon),
        ...leg(1600, 60, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 49, reason: 'the fixture stopped dropping');
      expect(runStartIndices(seg.points, fixOf: fixOf), seg.breakIndices);
    });

    test('cuts at the threshold but not below it', () {
      expect(
        runStartIndices([
          ...leg(0, 5, homeLat, homeLon),
          ...leg(4 + kSignalLossSeconds - 1, 5, homeLat, homeLon),
        ], fixOf: fixOf),
        isEmpty,
      );
      expect(
        runStartIndices([
          ...leg(0, 5, homeLat, homeLon),
          ...leg(4 + kSignalLossSeconds, 5, homeLat, homeLon),
        ], fixOf: fixOf),
        [5],
      );
    });

    test('is empty for a healthy, an empty and a single-fix track', () {
      expect(runStartIndices(leg(0, 60, homeLat, homeLon), fixOf: fixOf),
          isEmpty);
      expect(runStartIndices(<Fix>[], fixOf: fixOf), isEmpty);
      expect(runStartIndices(leg(0, 1, homeLat, homeLon), fixOf: fixOf),
          isEmpty);
    });
  });

  group('segmentTrack', () {
    test('drops a bracketed excursion and keeps the ride', () {
      // The shape of stint 2: ride, 20-minute blackout, a coherent excursion
      // 17.9 km away, then back where we left off.
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(1500, 49, driftLat, driftLon),
        ...leg(1600, 60, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.runs, hasLength(2), reason: 'excursion removed, gap remains');
      expect(seg.discardedCount, 49);
      expect(seg.points, hasLength(360));
      expect(seg.hasBreaks, isTrue);
      expect(seg.breakIndices, [300]);
      for (final p in seg.points) {
        expect(p.lat, closeTo(homeLat, 0.05));
      }
    });

    test('keeps a displacement the ride never returns from', () {
      // A long tunnel: the rider comes out kilometres away and carries on. The
      // tail is not bracketed, so amputating it would delete real riding.
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(1500, 49, driftLat, driftLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0);
      expect(seg.runs, hasLength(2));
      expect(seg.points, hasLength(349));
    });

    test('keeps a bracketed excursion too large to be an artefact', () {
      // Same bracketing, but the "excursion" holds most of the recorded time —
      // at that point it is the ride, whatever the coordinates say.
      final track = [
        ...leg(0, 30, homeLat, homeLon),
        ...leg(100, 600, driftLat, driftLon),
        ...leg(800, 30, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0);
      expect(seg.runs, hasLength(3));
    });

    test('never splits or drops on ordinary scatter', () {
      // A gap, but the track resumes 40 m away — a parked rider, not a fault.
      final track = [
        ...leg(0, 120, homeLat, homeLon),
        ...leg(600, 120, homeLat + 0.00036, homeLon),
        ...leg(900, 120, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0);
      expect(seg.runs, hasLength(3), reason: 'gaps still break the polyline');
      expect(seg.points, hasLength(360));
    });

    test('an unbroken track is returned untouched', () {
      final track = leg(0, 200, homeLat, homeLon);
      final seg = segmentTrack(track, fixOf: fixOf);
      expect(seg.runs, hasLength(1));
      expect(seg.hasBreaks, isFalse);
      expect(seg.breakIndices, isEmpty);
      expect(seg.discardedCount, 0);
    });
  });

  group('cumulativeMeters', () {
    test('does not advance across a gap', () {
      final track = [
        ...leg(0, 3, homeLat, homeLon),
        // Resumes 400 m north after a 20-minute blackout.
        ...leg(1200, 3, homeLat + 0.0036, homeLon),
      ];

      final cumulative = cumulativeMeters(track, fixOf: fixOf);

      expect(cumulative.first, 0);
      // Two 5.5 m steps within the first run.
      expect(cumulative[2], closeTo(11.1, 1.0));
      // The 400 m jump contributes nothing.
      expect(cumulative[3], closeTo(cumulative[2], 0.01));
      expect(cumulative.last, closeTo(cumulative[2] + 11.1, 1.0));
    });

    test('matches plain accumulation on a healthy track', () {
      final track = leg(0, 100, homeLat, homeLon);
      final cumulative = cumulativeMeters(track, fixOf: fixOf);
      expect(cumulative.last, closeTo(99 * 5.55, 5));
    });

    test('is zero-length-safe', () {
      expect(cumulativeMeters(<Fix>[], fixOf: fixOf), isEmpty);
      expect(cumulativeMeters(leg(0, 1, homeLat, homeLon), fixOf: fixOf), [0.0]);
    });
  });

  group('mainStart / mainEnd', () {
    test('are the track ends on a healthy ride', () {
      final track = leg(0, 200, homeLat, homeLon);
      final seg = segmentTrack(track, fixOf: fixOf);
      expect(seg.mainStart, track.first);
      expect(seg.mainEnd, track.last);
    });

    test('are the track ends across an ordinary blackout', () {
      final track = [
        ...leg(0, 120, homeLat, homeLon),
        ...leg(600, 120, homeLat, homeLon),
      ];
      final seg = segmentTrack(track, fixOf: fixOf);
      expect(seg.mainStart, track.first);
      expect(seg.mainEnd, track.last);
    });

    test('skip a head phantom that segmentation cannot drop', () {
      // The case P2 exists for. A short spray of fixes 17.9 km away opens the
      // track; nothing precedes it, so it can never be bracketed and is kept.
      final track = [
        ...leg(0, 30, driftLat, driftLon),
        ...leg(200, 300, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0,
          reason: 'a head cluster is structurally undroppable');
      expect(seg.points.first.lat, closeTo(driftLat, 0.001),
          reason: 'the geometry still carries it');
      expect(seg.mainStart!.lat, closeTo(homeLat, 0.05),
          reason: 'but it does not get to say where the ride started');
      expect(seg.mainEnd, track.last);
    });

    test('skip a tail phantom that segmentation cannot drop', () {
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(400, 30, driftLat, driftLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0);
      expect(seg.mainStart, track.first);
      expect(seg.mainEnd!.lat, closeTo(homeLat, 0.05));
    });

    test('keep a large relocation — a tunnel is not a phantom', () {
      // Same shape as the tail-phantom case, but the rider carries on for far too
      // long at the new place for it to be an artefact. Disowning this endpoint
      // would misreport where a real ride finished.
      final track = [
        ...leg(0, 60, homeLat, homeLon),
        ...leg(200, 400, driftLat, driftLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 0);
      expect(seg.mainEnd!.lat, closeTo(driftLat, 0.05),
          reason: 'the new place holds most of the ride, so it is the ride');
    });

    test('survive a dropped excursion', () {
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(1500, 49, driftLat, driftLon),
        ...leg(1600, 60, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      expect(seg.discardedCount, 49);
      expect(seg.mainStart, track.first);
      expect(seg.mainEnd, track.last);
    });

    test('are null only for an empty track', () {
      final empty = segmentTrack(<Fix>[], fixOf: fixOf);
      expect(empty.mainStart, isNull);
      expect(empty.mainEnd, isNull);

      final single = segmentTrack(leg(0, 1, homeLat, homeLon), fixOf: fixOf);
      expect(single.mainStart, isNotNull);
      expect(single.mainEnd, isNotNull);
    });
  });

  group('kMaxDisplacedShare is a whole-ride budget', () {
    test('several small excursions cannot cumulatively exceed it', () {
      // Four excursions at ~11% each. Tested per cluster they all clear the 15%
      // cap and take away 45% of the ride between them, which is the failure this
      // guards: the cap is a budget, not an allowance each one gets to spend.
      //
      // All four sit at the *same* displaced spot, which matters — they cluster
      // together, so this also pins that a single cluster spread across four runs
      // is measured as one.
      final track = [
        ...leg(0, 60, homeLat, homeLon),
        ...leg(100, 30, driftLat, driftLon),
        ...leg(200, 30, homeLat, homeLon),
        ...leg(300, 30, driftLat, driftLon),
        ...leg(400, 30, homeLat, homeLon),
        ...leg(500, 30, driftLat, driftLon),
        ...leg(600, 30, homeLat, homeLon),
        ...leg(700, 30, driftLat, driftLon),
        ...leg(800, 60, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);

      final displacedShare = seg.discardedCount / track.length;
      expect(displacedShare, lessThanOrEqualTo(0.5),
          reason: 'never more than the ride');
      // The four displaced runs form one cluster holding ~40% of the recorded
      // time, so the budget refuses it outright and they are all kept as breaks.
      expect(seg.discardedCount, 0,
          reason: 'over budget as one cluster — kept, not deleted');
    });

    test('a single small excursion still drops', () {
      final track = [
        ...leg(0, 300, homeLat, homeLon),
        ...leg(1500, 40, driftLat, driftLon),
        ...leg(1600, 300, homeLat, homeLon),
      ];

      final seg = segmentTrack(track, fixOf: fixOf);
      expect(seg.discardedCount, 40, reason: 'inside the budget');
    });
  });

  group('darkEnds', () {
    // The three real cases from the "Touring Ujung Genteng" trip.
    final track = leg(0, 60, homeLat, homeLon); // fixes at t+0s .. t+59s

    test('a ride whose fixes bracket it cleanly reports nothing', () {
      final dark = darkEnds(
        track,
        fixOf: fixOf,
        startedAt: _epoch,
        endedAt: _epoch.add(const Duration(seconds: 59)),
      );
      expect(dark.head, Duration.zero);
      expect(dark.tail, Duration.zero);
    });

    test('a dark head is the wait for the first fix (stint 10: 6m19s)', () {
      final dark = darkEnds(
        track,
        fixOf: fixOf,
        startedAt: _epoch.subtract(const Duration(minutes: 6, seconds: 19)),
        endedAt: _epoch.add(const Duration(seconds: 59)),
      );
      expect(dark.head, const Duration(minutes: 6, seconds: 19));
      expect(dark.tail, Duration.zero);
    });

    test('a dark tail is recording on past the last fix (stint 4: 1h14m)', () {
      final dark = darkEnds(
        track,
        fixOf: fixOf,
        startedAt: _epoch,
        endedAt: _epoch.add(const Duration(seconds: 59, minutes: 74, hours: 0)),
      );
      expect(dark.head, Duration.zero);
      expect(dark.tail, const Duration(minutes: 74));
    });

    test('an end time a second before the last fix is not negative dark time',
        () {
      // Real rows do this — 6 of the 10 stints stored an end time 1-2 s ahead of
      // their final fix. Reporting "-0h00m02s of no GPS" would be nonsense.
      final dark = darkEnds(
        track,
        fixOf: fixOf,
        startedAt: _epoch,
        endedAt: _epoch.add(const Duration(seconds: 57)),
      );
      expect(dark.tail, Duration.zero);
    });

    test('an empty track and an unfinished ride report nothing', () {
      expect(darkEnds(<Fix>[], fixOf: fixOf, startedAt: _epoch).head,
          Duration.zero);
      // No end time yet — a ride still in progress has no tail to speak of.
      expect(darkEnds(track, fixOf: fixOf, startedAt: _epoch).tail,
          Duration.zero);
    });
  });

  group('the gap the odometer must agree with', () {
    // Stint 1 of the "Touring Ujung Genteng" trip in miniature: a 26 s hole
    // between two fix *timestamps*, bridging ~430 m at an implied 59 km/h. Short
    // enough to look like ordinary riding, long enough to be a blackout.
    //
    // The engine decides a blackout from when a fix *arrived*; the track stores
    // the fix's own time and every consumer here segments on that. On the real
    // ride the two disagreed, the odometer counted the bridge and this module cut
    // it, and the stored total finished 2.03 km (0.43%) ahead of everything
    // re-derived from the same points. The engine now applies the rule below to
    // `fix.timestamp` as well, so what it refuses to count and what this module
    // refuses to draw are the same segments.
    // Each 20-fix leg covers 19 * 0.00005 deg ≈ 106 m, so the pair is ~212 m of
    // genuinely ridden track. The second leg restarts 0.004777 deg north of the
    // first's *end*, i.e. ~426 m further on — which is what 26 s at 59 km/h looks
    // like, the real bridge from stint 1. Bridged, the track totals ~638 m.
    List<Fix> withHole(int holeSeconds) => [
          ...leg(0, 20, homeLat, homeLon),
          ...leg(19 + holeSeconds, 20, homeLat + 0.00095 + 0.004777, homeLon),
        ];

    test('a 26 s hole is a blackout, and the bridge is not distance', () {
      final track = withHole(26);
      expect(splitIntoRuns(track, fixOf: fixOf), hasLength(2),
          reason: 'the read path must see two runs');

      // What the chart's distance axis shows: frozen across the hole.
      final cumulative = cumulativeMeters(track, fixOf: fixOf);
      final firstRun = cumulativeMeters(track.take(20).toList(), fixOf: fixOf);
      final secondRun = cumulativeMeters(track.skip(20).toList(), fixOf: fixOf);
      expect(cumulative.last, closeTo(firstRun.last + secondRun.last, 0.5),
          reason: 'the 426 m bridge leaked into the distance axis');
      // And the bridge really was worth excluding — otherwise this test would
      // pass on a track where there was nothing to exclude in the first place.
      expect(cumulative.last, lessThan(300),
          reason: 'the two legs alone are ~212 m; a bridged total would be ~638');
    });

    test('the threshold is exact — one second under is ordinary riding', () {
      final under = withHole(kSignalLossSeconds - 1);
      expect(splitIntoRuns(under, fixOf: fixOf), hasLength(1),
          reason: 'an 11 s gap is degraded reception, not a blackout');
      // Under the threshold the straight line *is* counted, by both paths.
      expect(cumulativeMeters(under, fixOf: fixOf).last, greaterThan(600),
          reason: 'the bridge should be included below the threshold');
    });
  });
}
