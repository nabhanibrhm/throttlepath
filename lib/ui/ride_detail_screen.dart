import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/geo.dart';
import '../core/units.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../providers/history_providers.dart';
import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';
import 'chart_frame.dart';
import 'detail_app_bar.dart';
import 'elevation_speed_chart.dart';
import 'no_track_notice.dart';
import 'place_route_label.dart';
import 'rename_dialog.dart';
import 'route_map_view.dart';
import 'share_flow.dart';
import 'smoothness_chart.dart';
import 'speed_distance_chart.dart';
import 'speed_zone_chart.dart';

/// Detail view for a saved ride: the recorded track replayed as a polyline on
/// the map, with the full summary stats below.
class RideDetailScreen extends ConsumerStatefulWidget {
  const RideDetailScreen({super.key, required this.ride});

  final Ride ride;

  @override
  ConsumerState<RideDetailScreen> createState() => _RideDetailScreenState();
}

class _RideDetailScreenState extends ConsumerState<RideDetailScreen> {
  bool _sharing = false;

  /// Local mirror of the ride's name so a rename lands in the app bar without
  /// leaving the screen.
  late String? _name = widget.ride.name;

  /// True when this ride is a leg of a trip — only the wording changes.
  bool get _isLeg => widget.ride.tripId != null;

  String get _title => _name?.trim().isNotEmpty == true
      ? _name!.trim()
      : (_isLeg ? 'Untitled leg' : 'Untitled ride');

  /// Renames this ride (or leg). Renaming a leg never touches its trip's name —
  /// the two are independent.
  Future<void> _rename() async {
    final next = await showRenameDialog(
      context,
      title: _isLeg ? 'Rename leg' : 'Rename ride',
      initial: _name,
      hint: _isLeg
          ? 'Leg name (e.g. Berangkat)'
          : 'Ride name (e.g. Morning commute)',
    );
    if (next == null) return;
    await DatabaseService.instance.setRideName(widget.ride.id, next);
    widget.ride.name = next; // keep the pushed-in object consistent
    ref.invalidate(rideHistoryProvider);
    final tripId = widget.ride.tripId;
    if (tripId != null) {
      ref.invalidate(tripLegsProvider(tripId));
      ref.invalidate(openTripsProvider);
      ref.invalidate(finishedTripsProvider);
    }
    if (mounted) setState(() => _name = next);
  }

