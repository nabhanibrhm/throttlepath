import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/duration_format.dart';
import '../core/units.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/models/trip.dart';
import '../data/trip_stats.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../theme/app_theme.dart';
import 'detail_app_bar.dart';
import 'no_track_notice.dart';
import 'place_route_label.dart';
import 'rename_dialog.dart';
import 'ride_detail_screen.dart';
import 'share_flow.dart';
import 'tracking_map_screen.dart' show basemapUrl;

/// Distinct per-stint route hues, cycled by stint index. Theme-independent so the
/// stints stay tellable apart on both the light and dark basemaps.
const _stintColors = <Color>[
  Color(0xFFFFB300), // amber
  Color(0xFF29B6F6), // light blue
  Color(0xFF66BB6A), // green
  Color(0xFFAB47BC), // purple
  Color(0xFFFF7043), // deep orange
  Color(0xFFEC407A), // pink
];

Color _stintColor(int i) => _stintColors[i % _stintColors.length];

/// Detail view for a whole trip: every stint drawn on one map (each its own hue),
/// combined stats, and the ordered list of stints (tap one to open it as a ride).
/// Open trips can be continued or finished here; finished trips can be reopened.
class TripDetailScreen extends ConsumerStatefulWidget {
  const TripDetailScreen({super.key, required this.trip});

