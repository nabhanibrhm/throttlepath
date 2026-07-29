import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Prompts for a new name, pre-filled with [initial] (selected, so typing
/// replaces it). Returns the trimmed name, or null when cancelled or left empty
/// — callers treat null as "leave the name alone".
///
/// Shared by the rename actions on a ride, a trip stint and a trip.
Future<String?> showRenameDialog(
  BuildContext context, {
  required String title,
  String? initial,
  String? hint,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RenameDialog(title: title, initial: initial, hint: hint),
  ).then((v) {
    final trimmed = v?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  });
}

/// The dialog owns its [TextEditingController] so it is disposed with the
/// dialog's own element — never while the [TextField] is still mounted (which
/// trips a `_dependents.isEmpty` assertion during the route's exit transition).
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title, this.initial, this.hint});

  final String title;
  final String? initial;
  final String? hint;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  )..selection = TextSelection(
      baseOffset: 0,
      extentOffset: (widget.initial ?? '').length,
    );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final cx = AppColors.of(context);
    return AlertDialog(
      backgroundColor: cx.surface,
      title: Text(widget.title, style: TextStyle(color: cx.textBright)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        style: TextStyle(color: cx.textBright),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: TextStyle(color: cx.textDim),
          filled: true,
          fillColor: cx.canvas,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cx.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: cx.accentInk),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: cx.textDim)),
        ),
        TextButton(
          onPressed: _submit,
          child: Text('Save', style: TextStyle(color: cx.accentInk)),
        ),
      ],
    );
  }
}
