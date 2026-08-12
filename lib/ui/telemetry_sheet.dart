/// The floating glassmorphic telemetry sheet and the rows it is built from.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../core/date_format.dart';
import '../core/duration_format.dart';
import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';
import '../data/models/ride.dart';
import '../providers/history_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/tracking_service.dart' show LiveTelemetry;
import '../theme/app_theme.dart';
import 'acquiring_progress.dart';
import 'analog_speed_gauge.dart';
import 'live_speed_announcer.dart';
import 'ride_controls.dart';
import 'ride_display_switcher.dart';
import 'speed_sparkline.dart';
import 'status_pills.dart';
import 'tracking_map_screen.dart';
import 'week_strip.dart';

/// The ride-lifecycle flags [TelemetrySheet]'s layout branches on, derived once
/// per build so no two sections can disagree about the state of the ride.
typedef _SheetPhase = ({
  bool tracking,
  bool paused,
  bool acquiring,
  bool countingDown,
  bool recording,
  bool frozen,
  bool hasTelemetry,
  double speedKmh,
  String heroNumber,
});

/// Floating glassmorphic sheet showing live (or last-ride) telemetry + the
/// start/stop control.
class TelemetrySheet extends StatelessWidget {
  const TelemetrySheet({
    super.key,
    required this.state,
    required this.unit,
    required this.view,
    required this.gaugeStyle,
    required this.accuracyMeters,
    required this.onViewChanged,
    required this.onGaugeStyleChanged,
    required this.onStart,
    required this.onStop,
    required this.onPause,
    required this.onResume,
    required this.onSkipCountdown,
  });

  final TrackingUiState state;
  final SpeedUnit unit;
  final RecordView view;
  final SpeedGaugeStyle gaugeStyle;

  /// Accuracy of the latest fix, for the idle readiness row. Null until the
  /// rider has located themselves this session.
  final double? accuracyMeters;

  final ValueChanged<RecordView> onViewChanged;
  final ValueChanged<SpeedGaugeStyle> onGaugeStyleChanged;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onSkipCountdown;

  /// The telemetry on display and the clock freeze both come off
  /// [TrackingUiState] now — the PiP card branches on the same rules, and they
  /// must not be able to disagree. (`isSignalLost` is reached through
  /// [TrackingUiState.isFrozen]; the sheet's own branch is "frozen but not
  /// paused", which can only be the blackout.)
  LiveTelemetry? get _t => state.displayTelemetry;

