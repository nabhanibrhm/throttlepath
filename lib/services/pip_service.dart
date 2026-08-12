import 'dart:async';

import 'package:flutter/services.dart';

/// Thin seam over the Android Picture-in-Picture channel, so a recording ride can
/// keep showing live telemetry in a floating window while the rider is in another
/// app.
///
/// Deliberately display-only — see `PipController.kt` for why the window carries no
/// buttons. Nothing here can start, pause or stop a ride; it only decides *whether*
/// PiP may be entered and reports when the mode flips.
///
/// Every call is best-effort and swallows platform failures. PiP is a convenience
/// layered on top of a ride that is already being recorded by the foreground
/// service — if the channel is missing (unit tests, a future iOS build, an OEM
/// without the feature) the ride is unaffected, so there is nothing worth throwing
/// over. Kept geolocator-style behind a singleton like the other services.
class PipService {
  PipService._();
  static final PipService instance = PipService._();

  static const MethodChannel _channel =
      MethodChannel('id.co.opentrack.throttlepath/pip');

  final StreamController<bool> _modeChanges =
      StreamController<bool>.broadcast();

  /// Fires `true` when the app enters PiP and `false` when it leaves.
  Stream<bool> get modeChanges => _modeChanges.stream;

  bool _listening = false;

  /// Whether this device can show PiP at all: API 26+ *and* the system feature
  /// present. Cached because the answer cannot change within a process, and the
  /// Settings row reads it on every build.
  bool? _supported;

  /// Installs the handler for mode changes pushed from the activity. Idempotent —
  /// safe to call from a widget that may rebuild or remount.
  void start() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        _modeChanges.add(call.arguments == true);
      }
      return null;
    });
  }

  Future<bool> isSupported() async {
    final cached = _supported;
    if (cached != null) return cached;
    try {
      final ok = await _channel.invokeMethod<bool>('isSupported');
      return _supported = ok ?? false;
    } on MissingPluginException {
      return _supported = false;
    } on PlatformException {
      return _supported = false;
    }
  }

  /// Tells the activity whether a ride is live. Armed means "enter PiP when the
  /// rider presses Home or Recents"; disarmed means backgrounding the app does
  /// nothing, so peeking at History with no ride running never pops an empty
  /// window.
  Future<void> setArmed(bool armed) async {
    try {
      await _channel.invokeMethod<void>('setArmed', armed);
    } on MissingPluginException {
      // No PiP on this platform; nothing to arm.
    } on PlatformException {
      // Best-effort, as above.
    }
  }
}
