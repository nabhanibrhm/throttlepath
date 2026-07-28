import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// What a detail screen shows in place of a map when the ride or trip captured no
/// GPS fixes at all.
///
/// Replaces a greyed-out map of a hardcoded fallback city with a sentence saying
/// what happened (F18). Showing Jakarta at 50% opacity to a rider in Bandung
/// implied a failed tile load, or worse, a route recorded somewhere they had never
/// been — the map was the least informative thing that could be on screen.
class NoTrackNotice extends StatelessWidget {
  const NoTrackNotice({
    super.key,
    required this.subject,
    this.detail,
  });

  /// 'ride', 'leg' or 'trip' — used in the explanation.
  final String subject;

  /// Optional extra line, e.g. the distance that was recorded anyway.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      width: double.infinity,
      color: cx.surface,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.location_off_outlined, size: 40, color: cx.textTertiary),
          const SizedBox(height: 14),
          Text(
            'No route to show',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cx.textBright,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This $subject recorded no GPS fixes — usually a recording that '
            'started indoors, or one stopped before the first lock.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cx.textDim, fontSize: 13, height: 1.4),
          ),
          if (detail != null) ...[
            const SizedBox(height: 10),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: TextStyle(color: cx.textTertiary, fontSize: kMinFontSize),
            ),
          ],
        ],
      ),
    );
  }
}
