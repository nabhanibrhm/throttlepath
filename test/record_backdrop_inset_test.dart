import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/units.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/lean_gauge.dart';
import 'package:throttlepath/ui/record_backdrops.dart';

/// Roughly the height the trip banner lays out at, and well clear of any
/// incidental padding so an assertion cannot pass by accident.
const double _banner = 96;

Widget _host(Widget child) => MaterialApp(
      theme: buildDarkTheme(),
      home: Scaffold(body: Stack(children: [Positioned.fill(child: child)])),
    );

TrackingUiState _recording({int samples = 0}) => TrackingUiState(
      isTracking: true,
      phase: 'recording',
      speedSamples: [
        for (var i = 0; i < samples; i++) SpeedSample(i * 100.0, 30.0 + i),
      ],
    );

/// Top edge of [finder] in global coordinates.
double _topOf(WidgetTester t, Finder finder) => t.getRect(finder.first).top;

/// Lays [build] out twice — without a banner and with one — and returns where
/// [target] landed each time.
///
/// Centred content is why this exists. A bare `top >= bannerHeight` assertion is
/// worthless for anything the backdrop centres: it already sits mid-screen and
/// passes whether or not the inset is honoured. What proves the strip is reserved
/// is that the content *moved*, by half the banner for centred content and by all
/// of it for content pinned to the top.
Future<({double without, double with_})> _shift(
  WidgetTester t,
  Widget Function(double topInset) build,
  Finder target,
) async {
  await t.pumpWidget(_host(build(0)));
  await t.pumpAndSettle();
  final without = _topOf(t, target);
  await t.pumpWidget(_host(build(_banner)));
  await t.pumpAndSettle();
  return (without: without, with_: _topOf(t, target));
}

void main() {
  // The trip banner is a translucent overlay pinned to the top of the record
  // stack. Over the map that is correct — it is spatial and continues underneath.
  // Over a chart it is not: the top of the plot is where the ride's peak speed
  // sits, so the banner was clipping the highest y-axis label.
  group('trip banner does not cover the backdrop', () {
    testWidgets('the speed chart gives up the whole strip', (t) async {
      // The plot is pinned to the top of its box, so it moves down by all of it.
      final r = await _shift(
        t,
        (top) => ChartBackdrop(
          state: _recording(samples: 12),
          unit: SpeedUnit.kmh,
          bottomInset: 0,
          topInset: top,
        ),
        find.byType(LineChart),
      );
      expect(r.without, lessThan(_banner));
      expect(r.with_ - r.without, closeTo(_banner, 0.5));
    });

    testWidgets('the chart empty state re-centres below it', (t) async {
      final r = await _shift(
        t,
        (top) => ChartBackdrop(
          state: _recording(),
          unit: SpeedUnit.kmh,
          bottomInset: 0,
          topInset: top,
        ),
        find.text('Speed / distance'),
      );
      expect(r.with_ - r.without, closeTo(_banner / 2, 0.5));
    });

    testWidgets('the lean dial re-centres below it', (t) async {
      final r = await _shift(
        t,
        (top) => LeanBackdrop(
          state: _recording(),
          bottomInset: 0,
          topInset: top,
        ),
        find.byType(LeanGauge),
      );
      expect(r.with_ - r.without, closeTo(_banner / 2, 0.5));
    });

    testWidgets('the stats backdrop gives up the strip', (t) async {
      final r = await _shift(
        t,
        (top) => StatsBackdrop(
          state: _recording(),
          bottomInset: 0,
          topInset: top,
        ),
        find.descendant(
          of: find.byType(StatsBackdrop),
          matching: find.byType(Column),
        ),
      );
      expect(r.with_, greaterThan(r.without));
    });
  });

  group('with no banner nothing is given up', () {
    testWidgets('the chart still reaches the top of the strip', (t) async {
      await t.pumpWidget(_host(ChartBackdrop(
        state: _recording(samples: 12),
        unit: SpeedUnit.kmh,
        bottomInset: 0,
      )));
      await t.pumpAndSettle();
      // Only the chart's own 16px breathing room, not a banner's worth.
      expect(_topOf(t, find.byType(LineChart)), lessThan(_banner));
    });

    testWidgets('the lean dial renders at the default inset', (t) async {
      await t.pumpWidget(_host(LeanBackdrop(
        state: _recording(),
        bottomInset: 0,
      )));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(LeanGauge), findsOneWidget);
    });
  });
}
