/// The one row shape the minimal-look pass replaced every filled card with.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A list row separated by a hairline instead of enclosed in a card (G1).
///
/// The app used to draw every list and stat item as a filled rounded card —
/// `surface` fill, 16dp radius, a full border. At three or four rows on screen
/// that reads as four competing objects rather than one list, and the fills
/// stack up against the amber the screen is actually trying to point at. A rule
/// above each row does the same separating job with none of the weight.
///
/// **Fills survive only where they mean something:** the record sheet (it floats
/// over a map), text inputs, chips, buttons and dialogs. Anywhere a row is just
/// a row, it gets this.
///
/// The hairline is [AppPalette.border], not the spec's `#1B1B1E` — that value
/// measures ~1.05:1 against both dark grounds, the same failure that got
/// `#262626` rejected from this palette once already (see `app_theme.dart`).
/// `border` is the darkest hairline this project has been willing to ship.
///
/// Both of those rejections were argued on WCAG ratio, which is fair on a dark
/// ground and misleading on a light one — the formula compresses near white, so
/// the light hairline passed its ratio check while reading half the weight of
/// the dark one. The light value is set by ΔL\* instead; see `app_theme.dart`.
class HairlineRow extends StatelessWidget {
  const HairlineRow({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.leadingGutter = kRowGutter,
    this.trailingGutter = kRowGutter,
    this.verticalPadding = kRowPadding,
    this.showRule = true,
    this.minHeight,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Floor for the whole row, padding included — so a one-line row still clears
  /// a glove-sized tap target. Applied *outside* the padding on purpose: inside
  /// it, a 48dp floor plus 13dp top and bottom would make every row 74dp.
  final double? minHeight;

  /// Overridable only for rows that carry their own inset content (nested
  /// stints); the default is the shared [kRowGutter] and should stay it.
  final double leadingGutter;
  final double trailingGutter;

  /// Padding, never a fixed height — a row must be free to grow when the system
  /// text scale is turned up. Fixed heights are what the a11y pass had to undo
  /// across the settings list.
  final double verticalPadding;

  /// The first row under a header already has that header's rule above it, so it
  /// can skip its own and avoid a doubled 2px line.
  final bool showRule;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    Widget body = Padding(
      padding: EdgeInsets.fromLTRB(
        leadingGutter,
        verticalPadding,
        trailingGutter,
        verticalPadding,
      ),
      child: child,
    );
    if (minHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight!),
        child: body,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: showRule
            ? Border(top: BorderSide(color: cx.border))
            : const Border(),
      ),
      // Transparent Material so the press ripple lands on the canvas rather than
      // reintroducing the fill this row exists to remove.
      child: Material(
        color: Colors.transparent,
        child: onTap == null && onLongPress == null
            ? body
            : InkWell(onTap: onTap, onLongPress: onLongPress, child: body),
      ),
    );
  }
}

/// An UPPERCASE section label over a rule, with an optional trailing figure
/// (a month's total, a group's count).
///
/// Shares [kRowGutter] with the rows beneath it, so the label and the names
/// below it sit on one left edge.
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.label,
    this.trailing,
    this.rule = true,
  });

  final String label;

  /// Right-hand figure, already formatted. Rendered in the metadata style.
  final String? trailing;

  /// The rule running from the label to the trailing figure. On by default,
  /// because a month header uses it to carry the eye across to that month's
  /// total. Off in a settings list, where the first row's own hairline sits
  /// directly beneath and two lines 6dp apart read as a mistake.
  final bool rule;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(kRowGutter, rule ? 20 : 18, kRowGutter,
          rule ? 8 : 6),
      child: Row(
        children: [
          Semantics(
            header: true,
            child: Text(label.toUpperCase(), style: t.labelSmall),
          ),
          if (rule) ...[
            const SizedBox(width: 10),
            Expanded(child: Divider(color: cx.border, height: 1)),
          ] else
            const Spacer(),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            Text(trailing!, style: t.bodySmall),
          ],
        ],
      ),
    );
  }
}
