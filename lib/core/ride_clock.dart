/// The ride clock: elapsed time, moving time, and the two ways a ride's clock
/// can freeze — a manual pause and a GPS blackout.
///
/// Pulled out of `tracking_service.dart` because it is the one part of the engine
/// that is pure bookkeeping over `DateTime`s, and the one part that had a bug
/// nothing could catch. The engine's entrypoint is a ~600-line isolate closure
/// holding all its state as locals, so none of this logic was reachable from a
/// test; the bug it hid froze a ride's duration at ~12 s and inflated its average
/// speed, silently, for the whole ride (see [onFixAccepted]).
///
/// Deliberately **not** in here: the Kalman filter, the accuracy gate, the
/// impossible-jump gate and the distance accumulator. Those were validated
/// against a real 33 km displaced blackout and are left exactly where they were.
///
/// Pure — no Flutter, no Isar, no plugins — so it is safe in the background
/// isolate and testable without standing one up.
library;

import 'track_runs.dart' show kSignalLossSeconds;

export 'track_runs.dart' show kSignalLossSeconds;

/// Below this ground speed (km/h) the rider counts as stopped rather than moving.
///
/// Used for two different questions that happen to share an answer: whether a
/// tick accrues moving time, and whether the ground covered during a blackout
/// means the rider actually went somewhere (see [onFixAccepted]).
const double kMovingSpeedThresholdKmh = 3.0;

/// Elapsed/moving time for one recording, and the freeze state behind both.
///
/// The engine owns *when* things happen (it has the fix stream and the ticker);
/// this owns what the clock does about it.
class RideClock {
  DateTime? _startedAt;

  var _paused = false;
  DateTime? _pauseStartedAt;
  var _totalPaused = Duration.zero;

  /// Set while GPS is dark mid-ride. While non-null the clock is frozen
  /// *provisionally* — at that moment there is no way to tell a rider parked in
  /// a basement from one crossing a tunnel at 80 km/h. The returning fix settles
  /// it (see [onFixAccepted]).
  DateTime? _signalLostAt;

  /// When the last accepted fix landed. Seeded by [start] so the first blackout
  /// window is measured from the moment recording began, not from process start.
  var _lastFixAt = DateTime.fromMillisecondsSinceEpoch(0);

  var _movingSeconds = 0;

  /// True once [start] has been called — i.e. the ride clock is live rather than
  /// still acquiring or counting down.
  bool get isRunning => _startedAt != null;

  bool get isPaused => _paused;

  /// True while GPS is dark. Drives the "GPS SIGNAL LOST" notification and the
  /// Record screen's blackout banner.
  bool get isSignalLost => _signalLostAt != null;

  /// When the current manual pause began, or null when not paused. The engine
  /// owns this rather than the UI so "paused 1:27 ago" survives a UI rebuild.
  DateTime? get pauseStartedAt => _pauseStartedAt;

  int get movingSeconds => _movingSeconds;

  /// Seconds since the last accepted fix — the engine's blackout and
  /// speed-decay input.
  double secondsSinceLastFix(DateTime now) =>
      now.difference(_lastFixAt).inMilliseconds / 1000.0;

  /// Wall clock since start, minus every frozen interval (completed pauses, any
  /// pause in progress, and any blackout in progress).
  ///
  /// Never negative: a backward system clock change would otherwise report a
  /// nonsense duration, and `DateTime.now()` is wall clock, not monotonic.
  int elapsedSeconds(DateTime now) {
    final startedAt = _startedAt;
    if (startedAt == null) return 0; // still acquiring / counting down
    var frozen = _totalPaused;
    final pausedAt = _pauseStartedAt;
    if (_paused && pausedAt != null) frozen += now.difference(pausedAt);
    final lostAt = _signalLostAt;
    if (lostAt != null) frozen += now.difference(lostAt);
    final elapsed = now.difference(startedAt) - frozen;
    return elapsed.isNegative ? 0 : elapsed.inSeconds;
  }

  /// Begins the ride clock. [now] is both the ride's start instant and the
  /// baseline for the first blackout window.
  void start(DateTime now) {
    _startedAt = now;
    _lastFixAt = now;
    _signalLostAt = null;
    _paused = false;
    _pauseStartedAt = null;
    _totalPaused = Duration.zero;
    _movingSeconds = 0;
  }

