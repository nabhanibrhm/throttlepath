import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';
import '../data/models/ride.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import 'analog_speed_gauge.dart';
import 'ride_summary_screen.dart';
import 'live_speed_chart.dart';

/// CartoDB basemap URL for the given brightness — dark tiles on the dark theme,
/// light tiles on the light theme.
String basemapUrl(bool isDark) => isDark
    ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
    : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';

/// Full-screen map with a floating glassmorphic telemetry sheet — the
/// Gowez-style tracking screen.
class TrackingMapScreen extends ConsumerStatefulWidget {
  const TrackingMapScreen({super.key});

  @override
  ConsumerState<TrackingMapScreen> createState() => _TrackingMapScreenState();
}

class _TrackingMapScreenState extends ConsumerState<TrackingMapScreen> {
  final MapController _mapController = MapController();

  /// Fallback center until the first fix arrives (Jakarta).
  static const LatLng _fallbackCenter = LatLng(-6.2088, 106.8456);

  bool _mapReady = false;

  /// The rider's last known position while idle (before/without a ride), used
  /// to center the map on open and show a "you are here" marker.
  LatLng? _myLocation;
  bool _locating = false;

  /// Reported accuracy (metres) of the last fix this session, or null if we
  /// haven't asked for one yet. Feeds the idle GPS-readiness row so it can say
  /// "±8 m" instead of only "location is on".
  double? _lastAccuracyMeters;

  /// The telemetry sheet's measured height, remeasured after every frame.
  final GlobalKey _sheetKey = GlobalKey();
  double _sheetHeight = 0;

  /// Where to put the rider so they land in the middle of the *visible* map.
  ///
  /// The map is full-bleed but the telemetry sheet covers its bottom ~40%, so
  /// centring on the widget's own centre parked the rider's marker underneath
  /// the sheet. Lifting the camera by half the sheet's height centres the marker
  /// in the strip that's actually on screen. Zero until the sheet is measured,
  /// which is harmless — that's the old behaviour.
  Offset get _cameraOffset => Offset(0, -_sheetHeight / 2);

