import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/services/settings_service.dart';
import 'package:throttlepath/services/tracking_service.dart';
import 'package:throttlepath/ui/tracking_map_screen.dart';

/// Phase 3 (recording lifecycle) guards: the frozen-clock signals that reach the
/// UI across the isolate boundary, and the wording that tells a rider their ride
/// is not being recorded.
void main() {
  group('pausedSentence', () {
    test('says it is not recording, always', () {
      // F12's core failure was a paused screen that looked like a recording one.
      // Whatever the elapsed time, the words "Not recording" must be present.
      for (final d in [
        null,
        Duration.zero,
        const Duration(seconds: 7),
        const Duration(minutes: 1, seconds: 27),
        const Duration(hours: 2),
      ]) {
        expect(pausedSentence(d), contains('Not recording'));
      }
    });

    test('reads in seconds under a minute', () {
      expect(pausedSentence(const Duration(seconds: 7)),
          'Not recording — paused 7s ago');
      expect(pausedSentence(const Duration(seconds: 59)),
          'Not recording — paused 59s ago');
    });

    test('reads as m:ss from a minute up, zero-padded', () {
      expect(pausedSentence(const Duration(seconds: 60)),
          'Not recording — paused 1:00 ago');
      expect(pausedSentence(const Duration(minutes: 1, seconds: 27)),
          'Not recording — paused 1:27 ago');
      // The audit's example. Seconds must not lose their leading zero, or
      // "1:07" would render as the very different-looking "1:7".
      expect(pausedSentence(const Duration(minutes: 1, seconds: 7)),
          'Not recording — paused 1:07 ago');
    });

    test('drops the elapsed part when the engine has not confirmed yet', () {
      // The UI flips to paused optimistically, so for up to a second there is no
      // pause timestamp. Better to say less than to invent "0s ago".
      expect(pausedSentence(null), 'Not recording — paused');
      expect(pausedSentence(null), isNot(contains('ago')));
    });
  });

  group('LiveTelemetry frozen-clock fields', () {
    /// The minimum payload the isolate sends — every key the older build emitted,
    /// and none of the ones Phase 3 added.
    Map<String, dynamic> legacyPayload() => {
          'rideId': 1,
          'distanceMeters': 100.0,
          'maxSpeedKmh': 40.0,
          'avgSpeedKmh': 20.0,
          'durationSeconds': 60,
          'pointCount': 10,
        };

    test('a payload without the new keys still parses, and reads as running',
        () {
      // Version skew between the UI and a background isolate that is already
      // running is normal on hot reload; it must not throw or claim a blackout.
      final t = LiveTelemetry.fromMap(legacyPayload());
      expect(t.pausedAtMs, isNull);
      expect(t.signalLost, isFalse);
      expect(t.pausedFor, isNull);
    });

    test('carries the pause timestamp and the blackout flag', () {
      final pausedAt = DateTime(2026, 7, 28, 11, 50);
      final t = LiveTelemetry.fromMap(legacyPayload()
        ..addAll({
          'paused': true,
          'pausedAtMs': pausedAt.millisecondsSinceEpoch,
          'signalLost': true,
        }));
      expect(t.paused, isTrue);
      expect(t.pausedAtMs, pausedAt.millisecondsSinceEpoch);
      expect(t.signalLost, isTrue);
    });

    test('pausedFor is null unless actually paused', () {
      // A stale timestamp left over from an earlier pause must not resurrect the
      // "paused 1:27 ago" line after the rider has resumed.
      final t = LiveTelemetry.fromMap(legacyPayload()
        ..addAll({
          'paused': false,
          'pausedAtMs': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        }));
      expect(t.pausedFor, isNull);
    });

    test('pausedFor measures from the timestamp', () {
      final t = LiveTelemetry.fromMap(legacyPayload()
        ..addAll({
          'paused': true,
          'pausedAtMs': DateTime.now()
              .subtract(const Duration(seconds: 90))
              .millisecondsSinceEpoch,
        }));
      final since = t.pausedFor;
      expect(since, isNotNull);
      expect(since!.inSeconds, closeTo(90, 2));
    });

    test('never reports a negative pause', () {
      // Clocks can disagree; "paused -3s ago" is worse than "paused 0s ago".
      final t = LiveTelemetry.fromMap(legacyPayload()
        ..addAll({
          'paused': true,
          'pausedAtMs': DateTime.now()
              .add(const Duration(seconds: 5))
              .millisecondsSinceEpoch,
        }));
      expect(t.pausedFor, Duration.zero);
    });
  });

  group('recording preferences', () {
    // No path_provider in a plain test binding, so these exercise the same
    // read-failure path a first run takes — which is exactly the default that
    // matters: both features must be OFF until the rider opts in (F10).
    test('the pre-ride countdown is off by default', () async {
      expect(await SettingsService.instance.loadCountdownEnabled(), isFalse);
    });

    test('keep-screen-on is off by default', () async {
      expect(await SettingsService.instance.loadKeepScreenOn(), isFalse);
    });
  });
}
