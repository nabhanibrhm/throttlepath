import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

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
import 'no_track_notice.dart';
import 'place_route_label.dart';
import 'rename_dialog.dart';
import 'ride_detail_screen.dart';
import 'share_flow.dart';
import 'tracking_map_screen.dart' show basemapUrl;

/// Distinct per-leg route hues, cycled by leg index. Theme-independent so the
/// legs stay tellable apart on both the light and dark basemaps.
const _legColors = <Color>[
  Color(0xFFFFB300), // amber
  Color(0xFF29B6F6), // light blue
  Color(0xFF66BB6A), // green
  Color(0xFFAB47BC), // purple
  Color(0xFFFF7043), // deep orange
  Color(0xFFEC407A), // pink
];

Color _legColor(int i) => _legColors[i % _legColors.length];

/// Detail view for a whole trip: every leg drawn on one map (each its own hue),
/// combined stats, and the ordered list of legs (tap one to open it as a ride).
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
  /// existing layouts, with the legs' tracks concatenated and [legStarts]
  /// marking the joins so each leg draws as its own colored polyline.
  Future<void> _shareTrip() async {
    if (_sharing) return;
    final legTracks = ref.read(tripLegsProvider(widget.trip.id)).valueOrNull;
    if (legTracks == null || legTracks.isEmpty) return;

    final stats = TripStats.fromLegs([for (final lt in legTracks) lt.leg]);
    final combined =
        stats.toCombinedRide(tripId: widget.trip.id, name: _name);
    final points = [for (final lt in legTracks) ...lt.track];
    final legStarts = <int>[];
    var acc = 0;
    for (final lt in legTracks) {
      if (acc > 0) legStarts.add(acc);
      acc += lt.track.length;
    }

    await showShareFlow(
      context,
      ride: combined,
      points: points,
      unit: ref.read(speedUnitProvider),
      legStarts: legStarts,
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
    ref.invalidate(tripLegsProvider(widget.trip.id));
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

  /// Renames the trip. A trip's name is independent of its legs' names, so this
  /// leaves every leg untouched.
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

  /// Renames one leg (a [Ride]) — never the trip.
  Future<void> _renameLeg(Ride leg, int index) async {
    final next = await showRenameDialog(
      context,
      title: 'Rename leg ${index + 1}',
      initial: leg.name,
      hint: 'Leg name (e.g. Berangkat)',
    );
    if (next == null || !mounted) return;
    setState(() => _busy = true);
    await DatabaseService.instance.setRideName(leg.id, next);
    _invalidateHistory();
    if (mounted) setState(() => _busy = false);
  }

  /// Resumes the trip: arms the next-leg continuation and drops the rider back
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
    final legsAsync = ref.watch(tripLegsProvider(widget.trip.id));
    final name = _name?.trim();
    final canShare = legsAsync.valueOrNull?.isNotEmpty == true;

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        centerTitle: true,
        shape: Border(bottom: BorderSide(color: cx.border)),
        title: Text(
          name?.isNotEmpty == true ? name! : 'Trip',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        actions: [
          if (_busy || _sharing)
            Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.2, color: cx.accentInk),
                ),
              ),
            )
          else ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: 'Share trip',
              onPressed: canShare ? _shareTrip : null,
            ),
            PopupMenuButton<String>(
              color: cx.surface,
              icon: Icon(Icons.more_vert, color: cx.textBright),
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _renameTrip();
                  case 'continue':
                    _continue();
                  case 'finish':
                    _finish();
                  case 'reopen':
                    _reopen();
                }
              },
              itemBuilder: (_) => [
                _menuItem('rename', Icons.edit_outlined, 'Rename trip', cx),
                if (_isOpen) ...[
                  _menuItem('continue', Icons.play_arrow, 'Continue trip', cx),
                  _menuItem('finish', Icons.flag, 'Finish trip', cx),
                ] else
                  _menuItem('reopen', Icons.lock_open, 'Reopen trip', cx),
              ],
            ),
          ],
        ],
      ),
      body: legsAsync.when(
        loading: () =>
            Center(child: CircularProgressIndicator(color: cx.accentInk)),
        error: (e, _) => Center(
          child: Text('Could not load trip:\n$e',
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.dangerInk)),
        ),
        data: (legTracks) {
          final stats =
              TripStats.fromLegs([for (final lt in legTracks) lt.leg]);
          return Column(
            children: [
              if (_isOpen) _OpenBadge(cx: cx),
              SizedBox(
                height: 300,
                child: _TripMap(legTracks: legTracks),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _TripSummaryPanel(stats: stats, unit: unit),
                      _LegList(
                        legTracks: legTracks,
                        unit: unit,
                        onOpenLeg: (leg) => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => RideDetailScreen(ride: leg),
                          ),
                        ),
                        onRenameLeg: _renameLeg,
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

  PopupMenuItem<String> _menuItem(
      String value, IconData icon, String label, AppPalette cx) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: cx.accentInk, size: 18),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: cx.textBright)),
        ],
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

