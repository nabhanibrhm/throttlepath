import '../core/geo.dart';
import '../data/database_service.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import 'geocoding_service.dart';

/// How close two endpoints have to be before they are the same place.
///
/// At the granularity these labels are written in — "subdistrict, city" — two
/// points this close cannot honestly be two different places. It is a loose
/// radius on purpose: the question is "is this the same spot", not "did the bike
/// move", and every real trip handoff in the ride that motivated it landed within
/// 10 m.
const double kSamePlaceMeters = 250;

/// What a relabel pass actually did.
///
/// [updated] and [failed] are counted apart because they used to be
/// indistinguishable, and that is what hid a total failure for weeks. A lookup
/// that returns null leaves the ride's existing name in place — correct, since a
/// transient failure must never wipe a good name — and the ride was then counted
/// as simply "unchanged". A pass in which *every* lookup failed therefore
/// reported the same `0` as a pass in which every name was already right, and the
/// UI rendered both as "Place names are already up to date."
///
/// [busy] is the third outcome the old `int` could not express: the shared
/// `_running` guard rejecting the call, which also returned 0.
typedef RelabelOutcome = ({int updated, int failed, bool busy});

/// Best-effort backfill of missing ride start/end place names.
///
/// Geocoding runs once, fire-and-forget, right after a ride is saved
/// (`_geocodeRide`) — so a ride saved while offline (common straight after a
/// ride, especially in a tunnel/train) never gets place names, and was never
/// retried. This fills that gap: whenever the History screen is shown it
/// re-attempts a bounded number of rides that still lack a place, so they fill
/// in later once the phone is back online.
///
/// Stays offline-first: every lookup is best-effort and online-only, so this is
/// a silent no-op when offline. A guard prevents overlapping runs.
class GeocodeBackfill {
  GeocodeBackfill._();
  static final GeocodeBackfill instance = GeocodeBackfill._();

  /// Max rides to attempt per invocation — keeps the platform Geocoder within
  /// its rate limit and avoids a burst on a long history. Older rides are
  /// picked up on later visits.
  static const int _maxPerRun = 4;

  /// Gap left between any two lookups fired by the same pass.
  ///
  /// Android's platform `Geocoder` is rate-limited, and a burst is answered with
  /// "Service not Available" for effectively all of it. [run] has always stayed
  /// under that by capping itself at [_maxPerRun] rides, and the post-save
  /// geocode spaces its pair for the same reason. [relabelAll] had neither guard
  /// and fired two lookups per ride across the entire history as fast as they
  /// resolved — 164 of them on the device this was found on, of which zero came
  /// back, twice in a row.
  static const Duration _lookupSpacing = Duration(milliseconds: 400);

  bool _running = false;

