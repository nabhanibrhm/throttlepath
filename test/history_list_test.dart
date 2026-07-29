import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/route_blob.dart';
import 'package:throttlepath/data/models/ride.dart';
import 'package:throttlepath/data/models/trip.dart';
import 'package:throttlepath/data/ride_stats.dart';
import 'package:throttlepath/data/trip_stats.dart';
import 'package:throttlepath/providers/history_providers.dart';
import 'package:throttlepath/providers/stats_providers.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/history_screen.dart';
import 'package:throttlepath/ui/route_sparkline.dart';
import 'package:throttlepath/ui/week_strip.dart';

/// Phase 5 — the rides list is the densest screen in the app: a week strip, a
/// collapsing header, month groups, sparklines and a five-value metrics line, all
/// on a 353dp-wide phone. These pump the real screen with the DB providers
/// overridden, so a layout that overflows or a `switch` that misses an entry type
/// fails here rather than on the device.

Ride makeRide({
  required int id,
  required DateTime start,
  String? name,
  String? startPlace,
  String? endPlace,
  double meters = 30670,
  int duration = 5400,
  int moving = 4200,
  double avg = 24.4,
  double max = 61.8,
  int? tripId,
  bool withShape = true,
}) {
  return Ride()
    ..id = id
    ..startTime = start
    ..endTime = start.add(Duration(seconds: duration))
    ..name = name
    ..startPlace = startPlace
    ..endPlace = endPlace
    ..totalDistanceMeters = meters
    ..durationSeconds = duration
    ..movingSeconds = moving
    ..averageSpeedKmh = avg
    ..maxSpeedKmh = max
    ..tripId = tripId
    ..routeBlob = withShape
        ? encodeRouteBlob([
            (lat: -6.914, lon: 107.609),
            (lat: -6.900, lon: 107.620),
            (lat: -6.880, lon: 107.612),
            (lat: -6.860, lon: 107.630),
          ])
        : null;
}

TripSummary makeTrip({
  required int id,
  required DateTime createdAt,
  String? name,
  required List<Ride> stints,
  bool finished = true,
}) {
  final trip = Trip()
    ..id = id
    ..name = name
    ..createdAt = createdAt
    ..finishedAt = finished ? createdAt.add(const Duration(days: 1)) : null;
  return TripSummary(trip, TripStats.fromStints(stints));
}

/// Loads the app's bundled Inter so text is measured with the metrics the phone
/// actually uses.
///
/// Without this the test binding falls back to a placeholder font whose every
/// glyph is a square of the font size — roughly 40% wider than Inter — so an
/// "overflow" test would fail on layouts that are fine in the app and pressure the
/// design into shrinking to satisfy a font nobody ships.
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
    loader.addFont(
        file.readAsBytes().then((b) => ByteData.view(b.buffer)));
  }
  await loader.load();
}

