import 'package:flutter/material.dart';

import '../core/record_view.dart';
import '../core/speed_gauge_style.dart';
import '../theme/app_theme.dart';

/// The Record screen's display control: what sits behind the telemetry sheet
/// (map / live chart / nothing) and how the live speed is drawn (analog dial /
/// plain numeral).
///
/// **Two groups, not one list of four.** The audit's mockups assume a single
/// `RideDisplayMode{dial, number, map, chart}` switcher, but backdrop and gauge
/// are independent axes: 3 × 2 = six reachable combinations. Flattening them
/// would silently delete three, including map + dial. So both axes stay, and
/// every pairing remains reachable.
///
/// This replaces a floating pill that blind-cycled map → chart → off and a
/// Settings row three taps from what it changed (F1). The control now lives on
/// the screen it affects, shows the current state rather than hiding it behind a
/// cycle, and is present in *every* backdrop — including the hidden one, which
/// previously needed its own "Show map" link as the only way out.
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

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Flex matches each group's segment count, so every segment in the row
        // ends up the same width regardless of how long its label is.
        //
        // Both groups are built from `values` rather than a hand-written list:
        // adding a backdrop used to mean remembering to add a segment here, and
        // the enum is the only place that should have to know how many there are.
        Expanded(
          flex: RecordView.values.length,
          child: _SegmentedGroup<RecordView>(
            groupLabel: 'Backdrop',
            value: view,
            onChanged: onViewChanged,
            segments: [
              for (final v in RecordView.values) _Segment(v),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: SpeedGaugeStyle.values.length,
          child: _SegmentedGroup<SpeedGaugeStyle>(
            groupLabel: 'Live speed',
            value: gaugeStyle,
            onChanged: onGaugeStyleChanged,
            segments: [
              for (final v in SpeedGaugeStyle.values) _Segment(v),
            ],
          ),
        ),
      ],
    );
  }
}

/// One choice in a group. Carries only the enum value — the visible text comes
/// from the enum's own `label`, which the Settings mirror reads too, so the two
/// surfaces cannot drift apart.
class _Segment<T> {
  const _Segment(this.value);
  final T value;
}

class _SegmentedGroup<T> extends StatelessWidget {
  const _SegmentedGroup({
    required this.segments,
    required this.value,
    required this.onChanged,
    required this.groupLabel,
  });

  final List<_Segment<T>> segments;
  final T value;
  final ValueChanged<T> onChanged;

  /// Spoken prefix for each segment, e.g. "Backdrop: Chart". The group has no
  /// visible heading — the labels are self-describing and a heading would cost
  /// vertical space the speed numeral needs more.
  final String groupLabel;

  /// Comfortable with a glove on, short enough that two groups still leave the
  /// speed the largest thing in the sheet.
  static const double _height = 44;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return Container(
      height: _height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        // A well recessed into the sheet, so the selected segment reads as
        // sitting proud of it without needing a fill that would compete with
        // START RIDE — the screen gets exactly one filled control.
        color: cx.canvas,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          for (final segment in segments)
            Expanded(
              child: _SegmentButton(
                label: _labelOf(segment.value),
                selected: segment.value == value,
                semanticsLabel: '$groupLabel: ${_labelOf(segment.value)}',
                onTap: () => onChanged(segment.value),
              ),
            ),
        ],
      ),
    );
  }

  static String _labelOf(Object? value) => switch (value) {
        RecordView v => v.label,
        SpeedGaugeStyle s => s.label,
        _ => '$value',
      };
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.semanticsLabel,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      // The light theme's raised surface is the same white as the sheet, so the
      // outline is what makes the selected segment visible there at all.
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
          child: Center(
            // The label is announced once, by the Semantics above, as
            // "Backdrop: Chart" rather than a bare "Chart" with no idea what
            // it selects. Without this the raw text is read a second time.
            child: ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? cx.accentInk : cx.textDim,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
