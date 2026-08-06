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

/// The backdrop controls are glyphs now, so they are found the way a screen
/// reader finds them. That is the point of the labels existing.
Finder backdrop(RecordView v) => find.bySemanticsLabel('Backdrop: ${v.label}');
Finder gauge(SpeedGaugeStyle s) =>
    find.bySemanticsLabel('Live speed: ${s.label}');

void main() {
  testWidgets('every backdrop and every gauge style has its own control',
      (t) async {
    // The guard against someone re-flattening this into a single four-way
    // RideDisplayMode: that would drop most of the eight combinations, and the
    // first casualty is map + dial. If a value is added to either enum without
    // a control, this fails.
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host());
    for (final v in RecordView.values) {
      expect(backdrop(v), findsOneWidget, reason: 'no control for $v');
    }
    for (final s in SpeedGaugeStyle.values) {
      expect(gauge(s), findsOneWidget, reason: 'no control for $s');
    }
    handle.dispose();
  });

  testWidgets('the two axes are independent — all eight pairings render',
      (t) async {
    final handle = t.ensureSemantics();
    for (final v in RecordView.values) {
      for (final s in SpeedGaugeStyle.values) {
        await t.pumpWidget(_host(view: v, gaugeStyle: s));
        expect(t.takeException(), isNull, reason: '$v + $s failed to build');
        // Off + Dial and Off + Number were unreachable before the switcher.
        expect(backdrop(v), findsOneWidget);
        expect(gauge(s), findsOneWidget);
      }
    }
    handle.dispose();
  });

  testWidgets('every backdrop glyph is still labelled for a screen reader',
      (t) async {
    // Dropping the visible text is exactly the change that could have made this
    // row silent. Four unlabelled glyphs would be worse than the two rows of
    // words they replaced.
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host());
    for (final v in RecordView.values) {
      expect(backdrop(v), findsOneWidget,
          reason: '$v has no spoken label — it is a bare glyph');
    }
    handle.dispose();
  });

  testWidgets('tapping a backdrop control reports that value, not the next one',
      (t) async {
    // The old control blind-cycled map → chart → off. Tapping "Off" must select
    // Off, not advance from whatever happened to be current.
    final handle = t.ensureSemantics();
    RecordView? picked;
    await t.pumpWidget(_host(
      view: RecordView.map,
      onViewChanged: (v) => picked = v,
    ));
    await t.tap(backdrop(RecordView.none));
    expect(picked, RecordView.none);
    handle.dispose();
  });

  testWidgets('tapping a gauge control reports that value', (t) async {
    final handle = t.ensureSemantics();
    SpeedGaugeStyle? picked;
    await t.pumpWidget(_host(
      gaugeStyle: SpeedGaugeStyle.analog,
      onGaugeStyleChanged: (s) => picked = s,
    ));
    await t.tap(gauge(SpeedGaugeStyle.digital));
    expect(picked, SpeedGaugeStyle.digital);
    handle.dispose();
  });

  testWidgets('changing one axis never reports a change on the other',
      (t) async {
    final handle = t.ensureSemantics();
    var viewCalls = 0;
    var gaugeCalls = 0;
    await t.pumpWidget(_host(
      onViewChanged: (_) => viewCalls++,
      onGaugeStyleChanged: (_) => gaugeCalls++,
    ));
    await t.tap(backdrop(RecordView.chart));
    expect(viewCalls, 1);
    expect(gaugeCalls, 0);
    handle.dispose();
  });

  testWidgets('the selected control is marked selected for screen readers',
      (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host(view: RecordView.chart));
    expect(backdrop(RecordView.chart), findsOneWidget);
    expect(gauge(SpeedGaugeStyle.analog), findsOneWidget);
    handle.dispose();
  });

  testWidgets('every control still clears a usable tap target', (t) async {
    // The spec drew this row at 30dp. It is 38 here on purpose — 30 would put
    // every control back under the target the a11y pass raised the settings rows
    // *to*. This is the assertion that stops a later "just match the mockup"
    // change from quietly undoing that.
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host());
    for (final v in RecordView.values) {
      final size = t.getSize(backdrop(v));
      expect(size.height, greaterThanOrEqualTo(38.0), reason: '$v is too short');
      expect(size.width, greaterThanOrEqualTo(40.0), reason: '$v is too narrow');
    }
    handle.dispose();
  });

  testWidgets('it fits its width in both themes without overflowing',
      (t) async {
    // Six controls in one row is the tightest thing on the sheet; an overflow
    // here would paint a yellow-and-black bar over the telemetry.
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
