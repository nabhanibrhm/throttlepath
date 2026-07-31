import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/date_format.dart';
import '../data/database_service.dart';
import '../data/models/trip.dart';
import '../services/geocoding_service.dart';
import '../services/permission_service.dart';
import '../services/tracking_service.dart';

/// The app-wide background tracking service.
final trackingServiceProvider =
    Provider<TrackingService>((ref) => TrackingService.instance);

/// One (distance, speed) sample for the live speed-vs-distance chart, captured
/// per accepted fix while recording. Distance in meters, speed in km/h (metric
/// internally; the chart shows no numbers so units don't affect its shape).
class SpeedSample {
  const SpeedSample(this.distanceMeters, this.speedKmh);
  final double distanceMeters;
  final double speedKmh;
}

/// Immutable UI state for the tracking screen.
class TrackingUiState {
  const TrackingUiState({
    this.isTracking = false,
    this.isPaused = false,
    this.phase = 'idle',
    this.countdown = 0,
    this.telemetry,
    this.route = const [],
    this.speedSamples = const [],
    this.leanMaxLeftDegrees = 0,
    this.leanMaxRightDegrees = 0,
    this.lastFinished,
    this.continuingTripId,
    this.continuingTripName,
    this.error,
  });

  final bool isTracking;
  final bool isPaused;

  /// Ride lifecycle: 'idle', 'acquiring' (waiting for first fix), 'countdown'
  /// (3-2-1 before the clock starts), or 'recording'.
  final String phase;

  /// Remaining countdown seconds while [phase] == 'countdown' (0 otherwise).
  final int countdown;
  final LiveTelemetry? telemetry;
  final List<LatLng> route;

  /// Per-fix (distance, speed) samples for the live chart, in capture order.
  final List<SpeedSample> speedSamples;

  /// Furthest lean reached each way this ride, as magnitudes in degrees, for the
  /// lean dial's max-hold marks. Zero until the first estimate arrives.
  ///
  /// Accumulated here rather than in the gauge because the Record screen builds a
  /// *different* backdrop widget per view, so cycling map → chart → lean destroys
  /// and recreates the dial. A max-hold that forgot the ride's peak on a view
  /// toggle would be worse than not having one.
  final double leanMaxLeftDegrees;
  final double leanMaxRightDegrees;
  final LiveTelemetry? lastFinished;

  /// When non-null, the next recording is a continuation of this open trip (its
  /// next stint) — set from the History "Continue" affordance and consumed when
  /// the stint is saved. [continuingTripName] is carried alongside for display.
  final int? continuingTripId;
  final String? continuingTripName;
  final String? error;

