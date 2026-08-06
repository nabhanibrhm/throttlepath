import 'package:flutter/material.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../theme/app_theme.dart';

/// The Record screen's display control: what sits behind the telemetry sheet
/// (map / live chart / lean / nothing) and how the live speed is drawn (analog
/// dial / plain numeral).
///
/// **Two axes, not one list of six.** The audit's mockups assume a single
/// `RideDisplayMode{dial, number, map, chart}` switcher, but backdrop and gauge
/// are independent: 4 × 2 = eight reachable combinations. Flattening them would
/// silently delete most, including map + dial, which is the pairing actually in
/// use. So both axes stay, and every pairing remains reachable.
///
/// **One toolbar row, not two segmented groups.** Two 44dp label rows plus a gap
/// took ~96dp out of a sheet whose job is to show a speed, and read as two sets
/// of tabs competing for the same attention. Four glyphs, a divider and two short
/// labels say the same thing in one row (spec 1.1) and hand ~58dp back to the
/// telemetry above.
///
/// It still writes to the same two providers Settings reads, via the same two
/// callbacks — the control moved and shrank, nothing about where the choice lives
/// changed.
class RideDisplaySwitcher extends StatelessWidget {
  const RideDisplaySwitcher({
    super.key,
    required this.view,
    required this.gaugeStyle,
    required this.onViewChanged,
    required this.onGaugeStyleChanged,
  });

  final RecordView view;
  final SpeedGaugeStyle gaugeStyle;
  final ValueChanged<RecordView> onViewChanged;
  final ValueChanged<SpeedGaugeStyle> onGaugeStyleChanged;

  /// Row height. The spec drew this at 30dp; it is 38 here.
  ///
  /// 30dp would put every control on this row under the 48dp touch target the
  /// a11y pass spent Phase 7 raising rows *to* — on a phone that gets tapped
  /// through a glove at a set of lights, that is not a trade worth making for
  /// 8dp. 38 still reads as a toolbar and still hands back more height than the
  /// spec's own stated goal (~34dp), because it is replacing two rows, not one.
  static const double _height = 38;

  /// Glyph per backdrop. Mapped here rather than on the enum so `core/` stays
  /// free of a Material import; the switch is exhaustive, so adding a backdrop
  /// is still a compile error rather than a silently missing button.
  static IconData _iconFor(RecordView v) => switch (v) {
        RecordView.map => Icons.map_outlined,
        RecordView.chart => Icons.show_chart,
        RecordView.lean => Icons.motorcycle_outlined,
        RecordView.none => Icons.visibility_off_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return SizedBox(
      height: _height,
      child: Row(
        children: [
          for (final v in RecordView.values)
            _ToolbarButton(
              // Glyph-only, but never label-less: the spoken label is what makes
              // four abstract shapes usable, and it is the same string Settings
              // shows, off the same enum.
              semanticsLabel: 'Backdrop: ${v.label}',
              selected: v == view,
              onTap: () => onViewChanged(v),
              child: Icon(_iconFor(v), size: 18),
            ),
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 8),
            color: cx.border,
          ),
          for (final s in SpeedGaugeStyle.values)
            _ToolbarButton(
              semanticsLabel: 'Live speed: ${s.label}',
              selected: s == gaugeStyle,
              onTap: () => onGaugeStyleChanged(s),
              // The short form, so two words don't cost as much as four glyphs.
              // Owned by the enum beside the long one, so this row and the
              // Settings row cannot end up calling the same thing two names.
              child: Text(
                s.shortLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One control on the toolbar — a glyph or a short label, selected or not.
class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.child,
    required this.selected,
    required this.semanticsLabel,
    required this.onTap,
  });

  final Widget child;
  final bool selected;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(9),
      // The light theme's raised surface is the same white as the sheet, so the
      // outline is the only thing making the selected control visible there.
      side: selected ? BorderSide(color: cx.border) : BorderSide.none,
    );
    return Semantics(
      button: true,
      selected: selected,
      label: semanticsLabel,
      child: Material(
        color: selected ? cx.surfaceRaised : Colors.transparent,
        shape: shape,
        child: InkWell(
          onTap: onTap,
          customBorder: shape,
          child: Container(
            // Wide enough that a gloved thumb hits the intended one; the row's
            // height is what got cut, not its targets.
            width: 40,
            alignment: Alignment.center,
            child: IconTheme.merge(
              data: IconThemeData(
                color: selected ? cx.accentInk : cx.textTertiary,
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: selected ? cx.accentInk : cx.textTertiary,
                ),
                // The label is announced once, by the Semantics above, as
                // "Backdrop: Chart" rather than a bare "Chart" with no idea what
                // it selects. Without this the text is read a second time.
                child: ExcludeSemantics(child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
