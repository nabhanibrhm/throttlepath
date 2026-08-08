import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/geo.dart';
import 'package:throttlepath/core/track_runs.dart';
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

/// The card under loose constraints — which is what both real callers give it
/// (the composer's `FittedBox`, the capture's overlay). It sizes itself to
/// [ShareCard.canvasSize], so an overflow here is an overflow in the exported PNG
/// and no third copy of the canvas size lives in this file.
Widget host(
  ShareLayout layout,
  Ride ride,
  List<TrackPoint> points, {
  List<int> stintStarts = const [],
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
            stintStarts: stintStarts,
          ),
        ),
      ),
    );

/// The two painters a card is built on — the route and the speed trace. Both are
/// private, so they are found by the name of their type.
///
/// Deliberately *not* found by `size == Size.infinite`, which is the very thing
/// under test: a finder keyed on the fix reports "no such widget" when the fix is
/// missing, which is a test that cannot fail for the reason it was written.
Finder fillPainters() => find.byWidgetPredicate((w) =>
    w is CustomPaint &&
    const {'_RoutePainter', '_TracePainter'}
        .contains(w.painter.runtimeType.toString()));

/// Every drawing call a painter made, as (method, arguments).
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

/// Bounding box of everything the painter actually drew, in its own coordinates.
Rect? paintedBounds(Finder finder) {
  Rect? box;
  void add(Rect r) => box = box == null ? r : box!.expandToInclude(r);
  for (final (method, args) in paintCalls(finder)) {
    switch (method) {
      case #drawPath:
        add((args[0] as Path).getBounds());
      case #drawLine:
        add(Rect.fromPoints(args[0] as Offset, args[1] as Offset));
      case #drawCircle:
        add(Rect.fromCircle(
            center: args[0] as Offset, radius: args[1] as double));
    }
  }
  return box;
}

/// A ride whose GPS went dark mid-way and came back 40 km down the road — a
/// train tunnel, a car park, a stale-ephemeris reacquisition. The engine already
/// refuses to count that leap, so nothing re-deriving geometry from these points
/// may count it either.
List<TrackPoint> blackoutTrack() {
  final out = <TrackPoint>[];
  var clock = DateTime(2026, 8, 3, 18, 17);
  void leg(double lat0, int n) {
    for (var i = 0; i < n; i++) {
      out.add(TrackPoint()
        ..latitude = lat0 + i * 0.0002 // ~22 m apart
        ..longitude = 106.99
        // Ramps from a standstill, so the *start* of the ride is unmistakably
        // the slow part — which is what the left edge of the card should show.
        ..speedMps = i * 25.0 / (n - 1)
        ..timestamp = clock
        ..altitude = 20);
      clock = clock.add(const Duration(seconds: 5));
    }
  }

  leg(-6.24, 30);
  clock = clock.add(const Duration(minutes: 10)); // the blackout
  leg(-5.88, 30); // ~40 km north
  return out;
}

