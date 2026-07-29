/// The recording control bar and its hold-to-end button.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../theme/app_theme.dart';
import 'telemetry_sheet.dart';

/// The recording bar: a wide primary (Pause / Resume) beside a narrow
/// hold-to-end pushed to the far edge.
///
/// F11 was that Pause and Stop were equal-width neighbours with the destructive
/// one under the rider's thumb, and that its 2.2s hold protection — the right
/// idea — was announced in small grey text *below* the buttons, where nobody
/// reads it in motion. So the requirement is now printed on the button itself,
/// and the two controls no longer look interchangeable.
///
/// Stateful because the hold's progress has to reach its siblings: the primary
/// dims while a hold is in flight, so there is no doubt which action is being
/// confirmed.
class RideControls extends StatefulWidget {
  const RideControls({
    super.key,
    required this.paused,
    required this.onPause,
    required this.onResume,
    required this.onStop,
  });

  final bool paused;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  /// How long the rider must hold to end a ride. Long enough that a knuckle
  /// brushing the screen can't finish it, short enough to not feel broken.
  static const double holdSeconds = 2.2;

  @override
  State<RideControls> createState() => _RideControlsState();
}

class _RideControlsState extends State<RideControls> {
  /// Tenths of a second left in the current hold, or null when not holding.
  /// Tenths rather than the raw animation value so this rebuilds ~22 times over
  /// a hold instead of once per frame.
  int? _remainingTenths;

  void _onHoldProgress(double progress) {
    if (!mounted) return;
    if (progress <= 0) {
      if (_remainingTenths != null) setState(() => _remainingTenths = null);
      return;
    }
    final tenths =
        ((1 - progress) * RideControls.holdSeconds * 10).round();
    if (tenths != _remainingTenths) setState(() => _remainingTenths = tenths);
  }

  /// A hold that started and then stopped is a rider who changed their mind or
  /// fumbled. Nothing else on screen changes in that case, so say it outright —
  /// otherwise the safest reading of the silence is "did that stop my ride?".
  void _onReleasedEarly() {
    if (!mounted) return;
    final cx = AppColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          backgroundColor: cx.surfaceRaised,
          content: Text(
            'Still recording — keep holding to end the ride.',
            style: TextStyle(color: cx.textBright),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final holding = _remainingTenths != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // Pause is the wide primary; once paused, Resume inherits that
            // weight — the rider's likely next action is always the big one.
            Expanded(
              flex: widget.paused ? 3 : 2,
              child: AnimatedOpacity(
                opacity: holding ? 0.35 : 1,
                duration: const Duration(milliseconds: 120),
                child: SheetButton(
                  label: widget.paused ? 'RESUME' : 'PAUSE',
                  color: cx.accent,
                  onPressed: () {
                    // Gloved thumbs get no travel and no click, so the only
                    // confirmation the tap registered is haptic.
                    HapticFeedback.mediumImpact();
                    widget.paused ? widget.onResume() : widget.onPause();
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: widget.paused ? 2 : 1,
              child: _HoldToEndButton(
                // The destructive verb only appears when ending the ride is
                // actually what the rider wants: mid-ride this is STOP, but from
                // a pause the honest label is that they're finishing.
                label: widget.paused ? 'FINISH RIDE' : 'STOP',
                holdSeconds: RideControls.holdSeconds,
                remainingTenths: _remainingTenths,
                onStop: widget.onStop,
                onProgress: _onHoldProgress,
                onReleasedEarly: _onReleasedEarly,
              ),
            ),
          ],
        ),
        // Height reserved in both states so the sheet doesn't grow (and shove
        // the map camera) the moment a hold begins.
        SizedBox(
          height: 22,
          child: Center(
            child: holding
                ? Text(
                    'Keep holding to end the ride',
                    style: TextStyle(
                      color: cx.accentInk,
                      fontSize: kMinFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// Press-and-hold button that ends the ride: a red fill with a translucent
/// progress overlay sweeping left→right as the rider holds, the requirement
/// printed under the label, and haptics at the halfway mark and on completion.
/// Releasing early cancels outright rather than animating back, so a cancelled
/// hold can never be mistaken for one still in progress.
class _HoldToEndButton extends StatefulWidget {
  const _HoldToEndButton({
    required this.label,
    required this.holdSeconds,
    required this.remainingTenths,
    required this.onStop,
    required this.onProgress,
    required this.onReleasedEarly,
  });

  final String label;
  final double holdSeconds;

  /// Tenths of a second left in the hold, or null when idle. Owned by the parent
  /// so the label and the sibling's dimming can't disagree.
  final int? remainingTenths;

  final VoidCallback onStop;
  final ValueChanged<double> onProgress;
  final VoidCallback onReleasedEarly;

  @override
  State<_HoldToEndButton> createState() => _HoldToEndButtonState();
}

class _HoldToEndButtonState extends State<_HoldToEndButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (widget.holdSeconds * 1000).round()),
  )
    ..addListener(_onTick)
    ..addStatusListener(_onStatus);

  /// Latched so the halfway haptic fires once per hold, not once per frame.
  bool _passedHalfway = false;

  void _onTick() {
    if (!_passedHalfway && _c.value >= 0.5) {
      _passedHalfway = true;
      // Halfway: tells a rider who can't watch the screen that the hold is
      // registering, before the point of no return.
      HapticFeedback.lightImpact();
    }
    widget.onProgress(_c.value);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    HapticFeedback.heavyImpact();
    _reset();
    widget.onStop();
  }

  void _reset() {
    _c.value = 0;
    _passedHalfway = false;
    widget.onProgress(0);
  }

  void _release() {
    if (_c.status == AnimationStatus.completed) return;
    final wasHolding = _c.value > 0;
    _c.stop();
    _reset();
    if (wasHolding) widget.onReleasedEarly();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final tenths = widget.remainingTenths;
    // Idle, the sub-label states the requirement (F11: on the control, not in
    // grey text below it). Mid-hold it becomes the live countdown.
    final subLabel = tenths != null
        ? '${(tenths / 10).toStringAsFixed(1)}s'
        : 'HOLD ${widget.holdSeconds.toStringAsFixed(1)}s';
    return Semantics(
      button: true,
      label: '${widget.label}. Press and hold for '
          '${widget.holdSeconds.toStringAsFixed(1)} seconds.',
      child: ExcludeSemantics(
        child: Listener(
          onPointerDown: (_) => _c.forward(),
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: SizedBox(
            height: 56,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: cx.danger),
                  AnimatedBuilder(
                    animation: _c,
                    builder: (_, _) => Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: _c.value,
                        heightFactor: 1,
                        child: ColoredBox(
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Scales down rather than overflowing on a narrow phone
                        // — "FINISH RIDE" is the widest label this slot takes.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            style: TextStyle(
                              color: cx.onAccent,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subLabel,
                          maxLines: 1,
                          style: TextStyle(
                            color: cx.onAccent.withValues(alpha: 0.85),
                            fontSize: kMinFontSize,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            fontFeatures: kTabularFigures,
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
      ),
    );
  }
}
