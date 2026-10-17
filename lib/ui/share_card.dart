import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../core/date_format.dart';
import '../core/duration_format.dart';
import '../core/speed_palette.dart';
import '../core/track_runs.dart';
import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../services/share_basemap.dart';

/// The shareable card layouts the rider can pick between before exporting.
///
/// All render on a fully transparent canvas (no background panel) so the sticker
/// drops cleanly onto a photo/video or saves as a transparent PNG. The one thing
/// that can be opaque is the optional basemap panel — see [ShareCard.basemap] —
/// and only inside the box the route already had.
///
/// **The minimal-look spec assumed an opaque `#0E0E0F` card at 1080×1350.** The
/// background is still wrong about this app — the canvas is transparent by
/// design, which is what makes these stickers rather than images.
///
/// The aspect ratio is no longer a disagreement. This was 9:16 (360×640 logical,
/// 1080×1920 exported) on the argument that a Story is 9:16, and that argument
/// was about the canvas a sticker *lands on*, not the sticker: a sticker is
/// scaled and placed by hand, so a tall one cannot fill a Story it does not own
/// and crops badly everywhere else. It is square now — see [ShareCard.canvasSize],
/// which is the one number all three call sites read.
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

  // `fullBleed` — route edge to edge under a gradient scrim — is gone. It was the
  // one card that carried a background, which on a transparent sticker meant a
  // dark bar the rider could not remove; and it scaled the route to *cover* the
  // frame, so the shape it showed was a crop of the ride rather than the ride.
  // Six styles that agree on what a route looks like beat seven that don't.

  /// A ride stub: start and end places, the route between two dashed rules.
  ticket('Ticket', 'Start to end, as a stub'),

  /// No map — the speed curve itself, for when the GPS wandered.
  trace('Trace', 'The speed curve, no map');

  const ShareLayout(this.title, this.blurb);

  final String title;
  final String blurb;
}