  final Trip trip;

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen> {
  // Local mirror of the trip's open/closed state so the actions update in place
  // after Finish/Reopen without leaving the screen.
  late DateTime? _finishedAt = widget.trip.finishedAt;

  /// Local mirror of the trip's name, so a rename shows in the app bar (and in
  /// the share card) without popping back to History.
  late String? _name = widget.trip.name;
  bool _busy = false;
  bool _sharing = false;

  bool get _isOpen => _finishedAt == null;

  /// Shares the whole trip as one card: a synthesized combined [Ride] fed to the
  /// existing layouts, with the stints' tracks concatenated and [stintStarts]
  /// marking the joins so each stint draws as its own colored polyline.
  Future<void> _shareTrip() async {
    if (_sharing) return;
    final stintTracks = ref.read(tripStintsProvider(widget.trip.id)).valueOrNull;
    if (stintTracks == null || stintTracks.isEmpty) return;

    final stats = TripStats.fromStints([for (final lt in stintTracks) lt.stint]);
    final combined =
        stats.toCombinedRide(tripId: widget.trip.id, name: _name);
    final points = [for (final lt in stintTracks) ...lt.track];
    final stintStarts = <int>[];
    var acc = 0;
    for (final lt in stintTracks) {
      if (acc > 0) stintStarts.add(acc);
      acc += lt.track.length;
    }

    await showShareFlow(
      context,
      ride: combined,
      points: points,
      unit: ref.read(speedUnitProvider),
      stintStarts: stintStarts,
      subject: 'trip',
      onBusyChanged: (b) {
        if (mounted) setState(() => _sharing = b);
      },
    );
  }

  void _invalidateHistory() {
    ref.invalidate(rideHistoryProvider);
    ref.invalidate(openTripsProvider);
    ref.invalidate(finishedTripsProvider);
    ref.invalidate(tripStintsProvider(widget.trip.id));
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    await DatabaseService.instance.finishTrip(widget.trip.id);
    _invalidateHistory();
    if (mounted) {
      setState(() {
        _finishedAt = DateTime.now();
        _busy = false;
      });
    }
  }

  Future<void> _reopen() async {
    if (_busy) return;
    setState(() => _busy = true);
    await DatabaseService.instance.reopenTrip(widget.trip.id);
    _invalidateHistory();
    if (mounted) {
      setState(() {
        _finishedAt = null;
        _busy = false;
      });
    }
  }

  /// Renames the trip. A trip's name is independent of its stints' names, so this
  /// leaves every stint untouched.
  Future<void> _renameTrip() async {
    final next = await showRenameDialog(
      context,
      title: 'Rename trip',
      initial: _name,
      hint: 'Trip name (e.g. Ride to Puncak)',
    );
    if (next == null || !mounted) return;
    setState(() => _busy = true);
    await DatabaseService.instance.setTripName(widget.trip.id, next);
    widget.trip.name = next; // keep the pushed-in object consistent
    _invalidateHistory();
    if (mounted) {
      setState(() {
        _name = next;
        _busy = false;
      });
    }
  }

  /// Renames one stint (a [Ride]) — never the trip.
  Future<void> _renameStint(Ride stint, int index) async {
    final next = await showRenameDialog(
      context,
      title: 'Rename stint ${index + 1}',
      initial: stint.name,
      hint: 'Stint name (e.g. Berangkat)',
    );
    if (next == null || !mounted) return;
    setState(() => _busy = true);
    await DatabaseService.instance.setRideName(stint.id, next);
    _invalidateHistory();
    if (mounted) setState(() => _busy = false);
  }

  /// Resumes the trip: arms the next-stint continuation and drops the rider back
  /// on the Record tab.
  void _continue() {
    ref
        .read(trackingControllerProvider.notifier)
        .beginContinuation(widget.trip.id, _name);
    ref.read(homeTabProvider.notifier).state = 0; // Record tab
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final unit = ref.watch(speedUnitProvider);
    final stintsAsync = ref.watch(tripStintsProvider(widget.trip.id));
    final name = _name?.trim();
    final canShare = stintsAsync.valueOrNull?.isNotEmpty == true;

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: DetailAppBar(
        title: name?.isNotEmpty == true ? name! : 'Trip',
        onRename: _renameTrip,
        renameTooltip: 'Rename trip',
        busy: _busy || _sharing,
        onShare: canShare ? _shareTrip : null,
        shareTooltip: 'Share trip',
        onMenuSelected: (v) {
          switch (v) {
            case 'continue':
              _continue();
            case 'finish':
              _finish();
            case 'reopen':
              _reopen();
          }
        },
        menuItems: [
          if (_isOpen) ...[
            const DetailMenuItem(
              value: 'continue',
              icon: Icons.play_arrow,
              label: 'Add the next stint',
            ),
            const DetailMenuItem(
              value: 'finish',
              icon: Icons.flag,
              label: 'Finish trip',
            ),
          ] else
            // Was "Reopen trip" — a name for the state change rather than for
            // what the rider came to do. Reopening is never the goal; adding
            // another stint is, and reopening is just what it takes.
            const DetailMenuItem(
              value: 'reopen',
              icon: Icons.lock_open,
              label: 'Add the next stint',
            ),
        ],
      ),
      body: stintsAsync.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: cx.accentInk)),
        error: (e, _) => Center(
          child: Text('Could not load trip:\n$e',
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.dangerInk)),
        ),
        data: (stintTracks) {
          final stats =
              TripStats.fromStints([for (final lt in stintTracks) lt.stint]);
          return Column(
            children: [
              if (_isOpen) _OpenBadge(cx: cx),
              SizedBox(
                height: 300,
                child: _TripMap(stintTracks: stintTracks),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _TripSummaryPanel(stats: stats, unit: unit),
                      _StintList(
                        stintTracks: stintTracks,
                        unit: unit,
                        onOpenStint: (stint) => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RideDetailScreen(ride: stint),
                          ),
                        ),
                        onRenameStint: _renameStint,
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

}

/// Thin "OPEN — CONTINUABLE" strip shown above the map for an open trip.
class _OpenBadge extends StatelessWidget {
  const _OpenBadge({required this.cx});
  final AppPalette cx;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: cx.accent.withValues(alpha: 0.14),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(
        'OPEN TRIP · CONTINUABLE',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: cx.accentInk,
          fontSize: 12,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// The combined route map: each stint its own colored polyline, a start dot, an
/// end dot, and neutral turnaround dots at the joins between stints.
class _TripMap extends StatelessWidget {
  const _TripMap({required this.stintTracks});

  final List<StintTrack> stintTracks;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);

    // Per-stint polylines + the flattened point set for the camera fit.
    final polylines = <Polyline>[];
    final allPoints = <LatLng>[];
    final stintLatLngs = <List<LatLng>>[];
    for (var i = 0; i < stintTracks.length; i++) {
      final pts = [
        for (final p in stintTracks[i].track) LatLng(p.latitude, p.longitude)
      ];
      stintLatLngs.add(pts);
      allPoints.addAll(pts);
      if (pts.length >= 2) {
        polylines.add(Polyline(points: pts, strokeWidth: 5, color: _stintColor(i)));
      }
    }

    if (allPoints.isEmpty) {
      return const NoTrackNotice(subject: 'trip');
    }

    // Endpoints: first point of the first non-empty stint, last of the last.
    final firstStint = stintLatLngs.firstWhere((p) => p.isNotEmpty, orElse: () => const []);
    final lastStint = stintLatLngs.lastWhere((p) => p.isNotEmpty, orElse: () => const []);
    final start = firstStint.isNotEmpty ? firstStint.first : allPoints.first;
    final end = lastStint.isNotEmpty ? lastStint.last : allPoints.last;

    // Turnaround dots: the end of every stint except the last non-empty one.
    final lastNonEmpty = stintLatLngs.lastIndexWhere((p) => p.isNotEmpty);
    final turnarounds = <LatLng>[
      for (var i = 0; i < stintLatLngs.length; i++)
        if (i != lastNonEmpty && stintLatLngs[i].isNotEmpty) stintLatLngs[i].last,
    ];

    return FlutterMap(
      options: MapOptions(
        backgroundColor: cx.canvas,
        initialCenter: start,
        initialZoom: 14,
        initialCameraFit: allPoints.length >= 2
            ? CameraFit.coordinates(
                coordinates: allPoints,
                padding: const EdgeInsets.all(44),
                maxZoom: 16,
              )
            : null,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: basemapUrl(cx.isDark),
          subdomains: const ['a', 'b', 'c', 'd'],
          userAgentPackageName: 'id.co.opentrack.throttlepath',
          tileProvider: NetworkTileProvider(silenceExceptions: true),
        ),
        if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
        MarkerLayer(
          markers: [
            for (final t in turnarounds) _dot(t, cx.textDim, 12),
            _dot(start, cx.accent, 18),
            _dot(end, cx.danger, 18),
          ],
        ),
      ],
    );
  }

  Marker _dot(LatLng point, Color color, double size) => Marker(
        point: point,
        width: size,
        height: size,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.5),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      );
}


