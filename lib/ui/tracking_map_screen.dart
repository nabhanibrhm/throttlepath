import 'dart:ui' show ImageFilter;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../core/units.dart';
import '../data/models/ride.dart';
import '../providers/history_providers.dart';
import '../providers/home_providers.dart';
import '../providers/settings_providers.dart';
import '../providers/stats_providers.dart';
import '../providers/tracking_providers.dart';
import '../services/permission_service.dart';
import '../services/tracking_service.dart' show LiveTelemetry;
import '../theme/app_theme.dart';
import 'analog_speed_gauge.dart';
import 'ride_display_switcher.dart';
import 'ride_summary_screen.dart';
import 'live_speed_chart.dart';
import 'week_strip.dart';

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
        Navigator.of(context)
            .push(
              MaterialPageRoute(
                builder: (_) =>
                    RideSummaryScreen(telemetry: next.lastFinished!),
              ),
            )
            .then((_) {
          if (!context.mounted) return;
          // The idle sheet's week total and last-ride row are `autoDispose`, but
          // History sits in the same IndexedStack and never unmounts — so it
          // keeps both providers alive and they'd serve the snapshot taken
          // before this ride existed. Same reason `home_shell` invalidates on
          // tab entry.
          ref.invalidate(weekStatsProvider);
          ref.invalidate(latestRideProvider);
        });
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
            Positioned.fill(
              child: _ChartBackdrop(
                state: state,
                unit: unit,
                bottomInset: _sheetHeight,
              ),
            )
          else
            Positioned.fill(
              child: _StatsBackdrop(state: state, bottomInset: _sheetHeight),
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
                _TelemetrySheet(
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

/// Backdrop shown when the view is [RecordView.chart]: a live speed-vs-distance
/// line chart built from the ride's accumulated samples. Draws no tiles/blur,
/// so — like [_StatsBackdrop] — the GPU stays idle. Shows a branded empty-state
/// until there are enough samples to plot.
class _ChartBackdrop extends StatelessWidget {
  const _ChartBackdrop({
    required this.state,
    required this.unit,
    required this.bottomInset,
  });

  final TrackingUiState state;
  final SpeedUnit unit;

  /// Measured height of the telemetry sheet covering the bottom of the stack.
  ///
  /// The chart used to be a floating overlay sized at a guessed fraction of the
  /// screen, which ran its x-axis underneath the sheet and hid the empty state's
  /// caption entirely (F8). Reserving the sheet's real height puts the chart on
  /// the same grid: it fills exactly the strip that is on screen.
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final samples = state.speedSamples;

    return Container(
      color: cx.canvas,
      // Bottom inset comes from the sheet, which already covers that area and
      // applies its own SafeArea — taking it twice would leave a dead band.
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: samples.length < 2
              ? _EmptyChart(recording: state.phase == 'recording')
              : Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 16, 8),
                  child: LiveSpeedChart(
                    spots: [
                      for (final s in samples)
                        FlSpot(s.distanceMeters / 1000.0, s.speedKmh),
                    ],
                    unit: unit,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shown until there are two samples to draw a line between.
class _EmptyChart extends StatelessWidget {
  const _EmptyChart({required this.recording});

  final bool recording;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Center(
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
              recording
                  ? 'Charting your speed as you cover distance…'
                  : 'Your live speed vs. distance chart appears here as you ride.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.textDim, fontSize: 13, height: 1.5),
            ),
          ),
        ],
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
  const _StatsBackdrop({required this.state, required this.bottomInset});

  final TrackingUiState state;

  /// Measured height of the telemetry sheet — see [_ChartBackdrop.bottomInset].
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final recording = state.phase == 'recording';
    return Container(
      color: cx.canvas,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Center(
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
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.visibility_off_outlined,
                          size: 15, color: cx.textDim),
                      const SizedBox(width: 8),
                      // No "Show map" link any more: the switcher in the sheet
                      // is always on screen, so this state is no longer a place
                      // the rider can get stuck in and need an escape hatch from.
                      Flexible(
                        child: Text(
                          recording
                              ? 'Map hidden — recording in the background'
                              : 'Map hidden to save battery',
                          style: TextStyle(color: cx.textDim, fontSize: 13),
                        ),
                      ),
                    ],
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

/// Floating glassmorphic sheet showing live (or last-ride) telemetry + the
/// start/stop control.
class _TelemetrySheet extends StatelessWidget {
  const _TelemetrySheet({
    super.key,
    required this.state,
    required this.unit,
    required this.view,
    required this.gaugeStyle,
    required this.accuracyMeters,
    required this.onViewChanged,
    required this.onGaugeStyleChanged,
    required this.onStart,
    required this.onStop,
    required this.onPause,
    required this.onResume,
    required this.onSkipCountdown,
  });

  final TrackingUiState state;
  final SpeedUnit unit;
  final RecordView view;
  final SpeedGaugeStyle gaugeStyle;

  /// Accuracy of the latest fix, for the idle readiness row. Null until the
  /// rider has located themselves this session.
  final double? accuracyMeters;

  final ValueChanged<RecordView> onViewChanged;
  final ValueChanged<SpeedGaugeStyle> onGaugeStyleChanged;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onSkipCountdown;

  /// The telemetry on display: the in-progress ride while tracking, otherwise the
  /// last finished ride's finalised numbers.
  LiveTelemetry? get _t =>
      state.isTracking ? state.telemetry : (state.lastFinished ?? state.telemetry);

  /// GPS has gone silent long enough to count as a blackout, without the rider
  /// asking for anything. The engine freezes the ride clock in this case exactly
  /// as a pause does, so the screen has to admit it.
  bool get _isSignalLost =>
      state.phase == 'recording' && (_t?.signalLost ?? false) && !state.isPaused;

  /// The ride clock has stopped advancing — by pause, or by blackout. Everything
  /// downstream of this reads as "these numbers are no longer moving".
  bool get _isFrozen => state.isPaused || _isSignalLost;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);

    return Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cx.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: cx.border)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Hazard rail across the full width of the sheet — the one cue that
            // survives being seen at arm's length on a mounted phone. Outside the
            // horizontal padding on purpose, so it spans edge to edge.
            if (_isFrozen) _StripedRail(color: cx.accent),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 22),
              child: _content(context, cx),
            ),
          ],
        ),
      ),
    );
  }

  /// The sheet's stack of readouts and controls. Split out from [build] so the
  /// hazard rail above can sit outside the horizontal padding.
  Widget _content(BuildContext context, AppPalette cx) {
    final tracking = state.isTracking;
    final paused = state.isPaused;
    // Lifecycle: START → acquiring (waiting for GPS) → countdown (3-2-1, only if
    // the rider opted in) → recording. The clock/distance only run in recording.
    final phase = state.phase;
    final acquiring = phase == 'acquiring';
    final countingDown = phase == 'countdown';
    final recording = phase == 'recording';
    final t = _t;
    // Frozen covers both freezes; within it, "not paused" can only mean the
    // blackout, which is what the pill and the sentence below branch on.
    final frozen = _isFrozen;
    // Is there a ride to report on at all? Only once the clock is actually
    // running (or a finished ride is waiting to be saved) — `phase == 'recording'`
    // covers paused too, since pausing doesn't change the phase.
    //
    // Deliberately NOT "tracking": during 'acquiring' and 'countdown' no ride
    // exists yet, so the stats would render 0.00 km / 00:00 / 0.0 / 0.0 — F5's
    // four zeros, which 2A removed from the idle screen and which 3.1 would have
    // reintroduced twice as loud now that distance and elapsed are 27sp. The GPS
    // readiness row is the honest content for that moment.
    final hasTelemetry = recording || state.lastFinished != null;
    final speedKmh = (recording && !paused) ? (t?.speedKmh ?? 0) : 0.0;
    // Big speed number: the countdown while starting, otherwise the live speed
    // (converted to the rider's chosen unit). While acquiring, the number is
    // replaced entirely by an "Acquiring GPS" pill, so no number is shown.
    final heroNumber = countingDown
        ? state.countdown.toString()
        : unit.speed(speedKmh).toStringAsFixed(0);

    return Column(
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
            const SizedBox(height: 12),
            // The display control sits above the readout it governs and stays
            // on screen in every backdrop, which is the whole of F1: it used to
            // be a blind-cycling pill plus a Settings row three taps away.
            RideDisplaySwitcher(
              view: view,
              gaugeStyle: gaugeStyle,
              onViewChanged: onViewChanged,
              onGaugeStyleChanged: onGaugeStyleChanged,
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
                  dimmed: !recording || frozen,
                )
              else
                // While counting down, the number itself is the skip target —
                // the whole point of F10 is that the rider can get past this
                // without hunting for a control. Opaque hit test so the taps
                // land in the gaps between the digits too.
                GestureDetector(
                  onTap: countingDown ? onSkipCountdown : null,
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      heroNumber,
                      style: TextStyle(
                        color: countingDown
                            ? cx.accentInk
                            : (frozen ? cx.textDim : cx.textBright),
                        // The one hero on the screen (F14). Distance and elapsed
                        // sit a full step below it, and avg/peak/moving two.
                        fontSize: countingDown ? 84 : 64,
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
                ),
              if (frozen) ...[
                const SizedBox(height: 10),
                // Filled, not outlined: at a glance this has to look like a
                // different screen, not the same screen with a small badge (F12).
                _FilledPill(
                  label: paused ? 'PAUSED' : 'GPS SIGNAL LOST',
                  background: cx.accent,
                  foreground: cx.onAccent,
                ),
                const SizedBox(height: 7),
                // Said in words, because a rider who glances down and sees a
                // plausible-looking screen will assume it is still recording.
                Text(
                  paused
                      ? pausedSentence(t?.pausedFor)
                      : 'Not recording — waiting for GPS',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: cx.accentInk,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: kTabularFigures,
                  ),
                ),
              ] else if (countingDown) ...[
                const SizedBox(height: 10),
                _OutlinePill(label: 'TAP TO SKIP', color: cx.accentInk),
              ],
            ],
            const SizedBox(height: 18),
            // Before a ride there is nothing to put in the 4-up grid, and four
            // zeroes read as broken rather than empty. Show the two things that
            // actually answer "should I hit start?" instead; the grid returns the
            // moment there is data in it.
            // Glance hierarchy for a phone on a handlebar (F14): distance and
            // elapsed are what the rider looks for after speed, so they get a
            // size of their own. Average, peak and moving time are post-ride
            // curiosities and drop to one quiet reference line — previously all
            // four sat at the same 20sp, which is no hierarchy at all.
            if (hasTelemetry) ...[
              Row(
                children: [
                  Expanded(
                    child: _HeroStat(
                      label: 'DISTANCE',
                      value: unit
                          .distanceMeters(t?.distanceMeters ?? 0)
                          .toStringAsFixed(2),
                      unit: unit.distanceLabel,
                      dimmed: frozen,
                    ),
                  ),
                  Expanded(
                    child: _HeroStat(
                      // A clock that has stopped says so on its own label, so
                      // the number underneath can't be misread as live.
                      label: !tracking
                          ? 'DURATION'
                          : (frozen ? 'ELAPSED · FROZEN' : 'ELAPSED'),
                      value: _fmtDuration(t?.durationSeconds ?? 0),
                      unit: 'min',
                      dimmed: frozen,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _ReferenceStats(unit: unit, telemetry: t, dimmed: frozen),
            ] else
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
            else
              _RideControls(
                paused: paused,
                onPause: onPause,
                onResume: onResume,
                onStop: onStop,
              ),
      ],
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

/// The recording bar: a wide primary (Pause / Resume) beside a narrow
/// hold-to-end pushed to the far edge.
///
/// F11 was that Pause and Stop were equal-width neighbours with the destructive
/// one under the rider's thumb, and that its 2.2s hold protection — the right
/// idea — was announced in small grey text *below* the buttons, where nobody
/// reads it in motion. So the requirement is now printed on the button itself,
/// and the two controls no longer look interchangeable.
///
/// Stateful because the hold's progress has to reach its siblings: the primary
/// dims while a hold is in flight, so there is no doubt which action is being
/// confirmed.
class _RideControls extends StatefulWidget {
  const _RideControls({
    required this.paused,
    required this.onPause,
    required this.onResume,
    required this.onStop,
  });

  final bool paused;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onStop;

  /// How long the rider must hold to end a ride. Long enough that a knuckle
  /// brushing the screen can't finish it, short enough to not feel broken.
  static const double holdSeconds = 2.2;

  @override
  State<_RideControls> createState() => _RideControlsState();
}

class _RideControlsState extends State<_RideControls> {
  /// Tenths of a second left in the current hold, or null when not holding.
  /// Tenths rather than the raw animation value so this rebuilds ~22 times over
  /// a hold instead of once per frame.
  int? _remainingTenths;

  void _onHoldProgress(double progress) {
    if (!mounted) return;
    if (progress <= 0) {
      if (_remainingTenths != null) setState(() => _remainingTenths = null);
      return;
    }
    final tenths =
        ((1 - progress) * _RideControls.holdSeconds * 10).round();
    if (tenths != _remainingTenths) setState(() => _remainingTenths = tenths);
  }

  /// A hold that started and then stopped is a rider who changed their mind or
  /// fumbled. Nothing else on screen changes in that case, so say it outright —
  /// otherwise the safest reading of the silence is "did that stop my ride?".
  void _onReleasedEarly() {
    if (!mounted) return;
    final cx = AppColors.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          backgroundColor: cx.surfaceRaised,
          content: Text(
            'Still recording — keep holding to end the ride.',
            style: TextStyle(color: cx.textBright),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final holding = _remainingTenths != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // Pause is the wide primary; once paused, Resume inherits that
            // weight — the rider's likely next action is always the big one.
            Expanded(
              flex: widget.paused ? 3 : 2,
              child: AnimatedOpacity(
                opacity: holding ? 0.35 : 1,
                duration: const Duration(milliseconds: 120),
                child: _SheetButton(
                  label: widget.paused ? 'RESUME' : 'PAUSE',
                  color: cx.accent,
                  onPressed: () {
                    // Gloved thumbs get no travel and no click, so the only
                    // confirmation the tap registered is haptic.
                    HapticFeedback.mediumImpact();
                    widget.paused ? widget.onResume() : widget.onPause();
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: widget.paused ? 2 : 1,
              child: _HoldToEndButton(
                // The destructive verb only appears when ending the ride is
                // actually what the rider wants: mid-ride this is STOP, but from
                // a pause the honest label is that they're finishing.
                label: widget.paused ? 'FINISH RIDE' : 'STOP',
                holdSeconds: _RideControls.holdSeconds,
                remainingTenths: _remainingTenths,
                onStop: widget.onStop,
                onProgress: _onHoldProgress,
                onReleasedEarly: _onReleasedEarly,
              ),
            ),
          ],
        ),
        // Height reserved in both states so the sheet doesn't grow (and shove
        // the map camera) the moment a hold begins.
        SizedBox(
          height: 22,
          child: Center(
            child: holding
                ? Text(
                    'Keep holding to end the ride',
                    style: TextStyle(
                      color: cx.accentInk,
                      fontSize: kMinFontSize,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// Press-and-hold button that ends the ride: a red fill with a translucent
/// progress overlay sweeping left→right as the rider holds, the requirement
/// printed under the label, and haptics at the halfway mark and on completion.
/// Releasing early cancels outright rather than animating back, so a cancelled
/// hold can never be mistaken for one still in progress.
class _HoldToEndButton extends StatefulWidget {
  const _HoldToEndButton({
    required this.label,
    required this.holdSeconds,
    required this.remainingTenths,
    required this.onStop,
    required this.onProgress,
    required this.onReleasedEarly,
  });

  final String label;
  final double holdSeconds;

  /// Tenths of a second left in the hold, or null when idle. Owned by the parent
  /// so the label and the sibling's dimming can't disagree.
  final int? remainingTenths;

  final VoidCallback onStop;
  final ValueChanged<double> onProgress;
  final VoidCallback onReleasedEarly;

  @override
  State<_HoldToEndButton> createState() => _HoldToEndButtonState();
}

class _HoldToEndButtonState extends State<_HoldToEndButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (widget.holdSeconds * 1000).round()),
  )
    ..addListener(_onTick)
    ..addStatusListener(_onStatus);

  /// Latched so the halfway haptic fires once per hold, not once per frame.
  bool _passedHalfway = false;

  void _onTick() {
    if (!_passedHalfway && _c.value >= 0.5) {
      _passedHalfway = true;
      // Halfway: tells a rider who can't watch the screen that the hold is
      // registering, before the point of no return.
      HapticFeedback.lightImpact();
    }
    widget.onProgress(_c.value);
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    HapticFeedback.heavyImpact();
    _reset();
    widget.onStop();
  }

  void _reset() {
    _c.value = 0;
    _passedHalfway = false;
    widget.onProgress(0);
  }

  void _release() {
    if (_c.status == AnimationStatus.completed) return;
    final wasHolding = _c.value > 0;
    _c.stop();
    _reset();
    if (wasHolding) widget.onReleasedEarly();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final tenths = widget.remainingTenths;
    // Idle, the sub-label states the requirement (F11: on the control, not in
    // grey text below it). Mid-hold it becomes the live countdown.
    final subLabel = tenths != null
        ? '${(tenths / 10).toStringAsFixed(1)}s'
        : 'HOLD ${widget.holdSeconds.toStringAsFixed(1)}s';
    return Semantics(
      button: true,
      label: '${widget.label}. Press and hold for '
          '${widget.holdSeconds.toStringAsFixed(1)} seconds.',
      child: ExcludeSemantics(
        child: Listener(
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Scales down rather than overflowing on a narrow phone
                        // — "FINISH RIDE" is the widest label this slot takes.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            style: TextStyle(
                              color: cx.onAccent,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          subLabel,
                          maxLines: 1,
                          style: TextStyle(
                            color: cx.onAccent.withValues(alpha: 0.85),
                            fontSize: kMinFontSize,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            fontFeatures: kTabularFigures,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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

/// Filled status chip (PAUSED / GPS SIGNAL LOST). Deliberately louder than
/// [_OutlinePill]: the paused screen used to differ from the recording one by a
/// single small outlined badge, which is how riders finished a leg believing it
/// had been captured (F12).
class _FilledPill extends StatelessWidget {
  const _FilledPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontSize: 13,
          letterSpacing: 1.4,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Diagonal hazard stripes across the top edge of the telemetry sheet, shown
/// whenever the ride clock is frozen. The cue that works at arm's length on a
/// handlebar mount: colour and texture, no reading required.
class _StripedRail extends StatelessWidget {
  const _StripedRail({required this.color});

  final Color color;

  static const double height = 6;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _StripePainter(color)),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // A wash under the stripes so the rail still reads as a solid band from far
    // enough away that the individual stripes blur together.
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: 0.3),
    );
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4;
    // 45°, starting off the left edge so the first stripe is a whole one.
    for (var x = -size.height; x < size.width + size.height; x += 12) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x + size.height, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_StripePainter oldDelegate) => oldDelegate.color != color;
}

/// Distance / elapsed — the second tier of the glance hierarchy (F14). One step
/// below the speed hero and a clear step above the reference line, so a rider
/// finds them without looking for them.
class _HeroStat extends StatelessWidget {
  const _HeroStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.dimmed,
  });

  final String label;
  final String value;
  final String unit;

  /// Drains the value's contrast while the clock is frozen — a number that has
  /// stopped changing should not look as authoritative as a live one.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: cx.textTertiary,
            fontSize: kMinFontSize,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                color: dimmed ? cx.textDim : cx.textBright,
                fontSize: 27,
                height: 1,
                fontWeight: FontWeight.w700,
                fontFeatures: kTabularFigures,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              unit,
              style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
            ),
          ],
        ),
      ],
    );
  }
}

/// Average, peak and moving time on one quiet line — post-ride curiosities that
/// used to compete with distance and elapsed at the same 20sp (F14). PEAK keeps
/// the neutral `peak` token from Phase 1: red is for destructive actions only.
class _ReferenceStats extends StatelessWidget {
  const _ReferenceStats({
    required this.unit,
    required this.telemetry,
    required this.dimmed,
  });

  final SpeedUnit unit;
  final LiveTelemetry? telemetry;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = telemetry;
    final labelStyle = TextStyle(
      color: cx.textTertiary,
      fontSize: kMinFontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    );
    final valueStyle = TextStyle(
      color: dimmed ? cx.textDim : cx.textBright,
      fontSize: kMinFontSize,
      fontWeight: FontWeight.w700,
      fontFeatures: kTabularFigures,
    );
    final peakStyle =
        valueStyle.copyWith(color: dimmed ? cx.textDim : cx.peak);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: 'AVG ', style: labelStyle),
          TextSpan(
            text: unit.speed(t?.avgSpeedKmh ?? 0).toStringAsFixed(1),
            style: valueStyle,
          ),
          TextSpan(text: '   ·   PEAK ', style: labelStyle),
          TextSpan(
            text: unit.speed(t?.maxSpeedKmh ?? 0).toStringAsFixed(1),
            style: peakStyle,
          ),
          TextSpan(text: '   ·   MOVING ', style: labelStyle),
          TextSpan(
            text: _TelemetrySheet._fmtDuration(t?.movingSeconds ?? 0),
            style: valueStyle,
          ),
        ],
      ),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
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
    final week = ref.watch(weekStatsProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _GpsReadinessRow(accuracyMeters: accuracyMeters),
        const SizedBox(height: 12),
        // The week's running total, one line (Phase 5.2, deferred here from 2.6).
        // Reserved even while the query is in flight, for the same reason as the
        // last-ride row below.
        SizedBox(
          height: 20,
          child: week == null
              ? null
              : WeekStrip(stats: week, unit: unit, compact: true),
        ),
        const SizedBox(height: 12),
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

