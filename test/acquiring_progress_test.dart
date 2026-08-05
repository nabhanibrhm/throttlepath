import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/providers/tracking_providers.dart';
import 'package:throttlepath/services/gnss_status.dart';
import 'package:throttlepath/theme/app_theme.dart';
import 'package:throttlepath/ui/acquiring_progress.dart';

/// A receiver the test drives by hand.
class _FakeGnssSource implements GnssStatusSource {
  final _controller = StreamController<GnssEvent>.broadcast();

  void report(int visible, int usedInFix) => _controller
      .add(GnssSnapshot(visible: visible, usedInFix: usedInFix));

  void reportFirstFix(int ttffMillis) =>
      _controller.add(GnssFirstFix(ttffMillis));

  @override
  Stream<GnssEvent> events() => _controller.stream;
}

/// A source that behaves like a device with no GNSS chip: opens, says nothing.
class _SilentGnssSource implements GnssStatusSource {
  @override
  Stream<GnssEvent> events() => const Stream<GnssEvent>.empty();
}

/// Riverpod hands a stream event to its listeners one microtask *after* the
/// stream delivers it, so the frame that drains the event is not the frame that
/// renders it. A single `pump()` here silently asserts against the previous
/// snapshot — and passes, when the value happens not to have changed.
/// `pumpAndSettle` is not an option: the widget owns a periodic timer, so
/// nothing ever settles.
Future<void> _settle(WidgetTester t, [Duration step = Duration.zero]) async {
  await t.pump(step);
  await t.pump();
}

/// A first-fix event travels further than a snapshot before it shows: the stream
/// wakes `gnssFirstFixProvider`, whose listener writes a sample into
/// `ttffSamplesProvider`, which only then dirties the widget. One more frame than
/// [_settle] needs.
Future<void> _settleSample(WidgetTester t) async {
  await _settle(t);
  await t.pump();
}

Widget _host(GnssStatusSource source) {
  return ProviderScope(
    overrides: [gnssStatusSourceProvider.overrideWithValue(source)],
    child: MaterialApp(
      theme: buildDarkTheme(),
      home: const Scaffold(body: Center(child: AcquiringProgress())),
    ),
  );
}

void main() {
  testWidgets('counts up while the receiver is still silent', (t) async {
    await t.pumpWidget(_host(_SilentGnssSource()));
    expect(find.text('Searching for satellites · 0s'), findsOneWidget);

    await t.pump(const Duration(seconds: 1));
    expect(find.text('Searching for satellites · 1s'), findsOneWidget);

    await t.pump(const Duration(seconds: 4));
    expect(find.text('Searching for satellites · 5s'), findsOneWidget);
  });

  testWidgets('reports used-of-visible once the constellation is heard',
      (t) async {
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));

    source.report(11, 0);
    await _settle(t);
    expect(find.text('0 of 11 satellites · 0s'), findsOneWidget);

    source.report(12, 6);
    await _settle(t, const Duration(seconds: 1));
    expect(find.text('6 of 12 satellites · 1s'), findsOneWidget);
  });

  testWidgets('a receiver that powers down stops claiming a constellation',
      (t) async {
    // GnssStatusStreamer reports (0, 0) on `onStopped`. Rendering that as
    // "0 of 0 satellites" would be a count where there is no report at all.
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));

    source.report(9, 5);
    await _settle(t);
    expect(find.text('5 of 9 satellites · 0s'), findsOneWidget);

    source.report(0, 0);
    await _settle(t);
    expect(find.text('Searching for satellites · 0s'), findsOneWidget);
  });

  testWidgets('says nothing about a typical lock until there is history',
      (t) async {
    // Two samples is one or two rides' luck. Claiming "usually about 5s" off
    // that would be a promise the app cannot keep.
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));

    source.reportFirstFix(5000);
    await _settleSample(t);
    source.reportFirstFix(5000);
    await _settleSample(t);

    expect(find.textContaining('Usually about'), findsNothing);
  });

  testWidgets('reports the median lock time once enough have been timed',
      (t) async {
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));

    // Median, not mean: the 90s outlier is exactly the kind of underground
    // cold start that must not set the rider's expectation.
    for (final ms in [12_000, 90_000, 18_000]) {
      source.reportFirstFix(ms);
      await _settleSample(t);
    }

    expect(find.text('Usually about 18s'), findsOneWidget);
    // Both halves stay on screen — the figure is a reference for the counter,
    // not a replacement for it.
    expect(find.text('Searching for satellites · 0s'), findsOneWidget);
  });

  testWidgets('the reserved line keeps the layout still when the figure lands',
      (t) async {
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));
    final before = t.getSize(find.byType(AcquiringProgress));

    for (final ms in [12_000, 18_000, 20_000]) {
      source.reportFirstFix(ms);
      await _settleSample(t);
    }
    expect(find.textContaining('Usually about'), findsOneWidget);

    expect(t.getSize(find.byType(AcquiringProgress)), before);
  });

  testWidgets('an implausible first fix is not filed as a sample', (t) async {
    final source = _FakeGnssSource();
    await t.pumpWidget(_host(source));

    for (final ms in [0, -1, 11 * 60 * 1000]) {
      source.reportFirstFix(ms);
      await _settleSample(t);
    }

    expect(find.textContaining('Usually about'), findsNothing);
  });

  testWidgets('the timer is cancelled with the widget', (t) async {
    // A Timer.periodic left running past dispose fails the test binding's
    // pending-timer check, so this is the whole assertion.
    await t.pumpWidget(_host(_SilentGnssSource()));
    await t.pump(const Duration(seconds: 2));
    await t.pumpWidget(const SizedBox.shrink());
  });
}
