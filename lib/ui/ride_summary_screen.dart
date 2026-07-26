import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/tracking_service.dart';
import '../theme/app_theme.dart';

/// Full-screen post-ride summary. Shows the finalised stats (distance, elapsed
/// vs moving time, avg/max speed) and lets the rider name-and-save the ride or
/// discard it. Backing out (hardware/gesture) keeps the ride unnamed.
///
/// The ride is *already* in the DB by the time this shows (the engine persists
/// as it records), so Save just names it and Discard deletes it.
class RideSummaryScreen extends ConsumerStatefulWidget {
  const RideSummaryScreen({super.key, required this.telemetry});

  final LiveTelemetry telemetry;

  @override
  ConsumerState<RideSummaryScreen> createState() => _RideSummaryScreenState();
}

class _RideSummaryScreenState extends ConsumerState<RideSummaryScreen> {
  final TextEditingController _nameController = TextEditingController();

  /// Name for the *trip* this ride would start — kept separate from the ride's
  /// own name, since a trip and its first leg are named independently. Only used
  /// by the "save & continue later" path; ignored by a plain save.
  final TextEditingController _tripNameController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameController.dispose();
    _tripNameController.dispose();
    super.dispose();
  }

  /// Runs a save/continue/finish action under the busy guard, then pops.
  Future<void> _run(Future<void> Function(String name) action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await action(_nameController.text);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _discard() async {
    if (_busy) return;
    final confirmed = await _confirmDiscard();
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    await ref.read(trackingControllerProvider.notifier).discardFinishedRide();
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final cx = AppColors.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cx.surface,
        title: Text('Discard ride?', style: TextStyle(color: cx.textBright)),
        content: Text(
          'This permanently deletes the ride and its recorded track.',
          style: TextStyle(color: cx.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancel', style: TextStyle(color: cx.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Discard', style: TextStyle(color: cx.dangerInk)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = widget.telemetry;
    final unit = ref.watch(speedUnitProvider);
    // Trip context: when a continuation is pending this ride is a leg of an open
    // trip, so the summary offers Continue-later / Finish-trip instead of a
    // plain save.
    final tripState = ref.watch(trackingControllerProvider);
    final continuingTripId = tripState.continuingTripId;
    final isTripLeg = continuingTripId != null;
    final tripName = tripState.continuingTripName?.trim();
    final notifier = ref.read(trackingControllerProvider.notifier);
    return PopScope(
      // Backing out keeps the (already-saved) ride, unnamed.
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(trackingControllerProvider.notifier).keepFinishedRide();
        }
      },
      child: Scaffold(
        backgroundColor: cx.canvas,
        // Let the content scroll when the keyboard shrinks the viewport; the
        // buttons stay pinned to the bottom (via the Spacer) when there's room.
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          isTripLeg ? 'LEG COMPLETE' : 'RIDE COMPLETE',
                          style: TextStyle(
                            color: cx.accentInk,
                            fontSize: 14,
                            letterSpacing: 3,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (isTripLeg) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Icon(
                                Icons.alt_route,
                                color: cx.textDim,
                                size: 15,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Part of ${tripName?.isNotEmpty == true ? '“$tripName”' : 'your trip'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: cx.textDim,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 24),
                        // Distance hero.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              unit
                                  .distanceMeters(t.distanceMeters)
                                  .toStringAsFixed(2),
                              style: TextStyle(
                                color: cx.accentInk,
                                fontSize: 64,
                                height: 1,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                unit.distanceLabel,
                                style: TextStyle(
                                  color: cx.textDim,
                                  fontSize: 20,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        Row(
                          children: [
                            _SummaryStat(
                              label: 'TOTAL TIME',
                              value: _fmtDuration(t.durationSeconds),
                            ),
                            _SummaryStat(
                              label: 'MOVING TIME',
                              value: _fmtDuration(t.movingSeconds),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            _SummaryStat(
                              label: 'AVG SPEED',
                              value: unit
                                  .speed(t.avgSpeedKmh)
                                  .toStringAsFixed(1),
                              unit: unit.speedLabel,
                            ),
                            _SummaryStat(
                              label: 'MAX SPEED',
                              value: unit
                                  .speed(t.maxSpeedKmh)
                                  .toStringAsFixed(1),
                              unit: unit.speedLabel,
                              color: cx.danger,
                            ),
                          ],
                        ),
                        const Spacer(),
                        _NameField(
                          controller: _nameController,
                          enabled: !_busy,
                          hint: isTripLeg
                              ? 'Name this leg (e.g. Leg 2 — to Lembang)'
                              : 'Name this ride (e.g. Morning commute)',
                        ),
                        // Starting a trip from this ride names the trip too — a
                        // trip's name is its own, not borrowed from its first
                        // leg. Hidden while continuing an existing trip (that
                        // trip is already named, and renameable in trip detail).
                        if (!isTripLeg) ...[
                          const SizedBox(height: 10),
                          _NameField(
                            controller: _tripNameController,
                            enabled: !_busy,
                            hint: 'Trip name — if continuing later',
                            icon: Icons.alt_route,
                          ),
                        ],
                        const SizedBox(height: 16),
                        // Primary action. Standalone ride → SAVE RIDE. A trip leg →
                        // CONTINUE LATER (keep the journey open to add more legs).
                        SizedBox(
                          height: 60,
                          child: ElevatedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    isTripLeg
                                        ? (n) => notifier.saveAndContinueTrip(n)
                                        : notifier.saveFinishedRide,
                                  ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: cx.accent,
                              foregroundColor: cx.onAccent,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              isTripLeg ? 'CONTINUE LATER' : 'SAVE RIDE',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Secondary action. Standalone ride → start a trip from this
                        // ride. A trip leg → finish the trip now.
                        SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    isTripLeg
                                        ? (n) => notifier.finishTripWithLeg(n)
                                        : (n) => notifier.saveAndContinueTrip(
                                              n,
                                              tripName:
                                                  _tripNameController.text,
                                            ),
                                  ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cx.accentInk,
                              side: BorderSide(color: cx.accentInk),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              isTripLeg
                                  ? 'FINISH TRIP'
                                  : 'SAVE & CONTINUE LATER',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            onPressed: _busy ? null : _discard,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cx.dangerInk,
                              side: BorderSide(color: cx.dangerInk),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: const Text(
                              'DISCARD',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One rounded name input on the summary screen — used for the ride/leg name and
/// (when this ride could start a trip) the trip name.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.enabled,
    required this.hint,
    this.icon,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return TextField(
      controller: controller,
      enabled: enabled,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(color: cx.textBright),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cx.textDim),
        prefixIcon: icon == null
            ? null
            : Icon(icon, color: cx.textDim, size: 18),
        filled: true,
        fillColor: cx.surface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cx.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cx.accentInk),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: cx.border),
        ),
      ),
    );
  }
}

/// Formats seconds as `m:ss` (or `h:mm:ss` past an hour).
String _fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.label,
    required this.value,
    this.unit = '',
    this.color,
  });

  final String label;
  final String value;
  final String unit;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: cx.textDim, fontSize: 11)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color ?? cx.accentInk,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit, style: TextStyle(color: cx.textDim, fontSize: 12)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