  bool get _isFrozen => state.isFrozen;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: cx.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Hazard rail across the full width of the sheet — the one cue that
            // survives being seen at arm's length on a mounted phone. Outside the
            // horizontal padding on purpose, so it spans edge to edge.
            if (_isFrozen) StripedRail(color: cx.accent),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
              child: _content(context, cx),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's stack of readouts and controls. Split out from [build] so the
  /// hazard rail above can sit outside the horizontal padding.
  Widget _content(BuildContext context, AppPalette cx) {
    final p = _phase();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _grabHandle(cx),
        const SizedBox(height: 12),
        // The display control sits above the readout it governs and stays on
        // screen in every backdrop, which is the whole of F1: it used to be a
        // blind-cycling pill plus a Settings row three taps away.
        RideDisplaySwitcher(
          view: view,
          gaugeStyle: gaugeStyle,
          onViewChanged: onViewChanged,
          onGaugeStyleChanged: onGaugeStyleChanged,
        ),
        const SizedBox(height: 16),
        ..._hero(cx, p),
        const SizedBox(height: 18),
        ..._stats(cx, p),
        const SizedBox(height: 20),
        _controls(cx, p),
      ],
    );
  }

  /// Every lifecycle flag the layout branches on, derived once so the builders
  /// below cannot disagree about what state the ride is in.
  _SheetPhase _phase() {
    // Lifecycle: START → acquiring (waiting for GPS) → countdown (3-2-1, only if
    // the rider opted in) → recording. The clock/distance only run in recording.
    final recording = state.phase == 'recording';
    final paused = state.isPaused;
    final countingDown = state.phase == 'countdown';
    final speedKmh = (recording && !paused) ? (_t?.speedKmh ?? 0) : 0.0;
    return (
      tracking: state.isTracking,
      paused: paused,
      acquiring: state.phase == 'acquiring',
      countingDown: countingDown,
      recording: recording,
      // Frozen covers both freezes; within it, "not paused" can only mean the
      // blackout, which is what the pill and the sentence branch on.
      frozen: _isFrozen,
      // Is there a ride to report on at all? Only once the clock is actually
      // running (or a finished ride is waiting to be saved) — `recording` covers
      // paused too, since pausing doesn't change the phase.
      //
      // Deliberately NOT `tracking`: during 'acquiring' and 'countdown' no ride
      // exists yet, so the stats would render 0.00 km / 00:00 / 0.0 / 0.0 — F5's
      // four zeros, which 2A removed from the idle screen and which 3.1 would
      // have reintroduced twice as loud now that distance and elapsed are 27sp.
      // The GPS readiness row is the honest content for that moment.
      hasTelemetry: recording || state.lastFinished != null,
      speedKmh: speedKmh,
      // The countdown while starting, otherwise the live speed in the rider's
      // chosen unit. While acquiring there is no number at all — a pill replaces
      // it entirely.
      heroNumber: countingDown
          ? state.countdown.toString()
          : unit.speed(speedKmh).toStringAsFixed(0),
    );
  }

  Widget _grabHandle(AppPalette cx) => Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: cx.border,
          borderRadius: BorderRadius.circular(2),
        ),
      );

  /// The hero row: the acquiring pill, or the speed gauge / big numeral, plus
  /// whichever status line belongs under it.
  List<Widget> _hero(AppPalette cx, _SheetPhase p) {
    if (p.acquiring) {
      return [
        StatusPill(
          label: 'ACQUIRING GPS…',
          dotColor: cx.accent,
          textColor: cx.textBright,
          borderColor: cx.border,
        ),
        // The pill alone is indefinite — it looks identical at 2 seconds and at
        // 2 minutes (F9). This line is what separates "working on it" from
        // "hung".
        const AcquiringProgress(),
      ];
    }
    return [
      // The analog gauge replaces the numeral only for live speed — the 3-2-1
      // countdown stays a big digit, since there is nothing to sweep.
      if (gaugeStyle == SpeedGaugeStyle.analog && !p.countingDown)
        _gauge(p)
      else
        _numeral(cx, p),
      if (p.frozen)
        ..._frozenNotice(cx, p)
      else if (p.countingDown) ...[
        const SizedBox(height: 10),
        OutlinePill(label: 'TAP TO SKIP', color: cx.accentInk),
      ],
    ];
  }

  /// Width the dial is given once it has to share its row with the trend.
  ///
  /// Not a lowering of `AnalogSpeedGauge`'s own 280 cap: that cap is right for
  /// the *standalone* dial, which is the whole hero on the idle and just-finished
  /// screens. The gauge already sizes to `constraints.maxWidth`, so the caller —
  /// the only party that knows what else is on the row — owns the budget.
  ///
  /// 150 splits the sheet's 313dp of content as 150 / 14 / 149, leaving the
  /// sparkline 9dp above the narrowest width it is tested at. It also makes the
  /// dial 109dp tall instead of 174, so this *frees* 65dp of sheet.
  static const double _dialWithTrend = 150;

  /// The dial, sharing its row with the same speed trend the numeral already gets
  /// (D-7): the dial says what the bike is doing now, the line says what the road
  /// has been doing, and neither question is answerable from the other.
  Widget _gauge(_SheetPhase p) {
    final dial = AnalogSpeedGauge(
      speed: unit.speed(p.speedKmh),
      maxSpeed: unit.speed(_t?.maxSpeedKmh ?? 0),
      topOfScale: AnalogSpeedGauge.topFor(unit),
      unitLabel: unit.speedLabel,
      dimmed: !p.recording || p.frozen,
    );

    // Gated on `recording` alone — deliberately *not* the numeral branch's
    // `recording && canDraw`. The numeral can afford `canDraw` for free because
    // its 74sp digits are taller than the sparkline either way, so nothing moves
    // when the trend appears. Here the dial's own height is what changes, and
    // waiting for `canDraw` would shrink the sheet 65dp about two seconds into
    // every ride — a jolt exactly where a rider glances down. Tying it to
    // `recording` puts that reflow on the acquiring→recording frame, which
    // already reflows. `SpeedSparkline` self-hides to a bare 46dp box until it
    // has a window worth drawing, which is invisible inside a 109dp row.
    final withTrend = p.recording;

    // The announcer stays outside the Row, as in the numeral branch: it
    // `ExcludeSemantics`-wraps its child, so the sparkline's own captions are
    // silent either way, and the row still announces one current speed.
    return LiveSpeedAnnouncer(
      speed: unit.speed(p.speedKmh),
      unitLabel: unit.speedLabel,
      active: p.recording && !p.frozen,
      child: withTrend
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(width: _dialWithTrend, child: dial),
                const SizedBox(width: 14),
                Expanded(
                  child: SpeedSparkline(
                    samples: state.speedSamples,
                    unit: unit,
                    dimmed: p.frozen,
                  ),
                ),
              ],
            )
          : dial,
    );
  }

  /// The big number. While counting down it is itself the skip target — the whole
  /// point of F10 is that the rider gets past this without hunting for a control.
  /// Opaque hit test so taps land in the gaps between the digits too.
  ///
  /// Once a ride has covered enough ground, the numeral shares its row with the
  /// last few kilometres of speed (spec 4.1). The numeral says what the bike is
  /// doing now; the line says what the road has been doing, which is the question
  /// a single instantaneous figure can never answer.
  Widget _numeral(AppPalette cx, _SheetPhase p) {
    final digits = Row(
      // Hugs its own width so the sparkline can have the rest; the whole row is
      // centred instead when there is no trend to show.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          p.heroNumber,
          style: TextStyle(
            color: p.countingDown
                ? cx.accentInk
                : (p.frozen ? cx.textDim : cx.textBright),
            // The one hero on the screen (F14). Distance and elapsed sit a full
            // step below it, avg/peak two.
            fontSize: p.countingDown ? 84 : 74,
            height: 1,
            fontWeight: FontWeight.w700,
            letterSpacing: -2.6,
            // Without tabular digits this readout re-flows on every GPS tick as
            // "1" and "8" swap widths — the single worst thing you can do to a
            // number read in motion.
            fontFeatures: kTabularFigures,
          ),
        ),
        if (!p.countingDown) ...[
          const SizedBox(width: 7),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(unit.speedLabel,
                style: TextStyle(color: cx.textDim, fontSize: 14)),
          ),
        ],
      ],
    );

    // A counting-down digit is a button, not a readout — say so, and say what
    // tapping it does.
    if (p.countingDown) {
      return GestureDetector(
        onTap: onSkipCountdown,
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: true,
          label: 'Starting in ${p.heroNumber}',
          hint: 'Tap to skip the countdown',
          child: ExcludeSemantics(child: Center(child: digits)),
        ),
      );
    }

    // Only while a ride is running, and only once there are two samples in the
    // window — before that the "trend" is a dot, and the numeral should have the
    // full width it has always had.
    final showTrend = p.recording &&
        SpeedSparkline.canDraw(state.speedSamples, unit);

    return LiveSpeedAnnouncer(
      speed: unit.speed(p.speedKmh),
      unitLabel: unit.speedLabel,
      active: p.recording && !p.frozen,
      child: showTrend
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                digits,
                const SizedBox(width: 14),
                Expanded(
                  child: SpeedSparkline(
                    samples: state.speedSamples,
                    unit: unit,
                    dimmed: p.frozen,
                  ),
                ),
              ],
            )
          : Center(child: digits),
    );
  }

  /// Says, in words, that nothing is being recorded. A rider who glances down at
  /// a plausible-looking screen will otherwise assume it still is.
  List<Widget> _frozenNotice(AppPalette cx, _SheetPhase p) => [
        const SizedBox(height: 10),
        // Filled, not outlined: at a glance this has to look like a different
        // screen, not the same screen with a small badge (F12).
        FilledPill(
          label: p.paused ? 'PAUSED' : 'GPS SIGNAL LOST',
          background: cx.accent,
          foreground: cx.onAccent,
        ),
        const SizedBox(height: 7),
        if (p.paused)
          _FrozenSentence(text: pausedSentence(_t?.pausedFor))
        else
          const _SignalLostSentence(),
      ];

  /// Distance + elapsed over one quiet reference line, or — before a ride exists —
  /// the readiness row instead.
  ///
  /// Glance hierarchy for a phone on a handlebar (F14): distance and elapsed are
  /// what the rider looks for after speed, so they get a size of their own.
  /// Average, peak and moving time are post-ride curiosities and drop to one
  /// quiet line; previously all four sat at the same 20sp, which is no hierarchy
  /// at all.
  List<Widget> _stats(AppPalette cx, _SheetPhase p) {
    if (!p.hasTelemetry) {
      return [_IdleContext(unit: unit, accuracyMeters: accuracyMeters)];
    }
    return [
      Row(
        children: [
          Expanded(
            child: _HeroStat(
              label: 'DISTANCE',
              value: unit
                  .distanceMeters(_t?.distanceMeters ?? 0)
                  .toStringAsFixed(2),
              unit: unit.distanceLabel,
              dimmed: p.frozen,
            ),
          ),
          Expanded(
            child: _HeroStat(
              // A clock that has stopped says so on its own label, so the number
              // underneath can't be misread as live.
              label: !p.tracking
                  ? 'DURATION'
                  : (p.frozen ? 'ELAPSED · FROZEN' : 'ELAPSED'),
              value: formatDuration(_t?.durationSeconds ?? 0),
              unit: 'min',
              dimmed: p.frozen,
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _ReferenceStats(unit: unit, telemetry: _t, dimmed: p.frozen),
    ];
  }

  Widget _controls(AppPalette cx, _SheetPhase p) {
    if (!p.tracking) {
      return SheetButton(
        label: 'START RIDE',
        color: cx.accent,
        onPressed: onStart,
      );
    }
    if (p.acquiring || p.countingDown) {
      // No ride has started yet — the only action is to back out.
      return SheetButton(label: 'CANCEL', outlined: true, onPressed: onStop);
    }
    return RideControls(
      paused: p.paused,
      onPause: onPause,
      onResume: onResume,
      onStop: onStop,
    );
  }

}

/// The one line under a PAUSED / GPS SIGNAL LOST pill, in the accent ink that
/// ties it to the pill and the hazard rail above.
class _FrozenSentence extends StatelessWidget {
  const _FrozenSentence({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: cx.accentInk,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: kTabularFigures,
      ),
    );
  }
}

/// The blackout sentence, with the constellation behind it.
///
/// "Not recording — 2 of 9 satellites" says the sky is still there and the
/// receiver simply cannot resolve a position; no report at all says the receiver
/// itself has gone quiet. Without that distinction a blackout gives the rider no
/// way to tell a tunnel from a hung app — the same complaint F9 raised about the
/// acquiring pill, in the one place it matters more, because here a ride is
/// already running.
///
/// A [ConsumerWidget] on purpose: [gnssStatusProvider] is `autoDispose`, so the
/// platform GNSS callback is registered for the length of the blackout and not a
/// second longer.
class _SignalLostSentence extends ConsumerWidget {
  const _SignalLostSentence();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gnss = ref.watch(gnssStatusProvider).valueOrNull;
    return _FrozenSentence(
      text: 'Not recording — ${gnss?.satellitePhrase ?? 'waiting for GPS'}',
    );
  }
}

/// Pill button used in the telemetry sheet (start / pause / resume). A solid
/// [color] fill with a dark label, or an [outlined] transparent variant (used
/// for CANCEL) with a bordered, bright label.
class SheetButton extends StatelessWidget {
  const SheetButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color,
    this.outlined = false,
  });

  final String label;
  final VoidCallback onPressed;
  final Color? color;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final style = const TextStyle(fontSize: 16, fontWeight: FontWeight.w800);
    if (outlined) {
      return SizedBox(
        height: 56,
        width: double.infinity,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: cx.textBright,
            side: BorderSide(color: cx.border),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
          ),
          child: Text(label, style: style),
        ),
      );
    }
    return SizedBox(
      height: 56,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: cx.onAccent,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: Text(label, style: style),
      ),
    );
  }
}