  /// Opens the shared "pick a layout → share/save" flow for this ride. Guarded
  /// so it only fires once the track has loaded (the button is disabled until
  /// then) and never re-enters while a render/share is in flight.
  Future<void> _share() async {
    if (_sharing) return;
    final points = ref.read(rideTrackProvider(widget.ride.id)).valueOrNull;
    if (points == null) return; // track still loading — button is disabled
    await showShareFlow(
      context,
      ride: widget.ride,
      points: points,
      unit: ref.read(speedUnitProvider),
      onBusyChanged: (b) {
        if (mounted) setState(() => _sharing = b);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final unit = ref.watch(speedUnitProvider);
    final trackAsync = ref.watch(rideTrackProvider(widget.ride.id));

    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: DetailAppBar(
        title: _title,
        onRename: _rename,
        renameTooltip: _isLeg ? 'Rename leg' : 'Rename ride',
        busy: _sharing,
        onShare: trackAsync.hasValue ? _share : null,
        shareTooltip: 'Share ride',
      ),
      body: Column(
        children: [
          // Fixed map header (mockup), then the stats scroll beneath it.
          SizedBox(
            height: 320,
            child: trackAsync.when(
              loading: () => Center(
                child: CircularProgressIndicator(color: cx.accentInk),
              ),
              error: (e, _) => Center(
                child: Text(
                  'Could not load track:\n$e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cx.dangerInk),
                ),
              ),
              data: (points) => _ExpandableMap(
                points: points,
                unit: unit,
                title: _title,
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _SummaryPanel(ride: widget.ride, unit: unit),
                  // Charts from the recorded track (needs at least two points).
                  if ((trackAsync.valueOrNull?.length ?? 0) >= 2)
                    _ChartTabs(
                      rideId: widget.ride.id,
                      points: trackAsync.value!,
                      avgSpeedKmh: widget.ride.averageSpeedKmh,
                      unit: unit,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The route map with a tap target over it that opens the fullscreen view (F30).
///
/// The hint chip is deliberate: a map that already pans and zooms gives no sign
/// that tapping it does a *third* thing, so the affordance has to be said.
class _ExpandableMap extends StatelessWidget {
  const _ExpandableMap({
    required this.points,
    required this.unit,
    required this.title,
  });

  final List<TrackPoint> points;
  final SpeedUnit unit;
  final String title;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    if (points.isEmpty) return const NoTrackNotice(subject: 'ride');

    return Stack(
      children: [
        Positioned.fill(child: RouteMapView(points: points, unit: unit)),
        Positioned(
          top: 12,
          right: 12,
          child: Semantics(
            button: true,
            label: 'Expand route map to full screen',
            child: Material(
              color: cx.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => FullScreenRouteMap.open(
                  context,
                  points: points,
                  unit: unit,
                  title: title,
                ),
                child: Container(
                  // 48dp tall so the a11y pass doesn't have to come back for it.
                  constraints: const BoxConstraints(minHeight: 48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: cx.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.open_in_full, size: 16, color: cx.accentInk),
                      const SizedBox(width: 7),
                      ExcludeSemantics(
                        child: Text(
                          'EXPAND',
                          style: TextStyle(
                            color: cx.textBright,
                            fontSize: kMinFontSize,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
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
      ],
    );
  }
}

/// Bottom stats panel — distance, elapsed vs moving time, avg/max speed.
class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.ride, required this.unit});

  final Ride ride;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      width: double.infinity,
      color: cx.canvas,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _formatDate(ride.startTime),
            style: TextStyle(color: cx.textDim, fontSize: 13),
          ),
          if (PlaceRouteLabel.label(ride.startPlace, ride.endPlace) != null) ...[
            const SizedBox(height: 6),
            PlaceRouteLabel(
              startPlace: ride.startPlace,
              endPlace: ride.endPlace,
              fontSize: 14,
            ),
          ],
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                unit
                    .distanceMeters(ride.totalDistanceMeters)
                    .toStringAsFixed(2),
                style: TextStyle(
                  color: cx.textBright,
                  fontSize: 44,
                  height: 1,
                  fontWeight: FontWeight.w800,
                  fontFeatures: kTabularFigures,
                ),
              ),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  unit.distanceLabel,
                  style: TextStyle(color: cx.textDim, fontSize: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              _Stat(
                label: 'TOTAL TIME',
                value: _fmtDuration(ride.durationSeconds),
              ),
              _Stat(
                label: 'MOVING TIME',
                value: _fmtDuration(ride.movingSeconds),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              _Stat(
                label: 'AVG SPEED',
                value: unit.speed(ride.averageSpeedKmh).toStringAsFixed(1),
                unit: unit.speedLabel,
              ),
              _Stat(
                label: 'PEAK SPEED',
                value: unit.speed(ride.maxSpeedKmh).toStringAsFixed(1),
                unit: unit.speedLabel,
                color: cx.peak,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The ride's charts behind a **labelled** tab bar.
///
/// Replaces a `PageView` under four 4px dots (F25). The dots said how many
/// charts existed and nothing about what they held, so finding the elevation
/// profile meant swiping through everything else to see what turned up — and the
/// pager gave no way back except swiping again. Tabs name the destinations and
/// let the rider jump straight to one.
///
/// The pager still resizes to the active tab's measured content height: the tabs
/// hold genuinely different amounts (a stacked bar and a table vs. a scatter), so
/// a fixed height would either clip the tallest or strand the shortest under a
/// screen of empty canvas.
class _ChartTabs extends StatefulWidget {
  const _ChartTabs({
    required this.rideId,
    required this.points,
    required this.avgSpeedKmh,
    required this.unit,
  });

  final int rideId;
  final List<TrackPoint> points;
  final double avgSpeedKmh;
  final SpeedUnit unit;

  /// Height used until a tab has been measured (first frame / unvisited tabs).
  static const double _fallbackHeight = 460;

  @override
  State<_ChartTabs> createState() => _ChartTabsState();
}

class _ChartTabsState extends State<_ChartTabs>
    with SingleTickerProviderStateMixin {
  TabController? _controller;
  int _index = 0;

  /// Measured natural content height per tab index.
  final _heights = <int, double>{};

  /// Mirrors [ElevationSpeedChart]'s own guard so the elevation tab is only
  /// offered when it would actually render (>= 2 altitude fixes, >= 2 m swing).
  bool get _hasElevation {
    var count = 0;
    double? mn, mx;
    for (final p in widget.points) {
      final a = p.altitude;
      if (a == null) continue;
      count++;
      mn = mn == null ? a : (a < mn ? a : mn);
      mx = mx == null ? a : (a > mx ? a : mx);
    }
    return count >= 2 &&
        mn != null &&
        mx != null &&
        (mx - mn) >= ElevationSpeedChart.minElevRange;
  }

  List<String> get _labels => [
        'Speed',
        'Zones',
        'Smoothness',
        if (_hasElevation) 'Elevation',
      ];

  @override
  void initState() {
    super.initState();
    _syncController();
  }

  @override
  void didUpdateWidget(covariant _ChartTabs old) {
    super.didUpdateWidget(old);
    _syncController();
  }

  /// (Re)builds the controller when the tab count changes — the elevation tab
  /// appears or disappears with the track, and a `TabController` whose length no
  /// longer matches its `TabBar` throws.
  void _syncController() {
    final length = _labels.length;
    if (_controller?.length == length) return;
    _controller?.removeListener(_onTab);
    _controller?.dispose();
    _controller = TabController(
      length: length,
      vsync: this,
      initialIndex: _index.clamp(0, length - 1),
    )..addListener(_onTab);
  }

  void _onTab() {
    final c = _controller;
    if (c == null || c.index == _index) return;
    setState(() => _index = c.index);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTab);
    _controller?.dispose();
    super.dispose();
  }

  void _setHeight(int index, double height) {
    if (_heights[index] == height) return;
    // Measurement lands in a post-frame callback, which can fire after the tab
    // count shrank this widget out from under it.
    if (!mounted) return;
    setState(() => _heights[index] = height);
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final controller = _controller!;
    final pages = <Widget>[
      _SpeedChartTab(
        points: widget.points,
        avgSpeedKmh: widget.avgSpeedKmh,
        unit: widget.unit,
      ),
      SpeedZoneChart(points: widget.points, unit: widget.unit),
      SmoothnessChart(
        rideId: widget.rideId,
        points: widget.points,
        unit: widget.unit,
      ),
      if (_hasElevation)
        ElevationSpeedChart(points: widget.points, unit: widget.unit),
    ];

    final index = _index.clamp(0, pages.length - 1);
    final height = _heights[index] ?? _ChartTabs._fallbackHeight;

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: cx.border),
              top: BorderSide(color: cx.border),
            ),
          ),
          child: TabBar(
            controller: controller,
            // Scrollable so four labels never compress into truncated stubs on a
            // 353dp screen, and so a fifth chart later doesn't force a redesign.
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: cx.accentInk,
            indicatorWeight: 2.5,
            indicatorSize: TabBarIndicatorSize.label,
            dividerColor: Colors.transparent,
            labelColor: cx.textBright,
            unselectedLabelColor: cx.textDim,
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            tabs: [for (final l in _labels) Tab(height: 46, text: l)],
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          height: height,
          child: TabBarView(
            controller: controller,
            children: [
              for (var i = 0; i < pages.length; i++)
                // Never-scrolling viewport: lets the child take its natural
                // height (for measurement) without stealing vertical drags from
                // the page behind it.
                SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: _MeasureSize(
                    onChange: (size) => _setHeight(i, size.height),
                    child: pages[i],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Reports its child's laid-out size via [onChange] after each frame it changes.
/// Used to size the chart pager to the active tab's real content height.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
      BuildContext context, _MeasureSizeRenderObject renderObject) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  _MeasureSizeRenderObject(this.onChange);

  ValueChanged<Size> onChange;
  Size? _old;

  @override
  void performLayout() {
    super.performLayout();
    final size = child?.size ?? Size.zero;
    if (size != _old) {
      _old = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(size));
    }
  }
}

/// Speed-vs-distance for a saved ride: cumulative Haversine distance on x,
/// per-fix ground speed on y, under the shared title + takeaway.
class _SpeedChartTab extends StatelessWidget {
  const _SpeedChartTab({
    required this.points,
    required this.avgSpeedKmh,
    required this.unit,
  });

  final List<TrackPoint> points;
  final double avgSpeedKmh;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    var distMeters = 0.0;
    var peakKmh = 0.0;
    var peakAtKm = 0.0;
    for (var i = 0; i < points.length; i++) {
      if (i > 0) {
        distMeters += haversineMeters(
          points[i - 1].latitude,
          points[i - 1].longitude,
          points[i].latitude,
          points[i].longitude,
        );
      }
      final kmh = points[i].speedMps * 3.6;
      if (kmh > peakKmh) {
        peakKmh = kmh;
        peakAtKm = distMeters / 1000.0;
      }
      spots.add(FlSpot(distMeters / 1000.0, kmh));
    }

    return ChartFrame(
      title: 'SPEED OVER DISTANCE',
      takeaway: _takeaway(peakKmh, peakAtKm),
      child: SizedBox(
        height: 260,
        child: SpeedDistanceChart(
          spots: spots,
          avgSpeedKmh: avgSpeedKmh,
          unit: unit,
          interactive: true,
        ),
      ),
    );
  }

  String _takeaway(double peakKmh, double peakAtKm) {
    final peak = unit.speed(peakKmh).toStringAsFixed(0);
    final avg = unit.speed(avgSpeedKmh).toStringAsFixed(0);
    final at = unit.distanceKm(peakAtKm).toStringAsFixed(1);
    if (peakKmh <= 0) {
      return 'No usable speed readings were recorded on this ride.';
    }
    return 'Peaked at $peak ${unit.speedLabel} about $at '
        '${unit.distanceLabel} in, against a $avg ${unit.speedLabel} average.';
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
          Text(
            label,
            style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
          ),
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
                Text(
                  unit,
                  style:
                      TextStyle(color: cx.textDim, fontSize: kMinFontSize),
                ),
              ],
            ],
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
