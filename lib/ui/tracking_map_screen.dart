import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/record_view.dart';
import '../core/units.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/permission_service.dart';
import '../services/tracking_service.dart' show LiveTelemetry;
import '../theme/app_theme.dart';
import 'ride_summary_screen.dart';
import 'record_backdrops.dart';
import 'telemetry_sheet.dart';

/// CartoDB basemap URL for the given brightness — dark tiles on the dark theme,
/// light tiles on the light theme.
String basemapUrl(bool isDark) => isDark
    ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png'
    : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';

/// "Not recording — paused 1:27 ago", the sentence under the PAUSED chip (F12).
///
/// The elapsed part is the whole point: a rider who paused at a petrol stop and
/// forgot needs to see *how long* it has been, not merely that they are paused.
/// Under a minute it reads in seconds, because "0:07" invites a second look.
/// [since] is null only in the moment between the tap and the engine confirming
/// the pause, where there is no honest number to show yet.
String pausedSentence(Duration? since) {
  if (since == null) return 'Not recording — paused';
  final seconds = since.inSeconds;
  final ago = seconds < 60
      ? '${seconds}s'
      : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  return 'Not recording — paused $ago ago';
}

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

  /// The trip banner's measured height, or 0 when no banner is up.
  ///
  /// The banner is a translucent overlay, which is the right treatment over the
  /// *map* — it is spatial, it continues underneath, and a rider can pan out from
  /// behind it. Over a chart it is not: the top of the plot is where the ride's
  /// peak speed sits, so occluding it hides the one value the axis exists to show.
  /// So the non-map backdrops reserve this strip the same way they already reserve
  /// [_sheetHeight] at the bottom.
  ///
  /// Measured below the banner's own `SafeArea`, because the backdrops sit inside
  /// theirs — taking the status bar into this number would count it twice.
  final GlobalKey _bannerKey = GlobalKey();
  double _bannerHeight = 0;

  /// Where to put the rider so they land in the middle of the *visible* map.
  ///
  /// The map is full-bleed but the telemetry sheet covers its bottom ~40%, so
  /// centring on the widget's own centre parked the rider's marker underneath
  /// the sheet. Lifting the camera by half the sheet's height centres the marker
  /// in the strip that's actually on screen. Zero until the sheet is measured,
  /// which is harmless — that's the old behaviour.
  Offset get _cameraOffset => Offset(0, -_sheetHeight / 2);

  /// Reads the sheet's laid-out height. Rebuilds when it changes, because the
  /// backdrops now lay themselves out in the strip above the sheet rather than
  /// guessing at an alignment. Safe from looping: the sheet sizes itself from
  /// its own content and never from this value, so the next measurement matches
  /// and the `!=` guard stops there.
  void _measureSheet() {
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final height = box.size.height;
    if (height == _sheetHeight || !mounted) return;
    setState(() => _sheetHeight = height);
    // The visible strip just changed size — switching Dial to Number shortens
    // the sheet by ~110dp — so whatever was centred in it no longer is. Re-issue
    // the move with the new offset. No loop: the sheet's height comes from its
    // own content, never from the camera.
    if (_mapReady && ref.read(recordViewProvider) == RecordView.map) {
      final target = _currentLatLng(ref.read(trackingControllerProvider));
      if (target != null) _moveCamera(target, _mapController.camera.zoom);
    }
  }

  /// Reads the trip banner's laid-out height, falling back to 0 once it is gone.
  ///
  /// Same no-loop argument as [_measureSheet]: the banner sizes itself from the
  /// trip's name, never from this value, so the next measurement matches and the
  /// `!=` guard stops there.
  void _measureBanner() {
    final box = _bannerKey.currentContext?.findRenderObject() as RenderBox?;
    final height = box != null && box.hasSize ? box.size.height : 0.0;
    if (height == _bannerHeight || !mounted) return;
    setState(() => _bannerHeight = height);
  }

  /// Centres the camera on [target] in the visible strip above the sheet.
  void _moveCamera(LatLng target, double zoom) =>
      _mapController.move(target, zoom, offset: _cameraOffset);

  /// Switches the backdrop (the choice is persisted via [recordViewProvider]).
  /// Leaving the map tears down the FlutterMap widget, so its controller
  /// detaches — reset [_mapReady].
  void _setView(RecordView next) {
    if (next != RecordView.map) {
      setState(() => _mapReady = false);
    }
    ref.read(recordViewProvider.notifier).set(next);
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

  /// Whether the screen is currently being held awake by us, so the plugin is
  /// only called on an actual change rather than every rebuild.
  bool _wakelockHeld = false;

  /// Holds the screen on for the duration of a ride, when the rider has asked
  /// for it (off by default — recording needs the foreground service, not the
  /// screen, so this is purely for a mounted phone and costs battery).
  ///
  /// Kept on through a pause: a rider stopped at a petrol station still wants to
  /// see the ride when they come back to it.
  void _applyWakelock({required bool wanted}) {
    if (wanted == _wakelockHeld) return;
    _wakelockHeld = wanted;
    // Fire-and-forget: a platform that refuses the wakelock is not a reason to
    // interrupt a ride, and there is nothing useful to tell the rider.
    WakelockPlus.toggle(enable: wanted).catchError((_) {});
  }

  @override
  void dispose() {
    if (_wakelockHeld) WakelockPlus.disable().catchError((_) {});
    super.dispose();
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

    // Guarded and idempotent, so calling it from build only reaches the platform
    // when the ride actually starts or ends.
    _applyWakelock(
        wanted: ref.watch(keepScreenOnProvider) && state.isTracking);

    _wireSideEffects(cx);

    final current = _currentLatLng(state);

    // The sheet grows and shrinks with the ride phase (idle context vs. the
    // 4-up grid, one button vs. two), so its height is remeasured every frame
    // rather than assumed once.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureSheet();
      _measureBanner();
    });

    return Scaffold(
      backgroundColor: cx.canvas,
      body: Stack(
        children: [
          _buildBackdrop(cx, state, view, unit, current),
          if (view == RecordView.map) const _MapAttribution(),
          // Pending trip continuation: a top banner naming the trip this next
          // recording will join, with a cancel to detach and ride standalone.
          if (state.continuingTripId != null)
            _ContinuingTripBanner(
              measureKey: _bannerKey,
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
              measureKey: _bannerKey,
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
                // Recenter is now the *only* floating control (F7): the backdrop
                // switcher moved into the sheet, so nothing else competes with
                // it for the same visual language.
                if (view == RecordView.map)
                  Padding(
                    padding:
                        const EdgeInsets.only(left: 16, right: 16, bottom: 12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _LocateButton(busy: _locating, onTap: _locateMe),
                    ),
                  ),
                TelemetrySheet(
                  key: _sheetKey,
                  state: state,
                  unit: unit,
                  view: view,
                  gaugeStyle: gaugeStyle,
                  accuracyMeters: _lastAccuracyMeters,
                  onViewChanged: _setView,
                  onGaugeStyleChanged: (style) =>
                      ref.read(speedGaugeStyleProvider.notifier).set(style),
                  onStart: () =>
                      ref.read(trackingControllerProvider.notifier).start(),
                  onStop: () =>
                      ref.read(trackingControllerProvider.notifier).stop(),
                  onPause: () =>
                      ref.read(trackingControllerProvider.notifier).pause(),
                  onResume: () =>
                      ref.read(trackingControllerProvider.notifier).resume(),
                  onSkipCountdown: () => ref
                      .read(trackingControllerProvider.notifier)
                      .skipCountdown(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The base layer behind the telemetry sheet: the live map on demand, a
  /// lightweight live chart or lean dial, or a static stats backdrop that keeps
  /// the GPU idle and lets the screen sleep to save battery.
  Widget _buildBackdrop(
    AppPalette cx,
    TrackingUiState state,
    RecordView view,
    SpeedUnit unit,
    LatLng? current,
  ) {
    return switch (view) {
      RecordView.map => _buildMap(cx, state, current),
      RecordView.chart => Positioned.fill(
          child: ChartBackdrop(
            state: state,
            unit: unit,
            topInset: _bannerHeight,
            bottomInset: _sheetHeight,
          ),
        ),
      RecordView.lean => Positioned.fill(
          child: LeanBackdrop(
            state: state,
            topInset: _bannerHeight,
            bottomInset: _sheetHeight,
          ),
        ),
      RecordView.none => Positioned.fill(
          child: StatsBackdrop(
            state: state,
            topInset: _bannerHeight,
            bottomInset: _sheetHeight,
          ),
        ),
    };
  }

  Widget _buildMap(AppPalette cx, TrackingUiState state, LatLng? current) {
    return FlutterMap(
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
          // Offline-first: swallow fetch failures (no error spam / red tiles
          // when there's no signal) and serve from the persistent disk cache
          // configured in TileCacheService.
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
    );
  }

  /// Follows the rider (only while the map is actually on screen), presents the
  /// post-ride summary, and surfaces errors.
  void _wireSideEffects(AppPalette cx) {
    ref.listen<TrackingUiState>(trackingControllerProvider, (prev, next) {
      _followRider(next);
      // A ride just finished → open the summary screen once.
      if (next.lastFinished != null && prev?.lastFinished == null) {
        _openSummary(next.lastFinished!);
      }
      if (next.error != null && next.error != prev?.error) {
        _showError(next.error!);
      }
    });
  }

  void _followRider(TrackingUiState next) {
    if (ref.read(recordViewProvider) != RecordView.map || !_mapReady) return;
    final t = next.telemetry;
    final lat = t?.lat;
    final lon = t?.lon;
    if (lat == null || lon == null) return;
    _moveCamera(LatLng(lat, lon), _mapController.camera.zoom);
  }

  void _openSummary(LiveTelemetry finished) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => RideSummaryScreen(telemetry: finished),
          ),
        )
        .then((_) {
      if (!context.mounted) return;
      // The idle sheet's week total and last-ride row are `autoDispose`, but
      // History sits in the same IndexedStack and never unmounts — so it keeps
      // both providers alive and they'd serve the snapshot taken before this
      // ride existed. Same reason `home_shell` invalidates on tab entry.
      ref.invalidate(weekStatsProvider);
      ref.invalidate(latestRideProvider);
    });
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
  const _ContinuingTripBanner({
    required this.measureKey,
    required this.tripName,
    required this.onCancel,
  });

  /// Attached below the `SafeArea` so the measured height is the banner itself —
  /// see `_TrackingMapScreenState._bannerHeight`.
  final GlobalKey measureKey;
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
          key: measureKey,
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
    required this.measureKey,
    required this.tripName,
    required this.onContinue,
    required this.onDismiss,
  });

  /// See [_ContinuingTripBanner.measureKey].
  final GlobalKey measureKey;
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
          key: measureKey,
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
