import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/track_point.dart';
import 'package:throttlepath/services/share_basemap.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/share_card.dart';

/// What the card does once it has tiles.
///
/// The loader's own maths is covered in `share_basemap_test.dart`; this is the
/// other half — that the panel is drawn, that the route is placed *in* it rather
/// than beside it, and that the attribution the tiles legally require actually
/// appears. A route projected by the wrong transform still renders a perfectly
/// pretty card, just of the wrong place, which is why the alignment is asserted
/// rather than eyeballed.

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

/// A tile image made without touching the network or the async codec.
///
/// `toImageSync`, not `toImage`: this suite runs in flutter_test's fake-async
/// zone, where the async imaging calls never complete and simply hang to the
/// timeout.
ui.Image solidTile() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 256, 256),
    Paint()..color = const Color(0xFF303030),
  );
  return recorder.endRecording().toImageSync(256, 256);
}

Ride makeRide() => Ride()
  ..id = 1
  ..startTime = DateTime(2026, 8, 3, 18, 17)
  ..endTime = DateTime(2026, 8, 3, 18, 49)
  ..startPlace = 'Bekasi Barat, Bekasi'
  ..endPlace = 'Jatiasih, Bekasi'
  ..totalDistanceMeters = 13860
  ..durationSeconds = 1953
  ..movingSeconds = 1800
  ..averageSpeedKmh = 26
  ..maxSpeedKmh = 82;

/// 5s apart, so `segmentTrack` keeps it as one run — at 20s it would come back
/// as N single-point runs and the card would draw dots with no line.
List<TrackPoint> track({int n = 40}) => [
      for (var i = 0; i < n; i++)
        TrackPoint()
          ..latitude = -6.24 + i * 0.0004
          ..longitude = 106.99 + (i % 7) * 0.0002
          ..timestamp = DateTime(2026, 8, 3, 18, 17).add(Duration(seconds: i * 5))
          ..speedMps = (i % 20) * 1.2
          ..altitude = 20,
    ];

/// A basemap whose crop really does contain [points], built the way the loader
/// builds one so the card is exercised against the real geometry.
ShareBasemap basemapFor(List<TrackPoint> points, {double zoom = 15}) {
  final route = [
    for (final p in points) LatLng(p.latitude, p.longitude),
  ];
  final crop = ShareBasemapLoader.cropFor(route, zoom);
  final range = ShareBasemapLoader.tileRange(crop, zoom.toInt());
  return ShareBasemap(
    zoom: zoom,
    crop: crop,
    tiles: [
      for (var y = range.top; y <= range.bottom; y++)
        for (var x = range.left; x <= range.right; x++)
          ShareBasemapTile(
            solidTile(),
            Rect.fromLTWH((x * 256).toDouble(), (y * 256).toDouble(), 256, 256),
          ),
    ],
  );
}

Widget host(
  ShareLayout layout,
  Ride ride,
  List<TrackPoint> points, {
  ShareBasemap? basemap,
}) =>
    MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(
        body: Center(
          child: ShareCard(
            ride: ride,
            points: points,
            unit: SpeedUnit.kmh,
            layout: layout,
            basemap: basemap,
          ),
        ),
      ),
    );

Finder routePainter() => find.byWidgetPredicate((w) =>
    w is CustomPaint && w.painter.runtimeType.toString() == '_RoutePainter');

List<(Symbol, List<dynamic>)> paintCalls(Finder finder) {
  final calls = <(Symbol, List<dynamic>)>[];
  expect(
    finder,
    paints
      ..everything((Symbol method, List<dynamic> arguments) {
        calls.add((method, arguments));
        return true;
      }),
  );
  return calls;
}

