import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/lean_gauge.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(body: Center(child: child)),
    );

/// Canvas angles are only meaningful modulo a full turn, and the dial's own
/// arithmetic can land on either representation of the same direction.
Matcher _pointsAt(double expected) => predicate<double>((actual) {
      final diff = (actual - expected) % (2 * math.pi);
      final wrapped = math.min(diff, 2 * math.pi - diff);
      return wrapped < 1e-9;
    }, 'points at ${expected}rad');

void main() {
  group('LeanGauge.needleAngle', () {
    // The clock positions the dial is specified by. Canvas angles run x-right,
    // y-down, so 12 o'clock is -pi/2, 9 o'clock is pi and 3 o'clock is 0.
    test('upright points straight up, at 12 o\'clock', () {
      expect(LeanGauge.needleAngle(0), _pointsAt(-math.pi / 2));
    });

    test('full left deflection points at 9 o\'clock', () {
      expect(LeanGauge.needleAngle(-90), _pointsAt(math.pi));
    });

    test('full right deflection points at 3 o\'clock', () {
      expect(LeanGauge.needleAngle(90), _pointsAt(0));
    });

    test('left lean rotates anticlockwise, right lean clockwise', () {
      // Measured as a signed offset from upright, which is what "which way does
      // the needle go" actually means.
      const up = -math.pi / 2;
      expect(LeanGauge.needleAngle(-30) - up, lessThan(0));
      expect(LeanGauge.needleAngle(30) - up, greaterThan(0));
    });

    test('the needle maps 1:1 to the angle — no gain, ever', () {
      // The dial's reason for existing: the needle IS the bike's lean line, so a
      // 12 deg lean must sit 12 deg off vertical and nothing may scale it.
      for (final lean in [1.0, 7.5, 12.0, 25.0, 45.0, 89.0]) {
        for (final signed in [lean, -lean]) {
          final offVertical =
              (LeanGauge.needleAngle(signed) - (-math.pi / 2)) * 180 / math.pi;
          expect(offVertical, closeTo(signed, 1e-9));
        }
      }
    });

    test('past full deflection the needle pins instead of wrapping under', () {
      // Physically unreachable, but a 120 deg glitch must not swing the needle
      // below the horizon where it would read as the opposite lean.
      expect(LeanGauge.needleAngle(200), _pointsAt(LeanGauge.needleAngle(90)));
      expect(LeanGauge.needleAngle(-200), _pointsAt(LeanGauge.needleAngle(-90)));
    });

    test('the scale is labelled with the deflection it actually has', () {
      expect(LeanGauge.scaleDegrees, 90);
    });
  });

  group('LeanGauge read-out', () {
    testWidgets('a left lean reads as a magnitude and the word LEFT',
        (t) async {
      await t.pumpWidget(
          _host(const LeanGauge(value: -35, caption: 'LIVE LEAN')));
      await t.pumpAndSettle();
      expect(find.text('35°'), findsOneWidget);
      expect(find.text('LEFT'), findsOneWidget);
      // Never a signed numeral — the side is a word, so there is no minus sign
      // for the rider to decode at a glance.
      expect(find.text('-35°'), findsNothing);
    });

    testWidgets('a right lean reads as the word RIGHT', (t) async {
      await t.pumpWidget(
          _host(const LeanGauge(value: 12, caption: 'LIVE LEAN')));
      await t.pumpAndSettle();
      expect(find.text('12°'), findsOneWidget);
      expect(find.text('RIGHT'), findsOneWidget);
    });

    testWidgets('no estimate says so rather than claiming a measured zero',
        (t) async {
      await t.pumpWidget(_host(
          const LeanGauge(value: null, caption: 'LIVE LEAN', dimmed: true)));
      await t.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('0°'), findsNothing);
      expect(find.text('LEFT'), findsNothing);
      expect(find.text('RIGHT'), findsNothing);
    });

    testWidgets('a hair off vertical is upright, not a side', (t) async {
      // Sub-degree noise must not flap the word between LEFT and RIGHT.
      await t.pumpWidget(
          _host(const LeanGauge(value: -0.4, caption: 'LIVE LEAN')));
      await t.pumpAndSettle();
      expect(find.text('UPRIGHT'), findsOneWidget);
      expect(find.text('LEFT'), findsNothing);
    });

    testWidgets('the dial labels both ends and its centre', (t) async {
      // Painted on the canvas, so assert the widget renders at all and trust the
      // painter's own arithmetic (covered by the needleAngle group above).
      await t.pumpWidget(
          _host(const LeanGauge(value: 8, caption: 'PEAK LEAN THIS RIDE')));
      await t.pumpAndSettle();
      expect(find.text('PEAK LEAN THIS RIDE'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('LeanGauge max-hold', () {
    testWidgets('renders with a peak marked each way', (t) async {
      await t.pumpWidget(_host(const LeanGauge(
        value: -14,
        caption: 'LIVE LEAN',
        maxLeftDegrees: 22,
        maxRightDegrees: 18,
        live: true,
      )));
      await t.pumpAndSettle();
      expect(find.text('14°'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a max beyond full deflection still paints on the dial',
        (t) async {
      await t.pumpWidget(_host(const LeanGauge(
        value: 0,
        caption: 'LIVE LEAN',
        maxLeftDegrees: 400,
        maxRightDegrees: 400,
      )));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('lays out at a large text scale without overflowing',
        (t) async {
      // The dial's height is deliberately unconstrained because the read-out
      // grows with the rider's text scale; a hard-coded height overflows here.
      t.view.physicalSize = const Size(1080, 1920);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildDarkTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const Scaffold(
            body: Center(
              child: LeanGauge(
                value: -20,
                caption: 'LIVE LEAN',
                maxLeftDegrees: 24,
                maxWidth: 240,
              ),
            ),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });
}
