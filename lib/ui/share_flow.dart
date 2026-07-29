import 'package:flutter/material.dart';

import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../services/gpx_export.dart';
import '../services/ride_share.dart';
import '../theme/app_theme.dart';
import 'share_card.dart';

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
  const _ShareRequest.card(this.layout, this.action) : gpx = false;
  // The layout is unused on this path; it just has to be *a* value.
  const _ShareRequest.gpx()
      : layout = ShareLayout.split,
        action = _ShareAction.more,
        gpx = true;

  final ShareLayout layout;
  final _ShareAction action;
  final bool gpx;
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
    ),
  );
  if (request == null || !context.mounted) return;

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
            stintStarts: stintStarts,
          );
        case _ShareAction.gallery:
          await RideShare.saveToGallery(
            context: context,
            ride: ride,
            points: points,
            unit: unit,
            layout: request.layout,
            stintStarts: stintStarts,
          );
          if (context.mounted) _showMessage(context, 'Saved to your gallery.');
        case _ShareAction.more:
          await RideShare.shareToSystem(
            context: context,
            ride: ride,
            points: points,
            unit: unit,
            layout: request.layout,
            stintStarts: stintStarts,
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
}

/// The sheet: a live preview that fills the width it can, a swipeable strip of
/// layouts, and the destinations.
class _ShareComposer extends StatefulWidget {
  const _ShareComposer({
    required this.ride,
    required this.points,
    required this.unit,
    required this.stintStarts,
    required this.subject,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final List<int> stintStarts;
  final String subject;

  @override
  State<_ShareComposer> createState() => _ShareComposerState();
}

class _ShareComposerState extends State<_ShareComposer> {
  final PageController _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  ShareLayout get _layout => ShareLayout.values[_index];

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
    return ConstrainedBox(
      // Nearly full height: the preview is the point of the sheet, and every dp
      // handed back to the screen behind it is a dp the card doesn't get.
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
            const SizedBox(height: 12),
            Expanded(
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
                            .pop(_ShareRequest.card(_layout, a)),
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

/// One full-size card preview on a dark backdrop, scaled to whatever room the
/// sheet has left.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.ride,
    required this.points,
    required this.unit,
    required this.stintStarts,
    required this.layout,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final List<int> stintStarts;
  final ShareLayout layout;

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
            child: SizedBox(
              width: 360,
              height: 640,
              child: ShareCard(
                ride: ride,
                points: points,
                unit: unit,
                layout: layout,
                stintStarts: stintStarts,
              ),
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
