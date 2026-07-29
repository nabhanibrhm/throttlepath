import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ride_stats.dart';
import '../providers/settings_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/route_derivation.dart' show kRouteMinDistanceMeters;
import '../services/tracking_service.dart';
import '../theme/app_theme.dart';
import 'place_route_label.dart';
import 'route_sparkline.dart';

/// Full-screen post-ride summary — the moment the ride becomes a thing the rider
/// keeps.
///
/// Leads with where they went and how far (not with a form), places the ride
/// against their own history, and reduces naming to reading a pre-filled
/// suggestion. The ride is *already* in the DB by the time this shows (the engine
/// persists as it records), so Save just names it and Discard deletes it.
class RideSummaryScreen extends ConsumerStatefulWidget {
  const RideSummaryScreen({super.key, required this.telemetry});

  final LiveTelemetry telemetry;

  @override
  ConsumerState<RideSummaryScreen> createState() => _RideSummaryScreenState();
}

/// Under either of these a ride is almost certainly an accident — a mis-tapped
/// START, or a stop the rider forgot to end. Prompting is kinder than letting it
/// silently join the history and drag every average down (F18).
const double _kTrivialDistanceMeters = 100;
const int _kTrivialDurationSeconds = 60;

class _RideSummaryScreenState extends ConsumerState<RideSummaryScreen> {
  final TextEditingController _nameController = TextEditingController();
  bool _busy = false;

  /// The auto-name has been written into the field once. Not state that affects
  /// layout — purely a latch so a rebuild can't overwrite the rider's typing.
  bool _prefilled = false;
  bool _trivialPromptShown = false;

