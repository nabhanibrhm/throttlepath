import 'package:flutter/material.dart';

import '../core/units.dart';
import '../data/models/ride.dart';
import '../data/models/track_point.dart';
import '../services/ride_share.dart';
import '../theme/app_theme.dart';
import 'share_card.dart';

/// The two ways a rendered card can be sent off.
enum _ShareAction { instagram, download }

/// Runs the shared "pick a layout → pick an action → render & dispatch" flow
/// used by both ride detail and trip detail.
///
/// [ride] may be a real saved ride or a synthesized combined trip ride; when it
/// is a trip, [legStarts] marks the leg boundaries in [points] so the card
/// draws each leg as its own colored polyline. [onBusyChanged] toggles the
/// caller's spinner around the render. [subject] tunes the dialog wording
/// ("ride" / "trip").
Future<void> showShareFlow(
  BuildContext context, {
  required Ride ride,
  required List<TrackPoint> points,
  required SpeedUnit unit,
  required ValueChanged<bool> onBusyChanged,
  List<int> legStarts = const [],
  String subject = 'ride',
}) async {
  // Step 1 — pick one of the four card layouts (live previews).
  final layout = await _pickLayout(context, ride, points, unit, legStarts);
  if (layout == null || !context.mounted) return;

  // Step 2 — pick the export action for the chosen layout.
  final action = await _showShareOptions(context, subject);
  if (action == null || !context.mounted) return;

  onBusyChanged(true);
  try {
    if (action == _ShareAction.instagram) {
      await RideShare.shareToInstagram(
        context: context,
        ride: ride,
        points: points,
        unit: unit,
        layout: layout,
        legStarts: legStarts,
      );
    } else {
      await RideShare.saveToGallery(
        context: context,
        ride: ride,
        points: points,
        unit: unit,
        layout: layout,
        legStarts: legStarts,
      );
      if (context.mounted) _showMessage(context, 'Saved to your gallery.');
    }
  } catch (_) {
    if (context.mounted) {
      _showMessage(
        context,
        action == _ShareAction.instagram
            ? "Couldn't share this $subject. Try again."
            : "Couldn't save the image. Try again.",
        isError: true,
      );
    }
  } finally {
    onBusyChanged(false);
  }
}

/// Bottom sheet of the four card layouts, each rendered as a live preview on a
/// dark backdrop. Returns the picked [ShareLayout], or null if dismissed.
Future<ShareLayout?> _pickLayout(
  BuildContext context,
  Ride ride,
  List<TrackPoint> points,
  SpeedUnit unit,
  List<int> legStarts,
) {
  final cx = AppColors.of(context);
  return showModalBottomSheet<ShareLayout>(
    context: context,
    backgroundColor: cx.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Choose a layout',
                style: TextStyle(
                    color: cx.textBright,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Pick a card style, then share or save it.',
                style: TextStyle(color: cx.textDim, fontSize: 13)),
            const SizedBox(height: 16),
            Flexible(
              child: GridView.count(
                shrinkWrap: true,
                crossAxisCount: 2,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                childAspectRatio: 0.52,
                children: [
                  for (final layout in ShareLayout.values)
                    _LayoutTile(
                      ride: ride,
                      points: points,
                      unit: unit,
                      layout: layout,
                      legStarts: legStarts,
                      onTap: () => Navigator.of(ctx).pop(layout),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<_ShareAction?> _showShareOptions(BuildContext context, String subject) {
  final cx = AppColors.of(context);
  return showDialog<_ShareAction>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: cx.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Share $subject',
                style: TextStyle(
                    color: cx.textBright,
                    fontSize: 17,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            _ShareOption(
              icon: Icons.camera_alt,
              label: 'Share to Instagram',
              onTap: () => Navigator.of(ctx).pop(_ShareAction.instagram),
            ),
            _ShareOption(
              icon: Icons.download,
              label: 'Download as PNG',
              onTap: () => Navigator.of(ctx).pop(_ShareAction.download),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('Cancel', style: TextStyle(color: cx.textDim)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
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

/// A row in the share sheet: an amber icon in a rounded square + a label.
class _ShareOption extends StatelessWidget {
  const _ShareOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cx.canvas,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: cx.accentInk, size: 18),
            ),
            const SizedBox(width: 14),
            Text(label,
                style: TextStyle(
                    color: cx.textBright,
                    fontSize: 15,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// One tappable card-layout preview: the real [ShareCard] scaled to fit on a
/// fixed dark backdrop, with the layout's name + blurb beneath.
class _LayoutTile extends StatelessWidget {
  const _LayoutTile({
    required this.ride,
    required this.points,
    required this.unit,
    required this.layout,
    required this.legStarts,
    required this.onTap,
  });

  final Ride ride;
  final List<TrackPoint> points;
  final SpeedUnit unit;
  final ShareLayout layout;
  final List<int> legStarts;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0A),
                borderRadius: BorderRadius.circular(14),
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
                    legStarts: legStarts,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(layout.title,
              style: TextStyle(
                  color: cx.textBright,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          Text(layout.blurb,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cx.textDim, fontSize: 11)),
        ],
      ),
    );
  }
}