/// Combined trip stats — distance, elapsed vs moving time, avg/max — matching
/// the ride-detail summary layout.
class _TripSummaryPanel extends StatelessWidget {
  const _TripSummaryPanel({required this.stats, required this.unit});

  final TripStats stats;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final stintLabel = stats.stintCount == 1 ? '1 stint' : '${stats.stintCount} stints';
    return Container(
      width: double.infinity,
      color: cx.canvas,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$stintLabel · combined',
            style: TextStyle(color: cx.textDim, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                unit.distanceMeters(stats.totalDistanceMeters).toStringAsFixed(2),
                style: TextStyle(
                  color: cx.textBright,
                  fontSize: 44,
                  height: 1,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(unit.distanceLabel,
                    style: TextStyle(color: cx.textDim, fontSize: 16)),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              _Stat(label: 'TOTAL TIME', value: formatDuration(stats.durationSeconds)),
              _Stat(label: 'MOVING TIME', value: formatDuration(stats.movingSeconds)),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _Stat(
                label: 'AVG SPEED',
                value: unit.speed(stats.averageSpeedKmh).toStringAsFixed(1),
                unit: unit.speedLabel,
              ),
              _Stat(
                label: 'PEAK SPEED',
                value: unit.speed(stats.maxSpeedKmh).toStringAsFixed(1),
                unit: unit.speedLabel,
                color: cx.peak,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: cx.border, height: 32),
          Text(
            'STINTS',
            style: TextStyle(
              color: cx.textTertiary,
              fontSize: 12,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Ordered stint rows, each a small card colored to match its map polyline;
/// tapping one opens that stint as a normal ride.
class _StintList extends StatelessWidget {
  const _StintList({
    required this.stintTracks,
    required this.unit,
    required this.onOpenStint,
    required this.onRenameStint,
  });

  final List<StintTrack> stintTracks;
  final SpeedUnit unit;
  final ValueChanged<Ride> onOpenStint;
  final void Function(Ride stint, int index) onRenameStint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          for (var i = 0; i < stintTracks.length; i++) ...[
            _StintRow(
              index: i,
              stint: stintTracks[i].stint,
              unit: unit,
              onTap: () => onOpenStint(stintTracks[i].stint),
              onRename: () => onRenameStint(stintTracks[i].stint, i),
            ),
            if (i < stintTracks.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _StintRow extends StatelessWidget {
  const _StintRow({
    required this.index,
    required this.stint,
    required this.unit,
    required this.onTap,
    required this.onRename,
  });

  final int index;
  final Ride stint;
  final SpeedUnit unit;
  final VoidCallback onTap;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = stint.name?.trim();
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        // Long-press renames this stint in place — the same action lives in the
        // stint's own detail screen for discoverability.
        onLongPress: onRename,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cx.border),
          ),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _stintColor(index),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'STINT ${index + 1}',
                      style: TextStyle(
                        color: cx.textTertiary,
                        fontSize: 12,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      name?.isNotEmpty == true ? name! : 'Untitled stint',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cx.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatDuration(stint.durationSeconds)} · '
                      '${unit.speed(stint.averageSpeedKmh).toStringAsFixed(0)} '
                      '${unit.speedLabel} avg',
                      style: TextStyle(color: cx.textDim, fontSize: 12),
                    ),
                    // Where this stint actually went. Collapses to nothing when
                    // neither end geocoded (offline saves, old rides).
                    if (PlaceRouteLabel.label(
                          stint.startPlace,
                          stint.endPlace,
                        ) !=
                        null) ...[
                      const SizedBox(height: 4),
                      PlaceRouteLabel(
                        startPlace: stint.startPlace,
                        endPlace: stint.endPlace,
                        fontSize: 12,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              RichText(
                text: TextSpan(
                  text: unit
                      .distanceMeters(stint.totalDistanceMeters)
                      .toStringAsFixed(2),
                  style: TextStyle(
                    color: cx.accentInk,
                    fontSize: 16,
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
              Icon(Icons.chevron_right, color: cx.textDim, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
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
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color ?? cx.textBright,
                  fontSize: 24,
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

