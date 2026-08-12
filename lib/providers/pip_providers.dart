import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/pip_service.dart';
import 'settings_providers.dart';
import 'tracking_providers.dart';

/// Whether this device can show Picture-in-Picture at all (API 26+ and the system
/// feature present). Read once per process — the answer cannot change.
///
/// Used only to decide whether the Settings row appears. Arming does not consult
/// it, because `PipController` re-checks natively before every entry; a Dart-side
/// check would be a second copy of the same rule with nothing to keep it honest.
final pipSupportedProvider =
    FutureProvider<bool>((ref) => PipService.instance.isSupported());

/// Tracks whether the app is *currently* in Picture-in-Picture.
///
/// A [StateNotifier] over the raw stream rather than a `StreamProvider` so
/// consumers get a plain `bool` starting at `false`, not an `AsyncValue` whose
/// loading state they would all have to unwrap into the same "not in PiP".
class PipModeController extends StateNotifier<bool> {
  PipModeController() : super(false) {
    PipService.instance.start();
    _sub = PipService.instance.modeChanges.listen((inPip) => state = inPip);
  }

  late final StreamSubscription<bool> _sub;

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// `true` while the app is rendering into the PiP window.
final pipModeProvider =
    StateNotifierProvider<PipModeController, bool>((ref) => PipModeController());

/// Whether leaving the app should shrink it into a PiP window right now.
///
/// Mirrors how the wakelock is gated (`keepScreenOnProvider && state.isTracking`):
/// the preference AND a live ride. `isTracking` is the right test rather than a
/// `phase` list — it spans acquiring, countdown, recording and paused, and goes
/// false only when a ride finishes or is cancelled, which is exactly when a
/// floating window would have nothing to say.
///
/// A plain [Provider] so Riverpod dedupes: this recomputes on every one-second
/// telemetry tick but only *notifies* on a transition, which is what keeps the
/// listener in `PipHost` from calling across the platform channel every second.
final pipShouldArmProvider = Provider<bool>((ref) {
  final enabled = ref.watch(pipEnabledProvider);
  final tracking = ref.watch(trackingControllerProvider).isTracking;
  return enabled && tracking;
});
