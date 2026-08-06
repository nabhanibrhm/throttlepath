import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/date_format.dart';
import '../core/duration_format.dart';
import '../core/units.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/ride_stats.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../theme/app_theme.dart';
import 'hairline_row.dart';
import 'place_route_label.dart';
import 'ride_detail_screen.dart';
import 'trip_detail_screen.dart';
import 'week_strip.dart';

/// The rides list: this week's totals above a searchable, month-grouped history.
///
/// Each row leads with the name, then the place, then one metadata line, with the
/// distance right-aligned on a shared axis so the distances read as a scannable
/// column (spec 6.3). Rows are separated by a hairline rather than enclosed in
/// cards — see [HairlineRow] for why. Trips render as one row that expands to
/// show its stints (F21).
///
/// The route sparkline that used to sit in every row is gone (spec 6.1): it cost
/// ~60dp of vertical space per row, which is most of a row, and a route's shape
/// is what the detail screen and the share card are for. [RouteSparkline] itself
/// stays — the post-ride summary still uses it.
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

/// How long the Undo window stays open after a swipe-delete.
const Duration _kUndoWindow = Duration(seconds: 6);

/// Collapsed toolbar height, and the room the week strip gets above it.
///
/// The strip lost its card in the minimal pass, so it is two plain lines now —
/// a 30sp figure plus a 12sp sentence, ~60dp in Inter; this reserves a little
/// more. It is *not* imposed on the strip — see `_appBar` — so a larger system
/// text scale clips at the bottom instead of throwing an overflow.
const double _kToolbarHeight = 56;
const double _kStripHeight = 70;

/// The width every row's distance is right-aligned within, so the figures form a
/// column the eye can run down instead of landing wherever each name ended
/// (spec 6.3). Wide enough for "187.65" plus its unit at 18sp.
const double _kDistanceColumnWidth = 78;

/// What the filter chips select.
enum _Filter {
  all('All'),
  rides('Rides'),
  trips('Trips'),
  thisMonth('This month');

  const _Filter(this.label);
  final String label;
}

/// One month's worth of list entries, with the header total.
typedef _MonthGroup = ({String label, double meters, List<_Entry> entries});