/// A shareable ride card, rendered off-screen into a square PNG at [canvasSize]
/// (see `captureWidgetToPng`).
///
/// Styled after Strava's share sticker: the route line and stats floating on a
/// square canvas, in ThrottlePath's amber brand palette. The route is a vector
/// polyline by default — being offline-first, the card has to be able to draw a
/// ride with no tiles at all — over an optional [basemap] panel when the rider
/// asks for one and the tiles can be had. No text on it carries
/// a drop shadow; legibility over a photo is [scrim]'s job, and doing both at once
/// only thickens small type.
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
    this.scrim = true,
    this.basemap,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final ShareLayout layout;

  /// Whether to lay a semi-transparent dark wash over the whole square behind the
  /// content — see [_scrimColor].
  ///
  /// On by default because that is the case the card cannot control: a sticker
  /// dropped onto someone's photo has no idea what is behind it, and white-on-white
  /// is the one outcome with no recovery. Off gives the original fully transparent
  /// sticker, which looks better over a dark or quiet image and is the rider's call
  /// to make per share.
  final bool scrim;

  /// Indices into [points] where each stint (after the first) begins — set when
  /// this card renders a whole multi-stint trip so the route draws each stint as a
  /// separate polyline instead of one line with false join connectors. All of them
  /// paint in the brand amber; the card does not colour-code its stints the way
  /// the Trip screen does. Empty for a single ride.
  final List<int> stintStarts;

  /// Real map tiles under the route, or null for the transparent sticker.
  ///
  /// Loaded by the composer rather than the card (see [ShareBasemapLoader]),
  /// because tiles arrive over seconds and this widget has to be able to paint
  /// in one frame — the export gives it two. Null is not a failure state: an area
  /// the rider has never loaded and no signal to fetch it lands here as null and
  /// the card renders exactly as it did before basemaps existed.
  final ShareBasemap? basemap;

  /// Whether this layout has a route box for a basemap to sit in. Trace is the
  /// one card with no map — it is the card for a ride whose positions went bad.
  bool get _hasMap => layout != ShareLayout.trace;

  /// Bundled brand mark — clean amber speedometer on transparent. Precached
  /// before capture (the render only waits a couple of frames).
  static const brandLogo = AssetImage('assets/icon/logo_foreground.png');

  /// The sticker's logical canvas, exported at 1080×1080 (`RideShare._pixelRatio`).
  ///
  /// The card sizes *itself* to this instead of trusting each caller to wrap it.
  /// The old 360×640 pair lived in three places — the capture, the composer
  /// preview and the test host — and a card whose shape depends on where it is
  /// mounted is a card that can export as something other than what the rider
  /// approved. Both remaining callers hand it unbounded or loose constraints, so
  /// this is now the only copy.
  static const Size canvasSize = Size(360, 360);

  // Brand colours, fixed for the shared artwork.
  static const _amber = Color(0xFFFFB22C);
  static const _ink = Color(0xFFF2F2F0);
  static const _dim = Color(0xFFD8D8D8);

  /// Recessive grey — the rules, and the timestamps that date a card.
  ///
  /// It used to carry the labels and the wordmark too; those are amber now (see
  /// [_labelStyle]). What is left is the stuff that should *not* be found: a
  /// hairline is furniture, and the stamp is provenance rather than a stat, which
  /// is why the Ticket has paired an amber `RIDE LOG` against a grey stamp in the
  /// same row from the start.
  static const _muted = Color(0xFF8A8A8A);

  /// The optional backdrop, laid behind everything — see [scrim].
  ///
  /// This is the "background panel" the card deliberately does without, as a
  /// *scrim* rather than a panel: enough to carry white and amber type over an
  /// arbitrary photo, sheer enough that the photo still reads through it.
  /// Per-glyph drop shadows used to do this job and did it worse — they thicken
  /// small type, muddy the amber, and could never help the route line, which had
  /// nothing behind it either.
  ///
  /// 40% black. It started at 60% and read as a grey box on the phone; the point
  /// is a wash, not a panel, and the feather below buys back some of the contrast
  /// by keeping the middle honest while the edges give way.
  static const Color _scrimColor = Color(0x66000000);

  /// How far the scrim is held back from each edge before it is blurred.
  ///
  /// With [_scrimFeather], this is what stops the sticker showing a hard square
  /// outline against a photo.
  ///
  /// Both numbers are pinned between two constraints, and the first attempt (26/14)
  /// missed the second one badly enough to be visible only in a render: the fade
  /// must reach ~0 by the canvas edge, *and* be over by [_pad], because that is
  /// where the content starts. At 26/14 the wash was not solid until ~40dp in, so
  /// the stat column and the wordmark sat in the gradient and disappeared against a
  /// pale photo — a scrim that fails exactly the case it exists for.
  ///
  /// At 10/5 the fade spans roughly 0-25dp: ~2% of the wash at the very edge (a
  /// 2-sigma tail, invisible), ~95% by the 18dp mark where the type begins.
  static const double _scrimInset = 10;

  /// Gaussian sigma for the scrim's edge.
  ///
  /// A radial gradient was the obvious alternative and cannot do this job: to
  /// reach the corners it needs a radius of at least 0.707, which leaves the edge
  /// *midpoints* at 0.7 of the way out and still most of the way opaque. Covering
  /// the corners and fading out at the edges are mutually exclusive for one radial
  /// on a square. A blurred rect softens all four sides evenly instead.
  static const double _scrimFeather = 5;

  /// Corner radius on the scrim rect, before it is blurred.
  ///
  /// The feather can only ever be about 20dp wide — it has to be spent by [_pad],
  /// where the content starts, and reach nothing by the canvas edge, or the
  /// leftover alpha is clipped into the hard line the feather exists to remove. A
  /// 20dp fade still leaves an unmistakably *square* wash, because what reads as a
  /// square is the corners rather than the sharpness of the sides. Rounding them
  /// off does more for that than any amount of extra blur, and costs only the four
  /// corners of coverage — where this card puts nothing.
  static const double _scrimRadius = 46;
  /// How much of its allotted box the route line actually fills.
  ///
  /// The route is the card's backdrop and the numbers are its subject, so it gets
  /// drawn at a fraction of whatever an `Expanded` hands it. Proportional rather
  /// than a fixed inset: the layouts give it boxes of very different shapes, and a
  /// fixed inset would take a third of the Split card's narrow column while barely
  /// touching the Stacked card's wide one.
  static const double _routeScale = 0.8;

  /// Inset from the sticker's edge, applied to the whole card.
  ///
  /// 18, not the 22 the 9:16 card used: the two margins were 6.9% of a 640dp
  /// height and would be 12% of a 360dp one. Margin did not become more important
  /// when the canvas got shorter — the route inside it became scarcer.
  static const double _pad = 18;

  @override
  Widget build(BuildContext context) {
    final content = switch (layout) {
      ShareLayout.split => _buildSplit(),
      ShareLayout.stacked => _buildStacked(),
      ShareLayout.statsTop => _buildStatsTop(),
      ShareLayout.speed => _buildSpeed(),
      ShareLayout.ticket => _buildTicket(),
      ShareLayout.trace => _buildTrace(),
    };

    return DefaultTextStyle(
      style: const TextStyle(
        fontFamily: 'Inter',
        color: _ink,
      ),
      child: SizedBox.fromSize(
        size: canvasSize,
        // The scrim sits *outside* the padding so it reaches all four edges of the
        // exported square. Inside it, and the sticker would carry an 18dp
        // transparent frame around a dark middle — which reads as a mistake rather
        // than a design.
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (scrim)
              ImageFiltered(
                imageFilter: ImageFilter.blur(
                    sigmaX: _scrimFeather, sigmaY: _scrimFeather),
                child: const Padding(
                  padding: EdgeInsets.all(_scrimInset),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _scrimColor,
                      borderRadius:
                          BorderRadius.all(Radius.circular(_scrimRadius)),
                    ),
                  ),
                ),
              ),
            // Full-frame, not centred. Every layout used to float a min-height
            // column in the middle of the canvas, which is why the wordmark
            // appeared to hover mid-card (spec 9.1) — it was simply the last item
            // in a short column. The layouts now fill the height and anchor their
            // own feet.
            Padding(padding: const EdgeInsets.all(_pad), child: content),
          ],
        ),
      ),
    );
  }

  // --- Layouts --------------------------------------------------------------

  Widget _buildSplit() {
    return Column(
      children: [
        Expanded(
          child: Row(
            // Both vertically centred (the Row's default). Top-aligning them was
            // tried and reverted: it left the whole bottom third of the square
            // empty under a short stat column, which reads as a mistake rather
            // than as breathing room.
            children: [
              // A bounded box rather than an `Expanded`. While the route took every
              // spare dp, the stat column was pinned against the card's right edge
              // and the gap between the two was whatever the route's own shape did
              // not fill — on a north-south ride, most of the card.
              SizedBox(width: 140, child: _route()),
              const SizedBox(width: 10),
              SizedBox(
                width: 150,
                child: Column(
                  // Left, not right. Right-aligning pushed every value as far from
                  // the route as the column was wide, which is what read as "plenty
                  // of space" between them.
                  crossAxisAlignment: CrossAxisAlignment.start,
                  // Intrinsic height so the Row can centre the block as a unit.
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _hero(_distance, _dLabel, size: 34),
                    const SizedBox(height: 12),
                    _rule(),
                    const SizedBox(height: 12),
                    // PACE is back, against spec 9.4. 9.4 dropped it as a running
                    // metric and as the sixth number competing to be read; the
                    // second half was the real argument and it no longer holds —
                    // these are six quiet `_statLine` rows under one amber hero in
                    // a 296dp column, not six things shouting. The first half is
                    // wrong about riders: minutes per kilometre is exactly how a
                    // commute is compared to the same commute last week, which is
                    // the comparison a shared card is *for*. It sits after MOVING
                    // because that is what it is derived from.
                    _statLine('TIME', _totalTime),
                    _statLine('MOVING', _movingTime),
                    _statLine('PACE', '$_pace /$_dLabel'),
                    _statLine('AVG', '$_avg $_sLabel'),
                    _statLine('MAX', '$_max $_sLabel'),
                  ],
                ),
              ),
              // Absorbs whatever the two fixed columns leave, so the pair sits
              // against the left of the card instead of being spread across it.
              const Spacer(),
            ],
          ),
        ),
        _wordmark(),
        // Lifts the signature off the very foot of the square. Split is the one
        // layout whose content does not reach the bottom — the route and stats are
        // centred as a block — so a wordmark pinned to the edge sat alone with a
        // gap above it. The other five fill their height and want it at the foot,
        // which is why this is here and not in `_wordmark`.
        const SizedBox(height: 26),
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
            _hero(_distance, _dLabel, size: 34),
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
        _hero(_distance, _dLabel, size: 45),
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
              const SizedBox(width: 10),
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
            _hero(_max, _sLabel, size: 34, label: 'MAX SPEED'),
            const Spacer(),
            _statBlock('DISTANCE', '$_distance $_dLabel', alignEnd: true),
          ],
        ),
        _wordmark(),
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
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                          ),
            ),
            const Spacer(),
            Text(_stamp, style: _captionStyle),
          ],
        ),
        const SizedBox(height: 12),
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
        const SizedBox(height: 12),
        // The tightest band on the square canvas: everything above and below it
        // is fixed, so the route gets whatever is left — about 145dp. Each dp
        // trimmed from the header, the spacers and this inset went straight into
        // it. If it ever reads as a hairline the next thing to give is the
        // `_stamp` or the duration block, not this padding.
        Expanded(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: _muted),
                bottom: BorderSide(color: _muted),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: _route(),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _hero(_distance, _dLabel, size: 34),
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
          // See `_route()` for why the size is explicit — without it this
          // painter's width collapsed to zero and every x mapped to 0, which is
          // the "one straight vertical line" of QA 7.12.
          child: CustomPaint(
            size: Size.infinite,
            painter: _TracePainter(points, color: _amber),
          ),
        ),
        const SizedBox(height: 14),
        _rule(),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _hero(_max, _sLabel, size: 38, label: 'PEAK'),
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
  String get _pace => formatPace(
      ride.movingSeconds, unit.distanceMeters(ride.totalDistanceMeters));
  String get _dLabel => unit.distanceLabel;
  String get _sLabel => unit.speedLabel.toUpperCase();

  /// `AUG 3 2026 · 18:17`, for the layouts that date themselves.
  String get _stamp {
    final d = ride.startTime.toLocal();
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${shortMonth(d.month).toUpperCase()} ${d.day} ${d.year} · $hh:$mm';
  }

  /// Every caption on the card: the stat labels, the Trace and Speed-map headers,
  /// the ends of the colour scale.
  ///
  /// Amber, not the [_muted] grey these used to be. The app's "one accent per
  /// screen" rule does not reach here — that rule is about not making a rider
  /// hunt for the one thing they can act on, and nothing on a share card is
  /// actionable. What a card has instead is a brand, and the labels are the layer
  /// that carries it: they are the same words on all six styles, so making them
  /// the brand colour is what makes six layouts read as one app's cards. Size and
  /// weight still do the hierarchy — 8sp w600 under a 30sp w700 hero is in no
  /// danger of competing with it.
  ///
  /// Unshadowed, unlike the grey and ink text around it: a drop shadow under
  /// 8sp amber muddies the colour more than it separates it from the backdrop,
  /// and the brand layer is the one place that should read as flat ink. The
  /// trade is legibility over a light or busy photo, which is accepted.
  static const _labelStyle = TextStyle(
    color: _amber,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.05,
  );

  static const _captionStyle = TextStyle(
    color: _muted,
    fontSize: 12,
    fontWeight: FontWeight.w500,
  );

  static const _placeStyle = TextStyle(
    color: _ink,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  /// The route, filling whatever box it is given.
  ///
  /// `size:` is not decoration. A `CustomPaint` with neither a child nor a size
  /// resolves through `constraints.constrain(Size.zero)` — i.e.
  /// `constraints.smallest` — and `Expanded` tightens only the *main* axis, so
  /// the cross axis collapsed to nothing. The route was painting into a box one
  /// axis of which was 0dp on every layout that has survived — the since-deleted
  /// full-bleed card escaped only by accident, sitting in a
  /// `Stack(fit: StackFit.expand)` that hands down tight constraints. That one
  /// line is QA 7.9, 7.11 and 7.12 at once, plus the Ticket's invisible dashed
  /// rules and Stacked rendering stats-only.
  ///
  /// `Size.infinite` rather than an enclosing `SizedBox.expand`: the three other
  /// wrapped-`CustomPaint` sites in this app (`lean_gauge`, `speed_sparkline`,
  /// `route_sparkline`) wrap in order to impose a *fixed* height on an unbounded
  /// parent, which is the opposite problem. `constraints.constrain(Size.infinite)`
  /// is exactly "take everything offered", said in a parameter the render object
  /// already has. Safe here because every call site sits inside an `Expanded`
  /// bounded by the card's own fixed canvas.
  Widget _route({bool colorBySpeed = false}) => FractionallySizedBox(
        // The route is the card's backdrop, not its subject — the numbers are.
        // Every layout hands it an `Expanded`, so scaling the type up already took
        // some of it back; this takes the rest, proportionally rather than by a
        // fixed inset so a tall box and a wide one shrink by the same amount.
        //
        // A basemap opts out. That shrink buys air around a bare line, but the
        // panel is a defined rectangle that already carries a 12% margin of its
        // own and is then letterboxed to the ride's shape — taking another fifth
        // off leaves a stamp adrift in the middle of the card.
        widthFactor: basemap != null ? 1.0 : _routeScale,
        heightFactor: basemap != null ? 1.0 : _routeScale,
        child: CustomPaint(
          size: Size.infinite,
          painter: _RoutePainter(
            points,
            colorBySpeed: colorBySpeed,
            maxSpeedKmh: ride.maxSpeedKmh,
            stintStarts: stintStarts,
            basemap: basemap,
          ),
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
            ),
            children: [
              TextSpan(
                text: ' ${unitLabel.toLowerCase()}',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  color: _dim,
                  fontSize: 13,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
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
            fontSize: 16,
            height: 1.15,
            fontWeight: FontWeight.w600,
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
        fontSize: inline ? 14 : 16,
        height: 1.15,
        fontWeight: inline ? FontWeight.w500 : FontWeight.w600,
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
  ///
  /// Fixed height and centred, not `Expanded`. A full-height gradient was fine
  /// beside a 9:16 route — it read as a margin rule. On a square frame it becomes
  /// a second strong vertical competing with the route for the same glance, so
  /// the legend is deliberately shorter than the thing it explains. 4dp wide
  /// rather than 3, because 3dp is 9 pixels in a 1080px export, which is where a
  /// hairline stops being a bar and starts being an artefact.
  Widget _verticalSpeedScale() {
    return SizedBox(
      // Enough for a three-digit max ("120" at 8sp measures ~14dp).
      width: 16,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(_max, style: _labelStyle),
          const SizedBox(height: 4),
          Container(
            width: 4,
            height: 132,
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
  /// to belong to. Small and grey, it signs the card instead of competing with it.
  ///
  /// Centred, not bottom-left. Five of the six layouts put their stats directly
  /// above this, so 14 → 10 was all the "pull up" they needed; **Split** was the
  /// one that still read as floating, and its problem was horizontal — stats
  /// bottom-right, mark bottom-left under the route, signing nothing. One
  /// `mainAxisAlignment` fixes it everywhere at once: `RenderFlex` at the default
  /// `MainAxisSize.max` sizes to `constraints.maxWidth`, which is always bounded
  /// here, so this Row is full-width whatever its parent Column's
  /// `crossAxisAlignment` says. No per-layout edits.
  /// The tile credit, shown only on a card that is actually carrying tiles.
  ///
  /// Not optional and not decoration: CARTO and OpenStreetMap both require
  /// attribution on redistributed imagery, and a share card is redistribution by
  /// definition. It rides above the wordmark rather than beside it so the
  /// signature stays the app's own — and so it disappears completely, taking its
  /// space with it, on the transparent sticker that carries no tiles.
  Widget _credit() => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '© OPENSTREETMAP · CARTO',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _muted.withValues(alpha: 0.85),
            fontSize: 7,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.6,
          ),
        ),
      );

  Widget _wordmark() {
    if (basemap != null && _hasMap) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [_credit(), _wordmarkRow()],
      );
    }
    return _wordmarkRow();
  }

  Widget _wordmarkRow() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
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
              // Amber with the rest of the captions — and the mark beside it was
              // already amber, so the signature had been half one colour and half
              // another the whole time.
              color: _amber,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
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
    this.basemap,
  });

  final List<TrackPoint> points;
  final bool colorBySpeed;
  final double maxSpeedKmh;

  /// Real map tiles to draw the route on top of, or null for the transparent
  /// sticker this card has always been.
  ///
  /// Resolved before the card is built (see [ShareBasemapLoader]) precisely so
  /// this stays a synchronous painter: the export waits two frames and then
  /// rasterises, which no tile fetch can meet.
  final ShareBasemap? basemap;

  /// Indices where each stint (after the first) begins; empty for a single ride.
  ///
  /// Breaks the polyline *and* earns a turnaround dot. Blackout breaks are found
  /// from the timestamps instead (see [_ranges]) and get no dot.
  final List<int> stintStarts;

  /// Inset around the fitted route.
  ///
  /// Was a parameter so the full-bleed card could pass 0 and scale to *cover* the
  /// frame instead of fitting inside it. That card is gone, and with it the only
  /// reason a route ever showed a crop of the ride rather than the ride.
  static const double _pad = 10;

  static const _amber = Color(0xFFFFB22C);
  static const _red = Color(0xFFEF4444);
  static const _dim = Color(0xFFD8D8D8);

  /// Route stroke weights, in card-logical dp. Everything here is tripled in
  /// the 1080 export, which is why they read thinner on screen than they paint.
  ///
  /// Thinned from 3.5/8/4 and a radius-6 dot. The route is the backdrop of the
  /// card and the numbers are its subject; at the old weights a 13km ride came
  /// out as a 10px-wide amber rope on the export, which competed with the hero
  /// for the first glance and buried the shape of the ride inside its own line.
  static const double _lineWidth = 2.4;
  static const double _glowWidth = 6;
  static const double _glowBlur = 5;

  /// The speed-coloured route carries no glow, so it stays a shade heavier than
  /// [_lineWidth] — the colour ramp is the point of that card and needs the
  /// pixels to be read as a ramp rather than as a stipple.
  static const double _speedLineWidth = 2.8;

  /// Start / end / turnaround markers, and the dark ring that lifts them off
  /// whatever the line is doing underneath.
  static const double _dotRadius = 4.5;
  static const double _dotRing = 1.8;

  /// Laid over the basemap tiles, under the route.
  static const Color _mapWash = Color(0x40000000);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) {
      if (points.length == 1) {
        canvas.drawCircle(
            size.center(Offset.zero), 3, Paint()..color = _amber);
      }
      return;
    }

    // Where each fix lands on the canvas. Which projection is used is not a
    // preference: with a basemap the line has to sit on the roads it was ridden
    // on, so it must be placed by the tiles' own Web Mercator maths and nothing
    // else. Without one there is nothing to align to, and the older fit is kept
    // untouched so every card that shipped before this feature draws as it did.
    final mapped = basemap != null
        ? _projectOnBasemap(canvas, size, basemap!)
        : _projectFitted(size);

    // One contiguous range per stretch of continuous recording. Segments never
    // bridge a stint boundary or a GPS blackout, so neither draws a false
    // straight connector.
    final ranges = _ranges(points.length);

    if (colorBySpeed) {
      _paintSpeedColored(canvas, mapped, ranges);
    } else {
      _paintStints(canvas, mapped, ranges);
    }

    // Turnaround dots at each *stint* join, then the start (amber) and end (red)
    // dots on top. Deliberately not drawn at a blackout break: the dot means "the
    // rider stopped here and set off again", and a dead zone is the opposite
    // claim — nobody stopped, the receiver did. Marking both the same way would
    // turn a lost signal into a place the ride visits.
    final joins = stintStarts.toSet();
    for (var r = 0; r < ranges.length - 1; r++) {
      if (!joins.contains(ranges[r].$2)) continue;
      final end = ranges[r].$2 - 1;
      if (end >= 0 && end < mapped.length) _dot(canvas, mapped[end], _dim);
    }
    _dot(canvas, mapped.first, _amber);
    _dot(canvas, mapped.last, _red);
  }

  /// Draws the basemap panel and returns the route placed on it.
  ///
  /// Everything here lives in the tiles' world-pixel space, mapped to the canvas
  /// by one scale and one translate — so a fix and the tile under it cannot
  /// disagree about where they are.
  List<Offset> _projectOnBasemap(Canvas canvas, Size size, ShareBasemap map) {
    final panel = _panelFor(map.crop, size);
    final k = panel.width / map.crop.width;
    Offset place(Offset world) => (world - map.crop.topLeft) * k + panel.topLeft;

    canvas.save();
    canvas.clipRect(panel);
    final tilePaint = Paint()..filterQuality = FilterQuality.medium;
    for (final tile in map.tiles) {
      canvas.drawImageRect(
        tile.image,
        Rect.fromLTWH(
            0, 0, tile.image.width.toDouble(), tile.image.height.toDouble()),
        Rect.fromPoints(
            place(tile.world.topLeft), place(tile.world.bottomRight)),
        tilePaint,
      );
    }
    // Hold the basemap back a stop so the route stays the brightest thing in the
    // panel. The dark basemap is quiet already, but a city centre is a lot of
    // white label text and the amber line has to win against it.
    canvas.drawRect(panel, Paint()..color = _mapWash);
    canvas.restore();

    // A hairline edge. The panel is the one opaque thing on an otherwise
    // transparent sticker, and dropped onto a dark photo without an edge it does
    // not read as a map — it reads as part of the photo having gone wrong.
    canvas.drawRect(
      panel.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _dim.withValues(alpha: 0.28),
    );

    return [
      for (final p in points) place(map.worldOf(p.latitude, p.longitude)),
    ];
  }

  /// The map panel: the crop's own shape, letterboxed into the space the layout
  /// gave the route.
  ///
  /// This is "crop to the ride" — the panel takes the *ride's* aspect ratio, not
  /// the box's, so a north-south commute renders as a tall map with margin either
  /// side rather than a wide one mostly showing the neighbours. The crop already
  /// carries its own 12% margin, which is why nothing here adds [_pad] on top.
  static Rect _panelFor(Rect crop, Size size) {
    final k = math.min(size.width / crop.width, size.height / crop.height);
    final w = crop.width * k;
    final h = crop.height * k;
    return Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
  }

  /// The mapless fit: lat/lon onto a local equirectangular plane, scaled to the
  /// box. Unchanged from before basemaps existed.
  List<Offset> _projectFitted(Size size) {
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
    final availW = size.width - _pad * 2;
    final availH = size.height - _pad * 2;
    // One uniform scale, fitted to the tighter axis, so the route's true shape
    // survives and all of it is in frame. Zero spans (a stationary recording)
    // fall through to 1.0 rather than dividing by zero.
    final sx = spanX > 0 ? availW / spanX : double.infinity;
    final sy = spanY > 0 ? availH / spanY : double.infinity;
    final scale = math.min(sx, sy);
    final safeScale = scale.isFinite ? scale : 1.0;

    // Centre the scaled path in the box.
    final drawnW = spanX * safeScale;
    final drawnH = spanY * safeScale;
    final offsetX = _pad + (availW - drawnW) / 2;
    final offsetY = _pad + (availH - drawnH) / 2;

    Offset map(Offset o) => Offset(
          offsetX + (o.dx - minX) * safeScale,
          offsetY + (o.dy - minY) * safeScale,
        );

    return [for (final o in proj) map(o)];
  }

  /// Contiguous `[start, end)` index ranges, one per unbroken stretch of
  /// recording. With no boundaries the whole track is a single range.
  ///
  /// Two things break a range, and only one of them can be handed in. Stint joins
  /// come from [stintStarts], because only the caller knows where one stint ended
  /// and the next began. Blackouts are read off the timestamps here rather than
  /// asked for, the way the GPX writer does it — a card built straight from a
  /// ride's points would otherwise have to be told, and the one that wasn't drew
  /// a 33 km diagonal across a dead zone as if it were road.
  List<(int, int)> _ranges(int n) {
    final bounds = <int>{
      0,
      for (final b in stintStarts)
        if (b > 0 && b < n) b,
      for (final b in runStartIndices(points, fixOf: trackPointFix))
        if (b > 0 && b < n) b,
      n,
    }.toList()
      ..sort();
    final out = <(int, int)>[];
    for (var i = 0; i < bounds.length - 1; i++) {
      if (bounds[i + 1] > bounds[i]) out.add((bounds[i], bounds[i + 1]));
    }
    return out.isEmpty ? [(0, n)] : out;
  }

  /// Every stint in the one brand amber.
  ///
  /// A multi-stint trip used to cycle a six-hue palette here, which reads inside
  /// the app — the Trip screen has a legend to say which colour is which stint.
  /// A share card has no legend and is looked at for a second by someone who was
  /// not on the ride, so five extra hues only say "this is several things" where
  /// the card's whole claim is that it is one ride. The stints stay *segmented*
  /// (that is what keeps a straight line from being drawn across each join); only
  /// the colour is shared, and the grey turnaround dot still marks every join.
  void _paintStints(Canvas canvas, List<Offset> pts, List<(int, int)> ranges) {
    for (final (start, end) in ranges) {
      if (end - start < 2) continue;
      final path = Path()..moveTo(pts[start].dx, pts[start].dy);
      for (var i = start + 1; i < end; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      // Soft glow under the line.
      canvas.drawPath(
        path,
        Paint()
          ..color = _amber.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _glowWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _glowBlur),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = _amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = _lineWidth
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
      ..strokeWidth = _speedLineWidth
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
    canvas.drawCircle(c, _dotRadius, Paint()..color = color);
    canvas.drawCircle(
        c,
        _dotRadius,
        Paint()
          ..color = const Color(0xFF0A0A0A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = _dotRing);
  }

  @override
  bool shouldRepaint(covariant _RoutePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.colorBySpeed != colorBySpeed ||
      oldDelegate.maxSpeedKmh != maxSpeedKmh ||
      oldDelegate.basemap != basemap ||
      !listEquals(oldDelegate.stintStarts, stintStarts);
}

// `_fmtPace` used to live here as a private top-level, and came back as
// `formatPace` in `core/duration_format.dart` instead. Not for reuse — the Split
// card is still its only caller — but because it is arithmetic with three edge
// cases (the sub-50m sentinel, the `isFinite` guard, the `ss == 60` carry) that
// were otherwise testable only by rendering a widget and matching a string.

/// Speed against distance travelled, as a filled curve. The Trace card's whole
/// content.
///
/// The x axis is the project's read-path distance ([cumulativeMeters]), which
/// freezes across a GPS blackout. This used to roll its own equirectangular
/// accumulator over the flattened point list, justified as keeping the axis in
/// agreement with the shape the other cards draw — and that justification was
/// the bug. A blackout the write path refused to count still contributed one
/// enormous phantom segment here, crushing the whole real ride into a thin band
/// at the left. The agreement that matters is with the odometer and the
/// ride-detail speed chart: the distance the rider was *told* they rode, not the
/// span of the polyline's bounding box.
class _TracePainter extends CustomPainter {
  _TracePainter(this.points, {required this.color});

  final List<TrackPoint> points;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    final xs = cumulativeMeters(points, fixOf: trackPointFix);
    final run = xs.last;

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
