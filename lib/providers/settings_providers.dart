import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';
import '../services/settings_service.dart';

/// Holds the active [ThemeMode] and persists every change.
///
/// Three-way (System / Light / Dark), not a switch: "Dark mode: off" cannot
/// express "follow the phone", which is what most riders actually want — the app
/// going light at sunrise with the rest of the device.
class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(super.state);

  Future<void> setMode(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    await SettingsService.instance.saveThemeMode(mode);
  }
}

/// Rider-facing name for a theme mode. Lives beside the controller so the
/// Settings row and any future surface cannot word it differently.
String themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.system => 'System',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };

/// The app's theme mode. Seeded in `main()` (via override) with the persisted
/// value so there is no theme flash on launch.
final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
  (ref) => ThemeModeController(ThemeMode.dark),
);

/// Holds the display speed/distance unit and persists every change.
class SpeedUnitController extends StateNotifier<SpeedUnit> {
  SpeedUnitController(super.state);

  Future<void> setUnit(SpeedUnit unit) async {
    if (unit == state) return;
    state = unit;
    await SettingsService.instance.saveSpeedUnit(unit);
  }

  /// Flip between km/h and mph.
  Future<void> toggle() =>
      setUnit(state == SpeedUnit.kmh ? SpeedUnit.mph : SpeedUnit.kmh);
}

/// The display unit for speeds and distances. Seeded in `main()` (via override)
/// with the persisted value.
final speedUnitProvider =
    StateNotifierProvider<SpeedUnitController, SpeedUnit>(
  (ref) => SpeedUnitController(SpeedUnit.kmh),
);

/// Holds the Record screen's backdrop view (map / chart / none) and persists
/// every change.
class RecordViewController extends StateNotifier<RecordView> {
  RecordViewController(super.state);

  Future<void> set(RecordView view) async {
    if (view == state) return;
    state = view;
    await SettingsService.instance.saveRecordView(view);
  }

  /// Advance to the next view in the cycle map → chart → none → map.
  Future<void> cycle() => set(state.next);
}

/// The Record screen's backdrop view. Seeded in `main()` (via override) with
/// the persisted value so the last-used view is shown without a flash.
final recordViewProvider =
    StateNotifierProvider<RecordViewController, RecordView>(
  (ref) => RecordViewController(RecordView.none),
);

/// Holds the live-speed gauge style (digital numeral vs analog arc) and persists
/// every change.
class SpeedGaugeStyleController extends StateNotifier<SpeedGaugeStyle> {
  SpeedGaugeStyleController(super.state);

  Future<void> set(SpeedGaugeStyle style) async {
    if (style == state) return;
    state = style;
    await SettingsService.instance.saveSpeedGaugeStyle(style);
  }

  /// Flip between the digital readout and the analog gauge.
  Future<void> toggle() => set(state.next);
}

/// How the Record screen draws the live speed. Seeded in `main()` (via override)
/// with the persisted value so the chosen gauge is up on the first frame.
final speedGaugeStyleProvider =
    StateNotifierProvider<SpeedGaugeStyleController, SpeedGaugeStyle>(
  (ref) => SpeedGaugeStyleController(SpeedGaugeStyle.digital),
);

/// Holds the "3… 2… 1… countdown before the clock starts" preference.
///
/// The recording engine reads the same pref straight off disk in its own
/// isolate, so this provider drives the Settings row only — it is not the path
/// by which the engine learns the value.
class CountdownEnabledController extends StateNotifier<bool> {
  CountdownEnabledController(super.state);

  Future<void> set(bool enabled) async {
    if (enabled == state) return;
    state = enabled;
    await SettingsService.instance.saveCountdownEnabled(enabled);
  }

  Future<void> toggle() => set(!state);
}

/// Whether the pre-ride countdown runs. Off by default (F10). Seeded in
/// `main()` (via override) with the persisted value.
final countdownEnabledProvider =
    StateNotifierProvider<CountdownEnabledController, bool>(
  (ref) => CountdownEnabledController(false),
);

/// Holds the "keep the screen on while recording" preference.
class KeepScreenOnController extends StateNotifier<bool> {
  KeepScreenOnController(super.state);

  Future<void> set(bool enabled) async {
    if (enabled == state) return;
    state = enabled;
    await SettingsService.instance.saveKeepScreenOn(enabled);
  }

  Future<void> toggle() => set(!state);
}

/// Whether a recording ride holds the screen awake. Off by default. Seeded in
/// `main()` (via override) with the persisted value.
final keepScreenOnProvider =
    StateNotifierProvider<KeepScreenOnController, bool>(
  (ref) => KeepScreenOnController(false),
);
