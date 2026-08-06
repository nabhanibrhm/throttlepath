import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../core/date_format.dart';
import '../core/duration_format.dart';
import '../core/speed_palette.dart';
import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';

/// The shareable card layouts the rider can pick between before exporting.
///
/// All render on a fully transparent canvas (no background panel or map tiles) so
/// the sticker drops cleanly onto a photo/video or saves as a transparent PNG.
///
/// **The minimal-look spec assumed an opaque `#0E0E0F` card at 1080×1350.** Both
/// are wrong about this app: the canvas is transparent by design — that is what
/// makes these stickers rather than images — and it is 360×640 logical, exported
/// at 1080×1920 (9:16, Story). The spec's *compositions* are applied below; its
/// background and its aspect ratio are not, because changing either is a product
/// decision about what a shared ride is, not a restyle.
enum ShareLayout {
  /// Route down the left at full height, stats in a right-hand column under a
  /// promoted distance.
  split('Split', 'Route beside a stat column'),

  /// Route fills the upper frame, one stat band along the foot.
  stacked('Stacked', 'Route above a band of stats'),

  /// Distance large at the top, three stats, then the route takes the rest.
  statsTop('Stats first', 'Stats above the route'),

  /// Speed-coloured route with a slim vertical scale beside it; max speed leads.
  speed('Speed map', 'Route coloured by speed'),

  /// Route edge to edge and clipped, stats in a gradient foot. The only one that
  /// reads at thumbnail size.
  fullBleed('Full bleed', 'Route edge to edge'),

  /// A ride stub: start and end places, the route between two dashed rules.
  ticket('Ticket', 'Start to end, as a stub'),

  /// No map — the speed curve itself, for when the GPS wandered.
  trace('Trace', 'The speed curve, no map');

  const ShareLayout(this.title, this.blurb);

  final String title;
  final String blurb;
}

