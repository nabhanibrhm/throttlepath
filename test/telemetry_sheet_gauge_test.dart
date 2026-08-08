import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/record_view.dart';
import 'package:throttlepath/core/speed_gauge_style.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/ride_stats.dart';
import 'package:throttlepath/providers/history_providers.dart';
import 'package:throttlepath/providers/stats_providers.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/services/tracking_service.dart' show LiveTelemetry;
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/analog_speed_gauge.dart';
import 'package:throttlepath/ui/speed_sparkline.dart';
import 'package:throttlepath/ui/telemetry_sheet.dart';

/// The analog branch of the sheet, which nothing exercised before D-7 put a
/// second widget on its row.
///
/// The dial used to be the row: 280dp wide and 174dp tall, with the speed trend
/// available only to riders who had chosen the numeral. Both now get it, which
/// means the dial has to be handed a width instead of taking what it likes — and
/// a two-up row inside a sheet on a 353dp phone is exactly the shape that
/// overflows if a budget is a few dp out.

/// Without the real face, the test renderer measures every glyph as a fixed em
/// square — which makes the stats row below the dial overflow on its own, for
/// reasons that have nothing to do with the gauge. Same helper as
/// `history_list_test.dart` and `settings_a11y_test.dart`.
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

/// The device the app is tested against, portrait-locked.
const double _deviceWidth = 353;

/// Sheet padding is 20 a side, so this is what the hero row actually gets.
const double _content = _deviceWidth - 40;

void _useDevice(WidgetTester t) {
  t.view.physicalSize = const Size(_deviceWidth * 3, 760 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

LiveTelemetry _telemetry({double speed = 42, double max = 61}) => LiveTelemetry(
      rideId: 1,
      distanceMeters: 8200,
      speedKmh: speed,
      maxSpeedKmh: max,
      avgSpeedKmh: 31,
      durationSeconds: 950,
      movingSeconds: 900,
      pointCount: 400,
      finished: false,
      hasFix: true,
    );

/// A ride far enough along that the trend window is full — [samples] spread over
/// 8 km, so `SpeedSparkline.canDraw` is satisfied several times over.
List<SpeedSample> _samples(int n) => [
      for (var i = 0; i < n; i++)
        SpeedSample(i * (8000 / (n == 1 ? 1 : n - 1)), 20 + (i % 30).toDouble()),
    ];

Widget _host(TrackingUiState state) => ProviderScope(
      overrides: [
        latestRideProvider.overrideWith((ref) => null),
        weekStatsProvider.overrideWith((ref) => Completer<WeekStats>().future),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TelemetrySheet(
              state: state,
              unit: SpeedUnit.kmh,
              view: RecordView.none,
              // The branch under test. Everything here is invisible to a rider
              // on the numeral, which is why none of it had coverage.
              gaugeStyle: SpeedGaugeStyle.analog,
              accuracyMeters: null,
              onViewChanged: (_) {},
              onGaugeStyleChanged: (_) {},
              onStart: () {},
              onStop: () {},
              onPause: () {},
              onResume: () {},
              onSkipCountdown: () {},
            ),
          ),
        ),
      ),
    );

TrackingUiState _recording({int samples = 60, bool paused = false}) =>
    TrackingUiState(
      isTracking: true,
      phase: 'recording',
      isPaused: paused,
      telemetry: _telemetry(),
      speedSamples: _samples(samples),
    );

void main() {
  setUpAll(loadInter);

  group('recording', () {
    testWidgets('the dial gives up half the row to the speed trend', (t) async {
      _useDevice(t);
      await t.pumpWidget(_host(_recording()));
      await t.pumpAndSettle();

      expect(find.byType(SpeedSparkline), findsOneWidget);
      expect(t.getSize(find.byType(AnalogSpeedGauge)).width, 150);
      // 313 of content, less the dial and the 14dp gap.
      expect(t.getSize(find.byType(SpeedSparkline)).width, _content - 150 - 14);
    });

    testWidgets('the dial is shorter beside the trend than it was alone',
        (t) async {
      _useDevice(t);
      await t.pumpWidget(_host(_recording()));
      await t.pumpAndSettle();

      // width/2 for the half-disc, + 34 for the numeral in its mouth. The point
      // of the number is the direction: this is 65dp *less* than the 174 the
      // 280dp dial cost, so the row buys sheet height rather than spending it.
      expect(t.getSize(find.byType(AnalogSpeedGauge)).height, 150 / 2 + 34);
    });

    testWidgets('nothing overflows on the narrowest supported width', (t) async {
      _useDevice(t);
      await t.pumpWidget(_host(_recording()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('the trend appears with the ride, not two kilometres into it',
        (t) async {
      // One sample is not a trend — the sparkline draws nothing. What matters is
      // that the *row* is already the two-up shape, so the sheet does not shrink
      // 65dp under the rider a few seconds after START.
      _useDevice(t);
      await t.pumpWidget(_host(_recording(samples: 1)));
      await t.pumpAndSettle();

      expect(find.byType(SpeedSparkline), findsOneWidget);
      expect(t.getSize(find.byType(AnalogSpeedGauge)).width, 150);
      expect(t.takeException(), isNull);
    });

    testWidgets('the speed is still announced once, and unchanged', (t) async {
      final semantics = t.ensureSemantics();
      _useDevice(t);
      await t.pumpWidget(_host(_recording()));
      await t.pumpAndSettle();

      // The sparkline's own captions stay silent (the announcer excludes its
      // subtree), so a screen reader hears one speed, not a speed plus
      // "LAST 5 KM" and "peak 49".
      expect(
        t.getSemantics(find.bySemanticsLabel('Current speed')).value,
        '42 kilometres per hour',
      );
      semantics.dispose();
    });
  });

  group('standalone', () {
    testWidgets('the idle dial keeps its full width and no trend', (t) async {
      _useDevice(t);
      await t.pumpWidget(_host(const TrackingUiState()));
      await t.pumpAndSettle();

      // Idle, the dial is the whole hero — 280 is its own cap, and there is no
      // ride for a trend to be about.
      expect(find.byType(SpeedSparkline), findsNothing);
      expect(t.getSize(find.byType(AnalogSpeedGauge)).width, 280);
    });
  });
}