void main() {
  setUpAll(loadInter);

  /// Every layout that has a route box for a map to sit under.
  const mapLayouts = [
    ShareLayout.split,
    ShareLayout.stacked,
    ShareLayout.statsTop,
    ShareLayout.speed,
    ShareLayout.ticket,
  ];

  group('the basemap panel', () {
    for (final layout in mapLayouts) {
      testWidgets('${layout.title} draws one image per tile', (t) async {
        final points = track();
        final map = basemapFor(points);
        addTearDown(map.dispose);

        await t.pumpWidget(host(layout, makeRide(), points, basemap: map));
        await t.pumpAndSettle();

        final images = paintCalls(routePainter())
            .where((c) => c.$1 == #drawImageRect)
            .length;
        expect(images, map.tiles.length,
            reason: 'the panel dropped tiles it was holding');
      });
    }

    testWidgets('nothing is drawn without one', (t) async {
      await t.pumpWidget(host(ShareLayout.split, makeRide(), track()));
      await t.pumpAndSettle();

      final images = paintCalls(routePainter())
          .where((c) => c.$1 == #drawImageRect)
          .length;
      expect(images, 0,
          reason: 'a card with no basemap painted tiles from somewhere');
    });

    testWidgets('the route lands on the map, not beside it', (t) async {
      // The failure this exists for: project the line with the old
      // equirectangular fit while the tiles come from Web Mercator, and the card
      // still renders — the route just floats over the wrong roads. The dots are
      // the ends of the ride, so if they sit inside the tiles' own box the two
      // projections agree.
      final points = track();
      final map = basemapFor(points);
      addTearDown(map.dispose);

      await t.pumpWidget(
          host(ShareLayout.stacked, makeRide(), points, basemap: map));
      await t.pumpAndSettle();

      final calls = paintCalls(routePainter());
      final panel = calls
          .where((c) => c.$1 == #drawImageRect)
          .map((c) => c.$2[2] as Rect)
          .reduce((a, b) => a.expandToInclude(b));

      final dots = [
        for (final c in calls)
          if (c.$1 == #drawCircle) c.$2[0] as Offset,
      ];
      expect(dots, isNotEmpty);
      for (final dot in dots) {
        expect(panel.inflate(1).contains(dot), isTrue,
            reason: 'a route marker fell outside the tiles under it — the line '
                'and the map are on different projections');
      }
    });

    testWidgets('the panel keeps the ride\'s shape, not the box\'s', (t) async {
      // "Crop to the ride": Split hands the route a tall 140x296 column, and a
      // panel that simply filled it would show mostly neighbours. The panel takes
      // the crop's aspect instead.
      final points = track();
      final map = basemapFor(points);
      addTearDown(map.dispose);

      await t.pumpWidget(
          host(ShareLayout.split, makeRide(), points, basemap: map));
      await t.pumpAndSettle();

      final drawn = paintCalls(routePainter())
          .where((c) => c.$1 == #drawImageRect)
          .map((c) => c.$2[2] as Rect)
          .reduce((a, b) => a.expandToInclude(b));

      // Tiles overhang the crop, so compare against the crop's own ratio with
      // room for the partial tiles at the edges.
      expect(drawn.width / drawn.height,
          closeTo(map.crop.width / map.crop.height, 0.6),
          reason: 'the panel was stretched to the column instead of the ride');
    });
  });

  group('attribution', () {
    testWidgets('rides with the tiles and only with them', (t) async {
      final points = track();
      final map = basemapFor(points);
      addTearDown(map.dispose);

      await t.pumpWidget(
          host(ShareLayout.split, makeRide(), points, basemap: map));
      await t.pumpAndSettle();
      expect(find.text('© OPENSTREETMAP · CARTO'), findsOneWidget,
          reason: 'tiles were redistributed with no credit on the card');

      await t.pumpWidget(host(ShareLayout.split, makeRide(), points));
      await t.pumpAndSettle();
      expect(find.text('© OPENSTREETMAP · CARTO'), findsNothing,
          reason: 'a card carrying no tiles credited a tile provider');
    });

    testWidgets('is absent on Trace, which draws no map', (t) async {
      final points = track();
      final map = basemapFor(points);
      addTearDown(map.dispose);

      await t.pumpWidget(
          host(ShareLayout.trace, makeRide(), points, basemap: map));
      await t.pumpAndSettle();
      expect(find.text('© OPENSTREETMAP · CARTO'), findsNothing);
    });
  });

  group('the card still holds together', () {
    for (final layout in mapLayouts) {
      testWidgets('${layout.title} does not overflow with a map', (t) async {
        final points = track();
        final map = basemapFor(points);
        addTearDown(map.dispose);

        await t.pumpWidget(host(layout, makeRide(), points, basemap: map));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('a one-point ride with a map does not throw', (t) async {
      final points = track(n: 1);
      final map = basemapFor(points);
      addTearDown(map.dispose);

      await t.pumpWidget(
          host(ShareLayout.stacked, makeRide(), points, basemap: map));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });
  });
}
