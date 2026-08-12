import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/duration_format.dart';
import '../core/units.dart';
import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/tracking_service.dart';
import '../theme/app_theme.dart';

/// [PipCard] wired to the live providers.
///
/// Split from the card itself for the reason `TelemetrySheet` is: the readout stays
/// a pure function of (state, unit) that a test can pump at a real PiP window size
/// without standing up the tracking controller and its platform channels.
///
/// Mounted only while the app is actually in PiP, which is what makes it safe for
/// this to rebuild on every one-second telemetry tick — the rest of the time it
/// isn't in the tree at all.
class PipCardHost extends ConsumerWidget {
  const PipCardHost({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => PipCard(
        state: ref.watch(trackingControllerProvider),
        unit: ref.watch(speedUnitProvider),
      );
}

/// The whole app, shrunk to a Picture-in-Picture window: live speed, distance and
/// elapsed time, and nothing else.
///
/// **Display-only by design.** PiP content receives no touch events, so controls
/// here could only be system-drawn action buttons — which cannot press-and-hold,
/// and hold-to-stop is the guard that keeps a mis-tap from ending a ride. Tapping
/// the window restores the app, where the real controls live. See
/// `PipController.kt`.
///
/// Reads the same [TrackingUiState] the full Record screen does, including its
/// [TrackingUiState.isFrozen] / [TrackingUiState.isSignalLost] rules, so the two
/// surfaces cannot disagree about whether the clock is running.
class PipCard extends StatelessWidget {
  const PipCard({required this.state, required this.unit, super.key});

  final TrackingUiState state;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);

    // A PiP window is roughly a third of the screen's short edge — about 150dp on
    // the test device — and its exact size is the system's choice, not ours. So the
    // card is laid out at whatever width its own content wants and then scaled to
    // fit whatever it is given.
    //
    // [IntrinsicWidth] rather than a fixed design canvas, which is the part worth
    // keeping: a pinned width can be *overflowed* by content, and a readout this
    // small is exactly where that happens — a longer unit label, a wider numeral,
    // or a rider running a large system font scale. Sizing to the widest row
    // instead makes horizontal overflow structurally impossible, and hands the
    // fitting problem to [FittedBox], which is what it is for.
    // `Material` + an explicit `DefaultTextStyle` are **required here**, not
    // decoration. `PipHost` returns this card straight out of
    // `MaterialApp.builder`, in place of the Navigator — so unlike every other
    // screen there is no `Scaffold` (and therefore no `Material`) anywhere above
    // it, and `MaterialApp` alone does not install a `DefaultTextStyle`.
    //
    // Without one, `DefaultTextStyle.of(context)` resolves to Flutter's fallback,
    // whose debug style carries a **yellow double underline**. The styles below all
    // use `inherit: true`, so they merged on top of that and kept the underline
    // while overriding colour and size — every number in the window was underlined
    // in amber. `TextDecoration.none` is stated explicitly rather than left implied,
    // because the whole failure was an inherited decoration nobody asked for.
    return Material(
      color: cx.canvas,
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: 'Inter',
          color: cx.textBright,
          decoration: TextDecoration.none,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: FittedBox(child: IntrinsicWidth(child: _body(cx))),
          ),
        ),
      ),
    );
  }

  Widget _body(AppPalette cx) {
    // Before the clock runs there is no ride to report: distance and elapsed would
    // both read zero, which is the "four zeros" the Record screen was redesigned to
    // stop showing. A word about what the app is waiting for is the honest content.
    if (state.phase == 'acquiring') {
      return _message(cx, 'ACQUIRING GPS');
    }
    if (state.phase == 'countdown') {
      return _message(cx, state.countdown.toString(),
          color: cx.accentInk, size: 52);
    }

    final t = state.displayTelemetry;
    if (t == null) return _message(cx, 'NOT RECORDING');

    // Speed reads zero unless the clock is actually advancing — a frozen ride
    // showing its last-known speed would look like it was still moving.
    final speedKmh = (state.phase == 'recording' && !state.isFrozen)
        ? t.speedKmh
        : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _hero(cx, speedKmh, frozen: state.isFrozen),
        if (state.isFrozen) ...[
          const SizedBox(height: 6),
          _frozenPill(cx, state.isPaused ? 'PAUSED' : 'GPS SIGNAL LOST'),
        ],
        const SizedBox(height: 9),
        Divider(height: 1, thickness: 1, color: cx.border),
        const SizedBox(height: 9),
        _stats(cx, t, frozen: state.isFrozen),
      ],
    );
  }

  /// Live speed, the one number this window exists to show.
  Widget _hero(
    AppPalette cx,
    double speedKmh, {
    required bool frozen,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          unit.speed(speedKmh).toStringAsFixed(0),
          style: TextStyle(
            color: frozen ? cx.textDim : cx.textBright,
            fontSize: 46,
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.6,
            // Same reason as the full-size hero: without tabular digits the
            // readout jitters sideways on every GPS tick as 1 and 8 swap widths.
            fontFeatures: kTabularFigures,
          ),
        ),
        const SizedBox(width: 5),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            unit.speedLabel,
            style: TextStyle(color: cx.textDim, fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Distance and elapsed, side by side.
  ///
  /// Deliberately **unlabelled**, unlike the Record screen's DISTANCE / ELAPSED
  /// captions. There is not room here for both labels and type worth reading, and
  /// of the two it is the labels that can go: `12.40 km` and `24:13` are not
  /// ambiguous. Spending that space on the numbers is what keeps them legible once
  /// the card has been scaled down to the real window.
  Widget _stats(
    AppPalette cx,
    LiveTelemetry t, {
    required bool frozen,
  }) {
    final style = TextStyle(
      color: frozen ? cx.textDim : cx.textBright,
      fontSize: 17,
      height: 1,
      fontWeight: FontWeight.w600,
      fontFeatures: kTabularFigures,
    );
    final unitStyle = TextStyle(color: cx.textDim, fontSize: 11);

    // Hugs its content — the card's width is the widest of this row and the hero
    // above it, so neither may claim space it doesn't need.
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          unit.distanceMeters(t.distanceMeters).toStringAsFixed(2),
          style: style,
        ),
        const SizedBox(width: 3),
        Text(unit.distanceLabel, style: unitStyle),
        const SizedBox(width: 14),
        Text(formatDuration(t.durationSeconds), style: style),
      ],
    );
  }

  /// The one accent on this surface, and only when the clock has stopped. Filled
  /// rather than outlined for the Record screen's reason: at a glance a frozen ride
  /// has to look like a different window, not the same one with a small badge.
  Widget _frozenPill(AppPalette cx, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: cx.accent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: cx.onAccent,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );

  /// Stands in for the whole card when there are no numbers worth showing.
  Widget _message(AppPalette cx, String text, {Color? color, double? size}) =>
      Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: color ?? cx.textDim,
          fontSize: size ?? 14,
          height: 1,
          fontWeight: FontWeight.w700,
          letterSpacing: size == null ? 1 : -1.6,
          fontFeatures: kTabularFigures,
        ),
      );
}
