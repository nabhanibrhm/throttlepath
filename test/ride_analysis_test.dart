import 'dart:io';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/providers/stats_providers.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/chart_frame.dart';
import 'package:throttlepath/ui/chart_math.dart';
import 'package:throttlepath/ui/elevation_speed_chart.dart';
import 'package:throttlepath/ui/smoothness_chart.dart';
import 'package:throttlepath/ui/speed_zone_chart.dart';

/// Phase 6 — the analysis tabs. These pump the real charts at the device's width
/// so a takeaway sentence that wraps into an overflow, or a series that forgets to
/// downsample, fails here rather than on the phone.

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

final _t0 = DateTime(2026, 7, 29, 8);

/// A track of [count] fixes at 1 Hz. [speedAt] is metres per second; [altAt]
/// returns null for a track with no altitude at all.
List<TrackPoint> track(
  int count, {
  required double Function(int i) speedAt,
  double? Function(int i)? altAt,
}) {
  return [
    for (var i = 0; i < count; i++)
      TrackPoint()
        ..rideId = 1
        ..latitude = -6.914 - i * 0.0004
        ..longitude = 107.609 + i * 0.0003
        ..speedMps = speedAt(i)
        ..altitude = altAt?.call(i)
        ..timestamp = _t0.add(Duration(seconds: i)),
  ];
}

/// A varied but realistic urban trace: crawling, cruising, and a fast stretch.
double _mixedSpeed(int i) {
  if (i % 97 < 20) return 4 + (i % 5); // traffic
  if (i % 97 < 70) return 12 + (i % 7) * 0.4; // cruise
  return 24 + (i % 3) * 0.5; // open road
}

