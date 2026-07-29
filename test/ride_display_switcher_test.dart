import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/record_view.dart';
import 'package:throttlepath/core/speed_gauge_style.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/ride_display_switcher.dart';

Widget _host({
  RecordView view = RecordView.map,
  SpeedGaugeStyle gaugeStyle = SpeedGaugeStyle.analog,
  ValueChanged<RecordView>? onViewChanged,
  ValueChanged<SpeedGaugeStyle>? onGaugeStyleChanged,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? buildDarkTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 353, // the sheet's usable width on the test device
          child: RideDisplaySwitcher(
            view: view,
            gaugeStyle: gaugeStyle,
            onViewChanged: onViewChanged ?? (_) {},
            onGaugeStyleChanged: onGaugeStyleChanged ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('every backdrop and every gauge style has its own segment',
      (t) async {
    // The guard against someone re-flattening this into a single four-way
    // RideDisplayMode: that would drop most of the eight combinations, and the
    // first casualty is map + dial. If a value is added to either enum without
    // a segment, this fails.
    await t.pumpWidget(_host());
    for (final v in RecordView.values) {
      expect(find.text(v.label), findsOneWidget, reason: 'no segment for $v');
    }
    for (final s in SpeedGaugeStyle.values) {
      expect(find.text(s.label), findsOneWidget, reason: 'no segment for $s');
    }
  });

  testWidgets('the two axes are independent — all eight pairings render',
      (t) async {
    for (final v in RecordView.values) {
      for (final s in SpeedGaugeStyle.values) {
        await t.pumpWidget(_host(view: v, gaugeStyle: s));
        expect(t.takeException(), isNull, reason: '$v + $s failed to build');
        // Off + Dial and Off + Number were unreachable before the switcher.
        expect(find.text(v.label), findsOneWidget);
        expect(find.text(s.label), findsOneWidget);
      }
    }
  });

  testWidgets('tapping a backdrop segment reports that value, not the next one',
      (t) async {
    // The old control blind-cycled map → chart → off. Tapping "Off" must select
    // Off, not advance from whatever happened to be current.
    RecordView? picked;
    await t.pumpWidget(_host(
      view: RecordView.map,
      onViewChanged: (v) => picked = v,
    ));
    await t.tap(find.text(RecordView.none.label));
    expect(picked, RecordView.none);
  });

  testWidgets('tapping a gauge segment reports that value', (t) async {
    SpeedGaugeStyle? picked;
    await t.pumpWidget(_host(
      gaugeStyle: SpeedGaugeStyle.analog,
      onGaugeStyleChanged: (s) => picked = s,
    ));
    await t.tap(find.text(SpeedGaugeStyle.digital.label));
    expect(picked, SpeedGaugeStyle.digital);
  });

  testWidgets('changing one axis never reports a change on the other',
      (t) async {
    var viewCalls = 0;
    var gaugeCalls = 0;
    await t.pumpWidget(_host(
      onViewChanged: (_) => viewCalls++,
      onGaugeStyleChanged: (_) => gaugeCalls++,
    ));
    await t.tap(find.text(RecordView.chart.label));
    expect(viewCalls, 1);
    expect(gaugeCalls, 0);
  });

  testWidgets('the selected segment is marked selected for screen readers',
      (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host(view: RecordView.chart));
    expect(
      find.bySemanticsLabel('Backdrop: ${RecordView.chart.label}'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Live speed: ${SpeedGaugeStyle.analog.label}'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('it fits its width in both themes without overflowing',
      (t) async {
    // Six segments of text in one row is the tightest thing on the sheet;
    // an overflow here would paint a yellow-and-black bar over the telemetry.
    for (final theme in [buildDarkTheme(), buildLightTheme()]) {
      await t.pumpWidget(_host(theme: theme));
      expect(t.takeException(), isNull);
    }
  });

  test('the enums still describe eight distinct states', () {
    // Was six until the live Lean backdrop landed. The number matters because the
    // standing temptation is to flatten these two axes into one four-way enum,
    // which would silently delete most of the reachable combinations — map + dial
    // among them, which is what the rider actually uses.
    expect(RecordView.values.length * SpeedGaugeStyle.values.length, 8);
  });
}