  /// The label a stint's start already has by virtue of the trip it sits in, or
  /// null when the chain cannot say.
  ///
  /// A trip is a chain, and a stint *begins where the one before it ended*. That
  /// is not an inference about the data, it is what a stint is — on the ride that
  /// motivated this, 9 of the 10 handoffs agreed to within 10 m. So a join is
  /// **one place**, and one place gets one label: the earlier observation's. The
  /// later one is not looked up at all.
  ///
  /// This exists because the platform Geocoder can be *confidently wrong* rather
  /// than merely unavailable. Asked about two points 3 m apart it answered
  /// "Parungkuda, Sukabumi" and "Bekasi Timur, Bekasi" — the second some 130 km
  /// from where the bike was — and asked again it returned the same wrong answer,
  /// so retrying can never fix it. Nothing *within* a single lookup distinguishes
  /// a good answer from that one; only a second look at the same spot does.
  ///
  /// Deliberately one-directional. Letting an end also inherit from the next
  /// stint's start would make the two ends of a join inherit from each other, and
  /// a wrong label would flow in both directions along the trip. Reading the chain
  /// forward in time gives each join exactly one source. Note the consequence,
  /// which is a feature rather than a risk: if that source is wrong, one *place*
  /// is labelled wrong — where today the same place can carry two different names
  /// and one of them is guaranteed to be.
  ///
  /// Costs no lookups; it removes one, which keeps a pass further under the rate
  /// limit as a side effect.
  ///
  /// [myStart] is the caller's already-computed `rideEndpoints(...).start`, so a
  /// pass does not read the same track twice.
  Future<String?> _chainedStartPlace(Ride ride, TrackPoint? myStart) async {
    final tripId = ride.tripId;
    if (tripId == null || myStart == null) return null;
    final db = DatabaseService.instance;
    final stints = await db.getStintsForTrip(tripId);
    final at = stints.indexWhere((s) => s.id == ride.id);
    if (at <= 0) return null; // not in the trip, or it is the first stint

    final previous = stints[at - 1];
    final label = previous.endPlace;
    if (label == null) return null;

    // The neighbour's endpoint goes through `rideEndpoints` too, so this asks the
    // same "where was this ride" question every other caller does — a phantom at
    // either end is already excluded before the two are compared.
    final theirs =
        rideEndpoints(await db.getTrackPointsForRide(previous.id)).end;
    if (theirs == null) return null;

    final metres = haversineMeters(myStart.latitude, myStart.longitude,
        theirs.latitude, theirs.longitude);
    return metres <= kSamePlaceMeters ? label : null;
  }

  /// Reverse-geocodes [start] and/or [end], spaced so the pair cannot trip the
  /// rate limit on its own. Either may be null, meaning "nothing to look up
  /// for that end" — [run] uses that to re-attempt only the field still missing.
  ///
  /// Reports how many lookups came back empty so callers can tell a failed pass
  /// from a pass with nothing to do.
  Future<({String? start, String? end, int failed})> _lookupEnds(
    TrackPoint? start,
    TrackPoint? end,
  ) async {
    var failed = 0;
    String? startPlace;
    String? endPlace;

    if (start != null) {
      startPlace =
          await GeocodingService.placeName(start.latitude, start.longitude);
      if (startPlace == null) failed++;
    }
    if (start != null && end != null) await Future.delayed(_lookupSpacing);
    if (end != null) {
      endPlace = await GeocodingService.placeName(end.latitude, end.longitude);
      if (endPlace == null) failed++;
    }
    return (start: startPlace, end: endPlace, failed: failed);
  }

  /// Attempts to resolve places for rides still missing them. Calls [onUpdated]
  /// once if any ride was filled in, so the caller can refresh the list.
  Future<void> run({required void Function() onUpdated}) async {
    if (_running) return;
    _running = true;
    try {
      final db = DatabaseService.instance;
      final missing = await db.getRidesMissingPlaces();
      var updated = 0;
      for (final ride in missing.take(_maxPerRun)) {
        // Only look up the field(s) actually missing; keep any already resolved.
        //
        // The main cluster's endpoints, not the stored first/last fix — a phantom
        // at either end would otherwise name the ride after somewhere the rider
        // never was. See [rideEndpoints].
        final ends = ride.startPlace == null || ride.endPlace == null
            ? rideEndpoints(await db.getTrackPointsForRide(ride.id))
            : const (start: null, end: null);
        final looked = await _lookupEnds(
          ride.startPlace == null ? ends.start : null,
          ride.endPlace == null ? ends.end : null,
        );

        final startPlace = looked.start ?? ride.startPlace;
        final endPlace = looked.end ?? ride.endPlace;

        // Nothing new resolved (still offline / genuinely unresolvable) — skip
        // the write and try again on a later visit.
        if (startPlace == ride.startPlace && endPlace == ride.endPlace) continue;

        await db.setRidePlaces(ride.id,
            startPlace: startPlace, endPlace: endPlace);
        updated++;
      }
      if (updated > 0) onUpdated();
    } finally {
      _running = false;
    }
  }

