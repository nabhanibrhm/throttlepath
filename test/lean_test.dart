import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/lean.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/lean_chart.dart';
import 'package:throttlepath/ui/lean_gauge.dart';
import 'package:throttlepath/ui/lean_palette.dart';

/// Metres per degree of latitude, matching the constant the Kalman filter uses.
const double _mPerDegLat = 111320.0;

/// Builds a synthetic track riding a circle of [radiusMeters] at [speedMps].
///
/// This is the test that pins the physics down: a circle of known radius taken at
/// known speed demands exactly `atan(v² / (g·R))` of lean, so the estimator has a
/// closed-form answer to be checked against rather than a plausible-looking curve.
///
/// The path runs clockwise (north → east → south → west), which is a right-hand
/// turn and must therefore come out as positive lean.
List<LeanReading> circleTrack({
  required double radiusMeters,
  required double speedMps,
  required int seconds,
  double intervalSeconds = 1.0,
  bool withCourse = true,
  double centreLat = -6.9,
  double centreLon = 107.6,
}) {
  final mPerDegLon = _mPerDegLat * math.cos(centreLat * math.pi / 180.0);
  final omega = speedMps / radiusMeters; // rad/s
  final start = DateTime(2026, 7, 29, 8);
  final out = <LeanReading>[];
  final n = (seconds / intervalSeconds).floor();
  for (var i = 0; i <= n; i++) {
    final t = i * intervalSeconds;
    final phi = omega * t;
    // east = R sin φ, north = R cos φ — starts due north of centre and proceeds
    // clockwise, so the tangent at φ=0 points east.
    final east = radiusMeters * math.sin(phi);
    final north = radiusMeters * math.cos(phi);
    // Tangent bearing: d/dt(east, north) = (cos φ, −sin φ), scaled.
    final bearing =
        (math.atan2(math.cos(phi), -math.sin(phi)) * 180.0 / math.pi + 360.0) %
            360.0;
    out.add((
      time: start.add(Duration(milliseconds: (t * 1000).round())),
      speedMps: speedMps,
      headingDegrees: withCourse ? bearing : null,
      latitude: centreLat + north / _mPerDegLat,
      longitude: centreLon + east / mPerDegLon,
    ));
  }
  return out;
}

/// A dead-straight run due north at constant speed.
List<LeanReading> straightTrack({
  required double speedMps,
  required int seconds,
  bool withCourse = true,
  double startLat = -6.9,
  double startLon = 107.6,
}) {
  final start = DateTime(2026, 7, 29, 8);
  return [
    for (var i = 0; i <= seconds; i++)
      (
        time: start.add(Duration(seconds: i)),
        speedMps: speedMps,
        headingDegrees: withCourse ? 0.0 : null,
        latitude: startLat + (speedMps * i) / _mPerDegLat,
        longitude: startLon,
      ),
  ];
}

/// The lean a circle of [r] at [v] physically requires.
double expectedLean(double v, double r) =>
    math.atan((v * v) / (kGravity * r)) * 180.0 / math.pi;

/// Loads the bundled Inter so the widget tests lay out in the font the app ships.
///
/// Without this, `flutter_test` substitutes a font whose every glyph is a square of
/// the font size — roughly 40% larger than Inter in both directions — so a layout
/// that is fine on the device throws a RenderFlex overflow here. That is a real
/// trap this project has already been caught by once (see `history_list_test.dart`),
/// and it costs a design decisions made for a font nobody ships.
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