  /// Reads the sheet's laid-out height. Deliberately not `setState` — this only
  /// feeds camera maths, and rebuilding here would loop.
  void _measureSheet() {
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) _sheetHeight = box.size.height;
  }

  /// Centres the camera on [target] in the visible strip above the sheet.
  void _moveCamera(LatLng target, double zoom) =>
      _mapController.move(target, zoom, offset: _cameraOffset);

  /// Advances the backdrop view map → chart → none → map (the choice is
  /// persisted via [recordViewProvider]). Leaving the map tears down the
  /// FlutterMap widget, so its controller detaches — reset [_mapReady].
  void _cycleView() {
    final next = ref.read(recordViewProvider).next;
    if (next != RecordView.map) {
      setState(() => _mapReady = false);
    }
    ref.read(recordViewProvider.notifier).cycle();
  }

  /// Fetches the current position, centers the map on it, and drops the idle
  /// marker. Runs once the map is ready (app open) and on the locate button.
  Future<void> _locateMe({bool moveCamera = true}) async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      final perm = await PermissionService.ensureForegroundLocation();
      if (!perm.granted) {
        if (mounted) _showError(perm.message);
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (!mounted) return;
      final here = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _myLocation = here;
        _lastAccuracyMeters = pos.accuracy;
      });
      if (moveCamera && _mapReady) {
        _moveCamera(here, 16);
      }
    } catch (e) {
      if (mounted) _showError('Could not get your location. Try again.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _showError(String message) {
    final cx = AppColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: cx.surface,
          content: Text(message, style: TextStyle(color: cx.dangerInk)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final state = ref.watch(trackingControllerProvider);
    final view = ref.watch(recordViewProvider);
    final unit = ref.watch(speedUnitProvider);
    final gaugeStyle = ref.watch(speedGaugeStyleProvider);
    // Best-effort "you're near where a trip ended — continue it?" nudge.
    final nearby = ref.watch(nearbyOpenTripProvider).valueOrNull;
    final dismissedNudges = ref.watch(dismissedTripNudgesProvider);

    // Follow the rider (only while the map is actually on screen), present the
    // post-ride summary, and surface errors.
    ref.listen<TrackingUiState>(trackingControllerProvider, (prev, next) {
      final t = next.telemetry;
      if (ref.read(recordViewProvider) == RecordView.map &&
          _mapReady &&
          t?.lat != null &&
          t?.lon != null) {
        _moveCamera(LatLng(t!.lat!, t.lon!), _mapController.camera.zoom);
      }
      // A ride just finished → open the summary screen once.
      if (next.lastFinished != null && prev?.lastFinished == null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                RideSummaryScreen(telemetry: next.lastFinished!),
          ),
        );
      }
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              backgroundColor: cx.surface,
              content: Text(next.error!, style: TextStyle(color: cx.dangerInk)),
            ),
          );
      }
    });

    final current = _currentLatLng(state);

    // The sheet grows and shrinks with the ride phase (idle context vs. the
    // 4-up grid, one button vs. two), so its height is remeasured every frame
    // rather than assumed once.
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureSheet());

    return Scaffold(
      backgroundColor: cx.canvas,
      body: Stack(
        children: [
          // Base layer: the live map on demand, a lightweight live chart, or a
          // static stats backdrop that keeps the GPU idle and lets the screen
          // sleep to save battery.
          if (view == RecordView.map)
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: current ?? _fallbackCenter,
                initialZoom: 16,
                backgroundColor: cx.canvas,
                onMapReady: () {
                  _mapReady = true;
                  // Center on the rider as soon as the map can accept moves.
                  _locateMe();
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: basemapUrl(cx.isDark),
                  subdomains: const ['a', 'b', 'c', 'd'],
                  userAgentPackageName: 'id.co.opentrack.throttlepath',
                  // Offline-first: swallow fetch failures (no error spam / red
                  // tiles when there's no signal) and serve from the persistent
                  // disk cache configured in TileCacheService.
                  tileProvider: NetworkTileProvider(silenceExceptions: true),
                ),
                if (state.route.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: state.route,
                        strokeWidth: 5,
                        color: cx.accentInk,
                      ),
                    ],
                  ),
                if (current != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: current,
                        width: 26,
                        height: 26,
                        child: const _RiderDot(),
                      ),
                    ],
                  ),
              ],
            )
          else if (view == RecordView.chart)
            Positioned.fill(child: _ChartBackdrop(state: state, unit: unit))
          else
            Positioned.fill(
              child: _StatsBackdrop(state: state, onShowMap: _cycleView),
            ),
          if (view == RecordView.map) const _MapAttribution(),
          // Pending trip continuation: a top banner naming the trip this next
          // recording will join, with a cancel to detach and ride standalone.
          if (state.continuingTripId != null)
            _ContinuingTripBanner(
              tripName: state.continuingTripName,
              onCancel: () => ref
                  .read(trackingControllerProvider.notifier)
                  .cancelContinuation(),
            )
          // Otherwise, when idle near an open trip's end, nudge to continue it.
          else if (nearby != null &&
              !state.isTracking &&
              state.phase == 'idle' &&
              !dismissedNudges.contains(nearby.trip.id))
            _NearbyTripBanner(
              tripName: nearby.trip.name,
              onContinue: () => ref
                  .read(trackingControllerProvider.notifier)
                  .beginContinuation(nearby.trip.id, nearby.trip.name),
              onDismiss: () => ref
                  .read(dismissedTripNudgesProvider.notifier)
                  .update((s) => {...s, nearby.trip.id}),
            ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // View-cycle (left) + recenter (right) float just above the
                // sheet while the map or chart is on screen. In the hidden
                // state the backdrop carries its own centered "Show map" pill.
                if (view != RecordView.none)
                  Padding(
                    padding:
                        const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _ViewToggleButton(view: view, onTap: _cycleView),
                        if (view == RecordView.map)
                          _LocateButton(busy: _locating, onTap: _locateMe),
                      ],
                    ),
                  ),
                _TelemetrySheet(
                  key: _sheetKey,
                  state: state,
                  unit: unit,
                  gaugeStyle: gaugeStyle,
                  accuracyMeters: _lastAccuracyMeters,
                  onStart: () =>
                      ref.read(trackingControllerProvider.notifier).start(),
                  onStop: () =>
                      ref.read(trackingControllerProvider.notifier).stop(),
                  onPause: () =>
                      ref.read(trackingControllerProvider.notifier).pause(),
                  onResume: () =>
                      ref.read(trackingControllerProvider.notifier).resume(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  LatLng? _currentLatLng(TrackingUiState state) {
    final t = state.telemetry;
    if (t?.lat != null && t?.lon != null) return LatLng(t!.lat!, t.lon!);
    if (state.route.isNotEmpty) return state.route.last;
    return _myLocation; // idle: show where the rider is before a ride starts
  }
}

/// Glowing accent position marker.
class _RiderDot extends StatelessWidget {
  const _RiderDot();

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: cx.accent,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black, width: 3),
        boxShadow: [
          BoxShadow(
            color: cx.accent.withValues(alpha: 0.6),
            blurRadius: 12,
            spreadRadius: 2,
          ),
        ],
      ),
    );
  }
}

