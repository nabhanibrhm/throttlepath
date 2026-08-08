import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/share_card.dart';
import 'package:throttlepath/ui/share_flow.dart';

/// The share composer sized its preview with an `Expanded`, which was right while
/// the card was 9:16 — the preview was the point of the sheet and wanted every dp.
/// A square card stops wanting more once it is as wide as the sheet, so the
/// `Expanded` went on claiming height the `FittedBox` then declined to use,
/// leaving a band of dead space under the preview.
///
/// The sheet now sizes to its contents, which puts the burden on a computed
/// height — so it is the height that is tested, at the extremes.

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

Ride makeRide() => Ride()
  ..id = 1
  ..startTime = DateTime(2026, 8, 3, 18, 17)
  ..endTime = DateTime(2026, 8, 3, 18, 49)
  ..name = 'Evening commute'
  ..startPlace = 'Bekasi Barat, Bekasi'
  ..endPlace = 'Jatiasih, Bekasi'
  ..totalDistanceMeters = 13860
  ..durationSeconds = 1953
  ..movingSeconds = 1800
  ..averageSpeedKmh = 26
  ..maxSpeedKmh = 82;

List<TrackPoint> track() => [
      for (var i = 0; i < 40; i++)
        TrackPoint()
          ..latitude = -6.24 + i * 0.001
          ..longitude = 106.99 + (i % 7) * 0.0004
          ..speedMps = (i % 20) * 1.2
          ..timestamp = DateTime(2026, 8, 3, 18, 17).add(Duration(seconds: i * 5))
          ..altitude = 20,
    ];

/// Opens the composer the way the app does and leaves it on screen.
Future<void> openSheet(WidgetTester t, Size logical) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = logical;
  addTearDown(t.view.reset);

  await t.pumpWidget(MaterialApp(
    theme: buildDarkTheme(),
    home: Scaffold(
      body: Builder(
        builder: (ctx) => TextButton(
          onPressed: () => showShareFlow(
            ctx,
            ride: makeRide(),
            points: track(),
            unit: SpeedUnit.kmh,
            onBusyChanged: (_) {},
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadInter);

  // The test device (ASUS X01BDA, 720×1520 at 2.0) and a small phone, which is
  // where a content-sized sheet is most likely to run out of room.
  const sizes = <String, Size>{
    'test device': Size(360, 760),
    'small phone': Size(320, 568),
    'short phone': Size(360, 480),
  };

  sizes.forEach((name, logical) {
    testWidgets('the composer fits on a $name', (t) async {
      await openSheet(t, logical);
      expect(t.takeException(), isNull, reason: 'the sheet overflowed');
    });

    testWidgets('the composer sizes to its contents on a $name', (t) async {
      await openSheet(t, logical);

      // The `Expanded` made this exactly the cap on every screen, whether or not
      // the contents wanted it — the ~90dp of dead space under a square preview.
      final cap = logical.height * 0.9;
      expect(t.getSize(find.byType(BottomSheet)).height, lessThan(cap),
          reason: 'the sheet still stretches to the cap rather than to its '
              'contents');
    });
  });

  testWidgets('the preview is square and fills the sheet width', (t) async {
    await openSheet(t, const Size(360, 760));

    // `FittedBox` preserves the aspect ratio of what it scales, so a square here
    // means the card it wrapped is square — measured rather than assumed,
    // because the card is the thing that owns the canvas now.
    final preview = t.getSize(find.byType(FittedBox).first);
    expect(preview.width, closeTo(preview.height, 1));

    // 20dp of padding either side, minus the 1dp border the preview sits in.
    expect(preview.width, closeTo(360 - 40 - 2, 1));
  });

  testWidgets('a wide screen does not scale the card past 1:1', (t) async {
    // A tablet in landscape: the preview would otherwise take the full width and
    // blow a 360dp card up to twice its size.
    await openSheet(t, const Size(1024, 768));
    expect(t.getSize(find.byType(FittedBox).first).width,
        lessThanOrEqualTo(ShareCard.canvasSize.width));
  });
}