/// A shareable ride card, rendered off-screen into a 9:16 PNG (see
/// [captureWidgetToPng]).
///
/// Styled after Strava's share sticker: a fully transparent canvas with the
/// route line and stats floating directly on it (no map tiles — ThrottlePath is
/// offline-first, so the route is a vector polyline — and no background panel,
/// so nothing blocks a photo/video placed behind it), in ThrottlePath's amber
/// brand palette. Every piece of text carries a dark drop shadow (in place of a
/// solid panel) so it stays legible over whatever ends up behind it.
///
/// It's deliberately independent of the app's light/dark theme: the shared image
/// always uses the dark amber brand look so it reads the same for everyone.
/// Speeds and distances still honour the rider's [unit] choice.
class ShareCard extends StatelessWidget {
  const ShareCard({
    super.key,
    required this.ride,
    required this.points,
    required this.unit,
    this.layout = ShareLayout.split,
    this.stintStarts = const [],
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final ShareLayout layout;

  /// Indices into [points] where each stint (after the first) begins — set when
  /// this card renders a whole multi-stint trip so the route draws each stint as a
  /// separate colored polyline instead of one line with false join connectors.
  /// Empty for a single ride.
  final List<int> stintStarts;

  /// Bundled brand mark — clean amber speedometer on transparent. Precached
  /// before capture (the render only waits a couple of frames).
  static const brandLogo = AssetImage('assets/icon/logo_foreground.png');

  // Brand colours, fixed for the shared artwork.
  static const _amber = Color(0xFFFFB22C);
  static const _ink = Color(0xFFF2F2F0);
  static const _dim = Color(0xFFD8D8D8);

  /// Label grey — the wordmark and the small stat captions.
  static const _muted = Color(0xFF8A8A8A);

  /// Stands in for a background panel: keeps text readable over an arbitrary
  /// photo/video the rider places behind this transparent sticker.
  static const _textShadow = [
    Shadow(color: Color(0xE6000000), blurRadius: 10, offset: Offset(0, 2)),
  ];

  /// Inset from the sticker's edge. Every layout but [ShareLayout.fullBleed]
  /// applies it to the whole card; that one applies it only to its foot.
  static const double _pad = 22;

  @override
  Widget build(BuildContext context) {
    final content = switch (layout) {
      ShareLayout.split => _buildSplit(),
      ShareLayout.stacked => _buildStacked(),
      ShareLayout.statsTop => _buildStatsTop(),
      ShareLayout.speed => _buildSpeed(),
      ShareLayout.fullBleed => _buildFullBleed(),
      ShareLayout.ticket => _buildTicket(),
      ShareLayout.trace => _buildTrace(),
    };

    return DefaultTextStyle(
      style: const TextStyle(
        fontFamily: 'Inter',
        color: _ink,
        shadows: _textShadow,
      ),
      child: SizedBox(
        width: 360,
        height: 640,
        // Full-frame, not centred. Every layout used to float a min-height column
        // in the middle of the canvas, which is why the wordmark appeared to hover
        // mid-card (spec 9.1) — it was simply the last item in a short column. The
        // layouts now fill the height and anchor their own feet.
        child: layout == ShareLayout.fullBleed
            ? content
            : Padding(padding: const EdgeInsets.all(_pad), child: content),
      ),
    );
  }

  // --- Layouts --------------------------------------------------------------

  Widget _buildSplit() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // Route takes the full height of the frame rather than sitting in a
              // 210dp box floated mid-card.
              Expanded(child: _route()),
              const SizedBox(width: 18),
              SizedBox(
                width: 104,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _hero(_distance, _dLabel, size: 30, align: TextAlign.right),
                    const SizedBox(height: 12),
                    _rule(),
                    const SizedBox(height: 12),
                    // Five stats, not six: PACE is gone (spec 9.4). It is a
                    // running metric — minutes per kilometre means nothing at 60
                    // km/h — and it was the sixth thing competing to be read.
                    _statLine('TIME', _totalTime),
                    _statLine('MOVING', _movingTime),
                    _statLine('AVG', '$_avg $_sLabel'),
                    _statLine('MAX', '$_max $_sLabel'),
                  ],
                ),
              ),
            ],
          ),
        ),
        _wordmark(),
      ],
    );
  }

  Widget _buildStacked() {
    return Column(
      children: [
        Expanded(child: _route()),
        const SizedBox(height: 14),
        _rule(),
        const SizedBox(height: 13),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _hero(_distance, _dLabel, size: 30),
            const Spacer(),
            _statBlock('TIME', _totalTime),
            const SizedBox(width: 14),
            _statBlock('AVG', _avg),
            const SizedBox(width: 14),
            _statBlock('MAX', _max),
          ],
        ),
        _wordmark(),
      ],
    );
  }

  Widget _buildStatsTop() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero(_distance, _dLabel, size: 44),
        const SizedBox(height: 12),
        _rule(),
        const SizedBox(height: 11),
        Row(
          children: [
            Expanded(child: _statBlock('TIME', _totalTime)),
            Expanded(child: _statBlock('AVG $_sLabel', _avg)),
            Expanded(child: _statBlock('MAX $_sLabel', _max)),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _route()),
        _wordmark(),
      ],
    );
  }

  Widget _buildSpeed() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _route(colorBySpeed: true)),
              const SizedBox(width: 12),
              // The legend is a slim vertical scale beside the route now, not a
              // panel overlapping it (spec's Speed map row).
              _verticalSpeedScale(),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _rule(),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Max speed leads on this card — it is the one the colours are about.
            _hero(_max, _sLabel, size: 30, label: 'MAX SPEED'),
            const Spacer(),
            _statBlock('DISTANCE', '$_distance $_dLabel', alignEnd: true),
          ],
        ),
        _wordmark(),
      ],
    );
  }

  /// Route edge to edge, clipped, with the stats over a gradient foot.
  ///
  /// The one layout that survives an Instagram thumbnail, because the route is
  /// the whole frame rather than a shape inside a margin. The scrim is the only
  /// place this card departs from "no background": it is a gradient to fully
  /// transparent, so it darkens just enough of whatever is behind the text to
  /// keep it readable and disappears above the foot.
  Widget _buildFullBleed() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _route(fillBox: true, padding: 0),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xF71A1204), Color(0x00000000)],
              stops: [0.0, 0.46],
            ),
          ),
        ),
        Positioned(
          left: _pad,
          right: _pad,
          bottom: _pad,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _hero(_distance, _dLabel, size: 42, amber: false),
              const SizedBox(height: 8),
              Row(
                children: [
                  _statLine('', _totalTime, inline: true),
                  const SizedBox(width: 14),
                  _statLine('', '$_avg avg', inline: true),
                  const SizedBox(width: 14),
                  _statLine('', '$_max peak', inline: true, amber: true),
                ],
              ),
              _wordmark(),
            ],
          ),
        ),
      ],
    );
  }

  /// A ride stub — where it started, where it ended, and the route in between.
  ///
  /// The layout for a ride whose *places* are the story: a named commute, a trip
  /// to somewhere. Falls back to the times when a ride has no geocoded places, so
  /// it never renders an empty header.
  Widget _buildTicket() {
    final start = ride.startPlace?.trim();
    final end = ride.endPlace?.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'RIDE LOG',
              style: const TextStyle(
                color: _amber,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                shadows: _textShadow,
              ),
            ),
            const Spacer(),
            Text(_stamp, style: _captionStyle),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          start?.isNotEmpty == true ? start! : 'Start',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _placeStyle,
        ),
        // A vertical rule with the duration beside it: the two places are the
        // endpoints and this is what sits between them.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 1,
                height: 14,
                margin: const EdgeInsets.only(left: 2, right: 8),
                color: _muted,
              ),
              Text(_totalTime, style: _captionStyle),
            ],
          ),
        ),
        Text(
          end?.isNotEmpty == true ? end! : 'End',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _placeStyle,
        ),
        const SizedBox(height: 14),
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: _muted),
                bottom: BorderSide(color: _muted),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: _route(),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _hero(_distance, _dLabel, size: 32),
            const Spacer(),
            _statBlock('AVG $_sLabel', _avg, alignEnd: true),
          ],
        ),
        _wordmark(),
      ],
    );
  }

  /// No map at all — just the speed curve.
  ///
  /// The card to reach for when the GPS wandered and the route's shape is
  /// embarrassing: the speeds are still true even when the positions are not, and
  /// a ride is worth sharing on how it was ridden.
  Widget _buildTrace() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('SPEED OVER DISTANCE', style: _labelStyle),
            const Spacer(),
            Text(_stamp, style: _captionStyle),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: CustomPaint(
            painter: _TracePainter(points, color: _amber),
          ),
        ),
        const SizedBox(height: 14),
        _rule(),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _hero(_max, _sLabel, size: 34, label: 'PEAK'),
            const Spacer(),
            _statBlock('DISTANCE', '$_distance $_dLabel', alignEnd: true),
            const SizedBox(width: 14),
            _statBlock('TIME', _totalTime, alignEnd: true),
          ],
        ),
        _wordmark(),
      ],
    );
  }

  // --- Shared pieces --------------------------------------------------------

  String get _distance =>
      unit.distanceMeters(ride.totalDistanceMeters).toStringAsFixed(2);
  String get _totalTime => formatDuration(ride.durationSeconds);
  String get _movingTime => formatDuration(ride.movingSeconds);
  String get _avg => unit.speed(ride.averageSpeedKmh).toStringAsFixed(0);
  String get _max => unit.speed(ride.maxSpeedKmh).toStringAsFixed(0);
  String get _dLabel => unit.distanceLabel;
  String get _sLabel => unit.speedLabel.toUpperCase();

  /// `AUG 3 2026 · 18:17`, for the layouts that date themselves.
  String get _stamp {
    final d = ride.startTime.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${shortMonth(d.month).toUpperCase()} ${d.day} ${d.year} · $hh:$mm';
  }

  static const _labelStyle = TextStyle(
    color: _muted,
    fontSize: 8,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.05,
    shadows: _textShadow,
  );

  static const _captionStyle = TextStyle(
    color: _muted,
    fontSize: 10,
    fontWeight: FontWeight.w500,
    shadows: _textShadow,
  );

  static const _placeStyle = TextStyle(
    color: _ink,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    shadows: _textShadow,
  );

  /// The route, filling whatever box it is given.
  Widget _route({
    bool colorBySpeed = false,
    bool fillBox = false,
    double padding = 10,
  }) =>
      CustomPaint(
        painter: _RoutePainter(
          points,
          colorBySpeed: colorBySpeed,
          maxSpeedKmh: ride.maxSpeedKmh,
          stintStarts: stintStarts,
          fillBox: fillBox,
          pad: padding,
        ),
      );

  /// The card's one dominant number (spec 9.2). Amber unless the card's own
  /// background already carries the accent.
  Widget _hero(
    String value,
    String unitLabel, {
    required double size,
    String? label,
    bool amber = true,
    TextAlign align = TextAlign.left,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          align == TextAlign.right ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (label != null) ...[
          Text(label, style: _labelStyle),
          const SizedBox(height: 1),
        ],
        RichText(
          textAlign: align,
          text: TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'Inter',
              color: amber ? _amber : _ink,
              fontSize: size,
              height: 1,
              fontWeight: FontWeight.w700,
              letterSpacing: size * -0.03,
              shadows: _textShadow,
            ),
            children: [
              TextSpan(
                text: ' ${unitLabel.toLowerCase()}',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  color: _dim,
                  fontSize: 11,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                  shadows: _textShadow,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A supporting stat, label over value (spec 9.2's `600 13px` on a `600 8px`
  /// caption). Never amber and never red — one number leads, the rest report.
  Widget _statBlock(String label, String value, {bool alignEnd = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(label, style: _labelStyle),
        const SizedBox(height: 1),
        Text(
          value,
          maxLines: 1,
          style: const TextStyle(
            color: Color(0xFFE8E4DC),
            fontSize: 13,
            height: 1.15,
            fontWeight: FontWeight.w600,
            shadows: _textShadow,
          ),
        ),
      ],
    );
  }

  /// A right-aligned `LABEL   value` line, for the Split card's stat column.
  Widget _statLine(
    String label,
    String value, {
    bool inline = false,
    bool amber = false,
  }) {
    final text = Text(
      value,
      maxLines: 1,
      style: TextStyle(
        color: amber ? _amber : const Color(0xFFE8E4DC),
        fontSize: inline ? 11.5 : 13,
        height: 1.15,
        fontWeight: inline ? FontWeight.w500 : FontWeight.w600,
        shadows: _textShadow,
      ),
    );
    if (inline) return text;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: _labelStyle)),
          const SizedBox(width: 6),
          text,
        ],
      ),
    );
  }

  /// The hairline the stat band or column sits under (spec 9.1/9.2).
  Widget _rule() => Container(height: 1, color: _muted.withValues(alpha: 0.45));

  /// The speed scale as a slim vertical bar, for the Speed map card. Replaces the
  /// boxed horizontal legend that used to overlap the route it explained.
  Widget _verticalSpeedScale() {
    return SizedBox(
      width: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(_max, style: _labelStyle),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              width: 3,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  // Bottom-to-top, so slow sits at the foot and fast at the head
                  // — the same direction the numbers beside it run.
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: SpeedPalette.gradient,
                  stops: SpeedPalette.gradientStops,
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text('0', style: _labelStyle),
        ],
      ),
    );
  }

  /// The wordmark, anchored to the card's foot above a rule (spec 9.1).
  ///
  /// It used to be a 46dp logo and a 14sp name in the middle of a centred column,
  /// which is why it read as floating: it was as loud as the stats and had no edge
  /// to belong to. Small, grey, and pinned to the bottom-left, it signs the card
  /// instead of competing with it.
  Widget _wordmark() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          const Image(
            image: brandLogo,
            width: 18,
            height: 18,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: 7),
          Text(
            'THROTTLEPATH',
            style: TextStyle(
              color: _muted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              shadows: _textShadow,
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws the recorded track as a vector polyline, normalised to fit the box
/// (equirectangular projection, aspect-preserved), with start/end dots. When
/// [colorBySpeed] is set, each segment is coloured by its mean ground speed via
/// [SpeedPalette] instead of the flat amber line.
class _RoutePainter extends CustomPainter {
  _RoutePainter(
    this.points, {
    this.colorBySpeed = false,
    this.maxSpeedKmh = 0,
    this.stintStarts = const [],
    this.fillBox = false,
    this.pad = 10,
  });

  final List<TrackPoint> points;
  final bool colorBySpeed;
  final double maxSpeedKmh;

  /// Indices where each stint (after the first) begins; empty for a single ride.
  final List<int> stintStarts;

  /// Scale to *cover* the box and clip the overflow, instead of fitting inside it
  /// — SVG's `slice` rather than `meet`. Only the full-bleed card wants this: its
  /// whole premise is a route that reaches the edges, and a route's aspect ratio
  /// is whatever the roads were.
  final bool fillBox;

  /// Inset around the fitted route.
  final double pad;

  static const _amber = Color(0xFFFFB22C);
  static const _red = Color(0xFFEF4444);
  static const _dim = Color(0xFFD8D8D8);

  /// Per-stint route hues, cycled by stint index. Stint 1 is the brand amber so a
  /// single-stint trip (and every plain ride) keeps the original look.
  static const _stintPalette = <Color>[
    Color(0xFFFFB22C), // amber (brand)
    Color(0xFF29B6F6), // light blue
    Color(0xFF66BB6A), // green
    Color(0xFFAB47BC), // purple
    Color(0xFFFF7043), // deep orange
    Color(0xFFEC407A), // pink
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) {
      if (points.length == 1) {
        canvas.drawCircle(
            size.center(Offset.zero), 4, Paint()..color = _amber);
      }
      return;
    }

    // Project lat/lon to a local metric-ish plane (equirectangular).
    final midLat =
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final kx = math.cos(midLat * math.pi / 180.0);
    final proj = [
      for (final p in points) Offset(p.longitude * kx, -p.latitude),
    ];

    var minX = proj.first.dx, maxX = proj.first.dx;
    var minY = proj.first.dy, maxY = proj.first.dy;
    for (final o in proj) {
      minX = math.min(minX, o.dx);
      maxX = math.max(maxX, o.dx);
      minY = math.min(minY, o.dy);
      maxY = math.max(maxY, o.dy);
    }

    final spanX = (maxX - minX);
    final spanY = (maxY - minY);
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    // Uniform scale either way, so the route's true shape survives; `min` fits it
    // inside the box, `max` covers the box and lets the edges clip. Zero spans
    // (a stationary recording) fall through to 1.0 rather than dividing by zero.
    final sx = spanX > 0 ? availW / spanX : double.infinity;
    final sy = spanY > 0 ? availH / spanY : double.infinity;
    final scale = fillBox
        ? (sx.isFinite && sy.isFinite
            ? math.max(sx, sy)
            : (sx.isFinite ? sx : sy))
        : math.min(sx, sy);
    final safeScale = scale.isFinite ? scale : 1.0;

    if (fillBox) canvas.clipRect(Offset.zero & size);

    // Centre the scaled path in the box.
    final drawnW = spanX * safeScale;
    final drawnH = spanY * safeScale;
    final offsetX = pad + (availW - drawnW) / 2;
    final offsetY = pad + (availH - drawnH) / 2;

    Offset map(Offset o) => Offset(
          offsetX + (o.dx - minX) * safeScale,
          offsetY + (o.dy - minY) * safeScale,
        );

    final mapped = [for (final o in proj) map(o)];

    // One contiguous range per stint (single ride → one range). Segments never
    // bridge a stint boundary, so joins draw no false straight connector.
    final ranges = _stintRanges(points.length);

    if (colorBySpeed) {
      _paintSpeedColored(canvas, mapped, ranges);
    } else {
      _paintStints(canvas, mapped, ranges);
    }

    // Turnaround dots at each join (end of every non-final stint), then the start
    // (amber) and end (red) dots painted on top.
    for (var r = 0; r < ranges.length - 1; r++) {
      final end = ranges[r].$2 - 1;
      if (end >= 0 && end < mapped.length) _dot(canvas, mapped[end], _dim);
    }
    _dot(canvas, mapped.first, _amber);
    _dot(canvas, mapped.last, _red);
  }

  /// Contiguous `[start, end)` index ranges, one per stint, from [stintStarts]. With
  /// no boundaries the whole track is a single range.
  List<(int, int)> _stintRanges(int n) {
    final bounds = <int>[
      0,
      for (final b in stintStarts)
        if (b > 0 && b < n) b,
      n,
    ]..sort();
    final out = <(int, int)>[];
    for (var i = 0; i < bounds.length - 1; i++) {
      if (bounds[i + 1] > bounds[i]) out.add((bounds[i], bounds[i + 1]));
    }
    return out.isEmpty ? [(0, n)] : out;
  }

  void _paintStints(Canvas canvas, List<Offset> pts, List<(int, int)> ranges) {
    for (var r = 0; r < ranges.length; r++) {
      final (start, end) = ranges[r];
      if (end - start < 2) continue;
      final color = _stintPalette[r % _stintPalette.length];
      final path = Path()..moveTo(pts[start].dx, pts[start].dy);
      for (var i = start + 1; i < end; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      // Soft glow under the line.
      canvas.drawPath(
        path,
        Paint()
          ..color = color.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _paintSpeedColored(
      Canvas canvas, List<Offset> pts, List<(int, int)> ranges) {
    final maxS = maxSpeedKmh <= 0 ? 1.0 : maxSpeedKmh;
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final (start, end) in ranges) {
      for (var i = start + 1; i < end; i++) {
        final meanKmh = (points[i - 1].speedMps + points[i].speedMps) / 2 * 3.6;
        final t = (meanKmh / maxS).clamp(0.0, 1.0);
        canvas.drawLine(pts[i - 1], pts[i], base..color = SpeedPalette.at(t));
      }
    }
  }

  void _dot(Canvas canvas, Offset c, Color color) {
    canvas.drawCircle(c, 6, Paint()..color = color);
    canvas.drawCircle(
        c,
        6,
        Paint()
          ..color = const Color(0xFF0A0A0A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5);
  }

  @override
  bool shouldRepaint(covariant _RoutePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.colorBySpeed != colorBySpeed ||
      oldDelegate.maxSpeedKmh != maxSpeedKmh ||
      oldDelegate.fillBox != fillBox ||
      oldDelegate.pad != pad ||
      !listEquals(oldDelegate.stintStarts, stintStarts);
}

// `_fmtPace` went with the PACE stat (spec 9.4). Pace is a running metric —
// minutes per kilometre says nothing useful about a motorcycle — and it was the
// sixth number on a card that now leads with one.

/// Speed against distance travelled, as a filled curve. The Trace card's whole
/// content.
///
/// Distance comes from the same equirectangular projection the route uses, so the
/// x axis agrees with the shape the other cards draw from these same points.
class _TracePainter extends CustomPainter {
  _TracePainter(this.points, {required this.color});

  final List<TrackPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final midLat =
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length;
    final kx = math.cos(midLat * math.pi / 180.0);
    // Metres per degree of latitude, near enough for a normalised axis.
    const mPerDeg = 111320.0;

    final xs = <double>[0];
    var run = 0.0;
    for (var i = 1; i < points.length; i++) {
      final dLat = (points[i].latitude - points[i - 1].latitude) * mPerDeg;
      final dLon =
          (points[i].longitude - points[i - 1].longitude) * mPerDeg * kx;
      run += math.sqrt(dLat * dLat + dLon * dLon);
      xs.add(run);
    }

    var peak = 0.0;
    for (final p in points) {
      final kmh = p.speedMps * 3.6;
      if (kmh > peak) peak = kmh;
    }
    // A ride with no usable speeds has nothing to plot; a flat line at zero would
    // claim it stood still, which may not be true.
    if (peak <= 0 || run <= 0) return;

    final w = size.width;
    final h = size.height;
    Offset at(int i) => Offset(
          xs[i] / run * w,
          h - (points[i].speedMps * 3.6 / (peak * 1.08)).clamp(0.0, 1.0) * h,
        );

    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      final o = at(i);
      line.lineTo(o.dx, o.dy);
    }

    // Filled to the baseline at 10% — enough to read the curve as an area on a
    // transparent sticker, not enough to become a block.
    final fill = Path.from(line)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.10));

    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // The baseline, so the fill has something to sit on.
    canvas.drawLine(
      Offset(0, h),
      Offset(w, h),
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TracePainter old) =>
      old.points != points || old.color != color;
}