void main() {
  setUpAll(loadInter);

  testWidgets('the card carries its own canvas, and it is square', (t) async {
    // The composer preview and the off-screen capture both used to wrap the card
    // in their own `SizedBox(360, 640)`. Three copies of one number is three
    // chances for the exported PNG to be a different shape from the one the rider
    // swiped to — so the card owns it and the callers hand it loose constraints.
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), track()));
      await t.pumpAndSettle();
      expect(t.getSize(find.byType(ShareCard)), ShareCard.canvasSize,
          reason: '${layout.title} did not size itself');
    }
    expect(ShareCard.canvasSize.width, ShareCard.canvasSize.height,
        reason: 'a sticker is placed by hand — square is the shape that '
            'survives a Story, a feed post and a chat thumbnail alike');
  });

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
      final card = t.getRect(find.byType(ShareCard));
      final y = t.getCenter(mark).dy - card.top;
      expect(y, greaterThan(ShareCard.canvasSize.height * 0.66),
          reason: '${layout.title} floats its wordmark at ${y.round()}dp');

      // Centred, which is what stopped Split reading as floating: its stats sit
      // bottom-right and the mark sat bottom-left under the route, signing
      // nothing. Measured across the whole mark — the logo's left edge to the
      // last letter — since that pair is what the eye centres.
      final markLeft = t.getTopLeft(find.byType(Image)).dx;
      final markRight = t.getBottomRight(mark).dx;
      expect((markLeft + markRight) / 2, closeTo(card.center.dx, 1),
          reason: '${layout.title} signs itself off-centre');
    }
  });

  testWidgets('every caption is the brand amber, on every layout', (t) async {
    // The labels are the same words on all six styles, so they are the layer that
    // makes six layouts read as one app's cards — they carry the brand, and are
    // amber for that reason rather than as decoration. Asserted because a grey
    // caption is exactly the kind of thing a later pass "restores" for contrast.
    //
    // Everything at 9sp or under: the stat labels, the Trace/Speed-map headers,
    // the colour-scale ends, `RIDE LOG` and the wordmark. Deliberately *not* the
    // 10sp timestamp, which stays grey as provenance rather than a stat.
    const amber = Color(0xFFFFB22C);
    for (final layout in ShareLayout.values) {
      await t.pumpWidget(host(layout, makeRide(), track()));
      await t.pumpAndSettle();
      var captions = 0;
      for (final text in t.widgetList<Text>(find.byType(Text))) {
        final size = text.style?.fontSize;
        if (size == null || size > 9) continue;
        captions++;
        expect(text.style?.color, amber,
            reason: '${layout.title} writes "${text.data}" in '
                '${text.style?.color}');
      }
      expect(captions, greaterThan(0),
          reason: '${layout.title} has no captions to check — the finder has '
              'stopped matching anything');
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

  group('the painters get a box with two real dimensions', () {
    // QA 7.9, 7.11 and 7.12 were one bug. A childless `CustomPaint` with no
    // `size` resolves through `constraints.constrain(Size.zero)` —
    // `constraints.smallest` — and `Expanded` tightens only the *main* axis, so
    // the cross axis collapsed to nothing. The route painted into a box 0dp on
    // one side; the trace mapped every x to 0 and drew one vertical line. The one
    // layout that escaped it, Full bleed, did so by accident (a
    // `Stack(fit: StackFit.expand)` hands down tight constraints) and has since
    // been deleted, so there is no longer any exemption below.

    /// The canvas the cards are captured at. Assertions below are fractions of
    /// it, not dp, so a retune of the canvas cannot quietly weaken them.
    const canvas = ShareCard.canvasSize;

    testWidgets('no layout paints into a zero-width or zero-height box',
        (t) async {
      for (final layout in ShareLayout.values) {
        await t.pumpWidget(host(layout, makeRide(), track()));
        await t.pumpAndSettle();

        final painters = fillPainters();
        expect(painters, findsOneWidget,
            reason: '${layout.title} draws no route or trace at all');
        final size = t.getSize(painters.first);
        // Pre-fix, every layout but the since-deleted Full bleed measured 0 on
        // one side.
        expect(size.shortestSide, greaterThan(canvas.shortestSide * 0.15),
            reason: '${layout.title} paints into $size');
      }
    });

    testWidgets('every layout draws inside the box it was given', (t) async {
      for (final layout in ShareLayout.values) {
        await t.pumpWidget(host(layout, makeRide(), track()));
        await t.pumpAndSettle();

        final box = t.getSize(fillPainters().first);
        final drawn = paintedBounds(fillPainters());
        expect(drawn, isNotNull, reason: '${layout.title} painted nothing');

        // Normalising against a zero-height box put the route's own 10dp inset
        // *outside* it — the shape was drawn from y = -10, over the text above.
        expect(drawn!.top, greaterThan(-1), reason: '${layout.title}: $drawn');
        expect(drawn.left, greaterThan(-1), reason: '${layout.title}: $drawn');
        expect(drawn.bottom, lessThan(box.height + 1),
            reason: '${layout.title}: $drawn in $box');
        expect(drawn.right, lessThan(box.width + 1),
            reason: '${layout.title}: $drawn in $box');

        // And uses it. A route keeps its aspect ratio, so only the fitted axis
        // fills — but one of them must.
        final fill = math.max(
          drawn.width / box.width,
          drawn.height / box.height,
        );
        expect(fill, greaterThan(0.6),
            reason: '${layout.title} fills only ${(fill * 100).round()}% of '
                'its longest axis');
      }
    });
  });

  group('the route never draws across a dead zone', () {
    /// Just the route painter — the Speed card also carries a scale beside the
    /// map, and a finder that swept up every painter would average it in.
    Finder routePainter() => find.byWidgetPredicate((w) =>
        w is CustomPaint && w.painter.runtimeType.toString() == '_RoutePainter');

    /// The vertical extent of the single tallest thing the painter drew, as a
    /// fraction of the box — strokes and straight segments alike.
    ///
    /// Bridging shows up here and almost nowhere else: both legs get drawn either
    /// way, so the *bounds of everything* are identical whether or not the dead
    /// zone was joined. What changes is whether any one primitive spans it.
    double tallestPrimitive(Finder finder, Size box) {
      var tallest = 0.0;
      for (final (method, args) in paintCalls(finder)) {
        switch (method) {
          case #drawPath:
            tallest = math.max(tallest, (args[0] as Path).getBounds().height);
          case #drawLine:
            tallest = math.max(
                tallest, ((args[0] as Offset).dy - (args[1] as Offset).dy).abs());
        }
      }
      return tallest / box.height;
    }

    // Both flavours of the same painter: four cards stroke a flat amber path per
    // run, the Speed card draws every fix-to-fix segment individually. A bridge
    // would be one enormous path in the first and one enormous line in the second.
    for (final layout in const [
      ShareLayout.split,
      ShareLayout.stacked,
      ShareLayout.statsTop,
      ShareLayout.speed,
      ShareLayout.ticket,
    ]) {
      testWidgets('${layout.title} leaves the blackout unjoined', (t) async {
        final points = blackoutTrack();
        await t.pumpWidget(host(layout, makeRide(), points));
        await t.pumpAndSettle();

        final box = t.getSize(routePainter().first);

        // Guard the fixture before trusting what it proves. Both legs have to be
        // on the card and far apart, or "nothing spans the gap" would pass simply
        // because there was no gap to span.
        final drawn = paintedBounds(routePainter())!;
        expect(drawn.height / box.height, greaterThan(0.7),
            reason: 'the two legs are not far apart on this card, so the '
                'assertion below cannot mean what it says');

        expect(tallestPrimitive(routePainter(), box), lessThan(0.25),
            reason: 'something is drawn straight across the dead zone — the '
                '40 km the write path spent three guards refusing to count');
      });
    }

    testWidgets('a blackout is a break, not a turnaround', (t) async {
      // The grey dot says "the rider stopped here and set off again". A dead zone
      // is the opposite claim, so it breaks the line and stays unmarked.
      //
      // Compared as a packed int, not against a `Color` literal: a `Paint`'s colour
      // round-trips through float components, so `paint.color == Color(0xFFD8D8D8)`
      // is false for a paint that is unmistakably 0xFFD8D8D8.
      int greyDots(Finder f) => paintCalls(f)
          .where((c) =>
              c.$1 == #drawCircle &&
              (c.$2[2] as Paint).color.toARGB32() == 0xFFD8D8D8 &&
              (c.$2[2] as Paint).style == PaintingStyle.fill)
          .length;

      await t.pumpWidget(host(ShareLayout.stacked, makeRide(), blackoutTrack()));
      await t.pumpAndSettle();
      expect(greyDots(routePainter()), 0,
          reason: 'a lost signal was marked as a place the ride visited');

      // The same track handed in as two stints *is* a turnaround, and still says so.
      await t.pumpWidget(host(ShareLayout.stacked, makeRide(), blackoutTrack(),
          stintStarts: const [30]));
      await t.pumpAndSettle();
      expect(greyDots(routePainter()), 1,
          reason: 'a real stint join lost its turnaround dot');
    });
  });

  testWidgets('the trace spreads a blacked-out ride across the whole card',
      (t) async {
    // `_TracePainter` used to roll its own equirectangular accumulator over the
    // flattened point list, so a blackout the write path refused to count still
    // contributed one enormous phantom leg to the x axis — crushing the entire
    // real ride into a band at the left edge.
    final points = blackoutTrack();

    // Guard the fixture before trusting what it proves: if the phantom leg ever
    // stopped dominating, the assertion below would pass for the wrong reason.
    final ridden = cumulativeMeters(points, fixOf: trackPointFix).last;
    var naive = 0.0;
    for (var i = 1; i < points.length; i++) {
      naive += haversineMeters(points[i - 1].latitude, points[i - 1].longitude,
          points[i].latitude, points[i].longitude);
    }
    expect(naive / ridden, greaterThan(10),
        reason: 'the fixture no longer has a dominating phantom leg');

    await t.pumpWidget(host(ShareLayout.trace, makeRide(), points));
    await t.pumpAndSettle();

    final box = t.getSize(fillPainters().first);
    // The filled area under the curve, which `Path.contains` can be asked about
    // directly — no pixels, no image decode.
    final area = paintCalls(fillPainters())
        .firstWhere((c) =>
            c.$1 == #drawPath &&
            (c.$2[1] as Paint).style == PaintingStyle.fill)
        .$2[0] as Path;

    // How high the ink reaches inside the leftmost 5% of the card. Both legs
    // start from a standstill and ramp to 25 m/s, so with a true axis this strip
    // holds only the opening crawl. With the phantom leg it held the whole first
    // leg, peak included.
    var reach = 0.0;
    for (var i = 0; i <= 20; i++) {
      final x = box.width * 0.05 * i / 20;
      for (var j = 0; j <= 60; j++) {
        final y = box.height * j / 60;
        if (area.contains(Offset(x, y))) {
          reach = math.max(reach, 1 - y / box.height);
          break; // scanning downward, the first hit is the highest ink
        }
      }
    }
    expect(reach, lessThan(0.5),
        reason: 'the first 5% of the card reaches ${(reach * 100).round()}% of '
            'its height — the ride is banded at the left edge');
  });

  group('pace, back on the Split card', () {
    testWidgets('reads against the ride’s own moving time and distance',
        (t) async {
      // 1800 s moving over 13.86 km → 129.87 s/km.
      await t.pumpWidget(host(ShareLayout.split, makeRide(), track()));
      await t.pumpAndSettle();
      expect(find.text('PACE'), findsOneWidget);
      expect(find.text('2:10 /km'), findsOneWidget);
    });

    testWidgets('a ride that went nowhere says so instead of dividing by it',
        (t) async {
      // The sentinel exists because a card is shared, and `Infinity /km` is the
      // kind of thing that gets screenshotted.
      await t.pumpWidget(
          host(ShareLayout.split, makeRide(meters: 0), track()));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('--:-- /km'), findsOneWidget);
    });

    testWidgets('no other layout grew a sixth stat', (t) async {
      // Spec 9.4's real objection was crowding, and it applies to the cards that
      // report three or four numbers in a horizontal band — not to a vertical
      // column of quiet rows.
      for (final layout in ShareLayout.values) {
        if (layout == ShareLayout.split) continue;
        await t.pumpWidget(host(layout, makeRide(), track()));
        await t.pumpAndSettle();
        expect(find.text('PACE'), findsNothing,
            reason: '${layout.title} picked up a pace stat');
      }
    });
  });

  testWidgets('a multi-stint trip draws every stint in the one brand colour',
      (t) async {
    // Inside the app a trip's stints cycle six hues and the Trip screen prints a
    // legend saying which is which. A share card has no legend and is looked at
    // for a second by someone who wasn't on the ride, so the palette only said
    // "this is several things" about a card whose whole claim is one ride.
    //
    // The route line, not the glow (alpha 0.25) and not the dots — those are
    // start/end/turnaround markers and are meant to differ.
    List<Color> routeLines() => [
          for (final (method, args) in paintCalls(fillPainters()))
            if (method == #drawPath &&
                (args[1] as Paint).style == PaintingStyle.stroke &&
                (args[1] as Paint).strokeWidth == 3.5)
              (args[1] as Paint).color,
        ];

    await t.pumpWidget(host(ShareLayout.split, makeRide(), track()));
    await t.pumpAndSettle();
    final plain = routeLines();
    expect(plain, hasLength(1), reason: 'a plain ride is one polyline');

    await t.pumpWidget(host(ShareLayout.split, makeRide(), track(),
        stintStarts: const [14, 27]));
    await t.pumpAndSettle();
    final trip = routeLines();

    // Still three separate polylines — that is what keeps a straight line from
    // being drawn across either join — but all of them the plain ride's colour.
    expect(trip, hasLength(3), reason: 'the stints stopped being segmented');
    expect(trip.toSet(), plain.toSet(),
        reason: 'the stints are colour-coded again: $trip');
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
