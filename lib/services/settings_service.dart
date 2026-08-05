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
  static const _ttffSamplesFileName = 'gnss_ttff.txt';

  Future<File> _resolveNamed(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  /// Loads the saved theme mode.
  ///
  /// Defaults to dark (the app's original look) on first run or any read error.
  /// `system` is now a real, storable third value — it used to collapse into dark
  /// on read, so a rider who wanted the app to follow the phone had no way to say
  /// so, and the setting was a two-state switch pretending to be a preference.
  Future<ThemeMode> loadThemeMode() => _loadTag(
        _fileName,
        (tag) => switch (tag) {
          'light' => ThemeMode.light,
          'system' => ThemeMode.system,
          _ => ThemeMode.dark,
        },
        ThemeMode.dark,
      );

  /// Persists the theme mode. Best-effort — a write failure is non-fatal.
  Future<void> saveThemeMode(ThemeMode mode) => _saveTag(
        _fileName,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.system => 'system',
          ThemeMode.dark => 'dark',
        },
      );

  /// Loads the display speed/distance unit. Defaults to km/h on first run or
  /// any read error.
  Future<SpeedUnit> loadSpeedUnit() =>
      _loadTag(_speedUnitFileName, SpeedUnit.fromTag, SpeedUnit.kmh);

  /// Persists the display unit. Best-effort.
  Future<void> saveSpeedUnit(SpeedUnit unit) =>
      _saveTag(_speedUnitFileName, unit.tag);

  /// Loads the Record screen's backdrop view. Defaults to [RecordView.none]
  /// (map hidden — the battery-saving default) on first run or any read error.
  Future<RecordView> loadRecordView() =>
      _loadTag(_recordViewFileName, RecordView.fromTag, RecordView.none);

  /// Persists the Record backdrop view. Best-effort.
  Future<void> saveRecordView(RecordView view) =>
      _saveTag(_recordViewFileName, view.tag);

  /// Loads the live-speed gauge style. Defaults to [SpeedGaugeStyle.digital]
  /// (the app's original readout) on first run or any read error.
  Future<SpeedGaugeStyle> loadSpeedGaugeStyle() => _loadTag(
        _speedGaugeStyleFileName,
        SpeedGaugeStyle.fromTag,
        SpeedGaugeStyle.digital,
      );

  /// Persists the live-speed gauge style. Best-effort.
  Future<void> saveSpeedGaugeStyle(SpeedGaugeStyle style) =>
      _saveTag(_speedGaugeStyleFileName, style.tag);

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

  /// Recent GNSS time-to-first-fix readings in milliseconds, oldest first.
  ///
  /// Not a preference the rider sets — a measurement of their phone. It lives
  /// here because this is the app's one small-value store, and because it has to
  /// survive across launches to be worth collecting at all.
  Future<List<int>> loadTtffSamples() =>
      _loadTag(_ttffSamplesFileName, _parseTtffSamples, const []);

  /// Persists the sample window. Best-effort, like every other write here: a
  /// lost sample costs the median a little accuracy and nothing else.
  Future<void> saveTtffSamples(List<int> samples) =>
      _saveTag(_ttffSamplesFileName, samples.join(','));

  /// An unparseable entry is dropped rather than failing the whole list — a
  /// truncated write should cost one sample, not the history.
  static List<int> _parseTtffSamples(String tag) => tag
      .split(',')
      .map((part) => int.tryParse(part.trim()))
      .whereType<int>()
      .toList();

  /// Shared reader for the boolean prefs. Absent file or unreadable value reads
  /// as false, so every flag defaults to off.
  Future<bool> _loadFlag(String name) =>
      _loadTag(name, (tag) => tag == '1', false);

  Future<void> _saveFlag(String name, bool value) =>
      _saveTag(name, value ? '1' : '0');

  /// Shared reader behind every preference: an absent file or any read error
  /// falls back to [fallback], so each preference states its default exactly once.
  Future<T> _loadTag<T>(
    String name,
    T Function(String tag) parse,
    T fallback,
  ) async {
    try {
      final file = await _resolveNamed(name);
      if (!await file.exists()) return fallback;
      return parse((await file.readAsString()).trim());
    } catch (_) {
      return fallback;
    }
  }

  /// Shared writer. Best-effort by design: a failed write loses the preference for
  /// next launch, but the choice still applies for this session, and a settings
  /// toggle is not worth surfacing an error over.
  Future<void> _saveTag(String name, String tag) async {
    try {
      await (await _resolveNamed(name)).writeAsString(tag);
    } catch (_) {
      // best-effort; the choice still applies for this session
    }
  }
}