  /// One 1 Hz tick while recording and not paused.
  ///
  /// Latches the blackout marker once fixes have been missing for a full window,
  /// then accrues moving time — but never during a blackout, because no data is
  /// not the same as not moving. Pass the *displayed* speed, after the engine's
  /// decay has been applied, so a decayed-to-zero speed stops accruing.
  void tick(DateTime now, {required double currentSpeedKmh}) {
    if (_startedAt == null || _paused) return;
    if (_signalLostAt == null &&
        secondsSinceLastFix(now) >= kSignalLossSeconds) {
      _signalLostAt = now;
    }
    if (_signalLostAt == null && currentSpeedKmh > kMovingSpeedThresholdKmh) {
      _movingSeconds++;
    }
  }

  /// Records an accepted fix and resolves any blackout it just ended.
  ///
  /// Returns true when this fix closed a gap of at least [kSignalLossSeconds],
  /// which is the engine's signal to re-anchor its filter rather than bridge the
  /// dead zone into distance.
  ///
  /// [displacementSpeedKmh] is the straight-line speed implied since the last
  /// accepted position, or null when there is no anchor to measure from. It is
  /// what settles the provisional freeze:
  ///
  ///   *moved* — the rider covered real ground nobody could measure. The distance
  ///   is excluded (the engine refuses to bridge it), so the time has to go too,
  ///   or the average is diluted by riding that isn't in the numerator. Banked.
  ///
  ///   *parked* — the rider came back to where they left, so nothing was missed
  ///   but the standing around. That is ordinary stopped time and
  ///   `durationSeconds` is start-to-stop wall clock. Given back.
  ///
  /// **There is deliberately no "have we had a fix yet?" precondition here.** The
  /// engine used to gate this on `pointCount > 0`, which meant the very first fix
  /// of a ride could never clear a blackout: start somewhere GPS can't reach,
  /// wait past the window, and the marker latched for the rest of the ride —
  /// `elapsedSeconds` then cancels `now` against itself and freezes at a
  /// constant. The gate existed only because the first fix had no anchor to
  /// measure displacement from; the engine now seeds one at [start], so the first
  /// fix answers the same question every other fix does.
  bool onFixAccepted(DateTime now, {double? displacementSpeedKmh}) {
    final longGap = secondsSinceLastFix(now) >= kSignalLossSeconds;
    _lastFixAt = now;
    // Unconditional and idempotent: a fix is proof the receiver is back, so no
    // path may leave the marker set behind one.
    _resolveSignalLoss(
      now,
      displaced: displacementSpeedKmh == null ||
          displacementSpeedKmh > kMovingSpeedThresholdKmh,
    );
    return longGap;
  }

  /// The jump-gate re-anchor: too many implausible fixes in a row, so the anchor
  /// itself is assumed stale and the engine re-seeds from the current fix.
  ///
  /// Always displaced — a blackout that ends with a far jump is by definition one
  /// where the rider is somewhere else.
  void onReanchor(DateTime now) {
    _lastFixAt = now;
    _resolveSignalLoss(now, displaced: true);
  }

  /// Manual pause. Any blackout in progress is resolved first so the two freezes
  /// cannot double-count, and never as displaced: the rider is holding the phone,
  /// which is the one thing that proves they are here.
  void pause(DateTime now) {
    if (_paused) return;
    _resolveSignalLoss(now, displaced: false);
    _paused = true;
    _pauseStartedAt = now;
  }

  /// Resume from a manual pause, banking the paused interval so it stays out of
  /// elapsed. Also re-baselines the fix clock: the position stream was stopped
  /// while paused, so the silence since is not a blackout.
  void resume(DateTime now) {
    if (!_paused) return;
    final pausedAt = _pauseStartedAt;
    if (pausedAt != null) _totalPaused += now.difference(pausedAt);
    _pauseStartedAt = null;
    _paused = false;
    _lastFixAt = now;
  }

  /// Clears the blackout marker, banking its interval only when the rider
  /// actually got somewhere. Idempotent, so every path may call it.
  void _resolveSignalLoss(DateTime now, {required bool displaced}) {
    final lostAt = _signalLostAt;
    if (lostAt == null) return;
    if (displaced) {
      final frozen = now.difference(lostAt);
      // Guard against a backward wall-clock change turning a freeze into credit.
      if (!frozen.isNegative) _totalPaused += frozen;
    }
    _signalLostAt = null;
  }
}
