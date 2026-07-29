import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the lifetime of a controller owned by a dialog or bottom sheet.
///
/// The bug this exists for: the trip-name sheet disposed its
/// [TextEditingController] with `.whenComplete(controller.dispose)` on the
/// route's own future. That reads as "dispose it when the sheet is done", but a
/// route's future completes the moment it is *popped* — the start of the exit
/// transition, not the end. Dismissing the sheet by tapping the barrier disposed
/// the controller while the focused `TextField` was still mounted and animating
/// out; the throw from inside the still-live field aborted Flutter's unmount
/// walk, and the *next* frame died on `_dependents.isEmpty` with no mention of a
/// controller anywhere in the trace. Two hops from cause to symptom is what makes
/// it worth a guard rather than a comment.
void main() {
  test('a route future never disposes a controller', () {
    // The pattern is invisible in review because it looks like correct cleanup,
    // and the crash it causes names an unrelated framework assertion. The fix is
    // always the same: a StatefulWidget owning the controller, so disposal is
    // tied to the field's own element (see _TripNameSheet, _RenameDialog).
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final line in source.split('\n').indexed) {
        final (i, text) = line;
        final code = text.trim();
        // Comments are exempt — the fix's own doc comment quotes the bad pattern
        // to explain it, and naming the mistake is the point of that comment.
        if (code.startsWith('//') || code.startsWith('*')) continue;
        if (code.contains('whenComplete') && code.contains('dispose')) {
          offenders.add('${file.path}:${i + 1}: $code');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'dispose the controller in State.dispose(), not on a route '
            'future — the future completes before the widget unmounts:\n'
            '${offenders.join('\n')}');
  });

  testWidgets('dismissing a sheet by its barrier disposes nothing early',
      (t) async {
    // The reproduction, in the shape the sheet actually has: an autofocused field
    // whose controller belongs to a StatefulWidget. Popping via the barrier is
    // the path that used to crash, because it is the one where nothing in the
    // sheet's own code runs first.
    var disposed = false;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<String>(
              context: context,
              builder: (_) => _Sheet(onDispose: () => disposed = true),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(disposed, isFalse);

    // Tap the barrier, then let the exit transition run to completion. The
    // controller must survive every frame in which the field is still painted.
    await t.tapAt(const Offset(20, 20));
    await t.pump(const Duration(milliseconds: 50));
    expect(disposed, isFalse, reason: 'disposed mid-transition');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(disposed, isTrue, reason: 'never disposed at all — a real leak');
  });
}

/// Stands in for the trip-name sheet: same ownership, same autofocus.
class _Sheet extends StatefulWidget {
  const _Sheet({required this.onDispose});

  final VoidCallback onDispose;

  @override
  State<_Sheet> createState() => _SheetState();
}

class _SheetState extends State<_Sheet> {
  final TextEditingController controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(22),
        child: TextField(controller: controller, autofocus: true),
      );
}
