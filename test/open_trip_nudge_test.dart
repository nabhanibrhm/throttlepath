import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Record screen's "you're near where a trip ended — continue it?" nudge
/// went on offering to continue a trip the rider had already finished, and only
/// stopped after an app restart.
///
/// `nearbyOpenTripProvider` is `autoDispose`, which reads as self-refreshing —
/// but the three tabs live in an `IndexedStack`, so `TrackingMapScreen` never
/// unmounts and never stops listening. The provider therefore has a listener for
/// the app's entire life, never disposes, and answers once per launch. Two hops
/// from cause to symptom, and the cause is an *absence* — which is why this is
/// guarded rather than commented.
void main() {
  group('the autoDispose trap, in miniature', () {
    test('a permanent listener freezes the answer for the app’s lifetime', () {
      var reads = 0;
      final provider = FutureProvider.autoDispose<int>((ref) async => ++reads);
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // What the IndexedStack does: a listener that is never removed.
      container.listen(provider, (_, _) {}, fireImmediately: true);
      expect(reads, 1);

      // Re-reading is not re-asking. This is the whole bug: every later frame
      // sees the answer computed at launch, from wherever the phone was then.
      container.read(provider);
      container.read(provider);
      expect(reads, 1, reason: 'autoDispose does not help while something '
          'is still listening');

      // Only an explicit invalidate re-runs it — which is the fix.
      container.invalidate(provider);
      container.read(provider);
      expect(reads, 2);
    });
  });

  group('the invalidations that keep it honest', () {
    /// Source of the three files that must carry one.
    String read(String path) => File(path).readAsStringSync();

    test('finishing a ride re-asks, so the nudge follows the rider', () {
      // Without this the nudge could only ever fire about the position held at
      // app launch — and after finishing a trip it offered to continue the trip
      // just closed.
      expect(
        read('lib/ui/tracking_map_screen.dart'),
        contains('ref.invalidate(nearbyOpenTripProvider)'),
      );
    });

    test('entering the Record tab re-asks — and entering History does not', () {
      final source = read('lib/ui/home_shell.dart');
      expect(source, contains('ref.invalidate(nearbyOpenTripProvider)'));

      // It costs a GPS fix, and History never reads the answer. Assert it sits
      // in the Record branch by checking it comes after that branch opens.
      final recordBranch = source.indexOf('i == _recordTab');
      final invalidate = source.indexOf('ref.invalidate(nearbyOpenTripProvider)');
      expect(recordBranch, isNonNegative);
      expect(invalidate, greaterThan(recordBranch),
          reason: 'the nudge refetch must not hang off the History branch — '
              'that would wake the receiver for a screen that never asks');
    });

    test('finishing a trip from its detail screen disarms a continuation aimed '
        'at it', () {
      // The data half of the bug, and the worse half: `_resolveTripId` returns
      // `continuingTripId` without checking the trip still accepts stints, so
      // the next ride would be filed into a finished trip.
      final source = read('lib/ui/trip_detail_screen.dart');
      expect(source, contains('cancelContinuation()'));
      expect(source, contains('continuingTripId =='),
          reason: 'clearing unconditionally would also drop a continuation '
              'armed for a different, still-open trip');
    });

    test('the rename paths do not pay for a GPS fix', () {
      // `_invalidateHistory` runs from `_renameTrip` and `_renameStint` too.
      final source = read('lib/ui/trip_detail_screen.dart');
      final body = source.substring(
        source.indexOf('void _invalidateHistory()'),
        source.indexOf('Future<void> _finish()'),
      );
      expect(body, isNot(contains('nearbyOpenTripProvider')),
          reason: 'renaming a trip should not wake the GPS receiver');
    });
  });
}
