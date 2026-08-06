import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/speed_palette.dart';
import '../core/track_runs.dart';
import '../core/units.dart';
import '../data/models/track_point.dart';
import '../theme/app_theme.dart';
import 'no_track_notice.dart';
import 'tracking_map_screen.dart' show basemapUrl;

/// The recorded route drawn as a speed-coloured polyline with start/end markers
/// and a gradient legend.
///
/// Shared by the ride detail header and [FullScreenRouteMap] so the fullscreen
/// view is the *same* map, not a second implementation that can drift from it.
class RouteMapView extends StatelessWidget {
  const RouteMapView({
    super.key,
    required this.points,
    required this.unit,
    this.padding = 48,
    this.maxZoom = 17,
  });

  final List<TrackPoint> points;
  final SpeedUnit unit;

  /// Inset around the fitted route.
  final double padding;
  final double maxZoom;

  /// Number of quantized speed→color bands. Consecutive segments in the same
  /// band merge into one polyline (run-length), so a steady cruise draws a few
  /// polylines instead of one-per-fix while keeping the exact geometry.
  static const int _bands = 26;

  /// Dash geometry for a gap connector, in logical pixels: on, off.
  static const List<double> _gapDash = [12, 10];

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final route = [for (final p in points) LatLng(p.latitude, p.longitude)];

    if (route.isEmpty) {
      return const NoTrackNotice(subject: 'ride');
    }

    final speeds = [for (final p in points) p.speedMps * 3.6]; // km/h
    final maxSpeed = speeds.fold(0.0, (m, s) => s > m ? s : m);
    // Runs of continuously-tracked riding. The caller has already dropped any
    // displaced excursion; what is left are honest blackouts, and drawing
    // straight through one would claim roads nobody rode.
    final runs = splitIntoRuns(points, fixOf: trackPointFix);
    final segments = [
      ..._gapConnectors(runs, cx),
      for (final run in _runRanges(runs))
        ..._speedSegments(route, speeds, maxSpeed, run.from, run.to),
    ];

    // Map, then the legend as a real row beneath it (spec 7.2). It used to float
    // in the map's bottom-left corner, where it sat on top of whatever road
    // happened to be there and needed a translucent panel and a border to stay
    // readable — chrome that existed only because of where it was. Below the map
    // it needs none of that, and it stops covering part of the route it explains.
    //
    // Both the inline detail map and `FullScreenRouteMap` render through this one
    // widget, so this moves the legend in both at once.
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              FlutterMap(
                options: MapOptions(
                  backgroundColor: cx.canvas,
                  initialCenter: route.first,
                  initialZoom: 15,
                  // Fit the whole recorded route in view. A single-point ride
                  // keeps the initialCenter/zoom above (a coordinates fit needs
                  // >= 2).
                  initialCameraFit: route.length >= 2
                      ? CameraFit.coordinates(
                          coordinates: route,
                          padding: EdgeInsets.all(padding),
                          maxZoom: maxZoom,
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
                  if (segments.isNotEmpty) PolylineLayer(polylines: segments),
                  MarkerLayer(
                    markers: [
                      _endpointMarker(route.first, cx.accent), // start
                      if (route.length >= 2)
                        _endpointMarker(route.last, cx.danger), // end
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        if (maxSpeed > 0) SpeedLegendRow(maxSpeedKmh: maxSpeed, unit: unit),
      ],
    );
  }

  /// Half-open `[from, to)` index ranges into the flat point list, one per run.
  List<({int from, int to})> _runRanges(List<List<TrackPoint>> runs) {
    final out = <({int from, int to})>[];
    var at = 0;
    for (final run in runs) {
      out.add((from: at, to: at + run.length));
      at += run.length;
    }
    return out;
  }

  /// A dimmed dash across each blackout, joining the last fix before it to the
  /// first fix after.
  ///
  /// Deliberately *not* on the speed gradient: any colour from the palette would
  /// be read off the legend as a speed, and there is no speed here — nothing was
  /// measured. A neutral dash reads as what it is, an inference, and it keeps
  /// reading that way when the gap is 16 km instead of 400 m.
  List<Polyline> _gapConnectors(List<List<TrackPoint>> runs, AppPalette cx) => [
        for (var i = 1; i < runs.length; i++)
          if (runs[i - 1].isNotEmpty && runs[i].isNotEmpty)
            Polyline(
              points: [
                LatLng(runs[i - 1].last.latitude, runs[i - 1].last.longitude),
                LatLng(runs[i].first.latitude, runs[i].first.longitude),
              ],
              strokeWidth: 3.5,
              color: cx.textDim.withValues(alpha: 0.55),
              pattern: StrokePattern.dashed(segments: _gapDash),
            ),
      ];

  /// Builds one polyline per run of consecutive segments sharing a speed band,
  /// colored via [SpeedPalette], over the half-open range `[from, to)`. Each run
  /// reuses the previous run's boundary vertex so the colored line stays
  /// continuous (no gaps at band changes).
  List<Polyline> _speedSegments(
    List<LatLng> route,
    List<double> speeds,
    double maxSpeed,
    int from,
    int to,
  ) {
    if (to - from < 2) return const [];
    int bandOf(int seg) {
      // Segment `seg` joins route[seg-1]→route[seg]; color by its mean speed.
      final s = (speeds[seg - 1] + speeds[seg]) / 2;
      final t = maxSpeed <= 0 ? 0.0 : (s / maxSpeed).clamp(0.0, 1.0);
      return (t * (_bands - 1)).round();
    }

    final out = <Polyline>[];
    var runStart = from + 1; // first segment index within this run
    var runBand = bandOf(runStart);
    void flush(int endSeg) {
      out.add(Polyline(
        points: route.sublist(runStart - 1, endSeg + 1),
        strokeWidth: 5,
        color: SpeedPalette.at(runBand / (_bands - 1)),
      ));
    }

    for (var seg = from + 2; seg < to; seg++) {
      final band = bandOf(seg);
      if (band != runBand) {
        flush(seg - 1);
        runStart = seg;
        runBand = band;
      }
    }
    flush(to - 1);
    return out;
  }

  Marker _endpointMarker(LatLng point, Color color) => Marker(
        point: point,
        width: 20,
        height: 20,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 3),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.6),
                blurRadius: 10,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      );
}

