import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/units.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/ride_stats.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/route_derivation.dart' show kRouteMinDistanceMeters;
import '../theme/app_theme.dart';
import 'place_route_label.dart';
import 'ride_detail_screen.dart';
import 'route_sparkline.dart';
import 'trip_detail_screen.dart';
import 'week_strip.dart';

/// The rides list: this week's totals above a searchable, month-grouped history.
///
/// Each row leads with the name, then the distance, then the *shape* of the route
/// — a rider recognises a ride from its outline long before they read its stats
/// (F20). Trips render as a bracketed parent with their legs nested beneath (F21).
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

/// How long the Undo window stays open after a swipe-delete.
const Duration _kUndoWindow = Duration(seconds: 6);

/// Collapsed toolbar height, and the room the week strip gets above it.
///
/// Measured on the device, the strip comes to ~92dp in Inter (label row + 34sp
/// hero + the rides/moving line + 28dp of padding); this reserves a little more.
/// It is *not* imposed on the strip — see `_appBar` — so a larger system text
/// scale clips at the bottom instead of throwing an overflow.
const double _kToolbarHeight = 56;
const double _kStripHeight = 104;

/// What the filter chips select.
enum _Filter {
  all('All'),
  rides('Rides'),
  trips('Trips'),
  thisMonth('This month');

  const _Filter(this.label);
  final String label;
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  _Filter _filter = _Filter.all;

  /// Rides swiped away but not yet deleted. The row leaves the list immediately
  /// while the Undo snackbar is up, and the delete only reaches the DB when that
  /// window closes without an Undo — nothing is destroyed during the six seconds
  /// a rider might change their mind (F23).
  final Set<int> _pendingDelete = <int>{};

  @override
  void dispose() {
    // A rider who swipes and immediately leaves meant it. Commit: the alternative
    // is a row that reappears as if the swipe never happened.
    for (final id in _pendingDelete) {
      DatabaseService.instance.deleteRide(id);
    }
    _search.dispose();
    super.dispose();
  }

