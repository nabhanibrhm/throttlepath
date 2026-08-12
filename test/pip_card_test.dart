import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/services/tracking_service.dart' show LiveTelemetry;
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/pip_card.dart';

/// The Picture-in-Picture card: the whole app shrunk to a floating window with
/// live speed, distance and elapsed time, and deliberately no controls.
///
/// What these tests really protect is that the card cannot disagree with the
/// Record screen. Both read the same [TrackingUiState] rules, so a frozen clock, a
/// blackout and the pre-ride phases have to read the same way in the small window
/// as they do in the big one.

/// Without the real face the test renderer measures every glyph as a fixed em
/// square, which throws the layout off for reasons unrelated to the card. Same
/// helper as `telemetry_sheet_gauge_test.dart`.
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

LiveTelemetry _telemetry({
  double speedKmh = 63,
  double distanceMeters = 12400,
  int durationSeconds = 1453,
  bool paused = false,
  bool signalLost = false,
}) =>
    LiveTelemetry(
      rideId: 1,
      distanceMeters: distanceMeters,
      speedKmh: speedKmh,
      maxSpeedKmh: 88,
      avgSpeedKmh: 31,
      durationSeconds: durationSeconds,
      movingSeconds: 1400,
      pointCount: 900,
      finished: false,
      hasFix: true,
      paused: paused,
      signalLost: signalLost,
    );

/// A real PiP window is roughly a third of the screen's short edge. Pumping at
/// that size rather than a comfortable one is the point — the card scales itself
/// to fit, and an overflow here would be invisible at desktop dimensions.
const Size _pipWindow = Size(150, 100);

Future<void> _pump(
  WidgetTester t,
  TrackingUiState state, {
  SpeedUnit unit = SpeedUnit.kmh,
  Size size = _pipWindow,
}) async {
  await t.pumpWidget(
    MaterialApp(
      theme: buildDarkTheme(),
      home: Center(
        child: SizedBox.fromSize(
          size: size,
          child: PipCard(state: state, unit: unit),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(loadInter);

  testWidgets('shows live speed as the hero, with distance and elapsed',
      (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(),
      ),
    );

    expect(find.text('63'), findsOneWidget);
    expect(find.text('km/h'), findsOneWidget);
    expect(find.text('12.40'), findsOneWidget);
    expect(find.text('km'), findsOneWidget);
    expect(find.text('24:13'), findsOneWidget);
  });

  testWidgets('converts to the rider unit, like every other readout', (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(),
      ),
      unit: SpeedUnit.mph,
    );

    expect(find.text('39'), findsOneWidget); // 63 km/h
    expect(find.text('mph'), findsOneWidget);
    expect(find.text('7.71'), findsOneWidget); // 12.40 km
    expect(find.text('mi'), findsOneWidget);
  });

  testWidgets('says PAUSED and zeroes the speed when the clock is frozen',
      (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        isPaused: true,
        phase: 'recording',
        telemetry: _telemetry(paused: true),
      ),
    );

    expect(find.text('PAUSED'), findsOneWidget);
    // A frozen ride showing its last-known speed would look like it was moving.
    expect(find.text('0'), findsOneWidget);
    expect(find.text('63'), findsNothing);
  });

  testWidgets('admits a GPS blackout rather than showing a stalled clock',
      (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(signalLost: true),
      ),
    );

    expect(find.text('GPS SIGNAL LOST'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('shows what it is waiting for instead of four zeros', (t) async {
    // The Record screen was redesigned to stop rendering 0.00 km / 00:00 before a
    // ride exists; the small window must not reintroduce them.
    await _pump(t, const TrackingUiState(isTracking: true, phase: 'acquiring'));

    expect(find.text('ACQUIRING GPS'), findsOneWidget);
    expect(find.text('0.00'), findsNothing);
    expect(find.text('00:00'), findsNothing);
  });

  testWidgets('shows the countdown digit while starting', (t) async {
    await _pump(
      t,
      const TrackingUiState(
        isTracking: true,
        phase: 'countdown',
        countdown: 2,
      ),
    );

    expect(find.text('2'), findsOneWidget);
    expect(find.text('ACQUIRING GPS'), findsNothing);
  });

  testWidgets('carries no controls at all', (t) async {
    // The design decision this file exists to hold. PiP content receives no touch
    // events, so a button here would be dead — and pause/stop live behind
    // hold-to-stop in the restored app on purpose.
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(),
      ),
    );

    expect(find.byType(ButtonStyleButton), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(GestureDetector), findsNothing);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('does not overflow in a real-sized PiP window', (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        isPaused: true,
        phase: 'recording',
        // The tallest state — hero plus the frozen pill plus the stats row — and
        // the widest numbers: a 3-digit distance and an hour on the clock. The
        // Split share card already pushes "km" onto its own line at 132.09, so
        // that figure is the one worth pinning here.
        telemetry: _telemetry(
          distanceMeters: 132090,
          durationSeconds: 7325,
          paused: true,
        ),
      ),
    );

    expect(find.text('132.09'), findsOneWidget);
    expect(find.text('2:02:05'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('no text carries an inherited decoration', (t) async {
    // A real bug, found on the device: every number in the window was underlined
    // in amber. `PipHost` returns this card straight out of `MaterialApp.builder`
    // in place of the Navigator, so — unlike every other screen — there is no
    // Scaffold, and therefore no Material and no DefaultTextStyle, above it.
    // `DefaultTextStyle.of` fell through to Flutter's fallback, whose debug style
    // carries a yellow double underline, and the card's `inherit: true` styles
    // merged on top of it and kept the decoration.
    //
    // Asserted on every Text in the tree rather than on the widget that was
    // wrong, because the failure was inheritance: any future Text added here is
    // exposed to exactly the same thing.
    for (final state in <TrackingUiState>[
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(),
      ),
      TrackingUiState(
        isTracking: true,
        isPaused: true,
        phase: 'recording',
        telemetry: _telemetry(paused: true),
      ),
      const TrackingUiState(isTracking: true, phase: 'acquiring'),
      const TrackingUiState(
        isTracking: true,
        phase: 'countdown',
        countdown: 3,
      ),
    ]) {
      await _pump(t, state, size: const Size(300, 200));

      final elements = t.elementList(find.byType(Text)).toList();
      expect(elements, isNotEmpty);
      for (final element in elements) {
        final text = element.widget as Text;
        // Resolved from the Text's *own* context, so the lookup lands on the
        // DefaultTextStyle the card installs rather than whatever sits above it —
        // reading it any higher tests the ancestor, which is the thing that was
        // wrong in the first place.
        final effective =
            DefaultTextStyle.of(element).style.merge(text.style);
        expect(
          effective.decoration ?? TextDecoration.none,
          TextDecoration.none,
          reason: '"${text.data}" inherited a decoration',
        );
      }
    }
  });

  testWidgets('survives a window narrower than the design canvas', (t) async {
    await _pump(
      t,
      TrackingUiState(
        isTracking: true,
        phase: 'recording',
        telemetry: _telemetry(),
      ),
      size: const Size(96, 64),
    );
    expect(t.takeException(), isNull);
  });
}
