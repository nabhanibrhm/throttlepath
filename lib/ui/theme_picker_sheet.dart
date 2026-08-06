/// The Theme picker, moved out of the settings list into a sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_providers.dart';
import '../theme/app_theme.dart';

/// Opens the System / Light / Dark picker.
///
/// Theme was the only *inline* control in the settings list — a three-up
/// segmented row inside a card — which meant it set the row height for
/// everything around it and made the list look like it had one important
/// setting and six afterthoughts (spec 8.4). It reads as a value row now, like
/// the rest, and the choice lives here.
///
/// **No preview.** `share_flow.dart`'s sheet previews its card layouts because
/// you cannot picture "Stacked" from the word; System / Light / Dark need no
/// such help, and the moment a mode is tapped the whole app behind the sheet
/// re-themes — a better preview than anything a swatch could show.
Future<void> showThemePickerSheet(BuildContext context) {
  final cx = AppColors.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cx.surfaceRaised,
    // Deliberately not `isScrollControlled`: this is a three-row action sheet
    // that should size to its content, not the near-full-height card the share
    // composer needs.
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (_) => const _ThemePickerSheet(),
  );
}

class _ThemePickerSheet extends ConsumerWidget {
  const _ThemePickerSheet();

  static const _modes = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final current = ref.watch(themeModeProvider);

    return SafeArea(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(kRowGutter, 16, kRowGutter, 4),
            child: Row(
              children: [
                Text('Theme', style: t.titleLarge),
                const Spacer(),
              ],
            ),
          ),
          for (final m in _modes)
            _ThemeOptionRow(
              mode: m,
              selected: m == current,
              // Applies and closes in one motion, matching `_DestinationTile` in
              // the share sheet. A separate Done button would ask the rider to
              // confirm a choice they can already see has taken effect.
              onTap: () {
                ref.read(themeModeProvider.notifier).setMode(m);
                Navigator.of(context).pop();
              },
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _ThemeOptionRow extends StatelessWidget {
  const _ThemeOptionRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    final t = Theme.of(context).textTheme;
    final label = themeModeLabel(mode);
    final ink = selected ? cx.accentInk : cx.textBright;
    return Semantics(
      button: true,
      selected: selected,
      // Kept as "<Mode> theme" — the wording the retired segmented control used,
      // so a rider who learned it by ear does not have to relearn it.
      label: '$label theme',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(
              horizontal: kRowGutter,
              vertical: 10,
            ),
            // Excluding only the *contents*, not the InkWell: wrapping the whole
            // subtree strips the tap and focus actions off the Semantics node
            // above, leaving a row a screen reader can describe but not press.
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Icon(themeModeIcon(mode), size: 20, color: ink),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: t.bodyMedium!.copyWith(
                            color: ink,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        // Only System needs explaining — the other two say what
                        // they do. It is also the one riders never found while
                        // it was hidden behind a two-state switch.
                        if (mode == ThemeMode.system)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Follows your phone’s light/dark setting.',
                              style: t.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.check, size: 20, color: cx.accentInk),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
