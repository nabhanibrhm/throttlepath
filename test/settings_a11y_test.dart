import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/providers/settings_providers.dart';
import 'package:throttlepath/services/rides_csv_export.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/live_speed_announcer.dart';
import 'package:throttlepath/ui/settings_screen.dart';

/// Phase 7 — the settings regroup and the accessibility pass. The point of these
/// is the things a sighted developer on a default-sized screen never sees: rows
/// under the touch target, labels that clip at a larger text scale, and controls
/// that are silent to a screen reader.

Future<void> loadInter() async {
  final loader = FontLoader('Inter');
  for (final weight in const [
    'Regular',
    'Medium',
    'SemiBold',
    'Bold',
    'ExtraBold',
  ]) {
    final file = File('assets/fonts/Inter-$weight.ttf');
    if (!file.existsSync()) continue;
    loader.addFont(file.readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

void useDeviceSurface(WidgetTester t) {
  t.view.physicalSize = const Size(353 * 3, 760 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

/// The device's real *width* over a viewport tall enough to build the whole list
/// in one pass.
///
/// The width is what layout bugs come from and stays honest at 353dp; the height
/// only decides how much of a lazy `ListView` exists at all. Scrolling to reach
/// the later sections instead would destroy the earlier ones, and an ordering
/// assertion needs them all on screen at once.
void useTallSurface(WidgetTester t) {
  t.view.physicalSize = const Size(353 * 3, 2600 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

/// [version] left null deliberately means *no override*, so the About row runs
/// against the real `appVersionProvider` — which under `flutter test` hits an
/// unregistered plugin and takes its `catch`. That is the path most of this file
/// exercises incidentally, and one test below asserts on purpose.
Widget host({
  ThemeData? theme,
  double textScale = 1.0,
  ThemeMode mode = ThemeMode.dark,
  String? version,
}) {
  return ProviderScope(
    overrides: [
      themeModeProvider.overrideWith((ref) => ThemeModeController(mode)),
      if (version != null) appVersionProvider.overrideWith((ref) => version),
    ],
    child: MaterialApp(
      theme: theme ?? buildDarkTheme(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: const SettingsScreen(),
        ),
      ),
    ),
  );
}

List<Object> takeCapturedExceptions() {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}

void main() {
  setUpAll(loadInter);

  group('grouping', () {
    testWidgets('sections read Units, Display, Ride screen, Recording, Data, '
        'About — in that order', (t) async {
      useTallSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      const order = [
        'UNITS',
        'DISPLAY',
        'RIDE SCREEN',
        'RECORDING',
        'DATA',
        'ABOUT',
      ];
      var lastY = -1.0;
      for (final heading in order) {
        expect(find.text(heading), findsOneWidget, reason: '$heading missing');
        final y = t.getTopLeft(find.text(heading)).dy;
        expect(y, greaterThan(lastY), reason: '$heading is out of order');
        lastY = y;
      }
    });

    testWidgets('speed unit moved out of Display into its own group', (t) async {
      useTallSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();
      // A measurement system and a colour scheme were sharing a heading.
      final unitsY = t.getTopLeft(find.text('UNITS')).dy;
      final displayY = t.getTopLeft(find.text('DISPLAY')).dy;
      final rowY = t.getTopLeft(find.text('Speed and distance')).dy;
      expect(rowY, greaterThan(unitsY));
      expect(rowY, lessThan(displayY));
    });

    testWidgets('every settings row clears the 48dp touch target', (t) async {
      useTallSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      for (final title in const [
        'Speed and distance',
        'Backdrop',
        'Live speed',
        'Start countdown',
        'Keep screen on',
        'Export all rides',
        'Refresh place names',
      ]) {
        final row = find.ancestor(
          of: find.text(title),
          matching: find.byType(InkWell),
        );
        expect(row, findsWidgets, reason: '$title has no tap target');
        expect(t.getSize(row.first).height, greaterThanOrEqualTo(48.0),
            reason: '$title is under 48dp');
      }
    });
  });

  // The three-up segmented control moved into a sheet (spec 8.4), so all three of
  // these now have to open it first. The *properties* being asserted are
  // unchanged — three reachable modes, System actually selectable and storable,
  // and the current one marked selected to a screen reader — because those are
  // what the original bug was about, not where the control happened to live.
  group('theme', () {
    testWidgets('is a three-way choice, not a dark-mode switch', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      // The row itself shows only the current value; it is no longer the control.
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('Dark mode'), findsNothing);
      expect(find.byType(Switch), findsNWidgets(2)); // countdown + screen-on

      await t.tap(find.text('Theme'));
      await t.pumpAndSettle();

      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      // Two: the sheet's option plus the row's own value behind it.
      expect(find.text('Dark'), findsNWidgets(2));
    });

    testWidgets('System is reachable and actually selectable', (t) async {
      useDeviceSurface(t);
      final container = ProviderContainer(overrides: [
        themeModeProvider
            .overrideWith((ref) => ThemeModeController(ThemeMode.dark)),
      ]);
      addTearDown(container.dispose);

      await t.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildDarkTheme(),
          home: const SettingsScreen(),
        ),
      ));
      await t.pumpAndSettle();

      expect(container.read(themeModeProvider), ThemeMode.dark);

      await t.tap(find.text('Theme'));
      await t.pumpAndSettle();
      await t.tap(find.text('System'));
      await t.pumpAndSettle();
      // This is the state loadThemeMode used to silently collapse into dark.
      expect(container.read(themeModeProvider), ThemeMode.system);
      // Selecting closes the sheet — one tap, not select-then-confirm.
      expect(find.text('Light'), findsNothing);

      await t.tap(find.text('Theme'));
      await t.pumpAndSettle();
      await t.tap(find.text('Light'));
      await t.pumpAndSettle();
      expect(container.read(themeModeProvider), ThemeMode.light);
    });

    testWidgets('the selected mode is marked selected for screen readers',
        (t) async {
      useDeviceSurface(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host(mode: ThemeMode.light));
      await t.pumpAndSettle();
      await t.tap(find.text('Theme'));
      await t.pumpAndSettle();

      expect(
        t.getSemantics(find.bySemanticsLabel('Light theme')),
        matchesSemantics(
          label: 'Light theme',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      semantics.dispose();
    });

    testWidgets('no row carries a decorative icon tile any more', (t) async {
      useTallSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      // G5: every row used to *lead* with a 36dp amber-tinted square. Eight of
      // them down the left edge spent the accent on decoration, and none told a
      // rider anything the label didn't.
      //
      // Asserted positionally rather than by count, because the icons that
      // legitimately remain — the share and refresh glyphs on the two action
      // rows — are trailing affordances saying "this row does something". What
      // must never come back is an icon in the *leading* slot, so every icon in
      // the list has to sit in the row's trailing half.
      final icons = find.byType(Icon);
      expect(icons, findsWidgets);
      for (var i = 0; i < icons.evaluate().length; i++) {
        expect(t.getTopLeft(icons.at(i)).dx, greaterThan(176),
            reason: 'an icon is back in the leading tile position');
      }
    });
  });

  group('about', () {
    testWidgets('the version is read from the build, not typed into the row',
        (t) async {
      useTallSurface(t);
      await t.pumpWidget(host(version: '9.9.9'));
      await t.pumpAndSettle();

      // Asserting the *real* version here would re-hardcode the bug one layer
      // down: `1.0.0` sat in this row for the whole of 1.1.0 precisely because
      // shipping a new version meant remembering to retype a string.
      expect(find.textContaining('Version 9.9.9'), findsOneWidget);
      expect(find.textContaining('1.0.0'), findsNothing);
    });

    testWidgets('a platform that will not answer says nothing, not a placeholder',
        (t) async {
      // No override, so `PackageInfo.fromPlatform()` throws — the same shape as
      // any platform with no manifest to read. The row has to drop the version
      // rather than invent one, because a wrong version in a bug report is worse
      // than none.
      useTallSurface(t);
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      expect(find.text('Rides are stored on this phone only.'), findsOneWidget);
      expect(find.textContaining('Version'), findsNothing);
      expect(takeCapturedExceptions(), isEmpty);
    });
  });

  group('screen reader', () {
    testWidgets('a value row announces its value once, not twice', (t) async {
      useDeviceSurface(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      final node = t.getSemantics(find.bySemanticsLabel('Speed and distance'));
      expect(node.value, 'km/h');
      // The trailing Text is excluded, so "km/h" isn't also read as a loose
      // string sitting next to the row.
      semantics.dispose();
    });

    testWidgets('an on/off row reads as toggled, not as a button', (t) async {
      useDeviceSurface(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host());
      await t.pumpAndSettle();

      expect(
        t.getSemantics(find.bySemanticsLabel('Start countdown')),
        isSemantics(hasToggledState: true, isToggled: false),
      );
      semantics.dispose();
    });

    testWidgets('section headings are marked as headings', (t) async {
      useTallSurface(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host());
      await t.pumpAndSettle();
      expect(
        t.getSemantics(find.text('DATA')),
        isSemantics(isHeader: true),
      );
      semantics.dispose();
    });
  });

  group('text scale', () {
    for (final scale in const [1.0, 1.3, 1.6]) {
      for (final (name, theme) in [
        ('dark', buildDarkTheme()),
        ('light', buildLightTheme()),
      ]) {
        testWidgets('nothing clips at ${scale}x in the $name theme', (t) async {
          useDeviceSurface(t);
          await t.pumpWidget(host(theme: theme, textScale: scale));
          await t.pumpAndSettle();
          // Rows size to their content (minHeight, not height), so a larger
          // system font grows the row instead of overflowing it.
          expect(takeCapturedExceptions(), isEmpty);
          await t.drag(find.byType(ListView), const Offset(0, -600));
          await t.pumpAndSettle();
          expect(takeCapturedExceptions(), isEmpty);
        });
      }
    }
  });

  group('live speed announcer', () {
    test('speaks units as words a screen reader can pronounce', () {
      // "42 km/h" is read as "forty-two kay em slash aitch".
      expect(LiveSpeedAnnouncer.spoken(42.4, 'km/h'), '42 kilometres per hour');
      expect(LiveSpeedAnnouncer.spoken(63.5, 'mph'), '64 miles per hour');
    });

    testWidgets('announces at most once per throttle window', (t) async {
      final semantics = t.ensureSemantics();

      Widget at(double speed) => MaterialApp(
            home: Scaffold(
              body: LiveSpeedAnnouncer(
                speed: speed,
                unitLabel: 'km/h',
                active: true,
                announceEvery: const Duration(seconds: 5),
                child: Text('${speed.round()}'),
              ),
            ),
          );

      await t.pumpWidget(at(40));
      await t.pumpAndSettle();
      String spoken() =>
          t.getSemantics(find.bySemanticsLabel('Current speed')).value;
      expect(spoken(), '40 kilometres per hour');

      // A second later the number on screen has moved, but the region stays
      // quiet — otherwise TalkBack talks over everything, once a second, forever.
      await t.pumpWidget(at(55));
      await t.pumpAndSettle();
      expect(spoken(), '40 kilometres per hour');
      expect(find.text('55'), findsOneWidget); // the visual reading is current

      semantics.dispose();
    });

    testWidgets('goes quiet when there is no live speed', (t) async {
      final semantics = t.ensureSemantics();
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LiveSpeedAnnouncer(
            speed: 0,
            unitLabel: 'km/h',
            active: false,
            child: Text('0'),
          ),
        ),
      ));
      await t.pumpAndSettle();
      final node = t.getSemantics(find.bySemanticsLabel('Speed'));
      expect(node.value, 'not recording');
      semantics.dispose();
    });
  });

  group('csv export', () {
    Ride ride({
      int id = 1,
      String? name,
      String? startPlace,
      double? smoothness,
    }) =>
        Ride()
          ..id = id
          ..name = name
          ..startTime = DateTime(2026, 7, 28, 7, 5, 30)
          ..endTime = DateTime(2026, 7, 28, 8, 0)
          ..totalDistanceMeters = 30670.4
          ..durationSeconds = 3270
          ..movingSeconds = 3000
          ..averageSpeedKmh = 24.44
          ..maxSpeedKmh = 61.8
          ..startPlace = startPlace
          ..smoothness = smoothness;

    test('the header names every column that gets written', () {
      final lines = RidesCsvExport.buildCsv([ride()]).trim().split('\n');
      expect(lines, hasLength(2));
      final headers = lines.first.trim().split(',');
      final values = lines[1].trim().split(',');
      expect(values, hasLength(headers.length));
      expect(headers.first, 'id');
      expect(headers, contains('smoothness'));
      expect(headers, contains('route_key'));
    });

    test('a comma in a ride name does not shift every later column', () {
      // "Bandung, then home" would otherwise silently become two fields.
      final csv = RidesCsvExport.buildCsv([ride(name: 'Bandung, then home')]);
      expect(csv, contains('"Bandung, then home"'));
      final row = csv.trim().split('\n')[1];
      expect(RidesCsvExport.csvField('Bandung, then home'),
          '"Bandung, then home"');
      // Fields outside the quoted one are still where they should be.
      expect(row, contains('30670.4'));
    });

    test('embedded quotes are doubled, per RFC 4180', () {
      expect(RidesCsvExport.csvField('the "long" way'), '"the ""long"" way"');
    });

    test('a plain field is not quoted for no reason', () {
      expect(RidesCsvExport.csvField('Morning commute'), 'Morning commute');
      expect(RidesCsvExport.csvField(null), '');
    });

    test('an unscored ride writes an empty cell, not a zero', () {
      // Zero means "ridden appallingly"; empty means "not scored".
      final csv = RidesCsvExport.buildCsv([ride(smoothness: null)]);
      final cells = csv.trim().split('\n')[1].split(',');
      final headers = csv.trim().split('\n').first.split(',');
      expect(cells[headers.indexOf('smoothness')], isEmpty);

      final scored = RidesCsvExport.buildCsv([ride(smoothness: 82.4)]);
      expect(scored.trim().split('\n')[1].split(',')[headers.indexOf('smoothness')],
          '82.4');
    });

    test('timestamps are local and spreadsheet-parseable', () {
      final csv = RidesCsvExport.buildCsv([ride()]);
      expect(csv, contains('2026-07-28 07:05:30'));
    });

    test('the filename carries the export date', () {
      expect(RidesCsvExport.fileNameFor(DateTime(2026, 7, 29)),
          'throttlepath-rides-20260729.csv');
    });
  });
}