/// Gradient scale explaining the speed-colored route: a Turbo bar from 0 to the
/// ride's max speed, in the rider's chosen unit.
///
/// **One row beneath the map** (spec 7.2), not a floating panel on it. As an
/// overlay it needed a translucent fill and a border to survive whatever was
/// under it, and it covered a corner of the route it was there to explain. On the
/// flat canvas it needs neither, and the row it occupies is 36dp the map gives
/// back rather than 36dp the map loses.
///
/// The range still reads as `0 – 81` rather than three separate tick numbers: a
/// horizontal bar spanning the full width has no room for stacked tick labels,
/// and the ends are what a rider checks — "is the red on this route 80 or 140?".
class SpeedLegendRow extends StatelessWidget {
  const SpeedLegendRow({
    super.key,
    required this.maxSpeedKmh,
    required this.unit,
  });

  final double maxSpeedKmh;
  final SpeedUnit unit;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final top = unit.speed(maxSpeedKmh);

    return Semantics(
      label: 'Route colour scale, 0 to ${top.toStringAsFixed(0)} '
          '${unit.speedLabel}',
      // One label for the whole strip: a gradient bar and two numbers announced
      // separately would be three fragments describing one scale.
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: kRowGutter,
            vertical: 10,
          ),
          decoration: BoxDecoration(
            color: cx.canvas,
            border: Border(bottom: BorderSide(color: cx.border)),
          ),
          child: Row(
            children: [
              Text(
                'SPEED ${unit.speedLabel}',
                style: t.labelSmall!.copyWith(letterSpacing: 0.8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    gradient: LinearGradient(
                      colors: SpeedPalette.gradient,
                      stops: SpeedPalette.gradientStops,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('0 – ${top.toStringAsFixed(0)}', style: t.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

/// The route map, full screen (F30).
///
/// A 320dp-tall map inside a scrolling page is enough to recognise a route and
/// not enough to inspect one — pinching it fights the page scroll for the same
/// gesture. This gives the map the whole screen and its own back button.
class FullScreenRouteMap extends StatelessWidget {
  const FullScreenRouteMap({
    super.key,
    required this.points,
    required this.unit,
    required this.title,
  });

  final List<TrackPoint> points;
  final SpeedUnit unit;
  final String title;

  static Future<void> open(
    BuildContext context, {
    required List<TrackPoint> points,
    required SpeedUnit unit,
    required String title,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            FullScreenRouteMap(points: points, unit: unit, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Scaffold(
      backgroundColor: cx.canvas,
      appBar: AppBar(
        backgroundColor: cx.canvas,
        foregroundColor: cx.textBright,
        elevation: 0,
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
      ),
      body: RouteMapView(points: points, unit: unit, padding: 32, maxZoom: 18),
    );
  }
}
