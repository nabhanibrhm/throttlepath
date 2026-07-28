import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';

/// Tiny file-backed store for user preferences. Kept dependency-free (plain file
/// via path_provider, no shared_preferences) in keeping with the offline-first
/// ethos — the theme mode, display unit, and Record backdrop view.
///
/// Each preference lives in its own tiny file so a value can be read in isolation
/// without parsing a shared format.
class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _fileName = 'settings.txt';
  static const _speedUnitFileName = 'speed_unit.txt';
  static const _recordViewFileName = 'record_view.txt';
  static const _speedGaugeStyleFileName = 'speed_gauge_style.txt';
  static const _countdownFileName = 'countdown_enabled.txt';
  static const _keepScreenOnFileName = 'keep_screen_on.txt';

  File? _file;

  Future<File> _resolve() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/$_fileName');
  }

  Future<File> _resolveNamed(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  /// Loads the saved theme mode. Defaults to dark (the app's original look) on
  /// first run or any read error.
  Future<ThemeMode> loadThemeMode() async {
    try {
      final f = await _resolve();
      if (!await f.exists()) return ThemeMode.dark;
      return switch ((await f.readAsString()).trim()) {
        'light' => ThemeMode.light,
        _ => ThemeMode.dark,
      };
    } catch (_) {
      return ThemeMode.dark;
    }
  }

  /// Persists the theme mode. Best-effort — a write failure is non-fatal.
  Future<void> saveThemeMode(ThemeMode mode) async {
    try {
      final f = await _resolve();
      await f.writeAsString(mode == ThemeMode.light ? 'light' : 'dark');
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }

  /// Loads the display speed/distance unit. Defaults to km/h on first run or
  /// any read error.
  Future<SpeedUnit> loadSpeedUnit() async {
    try {
      final f = await _resolveNamed(_speedUnitFileName);
      if (!await f.exists()) return SpeedUnit.kmh;
      return SpeedUnit.fromTag((await f.readAsString()).trim());
    } catch (_) {
      return SpeedUnit.kmh;
    }
  }

  /// Persists the display unit. Best-effort.
  Future<void> saveSpeedUnit(SpeedUnit unit) async {
    try {
      final f = await _resolveNamed(_speedUnitFileName);
      await f.writeAsString(unit.tag);
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }

  /// Loads the Record screen's backdrop view. Defaults to [RecordView.none]
  /// (map hidden — the battery-saving default) on first run or any read error.
  Future<RecordView> loadRecordView() async {
    try {
      final f = await _resolveNamed(_recordViewFileName);
      if (!await f.exists()) return RecordView.none;
      return RecordView.fromTag((await f.readAsString()).trim());
    } catch (_) {
      return RecordView.none;
    }
  }

  /// Persists the Record backdrop view. Best-effort.
  Future<void> saveRecordView(RecordView view) async {
    try {
      final f = await _resolveNamed(_recordViewFileName);
      await f.writeAsString(view.tag);
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }

  /// Loads the live-speed gauge style. Defaults to [SpeedGaugeStyle.digital]
  /// (the app's original readout) on first run or any read error.
  Future<SpeedGaugeStyle> loadSpeedGaugeStyle() async {
    try {
      final f = await _resolveNamed(_speedGaugeStyleFileName);
      if (!await f.exists()) return SpeedGaugeStyle.digital;
      return SpeedGaugeStyle.fromTag((await f.readAsString()).trim());
    } catch (_) {
      return SpeedGaugeStyle.digital;
    }
  }

  /// Persists the live-speed gauge style. Best-effort.
  Future<void> saveSpeedGaugeStyle(SpeedGaugeStyle style) async {
    try {
      final f = await _resolveNamed(_speedGaugeStyleFileName);
      await f.writeAsString(style.tag);
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }

  /// Whether to run the "3… 2… 1…" countdown before the ride clock starts.
  /// **Defaults to off** — it delights once and taxes every ride after that, and
  /// a commuter starts ten rides a week. Opt in from Settings.
  ///
  /// Also read from the *background isolate* (which has its own copy of this
  /// singleton), so the engine never has to wait on a message from the UI to
  /// know whether to count down.
  Future<bool> loadCountdownEnabled() => _loadFlag(_countdownFileName);

  /// Persists the countdown preference. Best-effort.
  Future<void> saveCountdownEnabled(bool enabled) =>
      _saveFlag(_countdownFileName, enabled);

  /// Whether to hold the screen awake while a ride is recording. Defaults to
  /// off: recording itself doesn't need the screen (the foreground service keeps
  /// the CPU alive), so leaving it on is a battery cost the rider should choose.
  Future<bool> loadKeepScreenOn() => _loadFlag(_keepScreenOnFileName);

  /// Persists the keep-screen-on preference. Best-effort.
  Future<void> saveKeepScreenOn(bool enabled) =>
      _saveFlag(_keepScreenOnFileName, enabled);

  /// Shared reader for the boolean prefs. Absent file or unreadable value reads
  /// as false, so every flag defaults to off.
  Future<bool> _loadFlag(String name) async {
    try {
      final f = await _resolveNamed(name);
      if (!await f.exists()) return false;
      return (await f.readAsString()).trim() == '1';
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveFlag(String name, bool value) async {
    try {
      final f = await _resolveNamed(name);
      await f.writeAsString(value ? '1' : '0');
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }
}