/// Everything the History list derives from the raw rides + trips for one build.
typedef _ListModel = ({
  /// Rides and finished trips merged and sorted newest-first, before searching.
  List<_Entry> all,

  /// The lower-cased search text, also handed to the cards so they can highlight
  /// the matched substring.
  String query,

  /// What survives both the search and the selected filter chip.
  List<_Entry> visible,
  List<_MonthGroup> groups,
  Map<_Filter, int> counts,
});

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
    final model = _derive(rides, finishedTrips);

    if (model.all.isEmpty && openTrips.isEmpty) {
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
              padding: const EdgeInsets.fromLTRB(kRowGutter, 12, kRowGutter, 0),
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
            padding: const EdgeInsets.fromLTRB(kRowGutter, 12, kRowGutter, 4),
            child: _FilterRow(
              selected: _filter,
              counts: model.counts,
              onSelect: (f) => setState(() => _filter = f),
            ),
          ),
        ),
        for (final t in openTrips)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(kRowGutter, 12, kRowGutter, 0),
              child: _OpenTripCard(
                summary: t,
                unit: unit,
                onContinue: () => _continueTrip(t),
                onTap: () => _openTrip(t),
              ),
            ),
          ),
        if (model.visible.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(kRowGutter, 40, kRowGutter, 40),
              child: Text(
                model.query.isEmpty
                    ? 'Nothing filed under ${_filter.label.toLowerCase()}.'
                    : 'No rides match “${_search.text.trim()}”.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cx.textDim, fontSize: 14),
              ),
            ),
          ),
        for (final group in model.groups)
          SliverList(
            delegate: SliverChildListDelegate([
              SectionLabel(
                label: group.label,
                trailing: '${unit.distanceMeters(group.meters)
                    .toStringAsFixed(0)} ${unit.distanceLabel}',
              ),
              for (final entry in group.entries)
                _entryRow(entry, unit, model.query),
            ]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Everything the list derives from the raw rides + trips: the merged and
  /// date-sorted entries, what survives the search and the filter chip, and the
  /// per-chip counts.
  ///
  /// Re-run on every keystroke (search calls `setState`), so it is deliberately
  /// one pass per stage over an entry count in the hundreds — not the track-point
  /// scale where that would matter.
  _ListModel _derive(List<Ride> rides, List<TripSummary> finishedTrips) {
    final all = <_Entry>[
      for (final t in finishedTrips) _TripEntry(t),
      for (final r in rides)
        if (!_pendingDelete.contains(r.id)) _RideEntry(r),
    ]..sort((a, b) => b.when.compareTo(a.when));

    final query = _search.text.trim().toLowerCase();
    final matched = query.isEmpty
        ? all
        : all.where((e) => e.matches(query)).toList(growable: false);
    final visible = matched.where(_filter.accepts).toList(growable: false);

    return (
      all: all,
      query: query,
      visible: visible,
      groups: _groupByMonth(visible),
      // Counts are over the *searched* set, not the whole history — a chip
      // reading "Trips 3" that yields nothing once tapped is worse than no count.
      counts: {
        for (final f in _Filter.values) f: matched.where(f.accepts).length,
      },
    );
  }

  Widget _entryRow(_Entry entry, SpeedUnit unit, String query) =>
      switch (entry) {
        _RideEntry(:final ride) => _RideRow(
            ride: ride,
            unit: unit,
            query: query,
            onTap: () => _openRide(ride),
            onDelete: () => _deleteWithUndo(ride),
          ),
        _TripEntry(:final summary) => _TripRow(
            summary: summary,
            unit: unit,
            query: query,
            onTap: () => _openTrip(summary),
            onOpenStint: _openRide,
          ),
      };

  /// Arms the next recording as this trip's next stint, then jumps to Record.
  void _continueTrip(TripSummary t) {
    ref
        .read(trackingControllerProvider.notifier)
        .beginContinuation(t.trip.id, t.trip.name);
    ref.read(homeTabProvider.notifier).state = 0; // Record tab
  }

  void _openTrip(TripSummary t) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TripDetailScreen(trip: t.trip)),
      );

  void _openRide(Ride r) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => RideDetailScreen(ride: r)),
      );

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
                left: kRowGutter,
                right: kRowGutter,
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
                left: kRowGutter,
                right: 4,
                top: top,
                height: _kToolbarHeight,
                child: Row(
                  children: [
                    Text('Rides', style: Theme.of(context).textTheme.titleLarge),
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
        for (final stint in summary.stats.stints) ...[
          stint.name,
          stint.startPlace,
          stint.endPlace,
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
List<_MonthGroup> _groupByMonth(
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
        label: '${longMonth(local.month)} ${local.year}',
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
          final ink =
              on ? cx.onAccent : (count == 0 ? cx.textTertiary : cx.textBright);
          return Semantics(
            button: true,
            selected: on,
            label: '${f.label}, $count',
            child: ExcludeSemantics(
              child: Material(
                // Unselected chips go transparent-on-outline (spec 5.3): a row
                // of four filled chips reads as four buttons, when only one of
                // them is on.
                color: on ? cx.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                child: InkWell(
                  // A chip that would empty the list is not a filter, it's a
                  // dead end — leave it visible (the count explains why) but
                  // don't let it be selected.
                  onTap: count == 0 && !on ? null : () => onSelect(f),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: on ? cx.accent : cx.border),
                    ),
                    child: Text.rich(
                      TextSpan(
                        text: f.label,
                        children: [
                          // The count is the chip's supporting detail, not half
                          // its label — it steps down in weight and opacity so
                          // "Rides" still reads as the word being tapped.
                          TextSpan(
                            text: '  $count',
                            style: TextStyle(
                              color: ink.withValues(alpha: 0.6),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      style: TextStyle(
                        color: ink,
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

// The running-total line that used to sit under the chips ("7 results · 214.6
// km") is gone (spec 5.2) — every chip already carries its own count, and the
// line restated the selected one directly beneath it. The month headers still
// carry per-month totals, so the arithmetic didn't leave with it.
//
// `_MonthHeader` is gone too: it was `SectionLabel` with different padding, and
// now that Settings needs the same shape it lives in `hairline_row.dart`.

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
/// stints so far with a Continue button that resumes the trip on the Record tab.
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
    final stintCount = stats.stintCount;
    final stintLabel = stintCount == 1 ? '1 stint' : '$stintCount stints';
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
                '$stintLabel · $distance · ${formatDuration(stats.durationSeconds)}',
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

/// The distance every row is read by, right-aligned inside a fixed column so the
/// figures line up down the list (spec 6.3).
///
/// Neutral, not amber: with one of these on every row the amber stopped pointing
/// at anything (G2). The screen's single accent is the week total up top.
class _DistanceBlock extends StatelessWidget {
  const _DistanceBlock({
    required this.meters,
    required this.unit,
    this.style,
  });

  final double meters;
  final SpeedUnit unit;

  /// Overridden by nested stints, which sit a step down from their parent.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return SizedBox(
      width: _kDistanceColumnWidth,
      child: Text.rich(
        TextSpan(
          text: unit.distanceMeters(meters).toStringAsFixed(2),
          children: [
            TextSpan(
              text: ' ${unit.distanceLabel}',
              style: TextStyle(
                color: cx.textDim,
                fontSize: kMinFontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        textAlign: TextAlign.right,
        maxLines: 1,
        style: style ?? t.headlineSmall!.copyWith(color: cx.textBright),
      ),
    );
  }
}

/// A saved ride: name, place, one metadata line, and the distance on the shared
/// right-hand axis.
///
/// The old card gave name, date, distance and a four-column stat grid all
/// competing at the same weight, and painted PEAK in red on every single row
/// (F20). The redesign takes one more thing away — the route sparkline, which was
/// costing ~56dp per row for a shape the detail screen shows properly (spec 6.1).
class _RideRow extends StatelessWidget {
  const _RideRow({
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
    final t = Theme.of(context).textTheme;
    final named = ride.name?.trim().isNotEmpty == true;
    final name = named ? ride.name!.trim() : 'Untitled ride';
    final routeLabel = PlaceRouteLabel.label(ride.startPlace, ride.endPlace);

    return Dismissible(
      key: ValueKey(ride.id),
      direction: DismissDirection.endToStart,
      // No confirm dialog: the row leaves at once and the Undo snackbar is the
      // safety net. A modal on every swipe made deleting slower than the mistake
      // it was guarding against (F23).
      onDismissed: (_) => onDelete(),
      // Square and full-bleed now that the row it reveals is too — a rounded
      // background behind a square row shows its corners through the gap.
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: cx.danger.withValues(alpha: 0.18),
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
      child: HairlineRow(
        onTap: onTap,
        // Matches the trip row, whose chevron is a real 44dp control — so the
        // distance column lands on the same axis in both and the figures line up
        // down a mixed list.
        trailingGutter: 0,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Highlighted(
                    text: name,
                    query: query,
                    // An untitled ride is dimmed rather than given its own
                    // wording or badge — the absence *is* the information, and
                    // it should not shout louder than a name someone chose.
                    style: t.titleMedium!.copyWith(
                      color: named ? cx.textBright : cx.textDim,
                    ),
                  ),
                  if (routeLabel != null) ...[
                    const SizedBox(height: 3),
                    _Highlighted(
                      text: routeLabel,
                      query: query,
                      // The pin icon went with the card: at 14px beside 12px
                      // text it was the loudest thing in the row, and "A → B"
                      // already reads as a place without one.
                      style: t.bodySmall!.copyWith(color: cx.textDim),
                    ),
                  ],
                  const SizedBox(height: 3),
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
            const SizedBox(width: 12),
            _DistanceBlock(meters: ride.totalDistanceMeters, unit: unit),
            // Decorative: the whole row opens the ride, so this only says the
            // row leads somewhere. Excluded from semantics — the row is already
            // announced as a button. Sized to the trip row's real control so the
            // distance columns agree.
            ExcludeSemantics(
              child: SizedBox(
                width: 44,
                child: Center(
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    // Between `border` (which would be invisible) and
                    // `textTertiary` (which would compete with the metadata it
                    // sits beside). Alpha rather than a new token: this is one
                    // decoration, not a colour the design needs a name for.
                    color: cx.textTertiary.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A finished trip: one row that reads like any other, distinguished only by a
/// `TRIP · N stints` label before the name, expanding in place to its stints (F21).
///
/// The old card wore three separate badges of trip-ness — an amber bar down the
/// left edge, an `alt_route` icon, and a full-width "Show 2 stints" button across
/// the bottom — to say one thing. Now the label says it and the row's own chevron
/// does the expanding (spec 6.4), which also means a trip costs the list the same
/// height as a ride until someone asks it not to.
class _TripRow extends StatefulWidget {
  const _TripRow({
    required this.summary,
    required this.unit,
    required this.query,
    required this.onTap,
    required this.onOpenStint,
  });

  final TripSummary summary;
  final SpeedUnit unit;
  final String query;
  final VoidCallback onTap;
  final void Function(Ride stint) onOpenStint;

  @override
  State<_TripRow> createState() => _TripRowState();
}

class _TripRowState extends State<_TripRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final stats = widget.summary.stats;
    final unit = widget.unit;
    final name = widget.summary.trip.name?.trim();
    final named = name?.isNotEmpty == true;
    final stintLabel =
        stats.stintCount == 1 ? '1 stint' : '${stats.stintCount} stints';
    final expandable = stats.stintCount > 0;

    return Column(
      children: [
        HairlineRow(
          onTap: widget.onTap,
          // The chevron owns the right-hand edge and needs its full 48dp, so the
          // row gives up its own trailing gutter to it.
          trailingGutter: 0,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // The one amber thing in the row, and the only thing
                        // that has to survive at a glance: this entry is not a
                        // ride, it is several.
                        Text(
                          'TRIP · ${stintLabel.toUpperCase()}',
                          style: t.labelSmall!.copyWith(
                            color: cx.accentInk,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    _Highlighted(
                      text: named ? name! : 'Untitled trip',
                      query: widget.query,
                      style: t.titleMedium!.copyWith(
                        color: named ? cx.textBright : cx.textDim,
                      ),
                    ),
                    const SizedBox(height: 3),
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
              const SizedBox(width: 12),
              _DistanceBlock(meters: stats.totalDistanceMeters, unit: unit),
              // Unlike a ride's decorative chevron this one is a real control,
              // so it gets a real target: 44dp square, not a 16dp glyph. It does
              // *not* get its own colour, though — an amber chevron here put a
              // second amber on every trip row beside the TRIP label (G2), and
              // on device the two together read as a play button. The label
              // already says this entry is several rides; the chevron only has
              // to say it moves, which the flip to an up-arrow does.
              if (expandable)
                Semantics(
                  button: true,
                  expanded: _expanded,
                  label: _expanded ? 'Hide $stintLabel' : 'Show $stintLabel',
                  child: InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    customBorder: const CircleBorder(),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: Icon(
                          _expanded
                              ? Icons.keyboard_arrow_up
                              : Icons.chevron_right,
                          size: 18,
                          color: cx.textTertiary,
                        ),
                      ),
                    ),
                  ),
                )
              else
                const SizedBox(width: kRowGutter),
            ],
          ),
        ),
        if (_expanded)
          for (var i = 0; i < stats.stints.length; i++)
            _StintRow(
              stint: stats.stints[i],
              index: i + 1,
              unit: unit,
              query: widget.query,
              onTap: () => widget.onOpenStint(stats.stints[i]),
            ),
      ],
    );
  }
}

/// One nested stint, indented behind a rail (spec 6.5).
///
/// The numbered dots and per-stint connector segments are gone: a single unbroken
/// rail down the left says "these belong to the row above, in this order" with one
/// line instead of one widget per stint, and the stints are already listed in
/// order — the numbers were labelling their own position.
///
/// No hairline of its own. The rail is the separator here, and a rule as well
/// would draw a grid.
class _StintRow extends StatelessWidget {
  const _StintRow({
    required this.stint,
    required this.index,
    required this.unit,
    required this.query,
    required this.onTap,
  });

  final Ride stint;
  final int index;
  final SpeedUnit unit;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final name = stint.name?.trim().isNotEmpty == true
        ? stint.name!.trim()
        : 'Stint $index';
    final routeLabel = PlaceRouteLabel.label(stint.startPlace, stint.endPlace);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: kRowGutter),
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: cx.border)),
            ),
            // Right padding is the parent row's 44dp chevron slot, not the
            // shared gutter: the parent's distance is inset by that chevron, so
            // matching the gutter here would leave the stint figures 26dp
            // further right than the total they belong to. Caught on device —
            // the misalignment is invisible until a trip is actually expanded.
            padding: const EdgeInsets.fromLTRB(14, 9, 44, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Highlighted(
                        text: name,
                        query: query,
                        style: TextStyle(
                          color: cx.textBright,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [_formatDate(stint.startTime), ?routeLabel].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Same 78dp axis as the parent rows, a step down in weight — so
                // a stint's distance still lines up under the trip's total.
                _DistanceBlock(
                  meters: stint.totalDistanceMeters,
                  unit: unit,
                  style: TextStyle(
                    color: cx.textDim,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    fontFeatures: kTabularFigures,
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

/// The one quiet line a row ends on: when, how long, and the two speeds.
///
/// **One style, start to finish** (G3). It used to mix w600 values against w400
/// separators and paint peak in its own colour, which made a row's least
/// important line its most visually complicated. A rider scans this line or
/// ignores it; nothing in it needs to win.
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
    return Text(
      [
        date,
        formatDuration(durationSeconds),
        '${unit.speed(avgKmh).toStringAsFixed(0)} avg',
        '${unit.speed(maxKmh).toStringAsFixed(0)} peak ${unit.speedLabel}',
      ].join('  ·  '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodySmall,
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

/// e.g. `Jul 2 · 22:36`. The year is carried by the month header above, so the
/// row doesn't repeat it. Avoids pulling in the intl package.
String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${shortMonth(local.month)} ${local.day} · $hh:$mm';
}
