/// Route identity: the coarse "this journey, at this time of day" key that makes
/// repeats of the same ride recognisable, plus the naming that reads off it.
///
/// Pure — no Isar, no plugins, no `DateTime.now()`. Everything here is a function
/// of its arguments so the whole file is unit-testable and safe to call from the
/// background isolate.
library;

/// Geohash precision used for the route endpoints.
///
/// 5 characters is a cell of roughly 4.9 km × 4.9 km. That is deliberately loose:
/// the rider parks in a different bay, stops one street early, or the first fix
/// lands 200 m down the road, and the key must still match yesterday's ride. Go
/// finer (6 → ~1.2 km) and the same commute stops matching itself, which breaks
/// every feature built on this key.
const int kRouteKeyPrecision = 5;

const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

/// Encodes a coordinate as a geohash of [precision] characters.
///
/// Standard geohash: interleave longitude and latitude bits, most significant
/// first, five bits per base-32 character.
String geohash(double latitude, double longitude,
    {int precision = kRouteKeyPrecision}) {
  var latMin = -90.0, latMax = 90.0;
  var lonMin = -180.0, lonMax = 180.0;
  final out = StringBuffer();
  var isLon = true; // geohash starts with a longitude bit
  var bit = 0;
  var value = 0;

  while (out.length < precision) {
    if (isLon) {
      final mid = (lonMin + lonMax) / 2;
      if (longitude >= mid) {
        value = (value << 1) | 1;
        lonMin = mid;
      } else {
        value <<= 1;
        lonMax = mid;
      }
    } else {
      final mid = (latMin + latMax) / 2;
      if (latitude >= mid) {
        value = (value << 1) | 1;
        latMin = mid;
      } else {
        value <<= 1;
        latMax = mid;
      }
    }
    isLon = !isLon;
    if (++bit == 5) {
      out.write(_base32[value]);
      bit = 0;
      value = 0;
    }
  }
  return out.toString();
}

/// Coarse time-of-day bands. The bands exist to name rides and to keep a morning
/// commute distinct from the same road ridden at midnight — not to be precise, so
/// the boundaries are round hours a rider would recognise.
enum RidePeriod {
  night('night', 'Night'),
  morning('morning', 'Morning'),
  midday('midday', 'Midday'),
  afternoon('afternoon', 'Afternoon'),
  evening('evening', 'Evening');

  const RidePeriod(this.tag, this.label);

  /// Stable token embedded in a [buildRouteKey] string. Never change these — old
  /// rides carry them, and a rename would silently split every route in two.
  final String tag;

  /// Capitalised word used to open a ride name ("Morning ride to Lembang").
  final String label;

  /// The band a local wall-clock time falls in.
  static RidePeriod of(DateTime when) {
    final hour = when.toLocal().hour;
    if (hour < 5) return RidePeriod.night;
    if (hour < 11) return RidePeriod.morning;
    if (hour < 15) return RidePeriod.midday;
    if (hour < 18) return RidePeriod.afternoon;
    if (hour < 23) return RidePeriod.evening;
    return RidePeriod.night;
  }

  static RidePeriod? fromTag(String? tag) {
    for (final p in RidePeriod.values) {
      if (p.tag == tag) return p;
    }
    return null;
  }
}

/// Builds the `Ride.routeKey` for a ride that started at [startTime] and ran from
/// ([startLat], [startLon]) to ([endLat], [endLon]).
///
/// Format: `<startHash>><endHash>@<period>` — e.g. `qqguw>qqgv2@morning`. The
/// separators are characters no geohash or period tag contains, so the key parses
/// back apart unambiguously.
String buildRouteKey({
  required DateTime startTime,
  required double startLat,
  required double startLon,
  required double endLat,
  required double endLon,
}) {
  final from = geohash(startLat, startLon);
  final to = geohash(endLat, endLon);
  return '$from>$to@${RidePeriod.of(startTime).tag}';
}

/// The three parts of a route key, or null if [key] is null/unparseable.
///
/// Written defensively rather than assuming the format: a key read back from a
/// ride recorded by an older build is untrusted input.
({String from, String to, RidePeriod? period})? parseRouteKey(String? key) {
  if (key == null) return null;
  final at = key.lastIndexOf('@');
  if (at <= 0) return null;
  final arrow = key.indexOf('>');
  if (arrow <= 0 || arrow >= at) return null;
  return (
    from: key.substring(0, arrow),
    to: key.substring(arrow + 1, at),
    period: RidePeriod.fromTag(key.substring(at + 1)),
  );
}

/// True when a route key's endpoints land in the same coarse cell — the ride came
/// back to where it started (a loop, or an out-and-back).
bool isLoopRoute(String? key) {
  final parts = parseRouteKey(key);
  return parts != null && parts.from == parts.to;
}

/// How many earlier rides on the same route it takes before a route counts as
/// routine enough to call a "commute" rather than a "ride".
const int kCommuteThreshold = 2;

/// Name suggestions for a just-finished ride, best first.
///
/// The first entry is what the app pre-fills; the rest are the one-tap
/// alternatives (F16 — the common case should be zero typing). [priorRidesOnRoute]
/// is how many *earlier* rides already share this ride's `routeKey`.
///
/// Always returns at least one non-empty suggestion, so callers never have to
/// handle an empty list.
List<String> rideNameSuggestions({
  required DateTime startTime,
  String? startPlace,
  String? endPlace,
  bool isLoop = false,
  int priorRidesOnRoute = 0,
}) {
  final period = RidePeriod.of(startTime).label;
  final from = startPlace?.trim();
  final to = endPlace?.trim();
  final hasFrom = from != null && from.isNotEmpty;
  final hasTo = to != null && to.isNotEmpty;
  // Place names are coarse too, so a loop often reports the same name twice.
  final sameName = hasFrom && hasTo && from.toLowerCase() == to.toLowerCase();
  final loop = isLoop || sameName;

  final out = <String>[];
  void add(String s) {
    if (s.isNotEmpty && !out.contains(s)) out.add(s);
  }

  // A route ridden repeatedly at the same time of day is a routine, and that is
  // the most useful thing the name can say.
  if (priorRidesOnRoute >= kCommuteThreshold) {
    add('$period commute');
  }
  if (loop) {
    add(hasFrom ? '$period loop from $from' : '$period loop');
  } else if (hasTo) {
    add('$period ride to $to');
    if (hasFrom) add('$from → $to');
  } else if (hasFrom) {
    add('$period ride from $from');
  }
  add('$period ride');
  if (hasTo && !loop) add('$to run');

  return out.take(3).toList();
}
