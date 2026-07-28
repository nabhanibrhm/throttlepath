import 'package:flutter/material.dart';

import '../core/route_blob.dart';
import '../theme/app_theme.dart';

/// The shape of a ride, drawn from the downsampled `Ride.routeBlob` — no map
/// tiles, no network, no query.
///
/// A History row's job is to let the rider recognise a ride at a glance, and the
/// shape of the route does that faster than any number can (F20). Renders nothing
/// at all when the blob is missing or too short, so a caller can drop it straight
/// into a column without a conditional.
class RouteSparkline extends StatelessWidget {
  const RouteSparkline({
    super.key,
    required this.blob,
    this.height = 34,
    this.color,
    this.strokeWidth = 1.8,
  });

  /// The interleaved `[lat, lon, …]` blob straight off the ride.
  final List<double>? blob;
  final double height;

  /// Line colour; defaults to the palette's amber ink.
  final Color? color;
  final double strokeWidth;

  /// True when [blob] has enough of a shape to be worth drawing — lets callers
  /// skip surrounding padding as well as the line itself.
  static bool canDraw(List<double>? blob) => decodeRouteBlob(blob).length >= 2;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final points = normalizeRoute(decodeRouteBlob(blob));
    if (points.length < 2) return const SizedBox.shrink();
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparklinePainter(
          points: points,
          color: color ?? cx.accentInk,
          endColor: cx.textBright,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.points,
    required this.color,
    required this.endColor,
    required this.strokeWidth,
  });

  final List<({double x, double y})> points;
  final Color color;
  final Color endColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by the cap radius plus the end dot, so neither gets clipped at the
    // edges of a route that touches its own bounding box (every route does — the
    // normalisation fits it exactly).
    const dotRadius = 2.6;
    final inset = dotRadius + strokeWidth;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;
    if (w <= 0 || h <= 0) return;

    Offset at(({double x, double y}) p) =>
        Offset(inset + p.x * w, inset + p.y * h);

    final path = Path()..moveTo(at(points.first).dx, at(points.first).dy);
    for (final p in points.skip(1)) {
      final o = at(p);
      path.lineTo(o.dx, o.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Start hollow, end filled — the direction of travel, without an arrowhead
    // that would be indistinguishable from a corner at this size.
    final start = at(points.first);
    final end = at(points.last);
    canvas.drawCircle(
      start,
      dotRadius,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    canvas.drawCircle(end, dotRadius, Paint()..color = endColor);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color ||
      old.endColor != endColor ||
      old.strokeWidth != strokeWidth ||
      old.points != points;
}
