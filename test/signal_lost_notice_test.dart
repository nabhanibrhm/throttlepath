import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/record_view.dart';
import 'package:throttlepath/core/speed_gauge_style.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/services/gnss_status.dart';
import 'package:throttlepath/services/tracking_service.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/telemetry_sheet.dart';

class _FakeGnssSource implements GnssStatusSource {
  final _controller = StreamController<GnssEvent>.broadcast();

  void report(int visible, int usedInFix) => _controller
      .add(GnssSnapshot(visible: visible, usedInFix: usedInFix));

  @override
  Stream<GnssEvent> events() => _controller.stream;
}

class _SilentGnssSource implements GnssStatusSource {
  @override
  Stream<GnssEvent> events() => const Stream<GnssEvent>.empty();
}

/// See the note in acquiring_progress_test.dart: Riverpod delivers a stream event
/// one microtask after the stream does, so one pump asserts against the previous
/// value.
Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump();
}

LiveTelemetry _telemetry({required bool signalLost, bool paused = false}) =>
    LiveTelemetry(
      rideId: 1,
      distanceMeters: 4200,
      speedKmh: 0,
      maxSpeedKmh: 88,
      avgSpeedKmh: 31,
      durationSeconds: 480,
      movingSeconds: 460,
      pointCount: 300,
      finished: false,
      hasFix: true,
      paused: paused,
      signalLost: signalLost,
    );

Widget _host(GnssStatusSource source, TrackingUiState state) => ProviderScope(
      overrides: [gnssStatusSourceProvider.overrideWithValue(source)],
      child: MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: TelemetrySheet(
            state: state,
            unit: SpeedUnit.kmh,
            view: RecordView.none,
            gaugeStyle: SpeedGaugeStyle.digital,
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
    );

TrackingUiState _blackout() => TrackingUiState(
      isTracking: true,
      phase: 'recording',
      telemetry: _telemetry(signalLost: true),
    );

void main() {
  testWidgets('a blackout names the constellation still overhead', (t) async {
    // The point of the count here: "5 of 12" says the sky is fine and the
    // receiver just cannot resolve a position, which is a very different thing
    // for the rider than the app having stopped working.
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source, _blackout()));
    expect(find.text('GPS SIGNAL LOST'), findsOneWidget);

    source.report(12, 5);
    await _settle(t);
    expect(find.text('Not recording — 5 of 12 satellites'), findsOneWidget);
  });

  testWidgets('zero satellites in view reads as the sky being gone', (t) async {
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source, _blackout()));

    source.report(9, 4);
    await _settle(t);
    expect(find.text('Not recording — 4 of 9 satellites'), findsOneWidget);

    // A receiver that has powered down reports (0, 0). "0 of 0 satellites" would
    // be a count where there is no report at all.
    source.report(0, 0);
    await _settle(t);
    expect(find.text('Not recording — waiting for GPS'), findsOneWidget);
  });

  testWidgets('falls back to the old wording on a silent receiver', (t) async {
    await t.pumpWidget(_host(_SilentGnssSource(), _blackout()));
    await _settle(t);
    expect(find.text('Not recording — waiting for GPS'), findsOneWidget);
  });

  testWidgets('a paused ride keeps its own sentence, not a satellite count',
      (t) async {
    // Pausing is the rider's own doing; how many satellites are up has nothing
    // to say about it.
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(
      source,
      TrackingUiState(
        isTracking: true,
        isPaused: true,
        phase: 'recording',
        telemetry: _telemetry(signalLost: false, paused: true),
      ),
    ));

    source.report(12, 8);
    await _settle(t);
    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.textContaining('satellites'), findsNothing);
  });
}