  Future<void> _deleteWithUndo(Ride ride) async {
    final name =
        ride.name?.trim().isNotEmpty == true ? '“${ride.name!.trim()}”' : 'ride';
    setState(() => _pendingDelete.add(ride.id));

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final reason = await messenger
        .showSnackBar(
          SnackBar(
            duration: _kUndoWindow,
            content: Text('Deleted $name'),
            action: SnackBarAction(
              label: 'Undo',
              // The work happens off the close reason below, not here: the
              // snackbar dismisses itself either way, and `closed` is the only
              // signal that distinguishes "undone" from "timed out".
              onPressed: () {},
            ),
          ),
        )
        .closed;

    if (reason == SnackBarClosedReason.action) {
      if (mounted) setState(() => _pendingDelete.remove(ride.id));
      return;
    }
    await DatabaseService.instance.deleteRide(ride.id);
    if (!mounted) return;
    setState(() => _pendingDelete.remove(ride.id));
    ref.invalidate(rideHistoryProvider);
    ref.invalidate(weekStatsProvider);
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final ridesAsync = ref.watch(rideHistoryProvider);
    final unit = ref.watch(speedUnitProvider);
    final week = ref.watch(weekStatsProvider).valueOrNull ??
        WeekStats.emptyFor(DateTime.now());
    // Kick the two best-effort backfills (place names for rides saved offline;
    // route key + shape for rides recorded before those fields existed). Both
    // refresh the list themselves as they fill in.
    ref.watch(geocodeBackfillProvider);
    ref.watch(routeBackfillProvider);

    return Scaffold(
      backgroundColor: cx.canvas,
      body: ridesAsync.when(
        loading: () => Center(child: CircularProgressIndicator(color: cx.accentInk)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load rides:\n$e',
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.dangerInk),
            ),
          ),
        ),
        data: (rides) => _buildList(context, cx, rides, unit, week),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppPalette cx,
    List<Ride> rides,
    SpeedUnit unit,
    WeekStats week,
  ) {
    final openTrips = ref.watch(openTripsProvider).valueOrNull ?? const [];
    final finishedTrips =
        ref.watch(finishedTripsProvider).valueOrNull ?? const [];

    void continueTrip(TripSummary t) {
      ref
          .read(trackingControllerProvider.notifier)
          .beginContinuation(t.trip.id, t.trip.name);
      ref.read(homeTabProvider.notifier).state = 0; // Record tab
    }

    void openTrip(TripSummary t) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => TripDetailScreen(trip: t.trip)),
        );

    void openRide(Ride r) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => RideDetailScreen(ride: r)),
        );

    final all = <_Entry>[
      for (final t in finishedTrips) _TripEntry(t),
      for (final r in rides)
        if (!_pendingDelete.contains(r.id)) _RideEntry(r),
    ]..sort((a, b) => b.when.compareTo(a.when));

    final query = _search.text.trim().toLowerCase();
    final matched = query.isEmpty
        ? all
        : all.where((e) => e.matches(query)).toList(growable: false);
    // Counts are over the *searched* set, not the whole history — a chip reading
    // "Trips 3" that yields nothing once tapped is worse than no count.
    final counts = {
      for (final f in _Filter.values) f: matched.where(f.accepts).length,
    };
    final visible = matched.where(_filter.accepts).toList(growable: false);
    final groups = _groupByMonth(visible);
    final filtering = query.isNotEmpty || _filter != _Filter.all;

    if (all.isEmpty && openTrips.isEmpty) {
      return CustomScrollView(
        slivers: [
          _appBar(cx, week, unit),
          const SliverFillRemaining(hasScrollBody: false, child: _EmptyState()),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        _appBar(cx, week, unit),
        if (_searching)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _SearchField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                // Clears the query but keeps searching. Closing search is what
                // the toolbar's X does; two controls doing the same thing left no
                // way to start a different search without reopening the panel.
                onClear: () => setState(_search.clear),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: _FilterRow(
              selected: _filter,
              counts: counts,
              onSelect: (f) => setState(() => _filter = f),
            ),
          ),
        ),
        if (filtering)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _ResultLine(entries: visible, unit: unit),
            ),
          ),
        for (final t in openTrips)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _OpenTripCard(
                summary: t,
                unit: unit,
                onContinue: () => continueTrip(t),
                onTap: () => openTrip(t),
              ),
            ),
          ),
        if (visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
              child: Text(
                query.isEmpty
                    ? 'Nothing filed under ${_filter.label.toLowerCase()}.'
                    : 'No rides match “${_search.text.trim()}”.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cx.textDim, fontSize: 14),
              ),
            ),
          ),
        for (final group in groups)
          SliverList(
            delegate: SliverChildListDelegate([
              _MonthHeader(
                label: group.label,
                meters: group.meters,
                unit: unit,
              ),
              for (final entry in group.entries)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: switch (entry) {
                    _RideEntry(:final ride) => _RideCard(
                        ride: ride,
                        unit: unit,
                        query: query,
                        onTap: () => openRide(ride),
                        onDelete: () => _deleteWithUndo(ride),
                      ),
                    _TripEntry(:final summary) => _TripCard(
                        summary: summary,
                        unit: unit,
                        query: query,
                        onTap: () => openTrip(summary),
                        onOpenLeg: openRide,
                      ),
                  },
                ),
            ]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Collapsing header: the week strip scrolls away and the toolbar keeps "Rides"
  /// plus the week's distance, so the number stays reachable without holding
  /// 116dp of chrome open all the way down the list (F24).
  ///
  /// `floating` + `snap` means the bar is either fully open or fully closed, never
  /// parked halfway across the top of a card.
  Widget _appBar(AppPalette cx, WeekStats week, SpeedUnit unit) {
    return SliverAppBar(
      pinned: true,
      floating: true,
      snap: true,
      automaticallyImplyLeading: false,
      backgroundColor: cx.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      toolbarHeight: _kToolbarHeight,
      expandedHeight: _kToolbarHeight + _kStripHeight,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final top = MediaQuery.paddingOf(context).top;
          final minH = _kToolbarHeight + top;
          final maxH = _kToolbarHeight + _kStripHeight + top;
          final t = ((constraints.maxHeight - minH) / (maxH - minH))
              .clamp(0.0, 1.0);
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Strip sits below the toolbar and slides out under it. Given no
              // height on purpose: left+right+top leaves the vertical constraint
              // loose, so the strip is whatever tall it needs to be and the
              // Stack's hard clip trims it rather than a RenderFlex overflowing.
              Positioned(
                left: 16,
                right: 16,
                top: top + _kToolbarHeight,
                child: Opacity(
                  opacity: t,
                  child: IgnorePointer(
                    ignoring: t < 0.9,
                    child: WeekStrip(stats: week, unit: unit),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 4,
                top: top,
                height: _kToolbarHeight,
                child: Row(
                  children: [
                    Text(
                      'Rides',
                      style: TextStyle(
                        color: cx.textBright,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    // Only once the strip is out of the way — the same figure
                    // twice, 20dp apart, reads as a rendering bug.
                    if (t < 0.35) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Opacity(
                          opacity: (1 - t / 0.35).clamp(0.0, 1.0),
                          child: Text(
                            '· ${WeekStrip.distanceText(week, unit)} this week',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cx.textDim,
                              fontSize: 13,
                              fontFeatures: kTabularFigures,
                            ),
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    IconButton(
                      icon: Icon(_searching ? Icons.close : Icons.search),
                      color: cx.textBright,
                      tooltip: _searching ? 'Close search' : 'Search rides',
                      onPressed: _toggleSearch,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// --- Entries -----------------------------------------------------------------

/// One row in the history — a standalone ride or a finished trip. Sealed so the
/// list's `switch` is exhaustive and a third kind can't be silently forgotten.
sealed class _Entry {
  const _Entry();

  /// When this entry happened, for ordering and month grouping.
  DateTime get when;
  double get distanceMeters;

  /// True when [query] (already lowercased and trimmed) matches this entry.
  bool matches(String query);
}

class _RideEntry extends _Entry {
  const _RideEntry(this.ride);
  final Ride ride;

  @override
  DateTime get when => ride.startTime;

  @override
  double get distanceMeters => ride.totalDistanceMeters;

  @override
  bool matches(String query) => _haystack([
        ride.name,
        ride.startPlace,
        ride.endPlace,
      ]).contains(query);
}

class _TripEntry extends _Entry {
  const _TripEntry(this.summary);
  final TripSummary summary;

  @override
  DateTime get when => summary.stats.endTime ?? summary.trip.createdAt;

  @override
  double get distanceMeters => summary.stats.totalDistanceMeters;

  @override
  bool matches(String query) => _haystack([
        summary.trip.name,
        for (final leg in summary.stats.legs) ...[
          leg.name,
          leg.startPlace,
          leg.endPlace,
        ],
      ]).contains(query);
}

String _haystack(List<String?> parts) =>
    parts.whereType<String>().join(' ').toLowerCase();

extension on _Filter {
  bool accepts(_Entry e) => switch (this) {
        _Filter.all => true,
        _Filter.rides => e is _RideEntry,
        _Filter.trips => e is _TripEntry,
        _Filter.thisMonth => _isThisMonth(e.when),
      };
}

bool _isThisMonth(DateTime when) {
  final now = DateTime.now();
  final local = when.toLocal();
  return local.year == now.year && local.month == now.month;
}

/// Entries bucketed into calendar months, newest month first, each with its own
/// distance total.
///
/// Months rather than days: a rider records a handful of rides a week, so
/// day headers would outnumber the rows they head.
List<({String label, double meters, List<_Entry> entries})> _groupByMonth(
  List<_Entry> entries,
) {
  final out = <({String label, double meters, List<_Entry> entries})>[];
  var currentKey = '';
  for (final e in entries) {
    final local = e.when.toLocal();
    final key = '${local.year}-${local.month}';
    if (key != currentKey) {
      currentKey = key;
      out.add((
        label: '${_months[local.month - 1]} ${local.year}',
        meters: 0,
        entries: <_Entry>[],
      ));
    }
    final g = out.last;
    g.entries.add(e);
    out[out.length - 1] =
        (label: g.label, meters: g.meters + e.distanceMeters, entries: g.entries);
  }
  return out;
}

// --- Chrome ------------------------------------------------------------------

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      autofocus: true,
      textInputAction: TextInputAction.search,
      style: TextStyle(color: cx.textBright, fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: 14),
        hintText: 'Search names and places',
        hintStyle: TextStyle(color: cx.textDim, fontSize: 15),
        prefixIcon: Icon(Icons.search, size: 20, color: cx.textDim),
        suffixIcon: IconButton(
          icon: Icon(Icons.close, size: 18, color: cx.textDim),
          tooltip: 'Clear search',
          onPressed: onClear,
        ),
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
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.selected,
    required this.counts,
    required this.onSelect,
  });

  final _Filter selected;
  final Map<_Filter, int> counts;
  final ValueChanged<_Filter> onSelect;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _Filter.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final f = _Filter.values[i];
          final on = f == selected;
          final count = counts[f] ?? 0;
          return Semantics(
            button: true,
            selected: on,
            label: '${f.label}, $count',
            child: ExcludeSemantics(
              child: Material(
                color: on ? cx.accent : cx.surface,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  // A chip that would empty the list is not a filter, it's a
                  // dead end — leave it visible (the count explains why) but
                  // don't let it be selected.
                  onTap: count == 0 && !on ? null : () => onSelect(f),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: on ? cx.accent : cx.border),
                    ),
                    child: Text(
                      '${f.label}  $count',
                      style: TextStyle(
                        color: on
                            ? cx.onAccent
                            : (count == 0 ? cx.textTertiary : cx.textBright),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "7 entries · 214.6 km" — the running total for whatever the filters left, so a
/// search doubles as an ad-hoc report ("how far did I ride to Lembang?").
class _ResultLine extends StatelessWidget {
  const _ResultLine({required this.entries, required this.unit});

  final List<_Entry> entries;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final meters =
        entries.fold<double>(0, (sum, e) => sum + e.distanceMeters);
    final label = entries.length == 1 ? '1 result' : '${entries.length} results';
    return Text(
      entries.isEmpty
          ? 'No results'
          : '$label · ${unit.distanceMeters(meters).toStringAsFixed(1)} ${unit.distanceLabel}',
      style: TextStyle(
        color: cx.textDim,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        fontFeatures: kTabularFigures,
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.label,
    required this.meters,
    required this.unit,
  });

  final String label;
  final double meters;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: cx.textTertiary,
              fontSize: kMinFontSize,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Divider(color: cx.border, height: 1)),
          const SizedBox(width: 10),
          Text(
            '${unit.distanceMeters(meters).toStringAsFixed(0)} ${unit.distanceLabel}',
            style: TextStyle(
              color: cx.textDim,
              fontSize: kMinFontSize,
              fontWeight: FontWeight.w600,
              fontFeatures: kTabularFigures,
            ),
          ),
        ],
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
          Text('No rides yet',
              style: TextStyle(color: cx.textBright, fontSize: 18)),
          const SizedBox(height: 6),
          Text('Your saved rides will show up here.',
              style: TextStyle(color: cx.textDim, fontSize: 13)),
        ],
      ),
    );
  }
}

// --- Cards -------------------------------------------------------------------

/// Banner card for an open (continuable) trip: an amber-accented summary of the
/// legs so far with a Continue button that resumes the trip on the Record tab.
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
                      fontSize: 12,
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

/// A saved ride: name, distance, the route's shape, then one quiet metrics line.
///
/// The old card gave name, date, distance and a four-column stat grid all
/// competing at the same weight, and painted PEAK in red on every single row
/// (F20). Now there is one thing to read first, one picture to recognise it by,
/// and the numbers wait until asked for.
class _RideCard extends StatelessWidget {
  const _RideCard({
    required this.ride,
    required this.unit,
    required this.query,
    required this.onTap,
    required this.onDelete,
  });

  final Ride ride;
  final SpeedUnit unit;

  /// Active search term (lowercased), highlighted where it appears.
  final String query;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = ride.name?.trim().isNotEmpty == true
        ? ride.name!.trim()
        : 'Untitled ride';
    final routeLabel = PlaceRouteLabel.label(ride.startPlace, ride.endPlace);

    return Dismissible(
      key: ValueKey(ride.id),
      direction: DismissDirection.endToStart,
      // No confirm dialog: the row leaves at once and the Undo snackbar is the
      // safety net. A modal on every swipe made deleting slower than the mistake
      // it was guarding against (F23).
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: cx.danger.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, color: cx.dangerInk, size: 20),
            const SizedBox(width: 8),
            // Labelled, not a bare icon: a red icon sliding in from the right is
            // recognisable only once you already know what it does.
            Text(
              'Delete',
              style: TextStyle(
                color: cx.dangerInk,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
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
                      child: _Highlighted(
                        text: name,
                        query: query,
                        style: TextStyle(
                          color: cx.textBright,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text.rich(
                      TextSpan(
                        text: unit
                            .distanceMeters(ride.totalDistanceMeters)
                            .toStringAsFixed(2),
                        style: TextStyle(
                          color: cx.accentInk,
                          fontSize: 22,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          fontFeatures: kTabularFigures,
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
                if (routeLabel != null) ...[
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Icon(Icons.place_outlined, size: 14, color: cx.accentInk),
                      const SizedBox(width: 4),
                      Expanded(
                        child: _Highlighted(
                          text: routeLabel,
                          query: query,
                          style: TextStyle(
                            color: cx.textDim,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                // A recording that never went anywhere has a "shape" made
                // entirely of GPS drift; stretched across the card it reads as a
                // real route. Same floor the route key uses.
                if (ride.totalDistanceMeters >= kRouteMinDistanceMeters &&
                    RouteSparkline.canDraw(ride.routeBlob)) ...[
                  const SizedBox(height: 12),
                  RouteSparkline(blob: ride.routeBlob, height: 44),
                ],
                const SizedBox(height: 12),
                _MetricsLine(
                  date: _formatDate(ride.startTime),
                  durationSeconds: ride.durationSeconds,
                  avgKmh: ride.averageSpeedKmh,
                  maxKmh: ride.maxSpeedKmh,
                  unit: unit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A finished trip: the parent's combined stats, with its legs nested underneath
/// behind a connector line (F21).
///
/// Collapsed by default — the point of a trip is that it reads as *one* thing in
/// the list — but expandable in place, because "which leg was the long one?" used
/// to require opening a whole screen.
class _TripCard extends StatefulWidget {
  const _TripCard({
    required this.summary,
    required this.unit,
    required this.query,
    required this.onTap,
    required this.onOpenLeg,
  });

  final TripSummary summary;
  final SpeedUnit unit;
  final String query;
  final VoidCallback onTap;
  final void Function(Ride leg) onOpenLeg;

  @override
  State<_TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<_TripCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final stats = widget.summary.stats;
    final unit = widget.unit;
    final name = widget.summary.trip.name?.trim();
    final legLabel = stats.legCount == 1 ? '1 leg' : '${stats.legCount} legs';

    return Container(
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: BorderRadius.circular(16),
        // The bracket: a heavier amber edge down the left says everything inside
        // belongs to one journey.
        border: Border.all(color: cx.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // IntrinsicHeight + stretch so the bracket runs the full height of
          // whatever the header turns out to be — a fixed height stops short the
          // moment a long trip name wraps to two lines.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: cx.accent),
                Expanded(
                child: InkWell(
                  onTap: widget.onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(13, 14, 16, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.alt_route, color: cx.accentInk, size: 15),
                            const SizedBox(width: 5),
                            Text(
                              'TRIP · $legLabel',
                              style: TextStyle(
                                color: cx.accentInk,
                                fontSize: kMinFontSize,
                                letterSpacing: 1.4,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _Highlighted(
                                text: name?.isNotEmpty == true
                                    ? name!
                                    : 'Untitled trip',
                                query: widget.query,
                                style: TextStyle(
                                  color: cx.textBright,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text.rich(
                              TextSpan(
                                text: unit
                                    .distanceMeters(stats.totalDistanceMeters)
                                    .toStringAsFixed(2),
                                style: TextStyle(
                                  color: cx.accentInk,
                                  fontSize: 22,
                                  height: 1.1,
                                  fontWeight: FontWeight.w800,
                                  fontFeatures: kTabularFigures,
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
                        const SizedBox(height: 8),
                        _MetricsLine(
                          date: stats.startTime == null
                              ? '—'
                              : _formatDate(stats.startTime!),
                          durationSeconds: stats.durationSeconds,
                          avgKmh: stats.averageSpeedKmh,
                          maxKmh: stats.maxSpeedKmh,
                          unit: unit,
                        ),
                      ],
                    ),
                  ),
                ),
                ),
              ],
            ),
          ),
          if (stats.legCount > 0)
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: cx.border)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _expanded ? 'Hide legs' : 'Show $legLabel',
                      style: TextStyle(
                        color: cx.accentInk,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: cx.accentInk,
                    ),
                  ],
                ),
              ),
            ),
          if (_expanded)
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: cx.canvas,
                border: Border(top: BorderSide(color: cx.border)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Column(
                children: [
                  for (var i = 0; i < stats.legs.length; i++)
                    _LegRow(
                      leg: stats.legs[i],
                      index: i + 1,
                      isLast: i == stats.legs.length - 1,
                      unit: unit,
                      query: widget.query,
                      onTap: () => widget.onOpenLeg(stats.legs[i]),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One nested leg: a numbered node on a vertical connector, then the leg's name
/// and distance. The connector is what makes "these belong together, in this
/// order" legible without a caption.
class _LegRow extends StatelessWidget {
  const _LegRow({
    required this.leg,
    required this.index,
    required this.isLast,
    required this.unit,
    required this.query,
    required this.onTap,
  });

  final Ride leg;
  final int index;
  final bool isLast;
  final SpeedUnit unit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = leg.name?.trim().isNotEmpty == true
        ? leg.name!.trim()
        : 'Leg $index';
    final routeLabel = PlaceRouteLabel.label(leg.startPlace, leg.endPlace);
    return InkWell(
      onTap: onTap,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 22,
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: cx.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  // The trailing leg's line stops at its own node — a connector
                  // running past the last leg implies another one is coming.
                  Expanded(
                    child: Container(
                      width: 1.5,
                      color: isLast ? Colors.transparent : cx.border,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 8, 0, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _Highlighted(
                            text: name,
                            query: query,
                            style: TextStyle(
                              color: cx.textBright,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${unit.distanceMeters(leg.totalDistanceMeters).toStringAsFixed(2)} ${unit.distanceLabel}',
                          style: TextStyle(
                            color: cx.textDim,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFeatures: kTabularFigures,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        _formatDate(leg.startTime),
                        ?routeLabel,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cx.textTertiary,
                        fontSize: kMinFontSize,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The one quiet line a card ends on: when, how long, and the two speeds.
///
/// Every value the same size and the same neutral colour — the card's job is to
/// be scanned, and five equally-loud numbers in a four-column grid was the
/// opposite of that. Peak carries the neutral [AppPalette.peak], never red.
///
/// Moving time is deliberately *not* here. With it the line ran to 61 characters
/// and wrapped, stranding "peak km/h" alone on a second row — and the
/// elapsed/moving split is a detail the detail screen exists for.
class _MetricsLine extends StatelessWidget {
  const _MetricsLine({
    required this.date,
    required this.durationSeconds,
    required this.avgKmh,
    required this.maxKmh,
    required this.unit,
  });

  final String date;
  final int durationSeconds;
  final double avgKmh;
  final double maxKmh;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final dim = TextStyle(color: cx.textTertiary, fontSize: kMinFontSize);
    final value = TextStyle(
      color: cx.textDim,
      fontSize: kMinFontSize,
      fontWeight: FontWeight.w600,
      fontFeatures: kTabularFigures,
    );
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: date, style: dim),
          TextSpan(text: '  ·  ', style: dim),
          TextSpan(text: _fmtDuration(durationSeconds), style: value),
          TextSpan(text: '  ·  ', style: dim),
          TextSpan(text: unit.speed(avgKmh).toStringAsFixed(0), style: value),
          TextSpan(text: ' avg  ·  ', style: dim),
          TextSpan(
            text: unit.speed(maxKmh).toStringAsFixed(0),
            style: value.copyWith(color: cx.peak),
          ),
          TextSpan(text: ' peak ${unit.speedLabel}', style: dim),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// [text] with every occurrence of [query] picked out in amber.
///
/// Search that returns rows without saying *why* they matched makes the rider
/// re-read each one; highlighting answers it at a glance.
class _Highlighted extends StatelessWidget {
  const _Highlighted({
    required this.text,
    required this.query,
    required this.style,
  });

  final String text;
  final String query;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final cx = AppColors.of(context);
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    var i = 0;
    while (true) {
      final hit = lower.indexOf(query, i);
      if (hit < 0) {
        spans.add(TextSpan(text: text.substring(i)));
        break;
      }
      if (hit > i) spans.add(TextSpan(text: text.substring(i, hit)));
      spans.add(TextSpan(
        text: text.substring(hit, hit + query.length),
        style: TextStyle(color: cx.accentInk, fontWeight: FontWeight.w800),
      ));
      i = hit + query.length;
    }
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
  }
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// e.g. `Jul 2 · 22:36`. The year is carried by the month header above, so the
/// row doesn't repeat it. Avoids pulling in the intl package.
String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${_shortMonths[local.month - 1]} ${local.day} · $hh:$mm';
}

String _fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
