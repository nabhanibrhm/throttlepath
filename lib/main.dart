import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/settings_providers.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';
import 'ui/splash_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the saved preferences before the first frame so there is no flash of the
  // wrong theme or unit. Read together rather than in sequence — each lives in its
  // own file and none depends on another, so awaiting them one at a time is six
  // round-trips before anything can be drawn.
  //
  // Heavier startup work (DB, background service, tile cache) runs in
  // SplashScreen so the branded loader is visible while it happens.
  final prefs = SettingsService.instance;
  final (mode, unit, recordView, gaugeStyle, countdown, keepScreenOn) = await (
    prefs.loadThemeMode(),
    prefs.loadSpeedUnit(),
    prefs.loadRecordView(),
    prefs.loadSpeedGaugeStyle(),
    prefs.loadCountdownEnabled(),
    prefs.loadKeepScreenOn(),
  ).wait;
  runApp(
    ProviderScope(
      overrides: [
        themeModeProvider.overrideWith((ref) => ThemeModeController(mode)),
        speedUnitProvider.overrideWith((ref) => SpeedUnitController(unit)),
        recordViewProvider
            .overrideWith((ref) => RecordViewController(recordView)),
        speedGaugeStyleProvider
            .overrideWith((ref) => SpeedGaugeStyleController(gaugeStyle)),
        countdownEnabledProvider
            .overrideWith((ref) => CountdownEnabledController(countdown)),
        keepScreenOnProvider
            .overrideWith((ref) => KeepScreenOnController(keepScreenOn)),
      ],
      child: const ThrottlePathApp(),
    ),
  );
}

class ThrottlePathApp extends ConsumerWidget {
  const ThrottlePathApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'ThrottlePath',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      home: const SplashScreen(),
    );
  }
}
