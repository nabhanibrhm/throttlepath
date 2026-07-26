import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/units.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../theme/app_theme.dart';
import 'place_route_label.dart';
import 'ride_detail_screen.dart';
import 'trip_detail_screen.dart';

/// Scrollable list of saved rides, newest first. Each row is a compact ride
/// summary (name, date, distance, time, avg/max). Tap a row to open the
/// map+summary detail; swipe a row to delete.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final ridesAsync = ref.watch(rideHistoryProvider);
    final unit = ref.watch(speedUnitProvider);
    // Kick the best-effort backfill of missing start/end place names (rides
    // saved offline). Fire-and-forget: it refreshes the list itself when a
    // name resolves; we don't surface its loading/error state.
    ref.watch(geocodeBackfillProvider);

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          'Ride History',
          style: TextStyle(
            color: cx.textBright,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: ridesAsync.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: cx.accentInk),
        ),
        error: (e, _) => Center(
          child: Text(
            'Could not load rides:\n$e',
            textAlign: TextAlign.center,
            style: TextStyle(color: cx.dangerInk),
          ),
        ),
        data: (rides) {
          // Open trips render as amber banners at the top (Continue resumes them
          // on the Record tab); finished trips and standalone rides merge into
          // one date-sorted list below.
          final openTrips =
              ref.watch(openTripsProvider).valueOrNull ?? const [];
          final finishedTrips =
              ref.watch(finishedTripsProvider).valueOrNull ?? const [];
          if (rides.isEmpty && openTrips.isEmpty && finishedTrips.isEmpty) {
            return const _EmptyState();
          }

          void continueTrip(TripSummary t) {
            ref
                .read(trackingControllerProvider.notifier)
                .beginContinuation(t.trip.id, t.trip.name);
            ref.read(homeTabProvider.notifier).state = 0; // Record tab
          }

          void openTrip(TripSummary t) => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TripDetailScreen(trip: t.trip),
                ),
              );

          // Merge finished trips + standalone rides, newest activity first.
          final entries = <({DateTime when, Widget card})>[
            for (final t in finishedTrips)
              (
                when: t.stats.endTime ?? t.trip.createdAt,
                card: _TripCard(
                  summary: t,
                  unit: unit,
                  onTap: () => openTrip(t),
                ),
              ),
            for (final ride in rides)
              (
                when: ride.startTime,
                card: _RideCard(
                  ride: ride,
                  unit: unit,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RideDetailScreen(ride: ride),
                    ),
                  ),
                  onDelete: () async {
                    await DatabaseService.instance.deleteRide(ride.id);
                    ref.invalidate(rideHistoryProvider);
                  },
                ),
              ),
          ]..sort((a, b) => b.when.compareTo(a.when));

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              for (final t in openTrips) ...[
                _OpenTripCard(
                  summary: t,
                  unit: unit,
                  onContinue: () => continueTrip(t),
                  onTap: () => openTrip(t),
                ),
                const SizedBox(height: 12),
              ],
              for (var i = 0; i < entries.length; i++) ...[
                entries[i].card,
                if (i < entries.length - 1) const SizedBox(height: 12),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.two_wheeler, color: cx.textDim, size: 56),
          const SizedBox(height: 16),
          Text(
            'No rides yet',
            style: TextStyle(color: cx.textBright, fontSize: 18),
          ),
          const SizedBox(height: 6),
          Text(
            'Your saved rides will show up here.',
            style: TextStyle(color: cx.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Banner card for an open (continuable) trip: an amber-accented summary of the
/// legs so far with a Continue button that resumes the trip on the Record tab.
/// A single-entry, per-leg trip view lands in Phase 3; this is the entry point.
class _OpenTripCard extends StatelessWidget {
  const _OpenTripCard({
    required this.summary,
    required this.unit,
    required this.onContinue,
    required this.onTap,
  });

  final TripSummary summary;
  final SpeedUnit unit;
  final VoidCallback onContinue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final stats = summary.stats;
    final name = summary.trip.name?.trim();
    final legCount = stats.legCount;
    final legLabel = legCount == 1 ? '1 leg' : '$legCount legs';
    final distance =
        '${unit.distanceMeters(stats.totalDistanceMeters).toStringAsFixed(1)} ${unit.distanceLabel}';
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cx.accentInk.withValues(alpha: 0.55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.alt_route, color: cx.accentInk, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'OPEN TRIP',
                    style: TextStyle(
                      color: cx.accentInk,
                      fontSize: 11,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: cx.textDim, size: 18),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                name?.isNotEmpty == true ? name! : 'Untitled trip',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cx.textBright,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '$legLabel · $distance · ${_fmtDuration(stats.durationSeconds)}',
                style: TextStyle(color: cx.textDim, fontSize: 13),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 46,
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: onContinue,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text(
                    'CONTINUE',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: cx.accent,
                    foregroundColor: cx.onAccent,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A finished trip in the History list: a compact combined-stats card that taps
/// into the trip detail. Distinguished from a ride card by the route icon and
/// leg count.
class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.summary,
    required this.unit,
    required this.onTap,
  });

  final TripSummary summary;
  final SpeedUnit unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final stats = summary.stats;
    final name = summary.trip.name?.trim();
    final legLabel = stats.legCount == 1 ? '1 leg' : '${stats.legCount} legs';
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cx.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.alt_route, color: cx.accentInk, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TRIP · $legLabel',
                          style: TextStyle(
                            color: cx.accentInk,
                            fontSize: 11,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          name?.isNotEmpty == true ? name! : 'Untitled trip',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cx.textBright,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (stats.startTime != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _formatDate(stats.startTime!),
                            style: TextStyle(color: cx.textDim, fontSize: 13),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  RichText(
                    text: TextSpan(
                      text: unit
                          .distanceMeters(stats.totalDistanceMeters)
                          .toStringAsFixed(2),
                      style: TextStyle(
                        color: cx.accentInk,
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                      children: [
                        TextSpan(
                          text: ' ${unit.distanceLabel}',
                          style: TextStyle(
                            color: cx.textDim,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: 14),
                color: cx.border,
              ),
              Row(
                children: [
                  _MiniStat(
                    label: 'TIME',
                    value: _fmtDuration(stats.durationSeconds),
                  ),
                  _MiniStat(
                    label: 'MOVING',
                    value: _fmtDuration(stats.movingSeconds),
                  ),
                  _MiniStat(
                    label: 'AVG',
                    value: unit.speed(stats.averageSpeedKmh).toStringAsFixed(0),
                  ),
                  _MiniStat(
                    label: 'MAX',
                    value: unit.speed(stats.maxSpeedKmh).toStringAsFixed(0),
                    color: cx.danger,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RideCard extends StatelessWidget {
  const _RideCard({
    required this.ride,
    required this.unit,
    required this.onTap,
    required this.onDelete,
  });

  final Ride ride;
  final SpeedUnit unit;
  final VoidCallback onTap;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Dismissible(
      key: ValueKey(ride.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        decoration: BoxDecoration(
          color: cx.danger.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.delete_outline, color: cx.dangerInk),
      ),
      child: Material(
        color: cx.surface,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: cx.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            ride.name?.trim().isNotEmpty == true
                                ? ride.name!.trim()
                                : 'Untitled ride',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cx.textBright,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _formatDate(ride.startTime),
                            style: TextStyle(color: cx.textDim, fontSize: 13),
                          ),
                          if (PlaceRouteLabel.label(
                                  ride.startPlace, ride.endPlace) !=
                              null) ...[
                            const SizedBox(height: 4),
                            PlaceRouteLabel(
                              startPlace: ride.startPlace,
                              endPlace: ride.endPlace,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    RichText(
                      text: TextSpan(
                        text: unit
                            .distanceMeters(ride.totalDistanceMeters)
                            .toStringAsFixed(2),
                        style: TextStyle(
                          color: cx.accentInk,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                        children: [
                          TextSpan(
                            text: ' ${unit.distanceLabel}',
                            style: TextStyle(
                              color: cx.textDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 14),
                  color: cx.border,
                ),
                Row(
                  children: [
                    _MiniStat(
                      label: 'TIME',
                      value: _fmtDuration(ride.durationSeconds),
                    ),
                    _MiniStat(
                      label: 'MOVING',
                      value: _fmtDuration(ride.movingSeconds),
                    ),
                    _MiniStat(
                      label: 'AVG',
                      value: unit.speed(ride.averageSpeedKmh).toStringAsFixed(0),
                    ),
                    _MiniStat(
                      label: 'MAX',
                      value: unit.speed(ride.maxSpeedKmh).toStringAsFixed(0),
                      color: cx.danger,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final cx = AppColors.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cx.surface,
        title: Text(
          'Delete ride?',
          style: TextStyle(color: cx.textBright),
        ),
        content: Text(
          'This permanently removes the ride and its track.',
          style: TextStyle(color: cx.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cx.textDim),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Delete',
              style: TextStyle(color: cx.dangerInk),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: cx.textDim, fontSize: 10),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: color ?? cx.textBright,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// e.g. `Jul 2, 2026 · 22:36`. Avoids pulling in the intl package.
String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${_months[local.month - 1]} ${local.day}, ${local.year} · $hh:$mm';
}

String _fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