/// Required CartoDB / OpenStreetMap attribution, kept subtle in a corner.
class _MapAttribution extends StatelessWidget {
  const _MapAttribution();

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Positioned(
      top: 8,
      right: 8,
      child: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: cx.canvas.withValues(alpha: 0.5),
          child: Text(
            '© OpenStreetMap · CARTO',
            // Exempt from the 12sp floor, like the share card: this is tile
            // licence boilerplate, not something a rider reads at arm's length,
            // and at 12sp it outranked the street names it sits on top of.
            style: TextStyle(color: cx.textTertiary, fontSize: 10),
          ),
        ),
      ),
    );
  }
}

/// Top banner shown while a trip continuation is pending — names the trip the
/// next recording will join and offers a cancel (ride standalone instead).
class _ContinuingTripBanner extends StatelessWidget {
  const _ContinuingTripBanner({required this.tripName, required this.onCancel});

  final String? tripName;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = tripName?.trim();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cx.surface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cx.accentInk.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.alt_route, color: cx.accentInk, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'CONTINUING TRIP',
                            style: TextStyle(
                              color: cx.accentInk,
                              fontSize: 12,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            name?.isNotEmpty == true ? name! : 'Untitled trip',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cx.textBright,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                        foregroundColor: cx.textDim,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Cancel',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Top banner nudging the rider to continue a nearby open trip: shown while
/// idle when the current position is close to where an open trip last ended.
class _NearbyTripBanner extends StatelessWidget {
  const _NearbyTripBanner({
    required this.tripName,
    required this.onContinue,
    required this.onDismiss,
  });

  final String? tripName;
  final VoidCallback onContinue;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final name = tripName?.trim();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: cx.surface.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cx.accentInk.withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.near_me, color: cx.accentInk, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'NEAR A TRIP’S END',
                            style: TextStyle(
                              color: cx.accentInk,
                              fontSize: 12,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Continue ${name?.isNotEmpty == true ? '“$name”' : 'your trip'}?',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cx.textBright,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: onDismiss,
                      style: TextButton.styleFrom(
                        foregroundColor: cx.textDim,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('Not now',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                    const SizedBox(width: 2),
                    ElevatedButton(
                      onPressed: onContinue,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: cx.accent,
                        foregroundColor: cx.onAccent,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        minimumSize: const Size(0, 38),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Continue',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating "my location" button — re-fetches the current position and
/// re-centers the map. Shows a spinner while locating.
class _LocateButton extends StatelessWidget {
  const _LocateButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      button: true,
      enabled: !busy,
      label: busy ? 'Finding your location' : 'Centre the map on me',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            color: cx.surface.withValues(alpha: 0.72),
            child: InkWell(
              onTap: busy ? null : onTap,
              child: Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: cx.accentInk.withValues(alpha: 0.55)),
                ),
                child: busy
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: cx.accentInk),
                      )
                    : Icon(Icons.my_location, color: cx.accentInk),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Glass pill that cycles the backdrop view (map → chart → none). Shows the
/// current view's icon + label; tapping advances to the next.
///
/// Rendered in neutral ink rather than amber (F7): it and the recenter button
/// used to carry the identical amber outline, so neither read as more important
/// than the other. Recenter is the action, this is a mode indicator — recenter
/// keeps the accent.
class _ViewToggleButton extends StatelessWidget {
  const _ViewToggleButton({required this.view, required this.onTap});

  final RecordView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final (IconData icon, String label, String next) = switch (view) {
      RecordView.map => (Icons.map, 'Map', 'the live chart'),
      RecordView.chart => (Icons.show_chart, 'Chart', 'no backdrop'),
      RecordView.none => (Icons.visibility_off_outlined, 'Hidden', 'the map'),
    };
    return Semantics(
      button: true,
      label: 'Backdrop: $label. Switch to $next.',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Material(
            color: cx.surface.withValues(alpha: 0.72),
            child: InkWell(
              onTap: onTap,
              child: Container(
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cx.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: cx.textBright, size: 20),
                    const SizedBox(width: 8),
                    Text(label,
                        style: TextStyle(
                            color: cx.textBright,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Backdrop shown when the view is [RecordView.chart]: a live speed-vs-distance
/// line chart built from the ride's accumulated samples. Draws no tiles/blur,
/// so — like [_StatsBackdrop] — the GPU stays idle. Shows a branded empty-state
/// until there are enough samples to plot.
class _ChartBackdrop extends StatelessWidget {
  const _ChartBackdrop({required this.state, required this.unit});

  final TrackingUiState state;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final samples = state.speedSamples;

    if (samples.length < 2) {
      return Container(
        color: cx.canvas,
        child: SafeArea(
          child: Align(
            // Upper third, matching [_StatsBackdrop]: a centred block puts its
            // own caption behind the telemetry sheet, which is what left this
            // state showing a lone floating icon.
            alignment: const Alignment(0, -0.55),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.show_chart, size: 40, color: cx.textTertiary),
                const SizedBox(height: 14),
                Text(
                  'Speed / distance',
                  style: TextStyle(
                    color: cx.textBright,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Text(
                    state.phase == 'recording'
                        ? 'Charting your speed as you cover distance…'
                        : 'Your live speed vs. distance chart appears here as you ride.',
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: cx.textDim, fontSize: 13, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final spots = [
      for (final s in samples)
        FlSpot(s.distanceMeters / 1000.0, s.speedKmh),
    ];
    return Container(
      color: cx.canvas,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            // Keep the live chart compact and anchored near the top so both the
            // SPEED (y) and DISTANCE (x) axes stay fully visible above the
            // telemetry sheet — a full-bleed chart hides the x-axis behind it.
            // 0.5 still ran the x-axis under the sheet, which is roughly the
            // bottom 44% of the stack. Phase 2.5 replaces this guess by laying
            // the chart out on the same grid as the sheet instead of behind it.
            final h = math.min(300.0, c.maxHeight * 0.40);
            return Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  height: h,
                  child: LiveSpeedChart(
                    spots: spots,
                    unit: unit,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Lightweight backdrop shown in place of the map — no tiles, no blur, so the
/// GPU stays idle and the screen can sleep while recording continues in the
/// background service.
///
/// Deliberately quiet (F2, F3). The old version put a 72px logo in the middle of
/// the screen and a bordered "Show map" pill under it — the only boxed button
/// above the fold, which made *hiding the map* look like the screen's primary
/// action while START RIDE sat below it. Now the wordmark is a small mark in the
/// upper third and the way back to the map is a text link inside a status line.
/// The rider's actual pre-ride context lives in the sheet ([_IdleContext]), where
/// it shows in every backdrop rather than only this one.
class _StatsBackdrop extends StatelessWidget {
  const _StatsBackdrop({required this.state, required this.onShowMap});

  final TrackingUiState state;
  final VoidCallback onShowMap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final recording = state.phase == 'recording';
    return Container(
      color: cx.canvas,
      child: SafeArea(
        child: Align(
          // Upper third: everything below it belongs to the telemetry sheet,
          // which overlaps a centred block on a short screen.
          alignment: const Alignment(0, -0.55),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/icon/logo_foreground.png',
                    width: 26,
                    height: 26,
                    color: cx.textTertiary,
                    filterQuality: FilterQuality.medium,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'ThrottlePath',
                    style: TextStyle(
                      color: cx.textTertiary,
                      fontSize: 15,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.visibility_off_outlined,
                        size: 15, color: cx.textDim),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        recording
                            ? 'Map hidden — recording in the background'
                            : 'Map hidden to save battery',
                        style: TextStyle(color: cx.textDim, fontSize: 13),
                      ),
                    ),
                    // A link, not a button: the one filled control on this
                    // screen is START RIDE, and nothing else may compete with it.
                    TextButton(
                      onPressed: onShowMap,
                      style: TextButton.styleFrom(
                        foregroundColor: cx.accentInk,
                        // Visually a link, but still a full 48dp touch target.
                        minimumSize: const Size(0, 48),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      child: const Text(
                        'Show map',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating glassmorphic sheet showing live (or last-ride) telemetry + the
/// start/stop control.
class _TelemetrySheet extends StatelessWidget {
  const _TelemetrySheet({
    super.key,
    required this.state,
    required this.unit,
    required this.gaugeStyle,
    required this.accuracyMeters,
    required this.onStart,
    required this.onStop,
    required this.onPause,
    required this.onResume,
  });

  final TrackingUiState state;
  final SpeedUnit unit;
  final SpeedGaugeStyle gaugeStyle;

  /// Accuracy of the latest fix, for the idle readiness row. Null until the
  /// rider has located themselves this session.
  final double? accuracyMeters;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final VoidCallback onResume;

  /// How long the rider must hold STOP to end a ride (matches the prototype's
  /// "Hold STOP for 2.2s" affordance).
  static const double _stopHoldSeconds = 2.2;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final tracking = state.isTracking;
    final paused = state.isPaused;
    // Lifecycle: START → acquiring (waiting for GPS) → countdown (3-2-1) →
    // recording. The clock/distance only run in recording.
    final phase = state.phase;
    final acquiring = phase == 'acquiring';
    final countingDown = phase == 'countdown';
    final recording = phase == 'recording';
    // While tracking, show live telemetry; when stopped, show the last ride's
    // finalised summary if present.
    final t = tracking ? state.telemetry : (state.lastFinished ?? state.telemetry);
    // Is there a ride to report on at all? True from the moment START is pressed
    // until the finished ride is saved or discarded; false on a resting screen.
    final hasTelemetry = tracking || state.lastFinished != null;
    final speedKmh = (recording && !paused) ? (t?.speedKmh ?? 0) : 0.0;
    // Big speed number: the countdown while starting, otherwise the live speed
    // (converted to the rider's chosen unit). While acquiring, the number is
    // replaced entirely by an "Acquiring GPS" pill, so no number is shown.
    final heroNumber = countingDown
        ? state.countdown.toString()
        : unit.speed(speedKmh).toStringAsFixed(0);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: cx.border)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cx.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            // Hero: the acquiring pill, or the big speed/countdown number.
            if (acquiring)
              _StatusPill(
                label: 'ACQUIRING GPS…',
                dotColor: cx.accent,
                textColor: cx.textBright,
                borderColor: cx.border,
              )
            else ...[
              // The analog gauge replaces the numeral only for live speed — the
              // 3-2-1 countdown stays a big digit, since there's nothing to sweep.
              if (gaugeStyle == SpeedGaugeStyle.analog && !countingDown)
                AnalogSpeedGauge(
                  speed: unit.speed(speedKmh),
                  maxSpeed: unit.speed(t?.maxSpeedKmh ?? 0),
                  topOfScale: AnalogSpeedGauge.topFor(unit),
                  unitLabel: unit.speedLabel,
                  dimmed: !recording || paused,
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      heroNumber,
                      style: TextStyle(
                        color: countingDown ? cx.accentInk : cx.textBright,
                        fontSize: countingDown ? 84 : 60,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        // Without tabular digits this readout re-flows on every
                        // GPS tick as "1" and "8" swap widths — the single
                        // worst thing you can do to a number read in motion.
                        fontFeatures: kTabularFigures,
                      ),
                    ),
                    if (!countingDown) ...[
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(unit.speedLabel,
                            style: TextStyle(color: cx.textDim, fontSize: 18)),
                      ),
                    ],
                  ],
                ),
              if (paused) ...[
                const SizedBox(height: 8),
                _OutlinePill(label: 'PAUSED', color: cx.accentInk),
              ] else if (countingDown) ...[
                const SizedBox(height: 8),
                _OutlinePill(label: 'GET READY', color: cx.accentInk),
              ],
            ],
            const SizedBox(height: 18),
            // Before a ride there is nothing to put in the 4-up grid, and four
            // zeroes read as broken rather than empty. Show the two things that
            // actually answer "should I hit start?" instead; the grid returns the
            // moment there is data in it.
            if (hasTelemetry)
              Row(
                children: [
                  _Metric(
                      label: 'DIST',
                      value: unit
                          .distanceMeters(t?.distanceMeters ?? 0)
                          .toStringAsFixed(2),
                      unit: unit.distanceLabel),
                  _Metric(
                      label: 'TIME',
                      value: _fmtDuration(t?.durationSeconds ?? 0),
                      unit: 'min'),
                  _Metric(
                      label: 'AVG',
                      value: unit.speed(t?.avgSpeedKmh ?? 0).toStringAsFixed(1),
                      unit: unit.speedLabel),
                  _Metric(
                      label: 'PEAK',
                      value: unit.speed(t?.maxSpeedKmh ?? 0).toStringAsFixed(1),
                      unit: unit.speedLabel,
                      color: cx.peak),
                ],
              )
            else
              _IdleContext(unit: unit, accuracyMeters: accuracyMeters),
            const SizedBox(height: 20),
            if (!tracking)
              _SheetButton(
                label: 'START RIDE',
                color: cx.accent,
                onPressed: onStart,
              )
            else if (acquiring || countingDown)
              // No ride has started yet — the only action is to back out.
              _SheetButton(
                label: 'CANCEL',
                outlined: true,
                onPressed: onStop,
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: _SheetButton(
                      label: paused ? 'RESUME' : 'PAUSE',
                      color: cx.accent,
                      onPressed: paused ? onResume : onPause,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _HoldToStopButton(
                      onStop: onStop,
                      holdSeconds: _stopHoldSeconds,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Hold STOP for ${_stopHoldSeconds.toStringAsFixed(1)}s to end ride',
                style: TextStyle(color: cx.textTertiary, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _fmtDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// Pill button used in the telemetry sheet (start / pause / resume). A solid
/// [color] fill with a dark label, or an [outlined] transparent variant (used
/// for CANCEL) with a bordered, bright label.
class _SheetButton extends StatelessWidget {
  const _SheetButton({
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

/// Press-and-hold STOP button: a red fill with a translucent progress overlay
/// that sweeps left→right as the rider holds. Ends the ride once full; resets
/// if released early. Mirrors the prototype's hold-to-stop affordance.
class _HoldToStopButton extends StatefulWidget {
  const _HoldToStopButton({required this.onStop, required this.holdSeconds});

  final VoidCallback onStop;
  final double holdSeconds;

  @override
  State<_HoldToStopButton> createState() => _HoldToStopButtonState();
}

class _HoldToStopButtonState extends State<_HoldToStopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (widget.holdSeconds * 1000).round()),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onStop();
        _c.reset();
      }
    });

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _release() {
    if (_c.status != AnimationStatus.completed) _c.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Listener(
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
                child: Text(
                  'STOP',
                  style: TextStyle(
                    color: cx.onAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
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

/// Status pill with a leading dot (e.g. "● ACQUIRING GPS…") shown in place of
/// the speed number.
class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.dotColor,
    required this.textColor,
    required this.borderColor,
  });

  final String label;
  final Color dotColor;
  final Color textColor;
  final Color borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
              letterSpacing: 1,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small outlined status pill (PAUSED / GET READY) shown under the hero number.
class _OutlinePill extends StatelessWidget {
  const _OutlinePill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          letterSpacing: 1.5,
          fontWeight: FontWeight.w700,
        ),
      ),
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
class _IdleContext extends ConsumerWidget {
  const _IdleContext({required this.unit, required this.accuracyMeters});

  final SpeedUnit unit;
  final double? accuracyMeters;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final latest = ref.watch(latestRideProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GpsReadinessRow(accuracyMeters: accuracyMeters),
        const SizedBox(height: 14),
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
class _GpsReadinessRow extends StatefulWidget {
  const _GpsReadinessRow({required this.accuracyMeters});

  final double? accuracyMeters;

  @override
  State<_GpsReadinessRow> createState() => _GpsReadinessRowState();
}

enum _GpsReadiness { checking, servicesOff, permissionNeeded, ready }

class _GpsReadinessRowState extends State<_GpsReadinessRow> {
  _GpsReadiness _state = _GpsReadiness.checking;

  @override
  void initState() {
    super.initState();
    _probe();
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
    if (mounted) setState(() => _state = next);
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
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: kTabularFigures,
            ),
          ),
        ),
      ],
    );
  }
}

/// One quiet two-line recap of the previous ride, or an invitation when there
/// isn't one yet. Both states share a shape so the sheet stays put.
class _LastRideRow extends StatelessWidget {
  const _LastRideRow({required this.ride, required this.unit});

  final Ride? ride;
  final SpeedUnit unit;

  /// Reserved height, so loading / empty / populated are all the same size.
  static const double height = 38;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final r = ride;

    final String heading;
    final String? trailing;
    final String detail;
    if (r == null) {
      heading = 'NO RIDES YET';
      trailing = null;
      detail = 'Press START to record your first.';
    } else {
      final when = r.startTime.toLocal();
      heading = 'LAST RIDE';
      trailing = '${_months[when.month - 1]} ${when.day}';
      final distance =
          unit.distanceMeters(r.totalDistanceMeters).toStringAsFixed(2);
      final minutes = (r.durationSeconds / 60).round();
      final name = r.name?.trim();
      final parts = [
        if (name != null && name.isNotEmpty) name,
        '$distance ${unit.distanceLabel}',
        '$minutes min',
      ];
      detail = parts.join(' · ');
    }

    final labelStyle = TextStyle(
      color: cx.textTertiary,
      fontSize: kMinFontSize,
      letterSpacing: 1.0,
      fontWeight: FontWeight.w600,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(heading, style: labelStyle),
            const Spacer(),
            if (trailing != null) Text(trailing, style: labelStyle),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: r == null ? cx.textDim : cx.textBright,
            fontSize: 14,
            fontWeight: r == null ? FontWeight.w500 : FontWeight.w700,
            fontFeatures: kTabularFigures,
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
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
        children: [
          Text(label,
              style: TextStyle(
                  color: cx.textTertiary, fontSize: 12, letterSpacing: 0.5)),
          const SizedBox(height: 5),
          Text(value,
              style: TextStyle(
                  color: color ?? cx.textBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  fontFeatures: kTabularFigures)),
          if (unit.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(unit,
                  style: TextStyle(color: cx.textTertiary, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
