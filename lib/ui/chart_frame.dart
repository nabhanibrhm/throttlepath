import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared chrome for the four analysis charts: a title, a one-sentence
/// plain-language takeaway, and consistent padding.
///
/// The takeaway is the point of this widget (F26). A chart answers "what
/// happened"; the sentence under the title answers "so what" — the reading a
/// rider would otherwise have to do themselves, in words, computed from the same
/// data the chart is drawing. Chart 1 previously shipped with no title at all.
class ChartFrame extends StatelessWidget {
  const ChartFrame({
    super.key,
    required this.title,
    required this.takeaway,
    required this.child,
    this.trailing,
  });

  /// Short all-caps name of the chart.
  final String title;

  /// One sentence in plain language. Kept to a sentence deliberately — a
  /// paragraph here would be scrolled past.
  final String takeaway;

  /// Optional widget pinned to the right of the title row (a score, a toggle).
  final Widget? trailing;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      width: double.infinity,
      color: cx.canvas,
      padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: cx.textBright,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 5),
          Text(
            takeaway,
            style: TextStyle(
              color: cx.textDim,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          // A chart is a picture with no text in it, so to a screen reader the
          // whole tab is silent below this point. The takeaway is already the
          // one-sentence version of what the plot shows — reuse it as the
          // summary rather than inventing a second description that can drift.
          Semantics(
            label: '$title chart. $takeaway',
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Axis caption — the unit, stated **once**, under or beside its axis (F26).
///
/// Repeating the unit on every tick doubles the ink for no information; stating
/// it nowhere (which is what the charts did) leaves the rider guessing whether a
/// "40" is km/h or mph.
class AxisCaption extends StatelessWidget {
  const AxisCaption(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Text(
      text,
      style: TextStyle(
        color: color ?? cx.textTertiary,
        fontSize: kMinFontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }
}

/// A legend chip that toggles its series on and off (F26).
///
/// Tappable, and it *looks* tappable: the dot hollows out and the label dims
/// when the series is hidden, so the chip reports the state it controls rather
/// than just naming a colour.
class LegendToggle extends StatelessWidget {
  const LegendToggle({
    super.key,
    required this.color,
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final Color color;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Semantics(
      toggled: enabled,
      label: '$label series',
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          // Keeps the 48dp touch target the a11y pass asks for without the chip
          // itself having to be 48dp tall.
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: enabled ? color : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: color, width: 1.5),
                ),
              ),
              const SizedBox(width: 7),
              ExcludeSemantics(
                child: Text(
                  label,
                  style: TextStyle(
                    color: enabled ? cx.textDim : cx.textTertiary,
                    fontSize: kMinFontSize,
                    fontWeight: FontWeight.w600,
                    decoration: enabled ? null : TextDecoration.lineThrough,
                    decorationColor: cx.textTertiary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
