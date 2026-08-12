import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/ride_clock.dart';
import 'package:throttlepath/core/track_runs.dart' as track_runs;

/// The ride clock, which until now lived as a handful of locals inside a
/// ~600-line background-isolate closure and could not be reached from a test.
///
/// It is worth saying what that cost, because it is the reason this file exists:
/// a ride that began somewhere GPS could not reach latched its blackout marker
/// and never cleared it, so `elapsedSeconds` cancelled `now` against itself and
/// froze the duration at ~12 s — for the whole ride, with real distance still
/// accumulating against it. Silent, and it corrupted every ride that started in
/// a garage. The first test below is that exact scenario.

/// A ride start instant. Every test drives time explicitly rather than sleeping,
/// which is the whole point of the extraction.
final t0 = DateTime(2026, 8, 9, 7, 0, 0);

DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

/// Runs the 1 Hz ticker from [from]+1 to [to] inclusive, with no fixes arriving.
void tickThrough(RideClock clock, int from, int to,
    {double speedKmh = 0}) {
  for (var s = from + 1; s <= to; s++) {
    clock.tick(at(s), currentSpeedKmh: speedKmh);
  }
}

void main() {
  group('a blackout at the very start of a ride', () {
    test('the first fix clears it, and the clock keeps running', () {
      // Press record in a basement car park: the countdown ran off a marginal
      // lock, then nothing for half a minute.
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      expect(clock.isSignalLost, isTrue, reason: 'the blackout never latched');

      // Wheeled the bike outside — first real fix, a few metres from where it
      // started, so the rider plainly went nowhere.
      clock.onFixAccepted(at(30), displacementSpeedKmh: 0.6);

      expect(clock.isSignalLost, isFalse,
          reason: "the ride's first fix could not clear the blackout — this is "
              'the bug: nothing else ever clears it either');

      // The real damage was here. With the marker stuck, elapsed collapses to a
      // constant, because `now` appears on both sides of the subtraction.
      expect(clock.elapsedSeconds(at(60)), 60);
      expect(clock.elapsedSeconds(at(600)), 600,
          reason: 'the ride clock is frozen — it reports the same duration ten '
              'minutes later');
    });

    test('a first fix far away banks the dead time instead', () {
      // Same start, but the rider rode off immediately and GPS only caught up
      // half a minute later, kilometres on. That ground was never measured, so
      // its time must not dilute the average.
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      clock.onFixAccepted(at(30), displacementSpeedKmh: 45);

      expect(clock.isSignalLost, isFalse);
      // Latched at 12 s, resolved at 30 s → 18 s excluded.
      expect(clock.elapsedSeconds(at(60)), 42);
    });

    test('with no anchor at all the gap is treated as displaced', () {
      // A null displacement means "we cannot say", and the safe reading is that
      // the rider moved: crediting unmeasured riding as elapsed would dilute the
      // average with distance that is not in the numerator.
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      clock.onFixAccepted(at(30), displacementSpeedKmh: null);
      expect(clock.elapsedSeconds(at(60)), 42);
    });
  });

  group('a blackout mid-ride', () {
    /// A ride already underway: fixes every second for a minute.
    RideClock riding() {
      final clock = RideClock()..start(t0);
      for (var s = 1; s <= 60; s++) {
        clock.onFixAccepted(at(s), displacementSpeedKmh: 40);
        clock.tick(at(s), currentSpeedKmh: 40);
      }
      return clock;
    }

    test('a tunnel excludes its time', () {
      final clock = riding();
      tickThrough(clock, 60, 300, speedKmh: 40);
      expect(clock.isSignalLost, isTrue);
      clock.onFixAccepted(at(300), displacementSpeedKmh: 60);

      // Latched at 72 s, resolved at 300 s → 228 s excluded.
      expect(clock.elapsedSeconds(at(300)), 300 - 228);
    });

    test('a car park gives its time back', () {
      final clock = riding();
      tickThrough(clock, 60, 300, speedKmh: 40);
      clock.onFixAccepted(at(300), displacementSpeedKmh: 0.4);

      expect(clock.elapsedSeconds(at(300)), 300,
          reason: 'standing still is ordinary elapsed time — duration is '
              'start-to-stop wall clock');
    });

    test('moving time stops accruing once the blackout latches', () {
      final clock = riding();
      // The window before the latch still counts: fixes had been arriving and
      // the rider was demonstrably moving, so those seconds are real moving time.
      tickThrough(clock, 60, 60 + track_runs.kSignalLossSeconds, speedKmh: 40);
      expect(clock.isSignalLost, isTrue);
      final atLatch = clock.movingSeconds;

      // Everything after it does not — no data is not the same as not moving.
      tickThrough(clock, 60 + track_runs.kSignalLossSeconds, 300, speedKmh: 40);
      expect(clock.movingSeconds, atLatch,
          reason: 'four minutes of dead zone were credited as moving time');
    });
  });

  group('the blackout window', () {
    test('cuts at the threshold but not below it', () {
      final under = RideClock()..start(t0);
      tickThrough(under, 0, track_runs.kSignalLossSeconds - 1);
      expect(under.isSignalLost, isFalse);

      final atThreshold = RideClock()..start(t0);
      tickThrough(atThreshold, 0, track_runs.kSignalLossSeconds);
      expect(atThreshold.isSignalLost, isTrue);
    });

    test('is the same number the read path segments stored tracks on', () {
      // Not a tautology worth skipping: these were two independent `12`s in two
      // files, and CLAUDE.md warns that a fork would have the read path silently
      // re-bridge exactly the dead zones the engine refused to count.
      expect(kSignalLossSeconds, track_runs.kSignalLossSeconds);
    });
  });

  group('interaction with a manual pause', () {
    test('pausing during a blackout does not double-count the freeze', () {
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      expect(clock.isSignalLost, isTrue);

      // The rider pulls over and hits pause while still in the dead zone. The
      // blackout resolves as "not displaced" — holding the phone proves they are
      // here — and the pause takes over the freeze.
      clock.pause(at(30));
      expect(clock.isSignalLost, isFalse);
      expect(clock.isPaused, isTrue);
      expect(clock.pauseStartedAt, at(30));

      clock.resume(at(90));
      // 60 s of pause excluded; the blackout contributed nothing on its own.
      expect(clock.elapsedSeconds(at(120)), 60);
    });

    test('resume re-baselines the fix clock, so the pause is not a blackout',
        () {
      final clock = RideClock()..start(t0);
      clock.onFixAccepted(at(1), displacementSpeedKmh: 30);
      clock.pause(at(2));
      clock.resume(at(600));

      // The position stream was stopped for ten minutes. That silence must not
      // read as a dead zone the moment the ticker runs again.
      clock.tick(at(601), currentSpeedKmh: 30);
      expect(clock.isSignalLost, isFalse);
    });

    test('a paused clock does not latch a blackout or accrue moving time', () {
      final clock = RideClock()..start(t0);
      clock.pause(at(1));
      tickThrough(clock, 1, 120, speedKmh: 40);
      expect(clock.isSignalLost, isFalse);
      expect(clock.movingSeconds, 0);
    });
  });

  group('degenerate clocks', () {
    test('elapsed is zero before the ride starts', () {
      expect(RideClock().elapsedSeconds(t0), 0);
      expect(RideClock().isRunning, isFalse);
    });

    test('a backward wall-clock change never reports a negative duration', () {
      // DateTime.now() is wall clock, not monotonic: an NTP correction or a
      // timezone change mid-ride can hand the engine an earlier instant.
      final clock = RideClock()..start(t0);
      expect(clock.elapsedSeconds(at(-3600)), 0);
    });

    test('a backward jump during a blackout cannot credit time', () {
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      // Resolved at an instant *before* the blackout began.
      clock.onFixAccepted(at(5), displacementSpeedKmh: 90);
      expect(clock.elapsedSeconds(at(60)), lessThanOrEqualTo(60));
    });

    test('the jump-gate re-anchor always banks as displaced', () {
      final clock = RideClock()..start(t0);
      tickThrough(clock, 0, 30);
      clock.onReanchor(at(30));
      expect(clock.isSignalLost, isFalse);
      expect(clock.elapsedSeconds(at(60)), 42);
    });
  });
}
