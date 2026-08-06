import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/analog_speed_gauge.dart';

Widget _host(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('AnalogSpeedGauge.topFor', () {
    test('the dial is fixed per unit — it does not follow the ride', () {
      // The whole point of going fixed (F4): the same speed must sit at the
      // same angle on every ride, so the needle position is learnable.
      expect(AnalogSpeedGauge.topFor(SpeedUnit.kmh), 120);
      expect(AnalogSpeedGauge.topFor(SpeedUnit.mph), 80);
    });

    test('the top clears the fastest ride recorded so far', () {
      expect(AnalogSpeedGauge.topFor(SpeedUnit.kmh), greaterThan(107.5));
    });

    test('both tops divide into four whole-numbered tick steps', () {
      // Five major ticks means four gaps; a fractional step would print
      // labels like "27" on a 110 dial.
      for (final unit in SpeedUnit.values) {
        expect(AnalogSpeedGauge.topFor(unit) % 4, 0);
      }
    });

    test('the imperial top is close to the metric one in real terms', () {
      // 80 mph should cover roughly the same ground as 120 km/h, so a rider
      // switching units does not silently get a very different dial.
      final imperialAsKmh =
          AnalogSpeedGauge.topFor(SpeedUnit.mph) / 0.621371;
      expect(imperialAsKmh, greaterThan(110));
      expect(imperialAsKmh, lessThan(140));
    });
  });

  group('AnalogSpeedGauge rendering', () {
    testWidgets('the numeral tells the truth when the needle pins', (t) async {
      // Over the top of the scale the arc has nowhere left to go, but the
      // number in the dial's mouth must never lie about the speed.
      await t.pumpWidget(_host(const AnalogSpeedGauge(
        speed: 143,
        maxSpeed: 143,
        topOfScale: 120,
        unitLabel: 'km/h',
      )));
      await t.pumpAndSettle();
      expect(find.text('143'), findsOneWidget);
    });

    testWidgets('a standstill renders without dividing by the scale', (t) async {
      await t.pumpWidget(_host(const AnalogSpeedGauge(
        speed: 0,
        maxSpeed: 0,
        topOfScale: 120,
        unitLabel: 'km/h',
        dimmed: true,
      )));
      await t.pumpAndSettle();
      expect(find.text('0'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('the imperial dial names its own unit, not the metric one',
        (t) async {
      await t.pumpWidget(_host(AnalogSpeedGauge(
        speed: 40,
        maxSpeed: 55,
        topOfScale: AnalogSpeedGauge.topFor(SpeedUnit.mph),
        unitLabel: 'mph',
      )));
      await t.pumpAndSettle();
      expect(find.text('mph'), findsOneWidget);
    });
  });
}
