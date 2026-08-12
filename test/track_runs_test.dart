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
}
