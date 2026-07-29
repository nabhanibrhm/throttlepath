/// The denormalised route shape stored on `Ride.routeBlob`, and the geometry that
/// builds and reads it.
///
/// A History row must not cost a query. The full track lives in `TrackPoint`
/// (thousands of rows for a long ride); this reduces it to a few dozen points,
/// flattened to `[lat, lon, lat, lon, …]`, cheap enough to carry on the ride row
/// itself and draw straight into a sparkline.
///
/// Pure — no Isar, no plugins. Safe to call from the background isolate.
library;

import 'dart:math' as math;

/// Upper bound on points kept in a blob.
///
/// A card sparkline is ~100 dp wide, so past ~50 points the extra vertices are
/// sub-pixel. 48 points costs 768 bytes per ride.
const int kRouteBlobMaxPoints = 48;

/// One decoded blob vertex.
typedef RoutePoint = ({double lat, double lon});

/// Reduces [points] to at most [maxPoints] vertices and flattens them to the
/// interleaved form stored on the ride. Returns null when there is nothing worth
/// drawing (fewer than two points).
///
/// Simplification is Ramer–Douglas–Peucker rather than a uniform stride, because
/// a stride throws away exactly the vertices that carry the shape: a route with a
/// long straight and one tight switchback loses the switchback and reads as a
/// line. RDP keeps corners and discards the redundant middles.
List<double>? encodeRouteBlob(
  List<RoutePoint> points, {
  int maxPoints = kRouteBlobMaxPoints,
}) {
  if (points.length < 2) return null;
  final simplified = _simplifyToCount(points, maxPoints);
  final out = List<double>.filled(simplified.length * 2, 0);
  for (var i = 0; i < simplified.length; i++) {
    out[i * 2] = simplified[i].lat;
    out[i * 2 + 1] = simplified[i].lon;
  }
  return out;
}

/// Reads an interleaved blob back into points. Tolerates null, a stray odd length
/// (drops the trailing half-pair) and blobs too short to draw — a blob written by
/// an older build is untrusted input.
List<RoutePoint> decodeRouteBlob(List<double>? blob) {
  if (blob == null || blob.length < 4) return const [];
  final count = blob.length ~/ 2;
  return [
    for (var i = 0; i < count; i++) (lat: blob[i * 2], lon: blob[i * 2 + 1]),
  ];
}

/// Projects [points] into the unit square, y already flipped for screen space
/// (0 at the top). Returns an empty list for fewer than two points.
///
/// **Each axis is normalised independently**, so the trace always fills its box.
/// True aspect ratio was tried first and is wrong here: a card sparkline is about
/// 290 × 44 dp, and preserving proportions in a box that wide leaves a
/// north–south commute as an 8dp squiggle centred in an empty strip — measured on
/// a real Bekasi commute, which used a third of the card. A sparkline's whole job
/// is to be recognised at a glance, and it does that on the *pattern* of turns,
/// which independent scaling keeps while using every available pixel. The full
/// map, with real geometry, is one tap away.
///
/// An axis with no extent (a ride that never moved north–south) is centred rather
/// than divided by zero.
List<({double x, double y})> normalizeRoute(List<RoutePoint> points) {
  if (points.length < 2) return const [];

  var minX = double.infinity, maxX = -double.infinity;
  var minY = double.infinity, maxY = -double.infinity;
  for (final p in points) {
    if (p.lon < minX) minX = p.lon;
    if (p.lon > maxX) maxX = p.lon;
    if (p.lat < minY) minY = p.lat;
    if (p.lat > maxY) maxY = p.lat;
  }
  final spanX = maxX - minX;
  final spanY = maxY - minY;

  return [
    for (final p in points)
      (
        x: spanX <= 0 ? 0.5 : (p.lon - minX) / spanX,
        // Latitude grows north, screen y grows down.
        y: spanY <= 0 ? 0.5 : 1.0 - (p.lat - minY) / spanY,
      ),
  ];
}

/// RDP's worst case (a maximally unbalanced split every time — a real risk on
/// a many-hour recording nobody remembered to stop) is quadratic in point
/// count. A rider's real ride never approaches this — even 5.5 hours at 1 Hz
/// is under it — so it never touches normal behaviour; it only bounds the
/// freak case before the epsilon-search loop below gets a chance to run RDP
/// against the full track.
const int _maxRdpWorkingSet = 20000;

/// RDP with the tolerance searched for, rather than fixed: the caller cares about
/// a point budget, not about metres. Starts fine and coarsens geometrically until
/// the result fits, so a twisty route keeps more of its detail budget than a
/// straight one would need.
List<RoutePoint> _simplifyToCount(List<RoutePoint> points, int maxPoints) {
  if (points.length <= maxPoints) return points;
  final working = points.length > _maxRdpWorkingSet
      ? _stride(points, _maxRdpWorkingSet)
      : points;
  // ~1e-5 degrees is roughly a metre — below GPS noise, so the first pass mostly
  // just strips duplicate fixes.
  var epsilon = 1e-5;
  var result = working;
  for (var i = 0; i < 32; i++) {
    result = _rdp(working, epsilon);
    if (result.length <= maxPoints) return result;
    epsilon *= 1.8;
  }
  // Pathological input (every point a corner): fall back to a stride, still
  // keeping the true endpoints.
  return _stride(working, maxPoints);
}

List<RoutePoint> _rdp(List<RoutePoint> points, double epsilon) {
  final keep = List<bool>.filled(points.length, false);
  keep[0] = true;
  keep[points.length - 1] = true;
  // Explicit stack — a deep recursion on a few thousand fixes is avoidable.
  final stack = <(int, int)>[(0, points.length - 1)];
  while (stack.isNotEmpty) {
    final (first, last) = stack.removeLast();
    if (last <= first + 1) continue;
    var maxDist = -1.0;
    var index = first;
    for (var i = first + 1; i < last; i++) {
      final d = _perpendicularDistance(points[i], points[first], points[last]);
      if (d > maxDist) {
        maxDist = d;
        index = i;
      }
    }
    if (maxDist > epsilon) {
      keep[index] = true;
      stack.add((first, index));
      stack.add((index, last));
    }
  }
  return [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
}

/// Distance from [p] to the segment [a]–[b], in degrees. Degrees (not metres) is
/// fine here: the tolerance is only ever compared against itself.
double _perpendicularDistance(RoutePoint p, RoutePoint a, RoutePoint b) {
  final dx = b.lon - a.lon;
  final dy = b.lat - a.lat;
  if (dx == 0 && dy == 0) {
    return math.sqrt(math.pow(p.lon - a.lon, 2) + math.pow(p.lat - a.lat, 2));
  }
  final t = ((p.lon - a.lon) * dx + (p.lat - a.lat) * dy) / (dx * dx + dy * dy);
  final clamped = t.clamp(0.0, 1.0);
  final projX = a.lon + clamped * dx;
  final projY = a.lat + clamped * dy;
  return math.sqrt(
      math.pow(p.lon - projX, 2) + math.pow(p.lat - projY, 2));
}

List<RoutePoint> _stride(List<RoutePoint> points, int maxPoints) {
  final step = points.length / (maxPoints - 1);
  final out = <RoutePoint>[];
  for (var i = 0; i < maxPoints - 1; i++) {
    out.add(points[(i * step).floor()]);
  }
  out.add(points.last);
  return out;
}
