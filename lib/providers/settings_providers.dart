import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/ttff.dart';
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

/// Glyph for a theme mode, beside [themeModeLabel] for the same reason: the
/// Settings row and the picker sheet both draw it, and a mode that looked like
/// the sun in one place and a moon in the other would be worse than no icon.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
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

/// Holds the rolling window of GNSS time-to-first-fix samples.
///
/// The one store here that loads itself instead of being seeded from `main()`:
/// nothing on the first frame reads it, so paying a file read at launch to avoid
/// a flash there would be paying for nothing. It is asked for the first time a
/// rider presses START, by which point the read has long landed.
class TtffSamplesController extends StateNotifier<List<int>> {
  TtffSamplesController() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    final loaded = await SettingsService.instance.loadTtffSamples();
    // A lock timed while the read was still in flight is newer than what came
    // off disk, and dropping it would lose the very sample we just measured.
    if (state.isEmpty) state = loaded;
  }

  /// Files one reading from the receiver, dropping the oldest once the window is
  /// full. Implausible readings are ignored, hence the identity check.
  Future<void> record(int millis) async {
    final next = withTtffSample(state, millis);
    if (identical(next, state)) return;
    state = next;
    await SettingsService.instance.saveTtffSamples(next);
  }
}

/// Recent time-to-first-fix readings for this phone, oldest first. Empty until
/// the load lands, and empty forever on a receiver that never reports a first
/// fix — both of which [typicalTtffLabel] renders as "say nothing".
final ttffSamplesProvider =
    StateNotifierProvider<TtffSamplesController, List<int>>(
  (ref) => TtffSamplesController(),
);

/// The version the build actually stamped, for the Settings "About" row.
///
/// Read from the package manifest rather than typed into the widget: the row
/// said `1.0.0` for the whole of 1.1.0 because a string a human has to remember
/// to bump is a string that goes stale, and this one is what a rider would quote
/// in a bug report.
///
/// Self-loading rather than seeded from `main()`, for [TtffSamplesController]'s
/// reason: `main()`'s pref `.wait` exists to stop a flash of the wrong theme or
/// unit on the *first frame*, and the version has no such stake — nothing reads
/// it until a rider has navigated to a tab two taps away.
///
/// `null` on failure is load-bearing, not defensive noise: the plugin registrant
/// does not run under `flutter test`, so `fromPlatform()` throws
/// `MissingPluginException` in every widget test that pumps `SettingsScreen`.
/// The row renders null as *say nothing* — never as a placeholder like `0.0.0`,
/// which would be a wrong answer where no answer is the honest one.
final appVersionProvider = FutureProvider<String?>((ref) async {
  try {
    return (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    return null;
  }
});