/// Distance / elapsed — the second tier of the glance hierarchy (F14). One step
/// below the speed hero and a clear step above the reference line, so a rider
/// finds them without looking for them.
class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.dimmed,
  });

  final String label;
  final String value;
  final String unit;

  /// Drains the value's contrast while the clock is frozen — a number that has
  /// stopped changing should not look as authoritative as a live one.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cx.textTertiary,
            fontSize: kMinFontSize,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                color: dimmed ? cx.textDim : cx.textBright,
                fontSize: 27,
                height: 1,
                fontWeight: FontWeight.w700,
                fontFeatures: kTabularFigures,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              unit,
              style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
            ),
          ],
        ),
      ],
    );
  }
}

/// Average, peak and moving time on one quiet line — post-ride curiosities that
/// used to compete with distance and elapsed at the same 20sp (F14). PEAK keeps
/// the neutral `peak` token from Phase 1: red is for destructive actions only.
class _ReferenceStats extends StatelessWidget {
  const _ReferenceStats({
    required this.unit,
    required this.telemetry,
    required this.dimmed,
  });

  final SpeedUnit unit;
  final LiveTelemetry? telemetry;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = telemetry;
    final labelStyle = TextStyle(
      color: cx.textTertiary,
      fontSize: kMinFontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );
    final valueStyle = TextStyle(
      color: dimmed ? cx.textDim : cx.textBright,
      fontSize: kMinFontSize,
      fontWeight: FontWeight.w700,
      fontFeatures: kTabularFigures,
    );
    final peakStyle =
        valueStyle.copyWith(color: dimmed ? cx.textDim : cx.peak);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'AVG ', style: labelStyle),
          TextSpan(
            text: unit.speed(t?.avgSpeedKmh ?? 0).toStringAsFixed(1),
            style: valueStyle,
          ),
          TextSpan(text: '   ·   PEAK ', style: labelStyle),
          TextSpan(
            text: unit.speed(t?.maxSpeedKmh ?? 0).toStringAsFixed(1),
            style: peakStyle,
          ),
          TextSpan(text: '   ·   MOVING ', style: labelStyle),
          TextSpan(
            text: formatDuration(t?.movingSeconds ?? 0),
            style: valueStyle,
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// What the sheet shows before a ride starts, in place of four zeroed stats
/// (F5): whether recording will work if START is pressed, and what the last ride
/// was — the two questions a rider actually has on a resting screen.
///
/// It lives in the sheet rather than in the empty upper area the audit points
/// at, because the sheet is the one region present in *all* three backdrops —
/// map, chart and hidden — so the context follows the rider instead of only
/// appearing in battery-saver mode.
/// Two lines, not four stacked blocks (spec 2.1). GPS state and the week's total
/// share the first — one is a readiness check, the other a reason to ride, and
/// neither needed a row to itself. The last ride keeps the second.
class _IdleContext extends ConsumerWidget {
  const _IdleContext({required this.unit, required this.accuracyMeters});

  final SpeedUnit unit;
  final double? accuracyMeters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final latest = ref.watch(latestRideProvider);
    final week = ref.watch(weekStatsProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 20,
          child: Row(
            children: [
              // Left: can this record right now. Flexible, because "Location
              // permission needed" is the longest thing on the line and must not
              // push the week total off the edge.
              Flexible(child: _GpsReadinessRow(accuracyMeters: accuracyMeters)),
              const SizedBox(width: 12),
              // Right: the week so far, reduced to the figure. `WeekStrip`'s
              // compact form carries a calendar icon and a delta as well, which
              // is more than this line has room for beside a GPS state — so it
              // reuses the strip's own formatter rather than reformatting or
              // rounding the number differently.
              if (week != null)
                Text(
                  '${WeekStrip.distanceText(week, unit)} this week',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cx.textTertiary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFeatures: kTabularFigures,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Fixed height in every state — loading, empty and populated — so the
        // sheet doesn't jolt upward when the query lands a frame later.
        SizedBox(
          height: _LastRideRow.height,
          child: latest.hasValue
              ? _LastRideRow(ride: latest.value, unit: unit)
              : null,
        ),
      ],
    );
  }
}

/// Whether GPS is going to work, established *without* waking the receiver:
/// `isLocationServiceEnabled` and `checkPermission` both read cached platform
/// state, and neither raises a permission prompt — important, because this row
/// renders on app open and a surprise system dialog there would be hostile.
///
/// An accuracy figure only appears once something else (the map opening, or the
/// locate button) has produced a real fix; we never claim a precision we haven't
/// measured.
///
/// The state it reports can change while the app is in the background — which is
/// exactly where it changes, since fixing either condition means leaving for
/// Quick Settings or the Settings app. This is the app's only
/// [WidgetsBindingObserver]; see [_GpsReadinessRowState] for why a lifecycle
/// hook and not a location-service stream.
class _GpsReadinessRow extends StatefulWidget {
  const _GpsReadinessRow({required this.accuracyMeters});

  final double? accuracyMeters;

  @override
  State<_GpsReadinessRow> createState() => _GpsReadinessRowState();
}

enum _GpsReadiness { checking, servicesOff, permissionNeeded, ready }

class _GpsReadinessRowState extends State<_GpsReadinessRow>
    with WidgetsBindingObserver {
  _GpsReadiness _state = _GpsReadiness.checking;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _probe();
  }

  @override
  void dispose() {
    // Not optional bookkeeping: this row is rebuilt from scratch after every
    // saved ride (`_IdleContext` only exists while there is no telemetry), so a
    // missed removal leaks one dead observer per ride for the app's lifetime.
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-checks on return to the app, which is what makes the row *current*
  /// rather than a reading taken once at launch: a rider who sees "Location is
  /// off", fixes it, and comes back used to find the same sentence waiting.
  ///
  /// A lifecycle hook and not `getServiceStatusStream()` — that stream reports
  /// the services master toggle only, so it would fix at most half of what this
  /// row reports and leave the permission states just as stale. Every route to
  /// granting a permission or flipping the toggle exits and re-enters the app,
  /// so resume covers both with one signal.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _probe();
  }

  Future<void> _probe() async {
    var next = _GpsReadiness.ready;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        next = _GpsReadiness.servicesOff;
      } else {
        final perm = await Geolocator.checkPermission();
        if (perm != LocationPermission.always &&
            perm != LocationPermission.whileInUse) {
          next = _GpsReadiness.permissionNeeded;
        }
      }
    } catch (_) {
      // A platform that won't answer is not a platform we can promise a fix on.
      next = _GpsReadiness.permissionNeeded;
    }
    // Resume fires on every return to the app, and the answer is usually the
    // one we already have — rebuilding for it would repaint the sheet each time
    // the rider glances at a notification.
    if (!mounted || next == _state) return;
    setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final accuracy = widget.accuracyMeters;
    final (Color color, String label) = switch (_state) {
      _GpsReadiness.checking => (cx.textDim, 'Checking GPS…'),
      _GpsReadiness.servicesOff => (cx.accentInk, 'Location is off'),
      _GpsReadiness.permissionNeeded =>
        (cx.accentInk, 'Location permission needed'),
      _GpsReadiness.ready => accuracy != null
          ? (cx.positiveInk, 'GPS ready · ±${accuracy.round()} m')
          : (cx.positiveInk, 'Location on — GPS locks at start'),
    };
    return Row(
      // Hugs its content: it shares a line with the week total now, so it takes
      // the width it needs and leaves the rest rather than centring in it.
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFeatures: kTabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}

/// One quiet line recapping the previous ride, or an invitation when there isn't
/// one yet. Both states share a shape so the sheet stays put.
///
/// Was two lines with its own `LAST RIDE` heading above the detail (spec 2.1
/// line C). The label is inline now and reads `LAST`, which is enough beside a
/// ride name and a date, and the row costs half the height.
class _LastRideRow extends StatelessWidget {
  const _LastRideRow({required this.ride, required this.unit});

  final Ride? ride;
  final SpeedUnit unit;

  /// Reserved height, so loading / empty / populated are all the same size.
  static const double height = 20;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final r = ride;
    final labelStyle = TextStyle(
      color: cx.textTertiary,
      fontSize: kMinFontSize,
      letterSpacing: 1.3,
      fontWeight: FontWeight.w600,
    );

    // Nothing recorded yet: the invitation is the whole line — a `LAST` label
    // with nothing after it would be worse than no label.
    if (r == null) {
      return Text(
        'Press START to record your first ride.',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: cx.textDim,
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    final when = r.startTime.toLocal();
    final distance =
        unit.distanceMeters(r.totalDistanceMeters).toStringAsFixed(2);
    final minutes = (r.durationSeconds / 60).round();
    final name = r.name?.trim();
    final detail = [
      if (name != null && name.isNotEmpty) name,
      '$distance ${unit.distanceLabel}',
      '$minutes min',
    ].join(' · ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text('LAST', style: labelStyle),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: cx.textDim,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              fontFeatures: kTabularFigures,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('${shortMonth(when.month)} ${when.day}', style: labelStyle),
      ],
    );
  }
}