  TrackingUiState copyWith({
    bool? isTracking,
    bool? isPaused,
    String? phase,
    int? countdown,
    LiveTelemetry? telemetry,
    List<LatLng>? route,
    List<SpeedSample>? speedSamples,
    double? leanMaxLeftDegrees,
    double? leanMaxRightDegrees,
    LiveTelemetry? lastFinished,
    int? continuingTripId,
    String? continuingTripName,
    String? error,
    bool clearTelemetry = false,
    bool clearFinished = false,
    bool clearContinuation = false,
    bool clearError = false,
  }) {
    return TrackingUiState(
      isTracking: isTracking ?? this.isTracking,
      isPaused: isPaused ?? this.isPaused,
      phase: phase ?? this.phase,
      countdown: countdown ?? this.countdown,
      telemetry: clearTelemetry ? null : (telemetry ?? this.telemetry),
      route: route ?? this.route,
      speedSamples: speedSamples ?? this.speedSamples,
      leanMaxLeftDegrees: leanMaxLeftDegrees ?? this.leanMaxLeftDegrees,
      leanMaxRightDegrees: leanMaxRightDegrees ?? this.leanMaxRightDegrees,
      lastFinished: clearFinished ? null : (lastFinished ?? this.lastFinished),
      continuingTripId:
          clearContinuation ? null : (continuingTripId ?? this.continuingTripId),
      continuingTripName: clearContinuation
          ? null
          : (continuingTripName ?? this.continuingTripName),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Bridges the background [TrackingService] streams into Riverpod state and
/// accumulates the live route polyline.
class TrackingController extends StateNotifier<TrackingUiState> {
  TrackingController(this._service) : super(const TrackingUiState()) {
    _telemetrySub = _service.telemetry.listen(_onTelemetry);
    _stoppedSub = _service.onStopped.listen(_onStopped);
    _cancelledSub = _service.onCancelled.listen(_onCancelled);
  }

  final TrackingService _service;
  late final StreamSubscription<LiveTelemetry> _telemetrySub;
  late final StreamSubscription<LiveTelemetry> _stoppedSub;
  late final StreamSubscription<String?> _cancelledSub;

  void _onTelemetry(LiveTelemetry t) {
    final track = _extendTrack(t);
    final leanMax = _extendLeanMax(t);
    state = state.copyWith(
      isTracking: true,
      isPaused: t.paused,
      phase: t.phase,
      countdown: t.countdown,
      telemetry: t,
      route: track.route,
      speedSamples: track.samples,
      leanMaxLeftDegrees: leanMax.left,
      leanMaxRightDegrees: leanMax.right,
    );
  }

  /// The per-side lean maxima after folding in [t], unchanged when it carries no
  /// estimate. Only counts while recording, so a corner taken during acquisition
  /// or a countdown cannot seed a peak the ride never had.
  ({double left, double right}) _extendLeanMax(LiveTelemetry t) {
    final lean = t.leanDegrees;
    if (lean == null || t.phase != 'recording') {
      return (left: state.leanMaxLeftDegrees, right: state.leanMaxRightDegrees);
    }
    return (
      left: lean < 0
          ? math.max(state.leanMaxLeftDegrees, -lean)
          : state.leanMaxLeftDegrees,
      right: lean > 0
          ? math.max(state.leanMaxRightDegrees, lean)
          : state.leanMaxRightDegrees,
    );
  }

  /// The polyline and chart samples after folding in [t], unchanged when [t]
  /// carries nothing new.
  ///
  /// Telemetry ticks once a second and re-sends the last known coordinates, so
  /// growing the polyline on every tick would pile up duplicate vertices at a
  /// standstill.
  ({List<LatLng> route, List<SpeedSample> samples}) _extendTrack(
      LiveTelemetry t) {
    final route = state.route;
    final samples = state.speedSamples;
    final lat = t.lat;
    final lon = t.lon;
    if (lat == null || lon == null) return (route: route, samples: samples);

    final last = route.isNotEmpty ? route.last : null;
    if (last != null && last.latitude == lat && last.longitude == lon) {
      return (route: route, samples: samples);
    }
    return (
      route: [...route, LatLng(lat, lon)],
      // A chart sample only on a real new fix while recording — distance only
      // advances then, so acquiring/countdown fixes carry none.
      samples: t.phase == 'recording'
          ? [...samples, SpeedSample(t.distanceMeters, t.speedKmh)]
          : samples,
    );
  }

  void _onStopped(LiveTelemetry t) {
    state = state.copyWith(
        isTracking: false, phase: 'idle', countdown: 0, lastFinished: t);
  }

  /// Acquisition was aborted before a ride began (Cancel or acquire timeout) —
  /// return to idle, surfacing the reason (if any) so the UI can toast it.
  void _onCancelled(String? reason) {
    state = state.copyWith(
      isTracking: false,
      isPaused: false,
      phase: 'idle',
      countdown: 0,
      route: const [],
      speedSamples: const [],
      leanMaxLeftDegrees: 0,
      leanMaxRightDegrees: 0,
      clearTelemetry: true,
      error: reason,
    );
  }

  /// Requests permissions and, if granted, clears prior route/summary and
  /// starts recording. Surfaces a denial reason via [TrackingUiState.error].
  Future<void> start() async {
    final perm = await PermissionService.ensureTrackingPermissions();
    if (!perm.granted) {
      state = state.copyWith(error: perm.message);
      return;
    }
    state = state.copyWith(
      isTracking: true,
      isPaused: false,
      phase: 'acquiring',
      countdown: 0,
      route: const [],
      speedSamples: const [],
      leanMaxLeftDegrees: 0,
      leanMaxRightDegrees: 0,
      clearTelemetry: true,
      clearFinished: true,
      clearError: true,
    );
    await _service.startRide();
  }

  void stop() => _service.stopRide();

  /// Pauses the active ride (optimistically; telemetry confirms shortly after).
  void pause() {
    _service.pauseRide();
    state = state.copyWith(isPaused: true);
  }

  /// Resumes a paused ride.
  void resume() {
    _service.resumeRide();
    state = state.copyWith(isPaused: false);
  }

  /// Cuts a running pre-ride countdown short. Not applied optimistically — the
  /// engine owns the phase transition, and it is the thing that creates the Ride
  /// row, so the UI waits for it to say recording has begun.
  void skipCountdown() => _service.skipCountdown();

  /// Standalone save — names the just-finished ride (already persisted), with no
  /// trip link, and returns to idle so the next ride starts fresh.
  Future<void> saveFinishedRide(String name) async {
    await _persistStint(name);
    _resetToIdle(clearContinuation: true);
  }

  /// Saves the finished stint into its trip — creating a fresh open trip named
  /// [tripName] if this is a first stint, or linking to the trip currently being
  /// continued — and leaves the trip OPEN so the rider can continue it.
  ///
  /// [name] names the stint and [tripName] the trip: the two are independent, so
  /// naming a stint never renames its trip (or vice versa).
  Future<void> saveAndContinueTrip(String name, {String? tripName}) async {
    final tripId = await _resolveTripId(tripName);
    await _persistStint(name, tripId: tripId);
    _resetToIdle(clearContinuation: true);
  }

  /// Saves the finished stint into its trip (creating one named [tripName] if
  /// needed) and then FINISHES that trip — it accepts no more stints until
  /// reopened.
  Future<void> finishTripWithStint(String name, {String? tripName}) async {
    final tripId = await _resolveTripId(tripName);
    await _persistStint(name, tripId: tripId);
    await DatabaseService.instance.finishTrip(tripId);
    _resetToIdle(clearContinuation: true);
  }

  /// Marks the next recording as the next stint of [tripId]. Set from the History
  /// "Continue" affordance before the rider starts recording; consumed when that
  /// stint is saved. [tripName] is carried along for the record-screen banner.
  void beginContinuation(int tripId, String? tripName) {
    state = state.copyWith(
      continuingTripId: tripId,
      continuingTripName: tripName,
    );
  }

  /// Clears a pending continuation — the rider backed out before recording, or
  /// wants this recording to be a standalone ride after all.
  void cancelContinuation() =>
      state = state.copyWith(clearContinuation: true);

  /// Persists the just-finished stint: names it (when a name was given), optionally
  /// links it to [tripId], then fires the best-effort geocode. Shared by the
  /// standalone-save and trip-save paths.
  Future<void> _persistStint(String name, {int? tripId}) async {
    final t = state.lastFinished;
    if (t == null) return;
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) {
      await DatabaseService.instance.setRideName(t.rideId, trimmed);
    }
    if (tripId != null) {
      await DatabaseService.instance.setRideTrip(t.rideId, tripId);
    }
    _geocodeRide(t.rideId, state.route);
  }

  /// Resolves the trip this stint belongs to: the trip currently being continued,
  /// or a freshly-created open trip named [tripName]. A trip's name is asked for
  /// separately from its stints' — when the rider leaves it blank the trip falls
  /// back to a dated placeholder (never the stint's name), and stays renameable
  /// from trip detail.
  Future<int> _resolveTripId(String? tripName) async {
    final existing = state.continuingTripId;
    if (existing != null) return existing;
    final now = DateTime.now();
    final trimmed = tripName?.trim() ?? '';
    final trip = Trip()
      ..createdAt = now
      ..name = trimmed.isEmpty ? _defaultTripName(now) : trimmed;
    return DatabaseService.instance.createTrip(trip);
  }

  /// Reverse-geocodes the ride's first/last fix and persists the place names —
  /// fire-and-forget and off the save path, so returning to idle is instant and
  /// stays offline-first. If the lookup succeeds, the names simply appear on the
  /// next History refresh; if it fails (offline), nothing is written.
  void _geocodeRide(int rideId, List<LatLng> route) {
    if (route.isEmpty) return;
    final start = route.first;
    final end = route.last;
    unawaited(() async {
      final startPlace =
          await GeocodingService.placeName(start.latitude, start.longitude);
      // Space the second lookup off the first so the two don't collide with the
      // platform Geocoder's rate limit (which was dropping one of the pair).
      await Future.delayed(const Duration(milliseconds: 300));
      final endPlace =
          await GeocodingService.placeName(end.latitude, end.longitude);
      if (startPlace == null && endPlace == null) return;
      await DatabaseService.instance
          .setRidePlaces(rideId, startPlace: startPlace, endPlace: endPlace);
    }());
  }

  /// Deletes the just-finished ride (and its track points) and returns to idle.
  Future<void> discardFinishedRide() async {
    final t = state.lastFinished;
    if (t != null) {
      await DatabaseService.instance.deleteRide(t.rideId);
    }
    _resetToIdle();
  }

  /// Dismisses the summary without deleting — the ride stays in the DB (crash-safe
  /// default when the rider just backs out). If a continuation was pending, the
  /// stint is still linked to its (open) trip so a lazy back-out doesn't orphan it.
  ///
  /// [fallbackName] is the summary's auto-generated suggestion. Backing out used
  /// to leave the ride as "Untitled ride" forever; now the suggestion stands in,
  /// but only for a ride that has no name at all — a name the rider typed and then
  /// backed out of confirming is theirs, and is never overwritten.
  Future<void> keepFinishedRide({String? fallbackName}) async {
    final tripId = state.continuingTripId;
    final t = state.lastFinished;
    if (t != null) {
      final auto = fallbackName?.trim() ?? '';
      if (auto.isNotEmpty) {
        final ride = await DatabaseService.instance.getRideById(t.rideId);
        if (ride != null && (ride.name?.trim().isEmpty ?? true)) {
          await DatabaseService.instance.setRideName(t.rideId, auto);
        }
      }
      if (tripId != null) {
        await DatabaseService.instance.setRideTrip(t.rideId, tripId);
      }
    }
    _resetToIdle(clearContinuation: true);
  }

  void _resetToIdle({bool clearContinuation = false}) {
    state = state.copyWith(
      isTracking: false,
      isPaused: false,
      phase: 'idle',
      countdown: 0,
      route: const [],
      speedSamples: const [],
      leanMaxLeftDegrees: 0,
      leanMaxRightDegrees: 0,
      clearTelemetry: true,
      clearFinished: true,
      clearContinuation: clearContinuation,
    );
  }

  @override
  void dispose() {
    _telemetrySub.cancel();
    _stoppedSub.cancel();
    _cancelledSub.cancel();
    super.dispose();
  }
}

/// Dated placeholder for an unnamed trip, e.g. `Trip · Jul 26`. Keeps a
/// History list of unnamed trips distinguishable until the rider renames them.
String _defaultTripName(DateTime when) {
  final local = when.toLocal();
  return 'Trip · ${shortMonth(local.month)} ${local.day}';
}

final trackingControllerProvider =
    StateNotifierProvider<TrackingController, TrackingUiState>((ref) {
  return TrackingController(ref.watch(trackingServiceProvider));
});
