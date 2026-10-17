import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../providers/settings_providers.dart';
import '../services/gpx_export.dart';
import '../services/ride_share.dart';
import '../services/share_basemap.dart';
import '../theme/app_theme.dart';
import 'share_card.dart';
import 'tracking_map_screen.dart' show basemapUrl;

/// Where a finished card (or track) can be sent.
enum _ShareAction {
  instagram('Instagram', Icons.camera_alt),
  gallery('Save PNG', Icons.download),
  more('More…', Icons.ios_share);

  const _ShareAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// What the composer sheet hands back: the layout on screen when the rider chose,
/// and what they chose. `gpx` has no layout — it exports the track, not a card.
class _ShareRequest {
  const _ShareRequest.card(this.layout, this.action, this.scrim) : gpx = false;
  // The layout and backdrop are unused on this path; they just have to be values.
  const _ShareRequest.gpx()
      : layout = ShareLayout.split,
        action = _ShareAction.more,
        scrim = true,
        gpx = true;

  final ShareLayout layout;
  final _ShareAction action;

  /// The backdrop switch as it stood when the rider committed — read from the
  /// sheet rather than the provider at render time, so a card is exported exactly
  /// as it was previewed.
  final bool scrim;
  final bool gpx;
}

/// Carries the basemap between the sheet and the render that follows it.
///
/// The tiles are loaded inside the composer — that is where the toggle and the
/// preview are — but they are needed again *after* the sheet has popped, by the
/// export. Passing them out through [_ShareRequest] would leak them whenever the
/// rider dismisses the sheet instead of sharing; a holder owned by
/// [showShareFlow] is disposed on every path out.
class _BasemapHolder {
  ShareBasemap? value;

  /// The load in flight, if any.
  ///
  /// Awaited before the export so a rider who taps Instagram while the tiles are
  /// still arriving gets the card they asked for rather than a silent fallback.
  Future<void>? pending;