  /// Re-looks-up **one** ride's start/end places.
  ///
  /// Two lookups instead of the whole history, which is what makes it usable at
  /// all: repairing a single wrong name via [relabelAll] costs one lookup per end
  /// of every ride on the device, and that burst is the very thing the platform
  /// Geocoder refuses to serve. Same rules as [relabelAll] otherwise — an
  /// endpoint that fails to resolve keeps its existing name rather than being
  /// wiped.
  Future<RelabelOutcome> relabelRide(int rideId) async {
    if (_running) return (updated: 0, failed: 0, busy: true);
    _running = true;
    try {
      final db = DatabaseService.instance;
      final ride = await db.getRideById(rideId);
      if (ride == null) return (updated: 0, failed: 0, busy: false);

      final ends = rideEndpoints(await db.getTrackPointsForRide(rideId));
      // Where the trip chain already knows the answer, take it and skip the
      // lookup — see [_chainedPlaces].
      final chainedStart = await _chainedStartPlace(ride, ends.start);
      final looked = await _lookupEnds(
        chainedStart == null ? ends.start : null,
        ends.end,
      );
      final startPlace = chainedStart ?? looked.start ?? ride.startPlace;
      final endPlace = looked.end ?? ride.endPlace;

      if (startPlace == ride.startPlace && endPlace == ride.endPlace) {
        return (updated: 0, failed: looked.failed, busy: false);
      }
      await db.setRidePlaces(rideId,
          startPlace: startPlace, endPlace: endPlace);
      return (updated: 1, failed: looked.failed, busy: false);
    } finally {
      _running = false;
    }
  }

  /// One-time, user-initiated re-geocode of EVERY ride's start/end place names
  /// to the current label format — e.g. upgrading old "subdistrict"-only labels
  /// to "subdistrict, city". Unlike [run], this re-attempts rides that already
  /// have names (trip stints included, since [DatabaseService.getAllRides] spans
  /// them).
  ///
  /// Best-effort and online-only: a ride whose lookup fails keeps its existing
  /// name (never wiped on a transient error), and a ride that resolves to the
  /// same value is left untouched. Calls [onProgress] after each ride and
  /// returns what the pass actually did — see [RelabelOutcome], and note that
  /// "changed nothing" and "reached nothing" are different answers.
  Future<RelabelOutcome> relabelAll(
      {void Function(int done, int total)? onProgress}) async {
    if (_running) return (updated: 0, failed: 0, busy: true);
    _running = true;
    try {
      final db = DatabaseService.instance;
      // Oldest first. `getAllRides` is newest-first, but a stint inherits its
      // *predecessor's* end label, so the predecessor has to be settled before it
      // is read — otherwise a join converges only on the second pass.
      final rides = (await db.getAllRides()).reversed.toList();
      var updated = 0;
      var failed = 0;
      for (var i = 0; i < rides.length; i++) {
        // Paced, not hammered. Without this the whole pass is answered with
        // nothing at all — see [_lookupSpacing].
        if (i > 0) await Future.delayed(_lookupSpacing);
        final ride = rides[i];

        // Main-cluster endpoints, for [run]'s reason: this is the surface that
        // *fixes* a badly-named ride, so it must not re-apply the phantom's name.
        final ends = rideEndpoints(await db.getTrackPointsForRide(ride.id));
        // A trip join the chain can answer needs no lookup, and must not be
        // allowed to disagree with itself — see [_chainedPlaces].
        final chainedStart = await _chainedStartPlace(ride, ends.start);
        final looked = await _lookupEnds(
          chainedStart == null ? ends.start : null,
          ends.end,
        );
        failed += looked.failed;

        // Chain first, then a fresh lookup; on failure fall back to the old value.
        final startPlace = chainedStart ?? looked.start ?? ride.startPlace;
        final endPlace = looked.end ?? ride.endPlace;

        if (startPlace != ride.startPlace || endPlace != ride.endPlace) {
          await db.setRidePlaces(ride.id,
              startPlace: startPlace, endPlace: endPlace);
          updated++;
        }
        onProgress?.call(i + 1, rides.length);
      }
      return (updated: updated, failed: failed, busy: false);
    } finally {
      _running = false;
    }
  }
}
