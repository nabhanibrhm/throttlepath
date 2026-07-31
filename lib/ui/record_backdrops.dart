/// The three non-map backdrops behind the Record screen's telemetry sheet.
///
/// None of them draw tiles or a per-frame blur, which is the whole point: the map
/// is the dominant on-screen power draw, so each of these lets the GPU idle and
/// the screen sleep while recording continues in the background service.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../core/lean.dart' show kMinLeanSpeedKmh;
import '../core/record_view.dart';
import '../core/units.dart';
import '../providers/tracking_providers.dart';
import '../theme/app_theme.dart';
import 'lean_gauge.dart';
import 'live_speed_chart.dart';

/// Backdrop shown when the view is [RecordView.lean]: the live cornering estimate
/// on the same dial the analysis tab uses for a finished ride.
///
/// Draws no tiles and no blur, so like the other non-map backdrops the GPU stays
/// idle while recording continues.
///
/// **Honest about what it is.** The value lags — heading is differenced over a
/// three-second baseline, so a corner is half over before the needle agrees — and
/// the estimate reads low by construction. A rider cannot safely watch a phone
/// mid-corner anyway; this is for the pillion, and for glancing at a stop. Nothing
/// in the app depends on it, and it is never what gets saved: the ride's stored
/// figures are recomputed from the track afterwards.
///
/// Below [kMinLeanSpeedKmh] there is no honest number, so it says so rather than
/// parking the needle at zero as though it had measured zero.
class LeanBackdrop extends StatelessWidget {
  const LeanBackdrop({
    super.key,required this.state, required this.bottomInset});

  final TrackingUiState state;

  /// Measured height of the telemetry sheet covering the bottom of the stack.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final lean = state.telemetry?.leanDegrees;
    final recording = state.phase == 'recording';
    final speed = state.telemetry?.speedKmh ?? 0;

    final String note;
    if (!recording) {
      note = 'Start recording to see cornering lean.';
    } else if (lean == null && speed < kMinLeanSpeedKmh) {
      note = 'Below ${kMinLeanSpeedKmh.round()} km/h — nothing to estimate yet.';
    } else {
      note = 'Estimated from GPS turn rate. Lags a corner, and reads low.';
    }

    return Container(
      color: cx.canvas,
      // The sheet already covers this band and applies its own SafeArea.
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LeanGauge(
                    value: lean,
                    caption: 'LIVE LEAN',
                    // Max-hold comes from the controller, not from this widget:
                    // cycling the record view rebuilds the backdrop from scratch.
                    maxLeftDegrees: state.leanMaxLeftDegrees,
                    maxRightDegrees: state.leanMaxRightDegrees,
                    live: true,
                    dimmed: lean == null,
                    maxWidth: 240,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    note,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cx.textTertiary,
                      fontSize: 12,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Backdrop shown when the view is [RecordView.chart]: a live speed-vs-distance
/// line chart built from the ride's accumulated samples. Draws no tiles/blur,
/// so — like [StatsBackdrop] — the GPU stays idle. Shows a branded empty-state
/// until there are enough samples to plot.
class ChartBackdrop extends StatelessWidget {
  const ChartBackdrop({
    super.key,
    required this.state,
    required this.unit,
    required this.bottomInset,
  });

  final TrackingUiState state;
  final SpeedUnit unit;

  /// Measured height of the telemetry sheet covering the bottom of the stack.
  ///
  /// The chart used to be a floating overlay sized at a guessed fraction of the
  /// screen, which ran its x-axis underneath the sheet and hid the empty state's
  /// caption entirely (F8). Reserving the sheet's real height puts the chart on
  /// the same grid: it fills exactly the strip that is on screen.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final samples = state.speedSamples;

    return Container(
      color: cx.canvas,
      // Bottom inset comes from the sheet, which already covers that area and
      // applies its own SafeArea — taking it twice would leave a dead band.
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: samples.length < 2
              ? _EmptyChart(recording: state.phase == 'recording')
              : Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 16, 8),
                  child: LiveSpeedChart(
                    spots: [
                      for (final s in samples)
                        FlSpot(s.distanceMeters / 1000.0, s.speedKmh),
                    ],
                    unit: unit,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shown until there are two samples to draw a line between.
class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.recording});

  final bool recording;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart, size: 40, color: cx.textTertiary),
          const SizedBox(height: 14),
          Text(
            'Speed / distance',
            style: TextStyle(
              color: cx.textBright,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              recording
                  ? 'Charting your speed as you cover distance…'
                  : 'Your live speed vs. distance chart appears here as you ride.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.textDim, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lightweight backdrop shown in place of the map — no tiles, no blur, so the
/// GPU stays idle and the screen can sleep while recording continues in the
/// background service.
///
/// Deliberately quiet (F2, F3). The old version put a 72px logo in the middle of
/// the screen and a bordered "Show map" pill under it — the only boxed button
/// above the fold, which made *hiding the map* look like the screen's primary
/// action while START RIDE sat below it. Now the wordmark is a small mark in the
/// upper third and the way back to the map is a text link inside a status line.
/// The rider's actual pre-ride context lives in the sheet ([_IdleContext]), where
/// it shows in every backdrop rather than only this one.
class StatsBackdrop extends StatelessWidget {
  const StatsBackdrop({
    super.key,required this.state, required this.bottomInset});

  final TrackingUiState state;

  /// Measured height of the telemetry sheet — see [ChartBackdrop.bottomInset].
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final recording = state.phase == 'recording';
    return Container(
      color: cx.canvas,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/icon/logo_foreground.png',
                      width: 26,
                      height: 26,
                      color: cx.textTertiary,
                      filterQuality: FilterQuality.medium,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ThrottlePath',
                      style: TextStyle(
                        color: cx.textTertiary,
                        fontSize: 15,
                        letterSpacing: 0.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_off_outlined,
                          size: 15, color: cx.textDim),
                      const SizedBox(width: 8),
                      // No "Show map" link any more: the switcher in the sheet
                      // is always on screen, so this state is no longer a place
                      // the rider can get stuck in and need an escape hatch from.
                      Flexible(
                        child: Text(
                          recording
                              ? 'Map hidden — recording in the background'
                              : 'Map hidden to save battery',
                          style: TextStyle(color: cx.textDim, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