  void dispose() {
    value?.dispose();
    value = null;
  }
}

/// Opens the share composer for a ride (or a synthesized combined trip ride) and
/// carries out whatever the rider picked.
///
/// One sheet, not two modals: pick-a-layout used to be a grid of four postage
/// stamps, and choosing one immediately replaced it with a *second* dialog asking
/// where it should go — so the rider committed to a design they could barely see,
/// then answered a question they hadn't been asked yet, with no way back (F31).
/// Now the preview is the sheet, swiping changes it, and the destinations sit
/// underneath it the whole time.
///
/// [ride] may be a real saved ride or a synthesized combined trip ride; when it is
/// a trip, [stintStarts] marks the stint boundaries in [points] so both the card and
/// the GPX draw each stint separately. [onBusyChanged] toggles the caller's spinner
/// around the render. [subject] tunes the wording ("ride" / "trip").
Future<void> showShareFlow(
  BuildContext context, {
  required Ride ride,
  required List<TrackPoint> points,
  required SpeedUnit unit,
  required ValueChanged<bool> onBusyChanged,
  List<int> stintStarts = const [],
  String subject = 'ride',
}) async {
  final cx = AppColors.of(context);
  final basemap = _BasemapHolder();
  try {
    final request = await showModalBottomSheet<_ShareRequest>(
      context: context,
      backgroundColor: cx.surfaceRaised,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => _ShareComposer(
        ride: ride,
        points: points,
        unit: unit,
        stintStarts: stintStarts,
        subject: subject,
        basemap: basemap,
      ),
    );
    if (request == null || !context.mounted) return;

    // The tiles may still be arriving. Better a share that waits a beat than one
    // that quietly drops the map the rider switched on and previewed.
    await basemap.pending;
    if (!context.mounted) return;
    final tiles = request.gpx ? null : basemap.value;

    onBusyChanged(true);
    try {
      if (request.gpx) {
        await GpxExport.share(ride: ride, points: points, stintStarts: stintStarts);
      } else {
        switch (request.action) {
          case _ShareAction.instagram:
            await RideShare.shareToInstagram(
              context: context,
              ride: ride,
              points: points,
              unit: unit,
              layout: request.layout,
              scrim: request.scrim,
              stintStarts: stintStarts,
              basemap: tiles,
            );
          case _ShareAction.gallery:
            await RideShare.saveToGallery(
              context: context,
              ride: ride,
              points: points,
              unit: unit,
              layout: request.layout,
              scrim: request.scrim,
              stintStarts: stintStarts,
              basemap: tiles,
            );
            if (context.mounted) _showMessage(context, 'Saved to your gallery.');
          case _ShareAction.more:
            await RideShare.shareToSystem(
              context: context,
              ride: ride,
              points: points,
              unit: unit,
              layout: request.layout,
              scrim: request.scrim,
              stintStarts: stintStarts,
              basemap: tiles,
            );
        }
      }
    } catch (_) {
      if (context.mounted) {
        _showMessage(
          context,
          request.gpx
              ? "Couldn't export the track. Try again."
              : request.action == _ShareAction.gallery
                  ? "Couldn't save the image. Try again."
                  : "Couldn't share this $subject. Try again.",
          isError: true,
        );
      }
    } finally {
      onBusyChanged(false);
    }
  } finally {
    basemap.dispose();
  }
}

/// The sheet: a live preview that fills the width it can, a swipeable strip of
/// layouts, and the destinations.
class _ShareComposer extends ConsumerStatefulWidget {
  const _ShareComposer({
    required this.ride,
    required this.points,
    required this.unit,
    required this.stintStarts,
    required this.subject,
    required this.basemap,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final List<int> stintStarts;
  final String subject;

  /// Owned by [showShareFlow], filled in here — see [_BasemapHolder].
  final _BasemapHolder basemap;

  @override
  ConsumerState<_ShareComposer> createState() => _ShareComposerState();
}

class _ShareComposerState extends ConsumerState<_ShareComposer> {
  final PageController _pages = PageController();
  int _index = 0;

  /// True while tiles are in flight, so the row can say so instead of the
  /// preview just sitting there looking like the switch did nothing.
  bool _loadingMap = false;

  /// Set once a load has come back empty, so flipping the switch on and off does
  /// not re-run a twelve-second timeout over ground that has no tiles.
  bool _mapUnavailable = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  ShareLayout get _layout => ShareLayout.values[_index];

  /// Loads the basemap once and keeps it for every layout in the sheet.
  ///
  /// The tiles depend on the route, not on which card is on screen, so swiping
  /// between styles costs nothing. Switching the toggle off keeps them too: the
  /// rider who is comparing with and without should not pay a refetch each time.
  void _wantBasemap(bool on) {
    if (!on || _loadingMap || _mapUnavailable) return;
    if (widget.basemap.value != null) return;
    if (widget.points.isEmpty) return;

    setState(() => _loadingMap = true);
    final future = ShareBasemapLoader.load(
      route: [
        for (final p in widget.points) LatLng(p.latitude, p.longitude),
      ],
      // The card is always the dark brand look, whatever theme the app is in.
      urlTemplate: basemapUrl(true),
    ).then((map) {
      widget.basemap.value = map;
      if (mounted) {
        setState(() {
          _loadingMap = false;
          _mapUnavailable = map == null;
        });
      }
    });
    widget.basemap.pending = future;
  }

  /// What the settings row says just left of the map switch.
  ///
  /// Short by necessity — it shares a row with two switches and two labels on a
  /// 320dp phone — and empty whenever the preview already answers the question.
  String _mapHint({required bool mapAllowed, required bool on}) {
    if (!mapAllowed) return 'Not on this style';
    if (!on) return '';
    if (_loadingMap) return 'Loading…';
    // The silent-fallback decision is about the *card*, not the sheet: the export
    // never fails, but the rider standing in front of a preview that did not
    // change deserves to know why.
    if (_mapUnavailable) return 'No tiles here';
    return '';
  }

  @override
  void initState() {
    super.initState();
    // The preference is remembered, so a rider who left this on last time opens
    // the sheet to a card that is already loading rather than to one that only
    // starts once they touch the switch they already set.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _wantBasemap(ref.read(shareBasemapProvider));
    });
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final media = MediaQuery.of(context);
    final scrim = ref.watch(shareScrimProvider);
    final wantsMap = ref.watch(shareBasemapProvider);
    // Trace draws no route, so there is nothing for a map to sit under.
    final mapAllowed = _layout != ShareLayout.trace;
    final tiles = wantsMap && mapAllowed ? widget.basemap.value : null;
    // A square card wants a square preview: as wide as the sheet's content area
    // (20dp of padding either side) is also as tall as it can usefully be. The
    // second term is the rest of the sheet — handle, title, the settings row,
    // chips, blurb, destinations, GPX row — so on a short screen the preview
    // gives way. It went 300 -> 348 when the backdrop switch was added; a switch
    // carries a 48dp tap target, and leaving the old figure is what makes a sheet
    // overflow. The map switch cost nothing further only because it shares that
    // one row — see the settings row below before splitting it in two.
    // Never past 1:1; scaling a 360dp card up only softens it. The 120dp floor is
    // for the shortest supported screen, where the chrome alone fills the sheet —
    // it was 140 until the backdrop row arrived and took the last of the slack.
    final double preview = math
        .min(media.size.width - 40, media.size.height * 0.9 - 348)
        .clamp(120, 360)
        .toDouble();
    return ConstrainedBox(
      // A ceiling now, not a target. While the card was 9:16 the sheet took every
      // dp it could get, because a tall preview *was* the point of it; a square
      // preview stops wanting more once it is as wide as the sheet, so the column
      // sizes to its contents and this only catches the case where they don't fit.
      constraints: BoxConstraints(maxHeight: media.size.height * 0.9),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: cx.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Share this ${widget.subject}',
                      style: TextStyle(
                        color: cx.textBright,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    'Swipe to change style',
                    style:
                        TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            // Above the preview rather than beside the destinations: these change
            // what you are looking at, so they belong with the thing they change.
            //
            // Both on one row, which is not tidiness — it is the only way the map
            // switch fits. A second switch row costs 48dp, and on the shortest
            // supported phone the sheet is already within 7dp of its cap with the
            // preview at its floor; the sheet simply overflowed. The two hint
            // sentences that used to sit beside "Dark backdrop" paid for it: the
            // live preview a few dp below answers "what does this do" better than
            // they did, and the one hint that says something the preview *cannot*
            // — why a map is missing — is kept.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text(
                    'Backdrop',
                    style: TextStyle(
                      color: cx.textBright,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Switch(
                    value: scrim,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) =>
                        ref.read(shareScrimProvider.notifier).set(v),
                  ),
                  // Immediately left of the control it is about, and flexible so
                  // it gives way rather than overflowing a narrow phone.
                  Expanded(
                    child: Text(
                      _mapHint(mapAllowed: mapAllowed, on: wantsMap),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: cx.textTertiary, fontSize: kMinFontSize),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Map',
                    style: TextStyle(
                      color: mapAllowed ? cx.textBright : cx.textDim,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Switch(
                    value: wantsMap && mapAllowed,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    // Disabled on Trace rather than hidden: a control that appears
                    // and vanishes as the rider swipes styles is worse than one
                    // that stays put and says why it cannot be used here — and it
                    // keeps the sheet's height fixed, which the preview maths
                    // below depends on.
                    onChanged: mapAllowed
                        ? (v) {
                            ref.read(shareBasemapProvider.notifier).set(v);
                            _wantBasemap(v);
                          }
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: preview,
              child: PageView.builder(
                controller: _pages,
                itemCount: ShareLayout.values.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) => _Preview(
                  ride: widget.ride,
                  points: widget.points,
                  unit: widget.unit,
                  stintStarts: widget.stintStarts,
                  layout: ShareLayout.values[i],
                  scrim: scrim,
                  basemap:
                      ShareLayout.values[i] == ShareLayout.trace ? null : tiles,
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Layout names as a scrollable strip. Doubles as the page indicator —
            // four unlabelled dots told the rider how many styles existed and
            // nothing about which one they were looking at.
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: ShareLayout.values.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => _LayoutChip(
                  label: ShareLayout.values[i].title,
                  selected: i == _index,
                  onTap: () => _select(i),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _layout.blurb,
                maxLines: 2,
                textAlign: TextAlign.center,
                style: TextStyle(color: cx.textDim, fontSize: kMinFontSize),
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  for (final a in _ShareAction.values) ...[
                    if (a != _ShareAction.values.first)
                      const SizedBox(width: 10),
                    Expanded(
                      child: _DestinationTile(
                        action: a,
                        primary: a == _ShareAction.instagram,
                        onTap: () => Navigator.of(context)
                            .pop(_ShareRequest.card(_layout, a, scrim)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // The track itself, kept clearly apart from the card destinations —
            // it is data, not a picture, and nothing above it applies to it.
            const SizedBox(height: 10),
            Divider(color: cx.border, height: 1),
            InkWell(
              onTap: () =>
                  Navigator.of(context).pop(const _ShareRequest.gpx()),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.route_outlined, size: 18, color: cx.textDim),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Export the track as GPX',
                        style: TextStyle(
                          color: cx.textBright,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 18, color: cx.textDim),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One card preview on a dark backdrop, scaled by [FittedBox] into whatever room
/// the sheet gave the page.
///
/// No `SizedBox` around the card: it sizes itself to [ShareCard.canvasSize], so
/// there is nothing here that can disagree with what gets exported.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.ride,
    required this.points,
    required this.unit,
    required this.stintStarts,
    required this.layout,
    required this.scrim,
    this.basemap,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final List<int> stintStarts;
  final ShareLayout layout;
  final bool scrim;
  final ShareBasemap? basemap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Center(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0A0A0A),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cx.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: FittedBox(
            fit: BoxFit.contain,
            child: ShareCard(
              ride: ride,
              points: points,
              unit: unit,
              layout: layout,
              scrim: scrim,
              stintStarts: stintStarts,
              basemap: basemap,
            ),
          ),
        ),
      ),
    );
  }
}

class _LayoutChip extends StatelessWidget {
  const _LayoutChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Card style: $label',
      child: ExcludeSemantics(
        child: Material(
          color: selected ? cx.accent : cx.surface,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: selected ? cx.accent : cx.border),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? cx.onAccent : cx.textDim,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 54dp destination button. Instagram is filled (it is what most shares are);
/// the others are outlined peers of each other.
class _DestinationTile extends StatelessWidget {
  const _DestinationTile({
    required this.action,
    required this.primary,
    required this.onTap,
  });

  final _ShareAction action;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final fg = primary ? cx.onAccent : cx.textBright;
    return Semantics(
      button: true,
      label: action.label,
      child: ExcludeSemantics(
        child: Material(
          color: primary ? cx.accent : cx.surface,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(14),
            child: Container(
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: primary ? cx.accent : cx.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(action.icon, size: 17, color: fg),
                  const SizedBox(width: 7),
                  // The three labels differ in width; let the longest shrink
                  // rather than overflow a third of the row.
                  Flexible(
                    child: Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
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

void _showMessage(BuildContext context, String message,
    {bool isError = false}) {
  final cx = AppColors.of(context);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        backgroundColor: cx.surface,
        content: Text(message,
            style: TextStyle(color: isError ? cx.dangerInk : cx.textBright)),
      ),
    );
}
