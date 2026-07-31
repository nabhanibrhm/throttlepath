// Visual check for the lean dial. Regenerate with:
//   flutter test test/lean_gauge_render_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/lean_gauge.dart';

Future<void> _loadInter() async {
  final loader = FontLoader('Inter');
  for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Inter-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}

/// One row of dials, so a single image shows the whole range at once.
Widget _strip(bool dark, List<LeanGauge> gauges) => MaterialApp(
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      home: Scaffold(
        body: Center(
          child: Wrap(
            spacing: 24,
            runSpacing: 24,
            alignment: WrapAlignment.center,
            children: gauges,
          ),
        ),
      ),
    );

void main() {
  setUpAll(_loadInter);

  for (final (name, dark) in [('dark', true), ('light', false)]) {
    testWidgets('lean dial renders across its range ($name)', (t) async {
      t.view.physicalSize = const Size(1200, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_strip(dark, const [
        LeanGauge(value: null, caption: 'NO ESTIMATE', dimmed: true),
        // Mid-ride, stopped at a light: no current estimate, but the ride's peaks
        // must still be readable.
        LeanGauge(
          value: null,
          caption: 'STOPPED, PEAKS HELD',
          maxLeftDegrees: 19,
          maxRightDegrees: 24,
          dimmed: true,
        ),
        LeanGauge(value: 0, caption: 'UPRIGHT'),
        LeanGauge(
          value: -12,
          caption: 'LIVE LEAN',
          maxLeftDegrees: 22,
          maxRightDegrees: 16,
        ),
        LeanGauge(value: 13.9, caption: 'PEAK LEAN THIS RIDE'),
        // The case that hides a max-hold mark: the needle is AT the session peak,
        // so the mark falls on a band lit at full strength.
        LeanGauge(
          value: -18,
          caption: 'MAX == CURRENT',
          maxLeftDegrees: 18,
          maxRightDegrees: 20,
        ),
        LeanGauge(value: -45, caption: 'AT THE BAND LIMIT'),
        LeanGauge(value: 90, caption: 'FULL DEFLECTION'),
      ]));
      await t.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/lean_dial_$name.png'),
      );
    });
  }
}