/// The combined route map: each leg its own colored polyline, a start dot, an
/// end dot, and neutral turnaround dots at the joins between legs.
class _TripMap extends StatelessWidget {
  const _TripMap({required this.legTracks});

  final List<LegTrack> legTracks;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);

    // Per-leg polylines + the flattened point set for the camera fit.
    final polylines = <Polyline>[];
    final allPoints = <LatLng>[];
    final legLatLngs = <List<LatLng>>[];
    for (var i = 0; i < legTracks.length; i++) {
      final pts = [
        for (final p in legTracks[i].track) LatLng(p.latitude, p.longitude)
      ];
      legLatLngs.add(pts);
      allPoints.addAll(pts);
      if (pts.length >= 2) {
        polylines.add(Polyline(points: pts, strokeWidth: 5, color: _legColor(i)));
      }
    }

    if (allPoints.isEmpty) {
      return const NoTrackNotice(subject: 'trip');
    }

    // Endpoints: first point of the first non-empty leg, last of the last.
    final firstLeg = legLatLngs.firstWhere((p) => p.isNotEmpty, orElse: () => const []);
    final lastLeg = legLatLngs.lastWhere((p) => p.isNotEmpty, orElse: () => const []);
    final start = firstLeg.isNotEmpty ? firstLeg.first : allPoints.first;
    final end = lastLeg.isNotEmpty ? lastLeg.last : allPoints.last;

    // Turnaround dots: the end of every leg except the last non-empty one.
    final lastNonEmpty = legLatLngs.lastIndexWhere((p) => p.isNotEmpty);
    final turnarounds = <LatLng>[
      for (var i = 0; i < legLatLngs.length; i++)
        if (i != lastNonEmpty && legLatLngs[i].isNotEmpty) legLatLngs[i].last,
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
    final legLabel = stats.legCount == 1 ? '1 leg' : '${stats.legCount} legs';
    return Container(
      width: double.infinity,
      color: cx.canvas,
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$legLabel · combined',
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
              _Stat(label: 'TOTAL TIME', value: _fmtDuration(stats.durationSeconds)),
              _Stat(label: 'MOVING TIME', value: _fmtDuration(stats.movingSeconds)),
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
            'LEGS',
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

/// Ordered leg rows, each a small card colored to match its map polyline;
/// tapping one opens that leg as a normal ride.
class _LegList extends StatelessWidget {
  const _LegList({
    required this.legTracks,
    required this.unit,
    required this.onOpenLeg,
    required this.onRenameLeg,
  });

  final List<LegTrack> legTracks;
  final SpeedUnit unit;
  final ValueChanged<Ride> onOpenLeg;
  final void Function(Ride leg, int index) onRenameLeg;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          for (var i = 0; i < legTracks.length; i++) ...[
            _LegRow(
              index: i,
              leg: legTracks[i].leg,
              unit: unit,
              onTap: () => onOpenLeg(legTracks[i].leg),
              onRename: () => onRenameLeg(legTracks[i].leg, i),
            ),
            if (i < legTracks.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _LegRow extends StatelessWidget {
  const _LegRow({
    required this.index,
    required this.leg,
    required this.unit,
    required this.onTap,
    required this.onRename,
  });

  final int index;
  final Ride leg;
  final SpeedUnit unit;
  final VoidCallback onTap;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = leg.name?.trim();
    return Material(
      color: cx.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        // Long-press renames this leg in place — the same action lives in the
        // leg's own detail screen for discoverability.
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
                  color: _legColor(index),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LEG ${index + 1}',
                      style: TextStyle(
                        color: cx.textTertiary,
                        fontSize: 12,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      name?.isNotEmpty == true ? name! : 'Untitled leg',
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
                      '${_fmtDuration(leg.durationSeconds)} · '
                      '${unit.speed(leg.averageSpeedKmh).toStringAsFixed(0)} '
                      '${unit.speedLabel} avg',
                      style: TextStyle(color: cx.textDim, fontSize: 12),
                    ),
                    // Where this leg actually went. Collapses to nothing when
                    // neither end geocoded (offline saves, old rides).
                    if (PlaceRouteLabel.label(
                          leg.startPlace,
                          leg.endPlace,
                        ) !=
                        null) ...[
                      const SizedBox(height: 4),
                      PlaceRouteLabel(
                        startPlace: leg.startPlace,
                        endPlace: leg.endPlace,
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
                      .distanceMeters(leg.totalDistanceMeters)
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

String _fmtDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