/// Pins the surface to the test device's logical size, so "does it overflow" is
/// asked about a real phone rather than the 800x600 default.
void useDeviceSurface(WidgetTester t) {
  t.view.physicalSize = const Size(353 * 3, 760 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(t.view.reset);
}

void main() {
  group('signedTurnDegrees', () {
    test('a north crossing is a small correction, not a 358 degree swerve', () {
      expect(signedTurnDegrees(359, 1), closeTo(2, 1e-9));
      expect(signedTurnDegrees(1, 359), closeTo(-2, 1e-9));
    });

    test('keeps the sign of the shorter way round', () {
      expect(signedTurnDegrees(10, 40), closeTo(30, 1e-9));
      expect(signedTurnDegrees(40, 10), closeTo(-30, 1e-9));
      expect(signedTurnDegrees(350, 10), closeTo(20, 1e-9));
    });

    test('a half turn resolves to +180, never -180', () {
      expect(signedTurnDegrees(0, 180), closeTo(180, 1e-9));
    });
  });

  group('bearingDegrees', () {
    test('reads cardinal directions correctly', () {
      expect(bearingDegrees(0, 0, 1, 0), closeTo(0, 0.01)); // north
      expect(bearingDegrees(0, 0, 0, 1), closeTo(90, 0.01)); // east
      expect(bearingDegrees(0, 0, -1, 0).abs(), closeTo(180, 0.01)); // south
      expect(bearingDegrees(0, 0, 0, -1), closeTo(-90, 0.01)); // west
    });
  });

  group('analyseLean on a known circle', () {
    // 50 m radius at 15 m/s (54 km/h) demands 24.65 degrees.
    const r = 50.0;
    const v = 15.0;

    test('recovers the physically required lean from reported course', () {
      final a = analyseLean(circleTrack(radiusMeters: r, speedMps: v, seconds: 120));
      expect(a.source, LeanHeadingSource.reportedCourse);
      expect(a.hasEstimate, isTrue);
      expect(a.p95Degrees, closeTo(expectedLean(v, r), 1.0));
    });

    test('recovers the same lean from position bearing alone', () {
      final a = analyseLean(circleTrack(
          radiusMeters: r, speedMps: v, seconds: 120, withCourse: false));
      expect(a.source, LeanHeadingSource.positionBearing);
      expect(a.p95Degrees, closeTo(expectedLean(v, r), 1.0));
    });

    test('a clockwise circle reads as a right-hand lean', () {
      final a = analyseLean(circleTrack(radiusMeters: r, speedMps: v, seconds: 120));
      expect(a.rightSamples, greaterThan(0));
      expect(a.leftSamples, 0);
      expect(a.samples.every((s) => s.leanDegrees > 0), isTrue);
    });

    test('a sustained turn corroborates its peak', () {
      final a = analyseLean(circleTrack(radiusMeters: r, speedMps: v, seconds: 120));
      // Every sample is the same corner, so the peak survives corroboration and
      // lands on the same physical answer as the percentile.
      expect(a.peakDegrees, closeTo(expectedLean(v, r), 1.0));
    });

    test('a tighter radius leans further', () {
      final wide = analyseLean(circleTrack(radiusMeters: 120, speedMps: v, seconds: 200));
      final tight = analyseLean(circleTrack(radiusMeters: 40, speedMps: v, seconds: 120));
      expect(tight.p95Degrees!, greaterThan(wide.p95Degrees!));
      expect(wide.p95Degrees, closeTo(expectedLean(v, 120), 1.0));
      expect(tight.p95Degrees, closeTo(expectedLean(v, 40), 1.0));
    });
  });

  group('guards', () {
    test('a straight road produces essentially no lean', () {
      final a = analyseLean(straightTrack(speedMps: 20, seconds: 200));
      // Samples exist (it is fast enough) but every one is upright.
      expect(a.samples, isNotEmpty);
      expect(a.p95Degrees!, lessThan(0.5));
      expect(a.band, 'upright');
    });

    test('slow riding yields no estimate, however sharp the turning', () {
      // 4 m/s = 14.4 km/h, under the floor: a paddled U-turn has a large yaw
      // rate and no lean behind it at all.
      final a = analyseLean(circleTrack(radiusMeters: 6, speedMps: 4, seconds: 200));
      expect(a.hasEstimate, isFalse);
      expect(a.samples, isEmpty);
    });

    test('physically impossible lean is rejected, not clamped', () {
      // 60 m radius at 30 m/s (108 km/h) demands 56.8 degrees, past the cap.
      // Clamping would pile every sample onto 55 and read as confident;
      // rejection reports nothing at all. The radius is chosen so the turn stays
      // inside the unambiguous +/-180 window (see the aliasing test below).
      expect(expectedLean(30, 60), greaterThan(kMaxPlausibleLeanDegrees));
      final a = analyseLean(circleTrack(radiusMeters: 60, speedMps: 30, seconds: 200));
      expect(a.samples, isEmpty);
      expect(a.hasEstimate, isFalse);
      expect(a.p95Degrees, isNull);
    });

    test('a yaw rate past the aliasing limit under-reads rather than over-reads',
        () {
      // 10 m radius at 25 m/s is 2.5 rad/s: the heading turns 859 degrees across
      // the window, so the shortest-way-round turn necessarily under-states it.
      // The direction of that error is the point — aliasing can only hide an
      // extreme corner, never fabricate one, which is why it is left unguarded.
      final a = analyseLean(circleTrack(radiusMeters: 10, speedMps: 25, seconds: 200));
      final trueLean = expectedLean(25, 10);
      expect(trueLean, greaterThan(80));
      expect(a.samples, isNotEmpty);
      expect(a.samples.first.leanDegrees.abs(), lessThan(trueLean));
    });

    test('a short track cannot produce a headline number', () {
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 20));
      expect(a.samples.length, lessThan(kMinLeanSamples));
      expect(a.hasEstimate, isFalse);
    });

    test('an empty or trivial track is handled', () {
      expect(analyseLean(const []).hasEstimate, isFalse);
      expect(analyseLean(straightTrack(speedMps: 20, seconds: 2)).samples, isEmpty);
    });

    test('a blackout gap cannot manufacture a corner', () {
      // Two straight runs on opposite headings, separated by a 10 minute dead
      // zone. Bridging them would read as a violent turn; the interval guard must
      // drop every window that spans the gap.
      final before = straightTrack(speedMps: 20, seconds: 60);
      final resumeAt = before.last.time.add(const Duration(minutes: 10));
      final after = <LeanReading>[
        for (var i = 0; i <= 60; i++)
          (
            time: resumeAt.add(Duration(seconds: i)),
            speedMps: 20.0,
            headingDegrees: 180.0,
            latitude: -6.5 - (20.0 * i) / _mPerDegLat,
            longitude: 107.9,
          ),
      ];
      final a = analyseLean([...before, ...after]);
      // Whatever survives is upright — none of it crosses the dead zone.
      expect(a.samples.every((s) => s.leanDegrees.abs() < 1.0), isTrue);
    });
  });

  group('smooth-arc guard', () {
    test('a path that doubles back on itself is rejected', () {
      // The train-ride failure mode: inside a metal carriage the fixes stop
      // describing a route and start describing a scatter, and bearings between
      // them fabricate corners. A doubling-back path is that failure in its purest
      // deterministic form — the chord across each window is nearly zero while the
      // distance walked through it is not.
      //
      // Corroboration alone provably could NOT catch this: a blackout produces a
      // run of junk fixes rather than one, so consecutive samples vouched for each
      // other and a fake 36 degree corner reached the peak on two real rides.
      final start = DateTime(2026, 7, 29, 8);
      // Period 6 against a 3-fix half-window, so every window spans a reversal.
      final pts = <LeanReading>[
        for (var i = 0; i <= 200; i++)
          (
            time: start.add(Duration(seconds: i)),
            speedMps: 25.0,
            headingDegrees: null,
            latitude: -6.9 +
                (25.0 * ((i % 6) < 3 ? (i % 6) : (6 - (i % 6)))) / _mPerDegLat,
            longitude: 107.6,
          ),
      ];
      final a = analyseLean(pts, source: LeanHeadingSource.positionBearing);
      expect(a.samples, isEmpty,
          reason: 'a path with no net displacement is not a corner');
      expect(a.hasEstimate, isFalse);
    });

    test('a periodic zigzag cannot corroborate its own peak', () {
      // A zigzag whose period lines up with the window spacing puts the window's
      // ends on the same side, so it reads as one smooth V and slips past the
      // chord test. What stops it is that it flips direction every sample, and a
      // real corner does not: corroboration requires agreement on which way the
      // bike is leaning.
      final start = DateTime(2026, 7, 29, 8);
      final mPerDegLon = _mPerDegLat * math.cos(-6.9 * math.pi / 180.0);
      final pts = <LeanReading>[
        for (var i = 0; i <= 200; i++)
          (
            time: start.add(Duration(seconds: i)),
            speedMps: 25.0,
            headingDegrees: null,
            latitude: -6.9 + (25.0 * i) / _mPerDegLat,
            longitude: 107.6 + (i.isEven ? 20.0 : -20.0) / mPerDegLon,
          ),
      ];
      final a = analyseLean(pts, source: LeanHeadingSource.positionBearing);
      // Samples survive the chord check, and they are large...
      expect(a.samples, isNotEmpty);
      expect(a.samples.first.leanDegrees.abs(), greaterThan(20));
      // ...but they alternate sign, so none of them corroborates a peak.
      expect(a.peakDegrees, isNull);
    });

    test('a genuine arc is not mistaken for scatter', () {
      // The guard must not cost real cornering. Geometry says chord/path is
      // cos(theta/4) for a true arc, so a normal corner passes comfortably.
      final a = analyseLean(circleTrack(radiusMeters: 80, speedMps: 15, seconds: 150));
      expect(a.hasEstimate, isTrue);
      expect(a.p95Degrees, closeTo(expectedLean(15, 80), 1.0));
    });

    test('a straight line has a chord ratio of one', () {
      final a = analyseLean(straightTrack(speedMps: 25, seconds: 120));
      expect(a.samples, isNotEmpty,
          reason: 'the guard must not reject the simplest possible path');
    });
  });

  group('corroborated peak', () {
    test('an isolated bad fix cannot set the peak', () {
      // A straight run with one point thrown sideways: the raw maximum jumps, but
      // no two consecutive samples agree on it, so the peak stays far below.
      final pts = straightTrack(speedMps: 25, seconds: 200).toList();
      const bad = 100;
      pts[bad] = (
        time: pts[bad].time,
        speedMps: pts[bad].speedMps,
        // Course is left null on the outlier so the estimator falls back to
        // position bearing and actually sees the displacement.
        headingDegrees: null,
        latitude: pts[bad].latitude,
        longitude: pts[bad].longitude + 0.0004, // ~44 m sideways
      );
      final a = analyseLean(pts, source: LeanHeadingSource.positionBearing);
      final rawMax =
          a.samples.map((s) => s.leanDegrees.abs()).reduce(math.max);
      expect(rawMax, greaterThan(5),
          reason: 'the outlier should fabricate a large raw lean');
      expect(a.peakDegrees!, lessThan(rawMax),
          reason: 'corroboration must discount a spike no neighbour supports');
    });

    test('the peak never exceeds the raw maximum', () {
      final a = analyseLean(circleTrack(radiusMeters: 60, speedMps: 18, seconds: 150));
      final rawMax = a.samples.map((s) => s.leanDegrees.abs()).reduce(math.max);
      expect(a.peakDegrees!, lessThanOrEqualTo(rawMax + 1e-9));
    });
  });

  group('histogram and reporting', () {
    test('bands are time-weighted and ascending', () {
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));
      expect(a.histogram, isNotEmpty);
      final froms = a.histogram.map((b) => b.fromDegrees).toList();
      expect(froms, orderedEquals([...froms]..sort()));
      expect(a.histogram.every((b) => b.seconds > 0), isTrue);
      expect(a.histogram.every((b) => b.toDegrees == b.fromDegrees + 5), isTrue);
      // A 24.65 degree circle should sit in the 20-25 band.
      expect(a.histogram.any((b) => b.fromDegrees == 20), isTrue);
    });

    test('secondsBeyond sums only the bands at or past the threshold', () {
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));
      expect(a.secondsBeyond(20), greaterThan(0));
      expect(a.secondsBeyond(50), 0);
      expect(a.secondsBeyond(0), greaterThanOrEqualTo(a.secondsBeyond(20)));
    });

    test('band names the character of the ride', () {
      expect(LeanAnalysis.empty.band, 'unrated');
      final upright = analyseLean(straightTrack(speedMps: 20, seconds: 200));
      expect(upright.band, 'upright');
      final committed =
          analyseLean(circleTrack(radiusMeters: 35, speedMps: 15, seconds: 120));
      expect(committed.p95Degrees!, greaterThan(25));
      expect(committed.band, 'committed');
    });

    test('a one-sided circle reports no balance, having nothing to compare', () {
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));
      expect(a.leftP95Degrees, isNull);
      expect(a.balance, isNull);
    });

    test('no lean score is exposed — leaning more is not riding better', () {
      // Guards the locked decision: smoothness scores because smooth beats
      // rough, but lean is a fact about the road, not a virtue.
      expect(LeanAnalysis.empty.toString(), isNot(contains('score')));
    });
  });

  group('LeanChart', () {
    setUpAll(loadInter);

    Widget host(LeanAnalysis a, {ThemeData? theme}) => MaterialApp(
          theme: theme ?? buildDarkTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 353,
                child: LeanChart(analysis: a, unit: SpeedUnit.kmh),
              ),
            ),
          ),
        );

    final circle =
        analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));

    testWidgets('leads with the typical figure, not a maximum', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(circle));
      expect(t.takeException(), isNull);
      // The badge reads "<p95>° typical" — the word is the promise that this is
      // not a peak claim. Built as TextSpan children, so the finder has to be
      // told to look inside RichText.
      expect(find.textContaining('typical', findRichText: true), findsWidgets);
      expect(
        find.textContaining('${circle.p95Degrees!.round()}°',
            findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('always says the number is an estimate biased low', (t) async {
      // The single most important string in the feature. The estimate is a
      // corner's average and aliasing under-reads, so a rider must never read it
      // as a measured peak.
      useDeviceSurface(t);
      await t.pumpWidget(host(circle));
      expect(find.textContaining('Estimated from GPS turn rate'), findsOneWidget);
      expect(find.textContaining('true peaks run higher'), findsOneWidget);
    });

    testWidgets('names the side in words rather than a sign', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(circle));
      expect(find.text('RIGHT ▲'), findsOneWidget);
      expect(find.text('LEFT ▼'), findsOneWidget);
    });

    testWidgets('shows time per band, not a bare sample count', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(circle));
      expect(find.text('TIME SPENT LEANING'), findsOneWidget);
      expect(find.textContaining('of cornering measured above'), findsOneWidget);
    });

    testWidgets('renders nothing when there is no estimate', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(LeanAnalysis.empty));
      expect(t.takeException(), isNull);
      expect(find.text('LEAN'), findsNothing);
    });

    testWidgets('builds in both themes without overflowing', (t) async {
      useDeviceSurface(t);
      for (final theme in [buildDarkTheme(), buildLightTheme()]) {
        await t.pumpWidget(host(circle, theme: theme));
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('exposes no 0-100 score anywhere in the tab', (t) async {
      // Guards the locked decision at the UI layer too: smoothness earns a score
      // because smooth beats rough; lean must not grow one by imitation.
      useDeviceSurface(t);
      await t.pumpWidget(host(circle));
      expect(find.textContaining('/ 100', findRichText: true), findsNothing);
    });
  });

  group('display smoothing', () {
    test('kills single-sample jitter but keeps a sustained corner', () {
      // A steady corner with alternating noise on top. Smoothing must remove the
      // noise without shaving the corner it sits on — a smoothed trace that
      // flattened real corners would be a prettier lie.
      final samples = <LeanSample>[
        for (var i = 0; i < 40; i++)
          (
            tSec: i.toDouble(),
            distanceMeters: i * 20.0,
            leanDegrees: 20.0 + (i.isEven ? 8.0 : -8.0),
            speedKmh: 60,
          ),
      ];
      final smoothed = smoothLeanForDisplay(samples);
      // Mid-series, away from the window's edges, the noise has cancelled.
      for (var i = 5; i < 35; i++) {
        expect(smoothed[i].leanDegrees, closeTo(20.0, 2.0));
      }
      // Time and distance are carried through untouched — only lean is averaged.
      expect(smoothed.length, samples.length);
      expect(smoothed[10].tSec, samples[10].tSec);
      expect(smoothed[10].distanceMeters, samples[10].distanceMeters);
    });

    test('never changes the numbers the analysis reports', () {
      // The division that matters: smoothing is a drawing concern. A smoothed
      // trace has had exactly the extremes removed that the peak asks about, so it
      // must never be what the percentile or peak are computed from.
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));
      final before = (a.p95Degrees, a.peakDegrees);
      smoothLeanForDisplay(a.samples);
      expect((a.p95Degrees, a.peakDegrees), before);
    });

    test('leaves a series too short to smooth alone', () {
      final two = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120))
          .samples
          .take(2)
          .toList();
      expect(smoothLeanForDisplay(two), two);
    });
  });

  group('peak location', () {
    test('reports where the peak happened, on a real sample', () {
      final a = analyseLean(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 120));
      expect(a.peakAtDistanceMeters, isNotNull);
      expect(a.peakAtSeconds, isNotNull);
      // The reported spot is one of the ride's own samples, not an interpolation.
      expect(
        a.samples.any((s) =>
            s.tSec == a.peakAtSeconds &&
            s.distanceMeters == a.peakAtDistanceMeters),
        isTrue,
      );
    });

    test('the located sample is as strong as the peak claims', () {
      final a = analyseLean(circleTrack(radiusMeters: 40, speedMps: 15, seconds: 150));
      final at = a.samples.firstWhere((s) => s.tSec == a.peakAtSeconds);
      expect(at.leanDegrees.abs(), greaterThanOrEqualTo(a.peakDegrees! - 1e-9));
    });

    test('no peak means no location', () {
      expect(LeanAnalysis.empty.peakAtDistanceMeters, isNull);
      expect(LeanAnalysis.empty.peakAtSeconds, isNull);
    });
  });

  group('severity palette', () {
    test('is a single hue — never a green-to-red status ramp', () {
      // The external audit proposed green→red, borrowed from a MotoGP graphic.
      // Declined: that is the language of *status* ("this is bad"), and lean has no
      // score precisely because leaning further is not worse riding. A magnitude
      // gets one hue.
      for (final cx in [AppPalette.dark, AppPalette.light]) {
        for (final c in leanRamp(cx)) {
          final hue = HSLColor.fromColor(c).hue;
          expect(hue, inInclusiveRange(20, 55),
              reason: '$c is outside the amber family');
        }
      }
    });

    test('is calibrated to the bike, not to this rider\'s data', () {
      // The audit's ramp saturated at 25 deg, which would paint an ordinary
      // commute in alarm colours. A road bike scrapes a footpeg near 45, so the
      // deepest step belongs there — and an 18 deg peak must read as mid-ramp.
      for (final cx in [AppPalette.dark, AppPalette.light]) {
        final deepest = leanRamp(cx).last;
        expect(leanSeverityColor(cx, kLeanScaleMaxDegrees), deepest);
        expect(leanSeverityColor(cx, 18), isNot(deepest));
        expect(leanSeverityColor(cx, 25), isNot(deepest));
      }
    });

    test('rises monotonically in lightness, each way for each theme', () {
      // What actually makes a sequential ramp readable. Dark mode is stepped
      // separately rather than flipped: dim→bright on a dark canvas,
      // light→dark on paper.
      double lum(Color c) => c.computeLuminance();
      final dark = leanRamp(AppPalette.dark).map(lum).toList();
      for (var i = 1; i < dark.length; i++) {
        expect(dark[i], greaterThan(dark[i - 1]));
      }
      final light = leanRamp(AppPalette.light).map(lum).toList();
      for (var i = 1; i < light.length; i++) {
        expect(light[i], lessThan(light[i - 1]));
      }
    });

    test('ignores sign — the ramp encodes magnitude, not direction', () {
      for (final cx in [AppPalette.dark, AppPalette.light]) {
        expect(leanSeverityColor(cx, -22), leanSeverityColor(cx, 22));
      }
    });

    test('bands tile the whole scale without gaps', () {
      final bands = leanBands(AppPalette.dark);
      expect(bands.first.from, 0);
      expect(bands.last.to, kLeanScaleMaxDegrees.round());
      for (var i = 1; i < bands.length; i++) {
        expect(bands[i].from, bands[i - 1].to);
      }
    });
  });

  group('LeanGauge', () {
    setUpAll(loadInter);

    Widget host(double value, {ThemeData? theme}) => MaterialApp(
          theme: theme ?? buildDarkTheme(),
          home: Scaffold(
            body: Center(
              child: LeanGauge(value: value, caption: 'PEAK LEAN THIS RIDE'),
            ),
          ),
        );

    testWidgets('shows the value and its caption', (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(18));
      await t.pumpAndSettle();
      expect(find.text('18°'), findsOneWidget);
      expect(find.text('PEAK LEAN THIS RIDE'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('reads magnitude, so a left lean is not shown negative',
        (t) async {
      useDeviceSurface(t);
      await t.pumpWidget(host(-18));
      await t.pumpAndSettle();
      expect(find.text('18°'), findsOneWidget);
      expect(find.text('-18°'), findsNothing);
    });

    testWidgets('survives a value past the top of the scale', (t) async {
      // The needle pins; the numeral stays authoritative. Same contract as the
      // speed dial.
      useDeviceSurface(t);
      await t.pumpWidget(host(kLeanScaleMaxDegrees + 20));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('builds in both themes at a large text scale', (t) async {
      // The height is deliberately unconstrained so growing text cannot throw.
      for (final theme in [buildDarkTheme(), buildLightTheme()]) {
        useDeviceSurface(t);
        await t.pumpWidget(MaterialApp(
          theme: theme,
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: const Scaffold(
              body: Center(child: LeanGauge(value: 22, caption: 'PEAK LEAN')),
            ),
          ),
        ));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      }
    });
  });

  group('chooseHeadingSource', () {
    test('prefers reported course when the track is well covered', () {
      expect(
        chooseHeadingSource(circleTrack(radiusMeters: 50, speedMps: 15, seconds: 60)),
        LeanHeadingSource.reportedCourse,
      );
    });

    test('falls back for rides recorded before headings were stored', () {
      expect(
        chooseHeadingSource(straightTrack(speedMps: 20, seconds: 60, withCourse: false)),
        LeanHeadingSource.positionBearing,
      );
    });

    test('a scattering of headings does not switch the estimator', () {
      final pts = straightTrack(speedMps: 20, seconds: 100, withCourse: false).toList();
      for (var i = 0; i < 10; i++) {
        pts[i] = (
          time: pts[i].time,
          speedMps: pts[i].speedMps,
          headingDegrees: 0.0,
          latitude: pts[i].latitude,
          longitude: pts[i].longitude,
        );
      }
      expect(chooseHeadingSource(pts), LeanHeadingSource.positionBearing);
    });

    test('an empty track does not crash the chooser', () {
      expect(chooseHeadingSource(const []), LeanHeadingSource.positionBearing);
    });
  });
}
