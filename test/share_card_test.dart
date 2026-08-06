import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/share_card.dart';

/// The share cards had no test at all, which is how three of the four ended up
/// floating their wordmark in the middle of the canvas. These do not judge how a
/// card *looks* — that needs eyes on a real PNG — but they do catch the failures
/// that make one unshippable: a layout that overflows its fixed canvas, or one
/// that throws on a ride with nothing in it.

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

Ride makeRide({
  String? startPlace = 'Bekasi Barat, Bekasi',
  String? endPlace = 'Jatiasih, Bekasi',
  double meters = 13860,
  double max = 82,
}) =>
    Ride()
      ..id = 1
      ..startTime = DateTime(2026, 8, 3, 18, 17)
      ..endTime = DateTime(2026, 8, 3, 18, 49)
      ..name = 'Evening commute'
      ..startPlace = startPlace
      ..endPlace = endPlace
      ..totalDistanceMeters = meters
      ..durationSeconds = 1953
      ..movingSeconds = 1800
      ..averageSpeedKmh = 26
      ..maxSpeedKmh = max;

/// A short arc of track with a speed profile that rises and falls.
List<TrackPoint> track({int n = 40}) => [
      for (var i = 0; i < n; i++)
        TrackPoint()
          ..latitude = -6.24 + i * 0.001
          ..longitude = 106.99 + (i % 7) * 0.0004
          ..speedMps = (i % 20) * 1.2
          ..timestamp = DateTime(2026, 8, 3, 18, 17).add(Duration(seconds: i * 5))
          ..altitude = 20,
    ];

/// The real capture size, so an overflow here is an overflow in the exported PNG.
Widget host(ShareLayout layout, Ride ride, List<TrackPoint> points) =>
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 360,
            height: 640,
            child: ShareCard(
              ride: ride,
              points: points,
              unit: SpeedUnit.kmh,
              layout: layout,
            ),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadInter);

  testWidgets('every layout renders on the real canvas without overflowing',
      (t) async {
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), track()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '${layout.title} overflowed');
    }
  });

  testWidgets('every layout signs itself once, at the foot', (t) async {
    // The wordmark used to be a 46dp logo mid-column, which is what made it look
    // like it was floating (spec 9.1). It is now pinned to each card's bottom
    // edge — asserted as "in the lower third", which is the property that matters
    // and does not break every time a layout is retuned.
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), track()));
      await t.pumpAndSettle();
      final mark = find.text('THROTTLEPATH');
      expect(mark, findsOneWidget, reason: '${layout.title} has no wordmark');
      final y = t.getCenter(mark).dy - t.getTopLeft(find.byType(ShareCard)).dy;
      expect(y, greaterThan(640 * 0.66),
          reason: '${layout.title} floats its wordmark at ${y.round()}dp');
    }
  });

  testWidgets('no layout paints max speed in danger red', (t) async {
    // Spec 9.5: red is for the analysis screens, where it means "this is the
    // extreme". On a card with one amber hero it was a second thing shouting.
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), track()));
      await t.pumpAndSettle();
      for (final text in t.widgetList<Text>(find.byType(Text))) {
        expect(text.style?.color, isNot(AppPalette.dark.danger),
            reason: '${layout.title} still paints something danger red');
      }
    }
  });

  testWidgets('a ride with no places still renders the ticket', (t) async {
    // The Ticket layout is the only one that reads `startPlace`/`endPlace`, and
    // both are null on every ride recorded offline.
    await t.pumpWidget(host(
      ShareLayout.ticket,
      makeRide(startPlace: null, endPlace: null),
      track(),
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
  });

  testWidgets('a standstill recording does not divide by its own zero span',
      (t) async {
    // Every fix at the same place at zero speed: the route has no extent to scale
    // to and the trace has no peak to normalise against.
    final parked = [
      for (var i = 0; i < 6; i++)
        TrackPoint()
          ..latitude = -6.24
          ..longitude = 106.99
          ..speedMps = 0
          ..timestamp = DateTime(2026, 8, 3, 18, 17)
          ..altitude = 20,
    ];
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(meters: 4, max: 0), parked));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '${layout.title} threw');
    }
  });

  testWidgets('a single-point track renders every layout', (t) async {
    final one = [
      TrackPoint()
        ..latitude = -6.24
        ..longitude = 106.99
        ..speedMps = 3
        ..timestamp = DateTime(2026, 8, 3, 18, 17)
        ..altitude = 20,
    ];
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), one));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: '${layout.title} threw');
    }
  });
}