/// Pins the test surface to the real device's logical size, so an overflow here
/// means an overflow on the phone. A `MediaQuery` override alone would change only
/// what widgets *read*, not the box they're laid out in — the 800×600 default
/// would hide every horizontal overflow in a card.
void useDeviceSurface(WidgetTester t) {
  t.view.physicalSize = const Size(353 * 3, 760 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

Widget host({
  required List<Ride> rides,
  List<TripSummary> finishedTrips = const [],
  List<TripSummary> openTrips = const [],
  WeekStats? week,
  ThemeData? theme,
  Key? key,
}) {
  return ProviderScope(
    overrides: [
      rideHistoryProvider.overrideWith((ref) async => rides),
      finishedTripsProvider.overrideWith((ref) async => finishedTrips),
      openTripsProvider.overrideWith((ref) async => openTrips),
      latestRideProvider.overrideWith((ref) async => null),
      // Both backfills hit Isar; neutralise them.
      geocodeBackfillProvider.overrideWith((ref) async {}),
      routeBackfillProvider.overrideWith((ref) async {}),
      weekStatsProvider.overrideWith(
          (ref) async => week ?? WeekStats.emptyFor(DateTime.now())),
    ],
    child: MaterialApp(
      theme: theme ?? buildDarkTheme(),
      home: HistoryScreen(key: key),
    ),
  );
}

WeekStats weekWith({
  double meters = 42300,
  int rides = 3,
  double previous = 38000,
}) {
  final monday = weekStartOf(DateTime.now());
  return WeekStats.from([
    for (var i = 0; i < rides; i++)
      makeRide(
          id: 900 + i,
          start: monday.add(Duration(hours: i)),
          meters: meters / rides),
    if (previous > 0)
      makeRide(
          id: 800,
          start: monday.subtract(const Duration(days: 2)),
          meters: previous),
  ], DateTime.now());
}

void main() {
  final july = DateTime(2026, 7, 20, 8);
  final june = DateTime(2026, 6, 14, 17);

  setUpAll(loadInter);

  testWidgets('a ride reads name, distance, shape, then the quiet numbers',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(
          id: 1,
          start: july,
          name: 'Morning commute',
          startPlace: 'Bandung',
          endPlace: 'Lembang'),
    ]));
    await t.pumpAndSettle();

    expect(find.text('Morning commute'), findsOneWidget);
    expect(find.textContaining('30.67'), findsOneWidget);
    expect(find.text('Bandung → Lembang'), findsOneWidget);
    // The route's shape, drawn from routeBlob — no query, no tiles.
    expect(find.byType(RouteSparkline), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('a ride with no derived shape simply omits the sparkline',
      (t) async {
    useDeviceSurface(t);
    // Every ride recorded before the Phase 4 migration is in this state until the
    // backfill reaches it; the card must not reserve a blank strip for it.
    await t.pumpWidget(host(rides: [
      makeRide(id: 1, start: july, name: 'Old ride', withShape: false),
    ]));
    await t.pumpAndSettle();
    expect(find.text('Old ride'), findsOneWidget);
    expect(find.byType(RouteSparkline), findsNothing);
  });

  testWidgets('rides group under their month, with that month\'s total',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(id: 1, start: july, name: 'July one', meters: 20000),
      makeRide(
          id: 2,
          start: july.subtract(const Duration(days: 3)),
          name: 'July two',
          meters: 10000),
      makeRide(id: 3, start: june, name: 'June one', meters: 5000),
    ]));
    await t.pumpAndSettle();

    expect(find.text('JULY 2026'), findsOneWidget);
    expect(find.text('30 km'), findsOneWidget); // July's total

    // June is below the fold; the slivers build it lazily.
    await t.drag(find.text('July one'), const Offset(0, -600));
    await t.pumpAndSettle();
    expect(find.text('JUNE 2026'), findsOneWidget);
    expect(find.text('5 km'), findsOneWidget);
  });

  testWidgets('the week strip shows the total, the delta and the streak',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(
      rides: [makeRide(id: 1, start: july, name: 'A ride')],
      week: weekWith(meters: 42300, rides: 3, previous: 38000),
    ));
    await t.pumpAndSettle();

    expect(find.byType(WeekStrip), findsOneWidget);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('42.3'), findsOneWidget);
    expect(find.text('3 rides · 3h 30m moving'), findsOneWidget);
    expect(find.text('+11% vs last week'), findsOneWidget);
  });

  testWidgets('an empty week says so instead of showing zeros', (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(
      rides: [makeRide(id: 1, start: july, name: 'A ride')],
      week: WeekStats.emptyFor(DateTime.now()),
    ));
    await t.pumpAndSettle();
    expect(find.text('No rides yet this week.'), findsOneWidget);
  });

  testWidgets('a trip is one row until asked, then shows its stints', (t) async {
    final stints = [
      makeRide(id: 10, start: july, name: 'Out', tripId: 5, meters: 12000),
      makeRide(
          id: 11,
          start: july.add(const Duration(days: 1)),
          name: 'Back',
          tripId: 5,
          meters: 13000),
    ];
    await t.pumpWidget(host(
      rides: const [],
      finishedTrips: [
        makeTrip(id: 5, createdAt: july, name: 'Weekend run', stints: stints),
      ],
    ));
    await t.pumpAndSettle();

    expect(find.text('Weekend run'), findsOneWidget);
    expect(find.text('TRIP · 2 stints'), findsOneWidget);
    // Collapsed by default — the point of a trip is that it reads as one thing.
    expect(find.text('Out'), findsNothing);

    await t.tap(find.text('Show 2 stints'));
    await t.pumpAndSettle();
    expect(find.text('Out'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(find.text('Hide stints'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('filter chips carry counts and switch what is listed', (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(
      rides: [makeRide(id: 1, start: july, name: 'Solo ride')],
      finishedTrips: [
        makeTrip(
          id: 5,
          createdAt: july,
          name: 'A trip',
          stints: [makeRide(id: 10, start: july, name: 'Stint', tripId: 5)],
        ),
      ],
    ));
    await t.pumpAndSettle();

    expect(find.text('All  2'), findsOneWidget);
    expect(find.text('Rides  1'), findsOneWidget);
    expect(find.text('Trips  1'), findsOneWidget);

    await t.tap(find.text('Trips  1'));
    await t.pumpAndSettle();
    expect(find.text('A trip'), findsOneWidget);
    expect(find.text('Solo ride'), findsNothing);
    // The running total for whatever the filters left.
    expect(find.textContaining('1 result'), findsOneWidget);
  });

  testWidgets('search matches names and places, and reports the total',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(
          id: 1,
          start: july,
          name: 'To the hills',
          startPlace: 'Bandung',
          endPlace: 'Lembang',
          meters: 20000),
      makeRide(id: 2, start: july, name: 'Groceries', meters: 3000),
    ]));
    await t.pumpAndSettle();

    await t.tap(find.byTooltip('Search rides'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'lembang');
    await t.pumpAndSettle();

    expect(find.text('To the hills'), findsOneWidget);
    expect(find.text('Groceries'), findsNothing);
    expect(find.text('1 result · 20.0 km'), findsOneWidget);
  });

  testWidgets('a search with no matches says so in the rider\'s own words',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(id: 1, start: july, name: 'To the hills'),
    ]));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Search rides'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'zzzz');
    await t.pumpAndSettle();
    expect(find.text('No rides match “zzzz”.'), findsOneWidget);
  });

  testWidgets('swiping a ride away leaves an Undo, and Undo restores the row',
      (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(id: 1, start: july, name: 'Doomed ride'),
      makeRide(id: 2, start: july, name: 'Safe ride'),
    ]));
    await t.pumpAndSettle();

    await t.drag(find.text('Doomed ride'), const Offset(-500, 0));
    await t.pumpAndSettle();

    // The row leaves immediately — no confirmation modal in the way (F23).
    expect(find.text('Doomed ride'), findsNothing);
    expect(find.text('Deleted “Doomed ride”'), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await t.tap(find.text('Undo'));
    await t.pumpAndSettle();
    expect(find.text('Doomed ride'), findsOneWidget);
    expect(find.text('Safe ride'), findsOneWidget);
  });

  testWidgets('the swipe background is labelled, not a bare icon', (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: [
      makeRide(id: 1, start: july, name: 'A ride'),
    ]));
    await t.pumpAndSettle();
    await t.drag(find.text('A ride'), const Offset(-120, 0));
    await t.pump();
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('an empty history keeps its empty state', (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(rides: const []));
    await t.pumpAndSettle();
    expect(find.text('No rides yet'), findsOneWidget);
  });

  testWidgets('nothing overflows in either theme, with long names and places',
      (t) async {
    useDeviceSurface(t);
    for (final theme in [buildDarkTheme(), buildLightTheme()]) {
      await t.pumpWidget(host(
        // A fresh key per theme: without it the trip card's expand state
        // survives the re-pump and the second pass finds "Hide stints" instead.
        key: ValueKey(theme.brightness),
        theme: theme,
        week: weekWith(),
        openTrips: [
          makeTrip(
            id: 6,
            createdAt: july,
            name: 'An open trip with a rather long name indeed',
            finished: false,
            stints: [makeRide(id: 20, start: july, name: 'Stint one', tripId: 6)],
          ),
        ],
        finishedTrips: [
          makeTrip(
            id: 5,
            createdAt: july,
            name: 'A finished trip whose name also runs on and on',
            stints: [
              makeRide(
                  id: 10,
                  start: july,
                  name: 'A stint with an extremely long descriptive name',
                  startPlace: 'Bandung Wetan, Kota Bandung',
                  endPlace: 'Lembang, Kabupaten Bandung Barat',
                  tripId: 5),
            ],
          ),
        ],
        rides: [
          makeRide(
            id: 1,
            start: july,
            name: 'A ride with a name far longer than the card is wide',
            startPlace: 'Cibeunying Kaler, Kota Bandung',
            endPlace: 'Cisarua, Kabupaten Bandung Barat',
            meters: 187654,
            duration: 36000,
            moving: 30000,
            avg: 88.8,
            max: 155.5,
          ),
        ],
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull,
          reason: 'overflowed on ${theme.brightness}');
      // Expand the trip too — the nested rows are the tightest layout here.
      // It sits below the open-trip banner, so scroll it into reach first.
      // `.first` is the CustomScrollView's own Scrollable; the filter chips'
      // horizontal ListView is nested inside it and comes later.
      await t.scrollUntilVisible(
        find.text('Show 1 stint'),
        140,
        scrollable: find.byType(Scrollable).first,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Show 1 stint'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull,
          reason: 'nested stints overflowed on ${theme.brightness}');
    }
  });

  testWidgets('the header collapses to Rides plus the week total', (t) async {
    useDeviceSurface(t);
    await t.pumpWidget(host(
      week: weekWith(meters: 42300, rides: 3, previous: 0),
      rides: [
        for (var i = 0; i < 12; i++)
          makeRide(
              id: i + 1,
              start: july.subtract(Duration(days: i)),
              name: 'Ride ${i + 1}'),
      ],
    ));
    await t.pumpAndSettle();

    expect(find.text('Rides'), findsOneWidget);
    expect(find.textContaining('this week'), findsNothing);

    await t.drag(find.text('Ride 1'), const Offset(0, -400));
    await t.pumpAndSettle();

    expect(find.text('Rides'), findsOneWidget);
    expect(find.text('· 42.3 km this week'), findsOneWidget);
  });
}
