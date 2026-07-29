import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// One app bar for both detail screens (F29): back · title · share · overflow.
///
/// The two screens had drifted apart — ride detail put rename behind a pencil
/// icon and had no overflow menu; trip detail hid rename *inside* an overflow and
/// had no pencil. Same object, same depth in the app, two different grammars, so
/// neither taught the other.
///
/// Rename now lives in one place on both: **tap the title**. That is where the
/// name is, it costs no chrome, and it frees the icon slot that was carrying a
/// pencil on one screen and nothing on the other. Because a tappable title is not
/// self-announcing, it is also the first item of the overflow menu.
class DetailAppBar extends StatelessWidget implements PreferredSizeWidget {
  const DetailAppBar({
    super.key,
    required this.title,
    required this.onRename,
    required this.renameTooltip,
    this.busy = false,
    this.onShare,
    this.shareTooltip = 'Share',
    this.menuItems = const [],
    this.onMenuSelected,
  });

  final String title;

  /// Invoked by both the title tap and the menu's first entry.
  final VoidCallback onRename;

  /// Wording for the rename action — "Rename ride" / "Rename leg" / "Rename
  /// trip". Also the title's semantic hint.
  final String renameTooltip;

  /// Swaps the actions for a spinner while a share render or a write is running.
  final bool busy;

  /// Null disables the share button (e.g. the track hasn't loaded yet).
  final VoidCallback? onShare;
  final String shareTooltip;

  /// Screen-specific overflow entries, appended under Rename. An empty list
  /// still yields a menu — Rename alone justifies it, since the title tap needs
  /// somewhere to be discoverable.
  final List<DetailMenuItem> menuItems;
  final ValueChanged<String>? onMenuSelected;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return AppBar(
      backgroundColor: cx.canvas,
      foregroundColor: cx.textBright,
      elevation: 0,
      centerTitle: true,
      shape: Border(bottom: BorderSide(color: cx.border)),
      title: Semantics(
        button: true,
        hint: renameTooltip,
        child: InkWell(
          onTap: onRename,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Icon(Icons.edit_outlined, size: 15, color: cx.textDim),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (busy)
          Padding(
            padding: const EdgeInsets.only(right: 18),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: cx.accentInk,
                ),
              ),
            ),
          )
        else ...[
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: shareTooltip,
            onPressed: onShare,
          ),
          PopupMenuButton<String>(
            color: cx.surfaceRaised,
            icon: Icon(Icons.more_vert, color: cx.textBright),
            tooltip: 'More actions',
            onSelected: (v) {
              if (v == kRenameAction) {
                onRename();
                return;
              }
              onMenuSelected?.call(v);
            },
            itemBuilder: (_) => [
              _item(kRenameAction, Icons.edit_outlined, renameTooltip, cx),
              for (final m in menuItems) _item(m.value, m.icon, m.label, cx),
            ],
          ),
        ],
      ],
    );
  }

  PopupMenuItem<String> _item(
      String value, IconData icon, String label, AppPalette cx) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: cx.accentInk, size: 18),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: cx.textBright)),
        ],
      ),
    );
  }

  /// Menu value reserved for the rename entry, handled internally.
  static const String kRenameAction = '__rename';
}

/// One screen-specific overflow entry.
class DetailMenuItem {
  const DetailMenuItem({
    required this.value,
    required this.icon,
    required this.label,
  });

  final String value;
  final IconData icon;
  final String label;
}