Widget host(Widget child, {ThemeData? theme, List<double> previous = const []}) {
  return ProviderScope(
    overrides: [
      recentSmoothnessProvider(1).overrideWith((ref) async => previous),
    ],
    child: MaterialApp(
      theme: theme ?? buildDarkTheme(),
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  setUpAll(loadInter);

  group('speed zones', () {
    testWidgets('the donut is gone, replaced by one stacked bar', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(400, speedAt: _mixedSpeed), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      // F27: the donut asked the eye to compare angles and match wedges to a
      // legend. Nothing should be drawing one any more.
      expect(find.byType(PieChart), findsNothing);
      expect(find.text('SPEED ZONES'), findsOneWidget);
      // The table it sat above survives.
      expect(find.text('0 – 30'), findsOneWidget);
      expect(find.text('90+'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('the bar is ordered slowest to fastest and captioned',
        (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(400, speedAt: _mixedSpeed), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      final slowest = t.getTopLeft(find.text('SLOWEST'));
      final fastest = t.getTopLeft(find.text('FASTEST'));
      expect(slowest.dx, lessThan(fastest.dx));
      expect(find.text('SPEED ZONE (km/h)'), findsOneWidget);
    });

    testWidgets('the takeaway names the dominant zone in words', (t) async {
      useDeviceSurface(t);
      // Everything between 30 and 60 km/h (8.3–16.6 m/s).
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(200, speedAt: (_) => 12), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      expect(
        find.textContaining('was spent between 30 – 60 km/h'),
        findsOneWidget,
      );
      expect(find.textContaining('100%'), findsWidgets);
    });

    testWidgets('the top zone reads "above 90", not "between 90+"', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(200, speedAt: (_) => 30), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('was spent above 90 km/h'), findsOneWidget);
      expect(find.textContaining('between 90+'), findsNothing);
    });

    testWidgets('tapping a table row highlights it', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(400, speedAt: _mixedSpeed), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      TextStyle styleOf(String label) =>
          t.widget<Text>(find.text(label)).style!;
      expect(styleOf('0 – 30').fontWeight, FontWeight.w400);
      await t.tap(find.text('0 – 30'));
      await t.pumpAndSettle();
      expect(styleOf('0 – 30').fontWeight, FontWeight.w700);
      // Tapping again clears it — nothing should be stuck selected.
      await t.tap(find.text('0 – 30'));
      await t.pumpAndSettle();
      expect(styleOf('0 – 30').fontWeight, FontWeight.w400);
    });

    testWidgets('zone edges follow the display unit', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SpeedZoneChart(points: track(200, speedAt: _mixedSpeed), unit: SpeedUnit.mph),
      ));
      await t.pumpAndSettle();
      expect(find.text('SPEED ZONE (mph)'), findsOneWidget);
      expect(find.text('0 – 20'), findsOneWidget);
      expect(find.text('60+'), findsOneWidget);
    });
  });

  group('smoothness', () {
    testWidgets('the score leads, with the scatter as evidence', (t) async {
      useDeviceSurface(t);
      final semantics = t.ensureSemantics();
      await t.pumpWidget(host(
        SmoothnessChart(
          rideId: 1,
          // A perfectly constant speed: max |a| is zero, which used to trip
          // fl_chart's "grid interval couldn't be zero" assertion.
          points: track(300, speedAt: (_) => 12),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('SMOOTHNESS'), findsOneWidget);
      expect(find.byType(ScatterChart), findsOneWidget);
      expect(
        find.bySemanticsLabel('Smoothness score 100 out of 100'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Scored 100 out of 100 — very smooth'),
        findsOneWidget,
      );
      semantics.dispose();
    });

    testWidgets('the takeaway folds in the comparison when there is history',
        (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SmoothnessChart(
          rideId: 1,
          points: track(300, speedAt: (i) => i.isEven ? 10 : 11),
          unit: SpeedUnit.kmh,
        ),
        previous: const [30, 40, 90],
      ));
      await t.pumpAndSettle();
      // rms 1.0 of a 2.0 scale → 50.
      expect(
        find.textContaining('smoother than 2 of your last 3 rides'),
        findsOneWidget,
      );
    });

    testWidgets('the bands are named, not left as a signed number', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SmoothnessChart(
          rideId: 1,
          points: track(300, speedAt: _mixedSpeed),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('ACCELERATING ▲'), findsOneWidget);
      expect(find.text('BRAKING ▼'), findsOneWidget);
      // F28: the axis has to say what its numbers are.
      expect(find.text('KM/H PER SECOND'), findsOneWidget);
    });

    testWidgets('an unscoreable track says so instead of showing a bare chart',
        (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SmoothnessChart(
          rideId: 1,
          points: track(5, speedAt: (_) => 10),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('Too few usable GPS intervals'), findsOneWidget);
    });
  });

  group('elevation', () {
    List<TrackPoint> hilly(int n) => track(
          n,
          speedAt: _mixedSpeed,
          altAt: (i) => 700 + (i % 120) * 1.5,
        );

    testWidgets('each axis is coloured to its own series', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        ElevationSpeedChart(points: hilly(400), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      final cx = AppPalette.dark;
      expect(t.widget<Text>(find.text('KM/H')).style!.color, cx.accentInk);
      expect(t.widget<Text>(find.text('METRES')).style!.color, cx.positiveInk);
    });

    testWidgets('a legend chip actually turns its series off', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        ElevationSpeedChart(points: hilly(400), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      int bars() =>
          t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.length;
      expect(bars(), 2);
      await t.tap(find.text('Elevation (m)'));
      await t.pumpAndSettle();
      expect(bars(), 1);
      expect(find.text('METRES'), findsNothing);
    });

    testWidgets('the last visible series cannot be switched off', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        ElevationSpeedChart(points: hilly(400), unit: SpeedUnit.kmh),
      ));
      await t.pumpAndSettle();

      await t.tap(find.text('Elevation (m)'));
      await t.pumpAndSettle();
      // An empty plot reads as a bug and leaves no affordance to recover.
      await t.tap(find.text('Speed (km/h)'));
      await t.pumpAndSettle();
      expect(
        t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData.length,
        1,
      );
    });

    testWidgets('speed comes from the fix, never from the gap between fixes',
        (t) async {
      useDeviceSurface(t);
      // [track] spaces its fixes ~56 m apart at 1 Hz — a position-derived speed
      // of roughly 200 km/h — while each fix *reports* 36 km/h, and one reports
      // 90. The reported figure is the honest one: it is Doppler, measured, and
      // it is what the engine's own max speed comes from.
      //
      // A real ride carried this shape. Stint 5 of the "Touring Ujung Genteng"
      // trip holds a fix pair implying 105.5 km/h against a stored max of 92.8;
      // the jump gate never fired, because 105 is nowhere near its 220 km/h
      // ceiling. The position spike is simply still in the track. It is harmless
      // only for as long as nothing plots it, which is what this pins.
      const fastestMps = 25.0;
      final points = track(
        200,
        speedAt: (i) => i == 100 ? fastestMps : 10,
        altAt: (i) => 700 + i.toDouble(),
      );
      await t.pumpWidget(
          host(ElevationSpeedChart(points: points, unit: SpeedUnit.kmh)));
      await t.pumpAndSettle();

      // Drop elevation so the remaining bar is unambiguously the speed series.
      await t.tap(find.text('Elevation (m)'));
      await t.pumpAndSettle();

      final bars =
          t.widget<LineChart>(find.byType(LineChart)).data.lineBarsData;
      expect(bars, hasLength(1));
      final peak = bars.single.spots
          .map((s) => s.y)
          .reduce((a, b) => a > b ? a : b);
      // 200 points is under kChartMaxPoints, so nothing thinned the spike away.
      expect(peak, closeTo(fastestMps * 3.6, 0.5),
          reason: 'the chart plotted a position-derived speed, not speedMps');
    });

    testWidgets('a flat track drops the tab rather than drawing noise',
        (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        ElevationSpeedChart(
          points: track(200, speedAt: _mixedSpeed, altAt: (_) => 700),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.byType(LineChart), findsNothing);
    });
  });

  group('downsampling', () {
    testWidgets('a long trace is thinned before it is painted', (t) async {
      useDeviceSurface(t);
      // 4000 fixes is a bit over an hour at 1 Hz — the length that made the old
      // pager sticky (F26), because fl_chart laid out every sample every frame.
      await t.pumpWidget(host(
        ElevationSpeedChart(
          points: track(4000,
              speedAt: _mixedSpeed, altAt: (i) => 700 + (i % 400) * 0.4),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();

      final data = t.widget<LineChart>(find.byType(LineChart)).data;
      for (final bar in data.lineBarsData) {
        expect(bar.spots.length, lessThanOrEqualTo(kChartMaxPoints + 1));
      }
    });

    testWidgets('the scatter is thinned too', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(
        SmoothnessChart(
          rideId: 1,
          points: track(4000, speedAt: _mixedSpeed),
          unit: SpeedUnit.kmh,
        ),
      ));
      await t.pumpAndSettle();

      final data =
          t.widget<ScatterChart>(find.byType(ScatterChart)).data;
      expect(data.scatterSpots.length, lessThanOrEqualTo(kChartMaxPoints + 1));
    });

    test('thinning keeps the ends, which carry the start and finish', () {
      final xs = [for (var i = 0; i < 5000; i++) i];
      final out = downsample(xs, kChartMaxPoints);
      expect(out.length, lessThanOrEqualTo(kChartMaxPoints + 1));
      expect(out.first, 0);
      expect(out.last, 4999);
    });

    test('a series already short enough is returned untouched', () {
      final xs = [1, 2, 3];
      expect(identical(downsample(xs, kChartMaxPoints), xs), isTrue);
    });
  });

  group('layout', () {
    for (final (name, theme) in [
      ('dark', buildDarkTheme()),
      ('light', buildLightTheme()),
    ]) {
      testWidgets('nothing overflows in the $name theme', (t) async {
        useDeviceSurface(t);
        final points = track(
          600,
          speedAt: _mixedSpeed,
          altAt: (i) => 700 + (i % 120) * 1.5,
        );
        for (final chart in <Widget>[
          SpeedZoneChart(points: points, unit: SpeedUnit.kmh),
          SmoothnessChart(rideId: 1, points: points, unit: SpeedUnit.kmh),
          ElevationSpeedChart(points: points, unit: SpeedUnit.kmh),
        ]) {
          await t.pumpWidget(host(chart, theme: theme));
          await t.pumpAndSettle();
          expect(takeCapturedExceptions(), isEmpty, reason: '$chart overflowed');
        }
      });
    }

    testWidgets('every chart carries a title and a takeaway', (t) async {
      useDeviceSurface(t);
      final points = track(400, speedAt: _mixedSpeed);
      for (final chart in <Widget>[
        SpeedZoneChart(points: points, unit: SpeedUnit.kmh),
        SmoothnessChart(rideId: 1, points: points, unit: SpeedUnit.kmh),
      ]) {
        await t.pumpWidget(host(chart));
        await t.pumpAndSettle();
        // F26: chart 1 shipped with no title at all, and none of them explained
        // what they were showing.
        final frame = t.widget<ChartFrame>(find.byType(ChartFrame));
        expect(frame.title, isNotEmpty);
        expect(frame.takeaway.trim(), endsWith('.'));
      }
    });
  });
}

/// Any exception the binding captured during the last pump — an overflow shows
/// up here rather than as a failed expectation.
List<Object> takeCapturedExceptions() {
  final out = <Object>[];
  while (true) {
    final e = TestWidgetsFlutterBinding.instance.takeException();
    if (e == null) break;
    out.add(e as Object);
  }
  return out;
}
