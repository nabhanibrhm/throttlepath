import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:throttlepath/core/record_view.dart';
import 'package:throttlepath/core/speed_gauge_style.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/data/ride_stats.dart';
import 'package:throttlepath/providers/history_providers.dart';
import 'package:throttlepath/providers/stats_providers.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/telemetry_sheet.dart';

/// The idle sheet's GPS readiness line used to be a reading taken once, in
/// `initState`. A rider who saw "Location is off", left to switch it on, and came
/// back found the same sentence waiting — the app looked broken at exactly the
/// moment it had just been fixed.
///
/// Everything here is about *re-reading on resume*, because that is the only
/// signal available: the routes to granting the permission or flipping the master
/// toggle all leave the app, and `getServiceStatusStream` reports only the second
/// of those.

/// Stands in for the platform channel. `isLocationServiceEnabled` and
/// `checkPermission` are the only two calls the row makes, and both route through
/// [GeolocatorPlatform.instance] — so overriding the instance is enough, with no
/// method-channel mocking.
class _FakeGeolocator extends GeolocatorPlatform {
  /// Mutable rather than constructor-set: every test here changes one of them
  /// *after* the first frame, which is the whole scenario.
  bool serviceEnabled = true;
  LocationPermission permission = LocationPermission.whileInUse;

  /// How many times the row has asked. The re-probe is only worth anything if it
  /// actually re-runs, and an early-out that swallowed it would be invisible to a
  /// pixel assertion.
  int probes = 0;

  @override
  Future<bool> isLocationServiceEnabled() async {
    probes++;
    return serviceEnabled;
  }

  @override
  Future<LocationPermission> checkPermission() async => permission;
}

/// The idle sheet, with the two history queries stubbed out — neither is what is
/// under test, and both would otherwise open the on-device database.
Widget _host() => ProviderScope(
      overrides: [
        latestRideProvider.overrideWith((ref) => null),
        // Never completes: `valueOrNull` stays null, so the week total simply
        // isn't drawn. Cheaper than fabricating a WeekStats the test never reads.
        weekStatsProvider.overrideWith((ref) => Completer<WeekStats>().future),
      ],
      child: MaterialApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: TelemetrySheet(
              state: const TrackingUiState(),
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
      ),
    );

/// Backgrounds the app and brings it back, one state at a time rather than
/// jumping straight to `resumed` — a real return walks the whole path, and a
/// listener that only survives the shortcut would still be broken on a phone.
Future<void> _leaveAndReturn(WidgetTester t) async {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
  await t.pumpAndSettle();
}

void main() {
  late _FakeGeolocator gps;

  setUp(() {
    gps = _FakeGeolocator();
    GeolocatorPlatform.instance = gps;
  });

  testWidgets('a location toggle flipped while the app was away is picked up on '
      'return', (t) async {
    gps.serviceEnabled = false;
    await t.pumpWidget(_host());
    await t.pumpAndSettle();
    expect(find.text('Location is off'), findsOneWidget);

    // The rider goes to Quick Settings and switches it on.
    gps.serviceEnabled = true;
    await _leaveAndReturn(t);

    expect(find.text('Location is off'), findsNothing);
    expect(find.text('Location on — GPS locks at start'), findsOneWidget);
  });

  testWidgets('a permission granted while the app was away is picked up too',
      (t) async {
    // The half `getServiceStatusStream` would have missed: services are on the
    // whole time, and only the permission changes.
    gps.permission = LocationPermission.denied;
    await t.pumpWidget(_host());
    await t.pumpAndSettle();
    expect(find.text('Location permission needed'), findsOneWidget);

    gps.permission = LocationPermission.always;
    await _leaveAndReturn(t);

    expect(find.text('Location permission needed'), findsNothing);
    expect(find.text('Location on — GPS locks at start'), findsOneWidget);
  });

  testWidgets('resuming with nothing changed does not rebuild the row',
      (t) async {
    await t.pumpWidget(_host());
    await t.pumpAndSettle();
    expect(gps.probes, 1);

    await _leaveAndReturn(t);

    // It re-asks — that is the point — but the answer is the same, so the sheet
    // must not repaint every time the rider glances at a notification.
    expect(gps.probes, 2);
    expect(find.text('Location on — GPS locks at start'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the observer is dropped when the row goes away', (t) async {
    await t.pumpWidget(_host());
    await t.pumpAndSettle();

    // The idle row is rebuilt from scratch after every saved ride, so a listener
    // that outlived its State would accumulate one dead observer per ride —
    // each still calling setState on a defunct element.
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await t.pumpAndSettle();

    final before = gps.probes;
    await _leaveAndReturn(t);
    expect(gps.probes, before, reason: 'a disposed row is still probing');
    expect(t.takeException(), isNull);
  });
}