  @override
  void dispose() {
    _nameController.dispose();
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
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() => _busy = true);
    await ref.read(trackingControllerProvider.notifier).discardFinishedRide();
    if (mounted) Navigator.of(context).pop();
  }

  /// Confirms the discard in the rider's own numbers rather than in the abstract:
  /// "Delete 15.27 km" is a decision, "Delete" is a reflex (F15).
  Future<bool> _confirmDiscard() async {
    final cx = AppColors.of(context);
    final unit = ref.read(speedUnitProvider);
    final t = widget.telemetry;
    final distance =
        '${unit.distanceMeters(t.distanceMeters).toStringAsFixed(2)} ${unit.distanceLabel}';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cx.surfaceRaised,
        title: Text('Discard this ride?', style: TextStyle(color: cx.textBright)),
        content: Text(
          'You recorded $distance over ${_fmtDuration(t.durationSeconds)}. '
          'Discarding deletes the ride and its track for good.',
          style: TextStyle(color: cx.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Keep it', style: TextStyle(color: cx.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Delete $distance',
                style: TextStyle(
                    color: cx.dangerInk, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// Offers the way out on a ride that didn't go anywhere. Discard leads; saving
  /// it anyway stays available, because "didn't go anywhere" is a guess.
  Future<void> _promptTrivialRide() async {
    final cx = AppColors.of(context);
    final unit = ref.read(speedUnitProvider);
    final t = widget.telemetry;
    final distance = t.distanceMeters < 1000
        ? '${t.distanceMeters.round()} m'
        : '${unit.distanceMeters(t.distanceMeters).toStringAsFixed(2)} ${unit.distanceLabel}';
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cx.surfaceRaised,
        title: Text("Looks like this didn't go anywhere",
            style: TextStyle(color: cx.textBright)),
        content: Text(
          '$distance in ${_fmtDuration(t.durationSeconds)}. '
          'Recordings this short are usually a mis-tap.',
          style: TextStyle(color: cx.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Save anyway', style: TextStyle(color: cx.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Discard',
                style: TextStyle(
                    color: cx.dangerInk, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _busy = true);
      await ref.read(trackingControllerProvider.notifier).discardFinishedRide();
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = widget.telemetry;
    final unit = ref.watch(speedUnitProvider);
    // Trip context: when a continuation is pending this ride is a stint of an open
    // trip, so the summary offers Continue-later / Finish-trip instead of a
    // plain save.
    final tripState = ref.watch(trackingControllerProvider);
    final continuingTripId = tripState.continuingTripId;
    final isTripStint = continuingTripId != null;
    final tripName = tripState.continuingTripName?.trim();
    final notifier = ref.read(trackingControllerProvider.notifier);

    // Context (places, route shape, records, name suggestions) arrives a beat
    // after the screen does; every part of the layout that uses it degrades to
    // nothing rather than to a spinner, so the stats never wait on a query.
    final insight = ref.watch(rideInsightProvider(t.rideId)).valueOrNull;
    if (insight != null && !_prefilled) {
      _prefilled = true;
      // Straight assignment during build would notify the TextField's own
      // listeners mid-frame; defer a frame instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _nameController.text.isEmpty) {
          // setState, not a bare assignment: the suggestion chips filter out
          // whatever is already in the field, so they have to be rebuilt too or
          // the pre-filled name shows up twice.
          setState(
              () => _nameController.text = insight.nameSuggestions.first);
        }
      });
    }
    if (!_trivialPromptShown &&
        (t.distanceMeters < _kTrivialDistanceMeters ||
            t.durationSeconds < _kTrivialDurationSeconds)) {
      _trivialPromptShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _promptTrivialRide();
      });
    }

    return PopScope(
      // Backing out keeps the (already-saved) ride, auto-named.
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          ref.read(trackingControllerProvider.notifier).keepFinishedRide(
                fallbackName: insight?.nameSuggestions.first,
              );
        }
      },
      child: Scaffold(
        backgroundColor: cx.canvas,
        appBar: AppBar(
          backgroundColor: cx.canvas,
          automaticallyImplyLeading: false,
          title: Text(
            isTripStint ? 'STINT COMPLETE' : 'RIDE COMPLETE',
            style: TextStyle(
              color: cx.accentInk,
              fontSize: 14,
              letterSpacing: 3,
              fontWeight: FontWeight.w700,
            ),
          ),
          actions: [
            // Discard is deliberately out of the button stack: it was one slip
            // away from Save, and it is not a peer of it (F15).
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextButton(
                onPressed: _busy ? null : _discard,
                style: TextButton.styleFrom(foregroundColor: cx.dangerInk),
                child: const Text('Discard',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
        // Let the content scroll when the keyboard shrinks the viewport; the
        // buttons stay pinned to the bottom (via the Spacer) when there's room.
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isTripStint) ...[
                          _TripContextRow(tripName: tripName),
                          const SizedBox(height: 14),
                        ],
                        if (insight != null && insight.awards.isNotEmpty) ...[
                          _AwardRow(awards: insight.awards),
                          const SizedBox(height: 16),
                        ],
                        // Where they went, before how far — the route is what
                        // makes the ride recognisable a month later.
                        if (PlaceRouteLabel.label(insight?.ride.startPlace,
                                insight?.ride.endPlace) !=
                            null) ...[
                          PlaceRouteLabel(
                            startPlace: insight?.ride.startPlace,
                            endPlace: insight?.ride.endPlace,
                            fontSize: 14,
                          ),
                          const SizedBox(height: 10),
                        ],
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.baseline,
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
                                      fontFeatures: kTabularFigures,
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
                            ),
                            // Same floor as the History card: below it the trace
                            // is drift, not a route.
                            if (t.distanceMeters >= kRouteMinDistanceMeters &&
                                RouteSparkline.canDraw(insight?.ride.routeBlob))
                              SizedBox(
                                width: 76,
                                child: RouteSparkline(
                                  blob: insight!.ride.routeBlob,
                                  height: 56,
                                ),
                              ),
                          ],
                        ),
                        if (insight != null) ...[
                          const SizedBox(height: 10),
                          _ComparisonLine(insight: insight),
                        ],
                        const SizedBox(height: 26),
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
                              value:
                                  unit.speed(t.avgSpeedKmh).toStringAsFixed(1),
                              unit: unit.speedLabel,
                            ),
                            _SummaryStat(
                              label: 'PEAK SPEED',
                              value:
                                  unit.speed(t.maxSpeedKmh).toStringAsFixed(1),
                              unit: unit.speedLabel,
                              color: cx.peak,
                            ),
                          ],
                        ),
                        const Spacer(),
                        const SizedBox(height: 24),
                        _NameSection(
                          controller: _nameController,
                          enabled: !_busy,
                          label: isTripStint ? 'STINT NAME' : 'RIDE NAME',
                          suggestions:
                              insight?.nameSuggestions ?? const <String>[],
                          onPick: (s) => setState(() {
                            _nameController.text = s;
                            _nameController.selection =
                                TextSelection.collapsed(offset: s.length);
                          }),
                        ),
                        const SizedBox(height: 16),
                        // Primary action. Standalone ride → SAVE RIDE. A trip stint →
                        // CONTINUE LATER (keep the journey open to add more stints).
                        SizedBox(
                          height: 60,
                          child: ElevatedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                      isTripStint
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
                              isTripStint ? 'CONTINUE LATER' : 'SAVE RIDE',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // Secondary action. Standalone ride → start a trip from this
                        // ride (via a sheet that explains what one is). A trip stint →
                        // finish the trip now.
                        SizedBox(
                          height: 52,
                          child: OutlinedButton(
                            onPressed: _busy
                                ? null
                                : (isTripStint
                                    ? () => _run(notifier.finishTripWithStint)
                                    : _startTrip),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: cx.accentInk,
                              side: BorderSide(color: cx.accentInk),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            child: Text(
                              isTripStint ? 'FINISH TRIP' : 'CONTINUE AS A TRIP',
                              style: const TextStyle(
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

  /// Turns this ride into the first stint of a trip. The trip-name field lives in
  /// the sheet rather than on the summary: it used to sit there permanently,
  /// asking every rider to name a trip most of them never start, with no
  /// explanation of what one is (F16).
  Future<void> _startTrip() async {
    if (_busy) return;
    final tripName = await _askTripName(context, _nameController.text);
    if (tripName == null || !mounted) return;
    await _run((n) => ref
        .read(trackingControllerProvider.notifier)
        .saveAndContinueTrip(n, tripName: tripName));
  }
}

/// The sheet behind "Continue as a trip": one sentence on what a trip is, then
/// the name. Returns the (possibly empty) trip name, or null if dismissed.
Future<String?> _askTripName(BuildContext context, String rideName) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: AppColors.of(context).surfaceRaised,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => _TripNameSheet(rideName: rideName),
  );
}

/// The sheet's body, stateful purely so it *owns* its [TextEditingController].
///
/// It used to be a plain closure with `.whenComplete(controller.dispose)`, which
/// looks right and isn't: a route's future completes the moment it is popped,
/// which is the *start* of the exit transition, not the end. Dismissing the sheet
/// by tapping the barrier therefore disposed the controller while the focused
/// `TextField` was still mounted and animating out; the throw from inside the
/// still-live field aborted Flutter's unmount walk partway, and the next frame
/// failed the `_dependents.isEmpty` assertion with no hint of the real cause.
///
/// Owning it here ties disposal to this widget's own element, so it can only
/// happen after the field is gone. Same reasoning as [showRenameDialog] —
/// see `rename_dialog.dart`.
class _TripNameSheet extends StatefulWidget {
  const _TripNameSheet({required this.rideName});

  /// The ride's name, quoted back so the rider can see naming the *trip* doesn't
  /// rename the ride.
  final String rideName;

  @override
  State<_TripNameSheet> createState() => _TripNameSheetState();
}

class _TripNameSheetState extends State<_TripNameSheet> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final cx = AppColors.of(ctx);
    final rideName = widget.rideName;
    return Padding(
      // Lift clear of the keyboard the field is about to raise.
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.alt_route, color: cx.accentInk, size: 20),
                  const SizedBox(width: 8),
                  Text('Continue this as a trip',
                      style: TextStyle(
                          color: cx.textBright,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'A trip groups several rides into one journey — ride out today, '
                'ride back tomorrow, and the distance and time add up together.',
                style: TextStyle(
                    color: cx.textDim, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 18),
              Text('TRIP NAME',
                  style: TextStyle(
                      color: cx.textTertiary,
                      fontSize: kMinFontSize,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _RoundedField(
                controller: controller,
                enabled: true,
                hint: 'Optional — e.g. Weekend to Dieng',
                autofocus: true,
              ),
              const SizedBox(height: 6),
              Text(
                'Leave it blank and the trip gets a dated name you can change '
                'later. This ride stays “${rideName.trim().isEmpty ? 'Untitled ride' : rideName.trim()}”.',
                style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(controller.text),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cx.accent,
                    foregroundColor: cx.onAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('START THE TRIP',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Part of “Weekend to Dieng”" — the stint's place in its trip.
class _TripContextRow extends StatelessWidget {
  const _TripContextRow({this.tripName});

  final String? tripName;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Row(
      children: [
        Icon(Icons.alt_route, color: cx.textDim, size: 15),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Part of ${tripName?.isNotEmpty == true ? '“$tripName”' : 'your trip'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: cx.textDim, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// Filled amber badges for the records this ride broke (F17).
///
/// Filled rather than outlined because an award is rare — gated on a minimum
/// distance and on the rider actually having a history to beat — so the amber
/// can't become wallpaper.
class _AwardRow extends StatelessWidget {
  const _AwardRow({required this.awards});

  final List<RideAward> awards;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final a in awards)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: cx.accent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.emoji_events, size: 14, color: cx.onAccent),
                const SizedBox(width: 5),
                Text(
                  a.label.toUpperCase(),
                  style: TextStyle(
                    color: cx.onAccent,
                    fontSize: kMinFontSize,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One sentence putting the distance in the rider's own terms — against their
/// average, and against this route's history (F17).
class _ComparisonLine extends StatelessWidget {
  const _ComparisonLine({required this.insight});

  final RideInsight insight;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final parts = <({String text, Color color})>[];

    final delta = insight.distanceVsAvgFraction;
    if (delta == null) {
      // No comparison to draw — either a genuine first ride, or a recording too
      // short for "x% shorter" to mean anything (see `distanceVsAverage`). In the
      // second case say nothing rather than something wrong.
      if (insight.rider.rideCount == 0) {
        parts.add((text: 'Your first saved ride', color: cx.textDim));
      }
    } else if (delta.abs() < 0.05) {
      parts.add((text: 'About your usual distance', color: cx.textDim));
    } else {
      final pct = (delta.abs() * 100).round();
      parts.add(delta > 0
          // Further than usual is worth colouring; shorter is just a fact, and
          // colouring it would read as a reprimand.
          ? (text: '$pct% further than your average', color: cx.positiveInk)
          : (text: '$pct% shorter than your average', color: cx.textDim));
    }

    if (insight.isRepeatRoute) {
      final n = insight.route.priorRideCount;
      parts.add((
        text: n == 1
            ? 'ridden this route once before'
            : 'ridden this route $n times before',
        color: cx.textDim,
      ));
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            if (i > 0)
              TextSpan(
                  text: ' · ', style: TextStyle(color: cx.textTertiary)),
            TextSpan(
              text: parts[i].text,
              style: TextStyle(
                color: parts[i].color,
                fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
      style: const TextStyle(fontSize: 13, height: 1.3),
    );
  }
}

/// The name field with a permanent label above it and one-tap alternatives below.
///
/// The field arrives pre-filled with the best suggestion, so the common case is
/// reading it and pressing Save — no typing, no tapping (F16). The old version was
/// a bare hint-only input, which vanished the moment anything was typed and gave
/// no clue what a good name looked like.
class _NameSection extends StatelessWidget {
  const _NameSection({
    required this.controller,
    required this.enabled,
    required this.label,
    required this.suggestions,
    required this.onPick,
  });

  final TextEditingController controller;
  final bool enabled;
  final String label;
  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    // Only offer what isn't already in the field — a chip that does nothing is
    // worse than no chip.
    final current = controller.text.trim();
    final others =
        suggestions.where((s) => s != current).take(2).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: TextStyle(
            color: cx.textTertiary,
            fontSize: kMinFontSize,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _RoundedField(
          controller: controller,
          enabled: enabled,
          hint: 'Name this ride',
        ),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in others)
                _SuggestionChip(
                  label: s,
                  onTap: enabled ? () => onPick(s) : null,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          // 36dp tall: a suggestion is a convenience, not a primary target, but
          // it still has to be hittable with a glove on.
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: cx.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: cx.textBright,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// One rounded text input, matching the summary's card styling.
class _RoundedField extends StatelessWidget {
  const _RoundedField({
    required this.controller,
    required this.enabled,
    required this.hint,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final String hint;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return TextField(
      controller: controller,
      enabled: enabled,
      autofocus: autofocus,
      textCapitalization: TextCapitalization.sentences,
      style: TextStyle(color: cx.textBright),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cx.textDim),
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
          Text(label, style: TextStyle(color: cx.textTertiary, fontSize: 12)),
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
                  fontFeatures: kTabularFigures,
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
