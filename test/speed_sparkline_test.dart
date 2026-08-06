import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/providers/tracking_providers.dart'
    show SpeedSample;
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/speed_sparkline.dart';

/// The live speed trend beside the numeral — new code with no prior coverage, and
/// the one piece of the minimal pass that derives something rather than restyling
/// it. The window arithmetic is what these guard.

/// A ride climbing 0 → [n] km/h, one sample every 100 m.
List<SpeedSample> ride(int n) => [
      for (var i = 0; i < n; i++) SpeedSample(i * 100.0, i.toDouble()),
    ];

/// [width] defaults to what the sheet actually hands this widget on the test
/// device: 353dp less the sheet's 40dp of padding, less the 74sp numeral and its
/// unit and the gap — about 175dp, not the comfortable 200 the first version of
/// this test assumed.
Widget host(
  List<SpeedSample> samples, {
  SpeedUnit unit = SpeedUnit.kmh,
  double width = 175,
}) =>
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SpeedSparkline(samples: samples, unit: unit),
          ),
        ),
      ),
    );

void main() {
  group('window', () {
    test('an empty ride has no trend', () {
      expect(windowedSpeedTrend(const [], SpeedUnit.kmh), isEmpty);
      expect(SpeedSparkline.canDraw(const [], SpeedUnit.kmh), isFalse);
    });

    test('one sample is not a trend', () {
      final one = [const SpeedSample(0, 0)];
      expect(SpeedSparkline.canDraw(one, SpeedUnit.kmh), isFalse);
    });

    test('a ride shorter than the window keeps all of it', () {
      // 20 samples over 2 km, window is 5 — nothing to drop, and the trend must
      // not come back empty just because the ride has not reached 5 km yet.
      final trend = windowedSpeedTrend(ride(20), SpeedUnit.kmh);
      expect(trend.length, 20);
      expect(trend.first.x, 0.0);
    });

    test('a longer ride keeps only the last window', () {
      // 200 samples over 20 km. The last 5 km is the final 50 samples, plus the
      // one exactly on the boundary.
      final trend = windowedSpeedTrend(ride(200), SpeedUnit.kmh);
      expect(trend.length, 51);
      expect(trend.first.x, closeTo(14.9, 0.001));
      expect(trend.last.x, closeTo(19.9, 0.001));
    });

    test('the window is five of the rider’s own unit, not five km converted', () {
      // The same ride read in miles covers ~12.4 mi, so the last 5 *mi* reaches
      // further back through the samples than the last 5 km did. This is the
      // deliberate choice: a fixed 5 km would print "LAST 3.1 MI".
      final metric = windowedSpeedTrend(ride(200), SpeedUnit.kmh);
      final imperial = windowedSpeedTrend(ride(200), SpeedUnit.mph);
      expect(imperial.length, greaterThan(metric.length));
    });

    test('speeds come through in km/h, whatever the display unit', () {
      // Storage is metric everywhere in this app; only the axis is converted.
      final trend = windowedSpeedTrend(ride(10), SpeedUnit.mph);
      expect(trend.last.y, 9.0);
    });
  });

  group('rendering', () {
    testWidgets('a ride mid-window draws its trend and the window peak',
        (t) async {
      await t.pumpWidget(host(ride(200)));
      await t.pumpAndSettle();
      expect(find.text('LAST 5 KM'), findsOneWidget);
      // The peak of the *window*, not of the whole ride — the last 5 km of a ride
      // climbing to 199 tops out at 199.
      expect(find.text('peak 199'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('the caption follows the rider’s unit', (t) async {
      await t.pumpWidget(host(ride(200), unit: SpeedUnit.mph));
      await t.pumpAndSettle();
      expect(find.text('LAST 5 MI'), findsOneWidget);
    });

    testWidgets('too little ride to plot renders nothing, and does not throw',
        (t) async {
      await t.pumpWidget(host(const []));
      await t.pumpAndSettle();
      expect(find.textContaining('LAST'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('the caption ellipsizes rather than overflowing when squeezed',
        (t) async {
      // A wide unit label plus a three-digit peak in the narrowest slot the sheet
      // can hand over. An overflow here paints a yellow-and-black bar across the
      // live telemetry, which is the worst place in the app for one.
      await t.pumpWidget(host(ride(200), unit: SpeedUnit.mph, width: 140));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('a stationary ride does not divide by its own zero span',
        (t) async {
      // Every sample at the same distance and the same speed: both the x span and
      // the peak are zero, which is exactly where a normaliser reaches for a
      // division it cannot do.
      final parked = [
        for (var i = 0; i < 8; i++) const SpeedSample(1200, 0),
      ];
      await t.pumpWidget(host(parked));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('peak 0'), findsOneWidget);
    });
  });
}
