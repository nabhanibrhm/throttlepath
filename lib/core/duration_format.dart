/// The two ways this app writes an elapsed time — and the reason there are two.
///
/// Both were previously re-declared, identically, in nearly every screen that
/// shows a time, which is how the two variants below came to differ by accident
/// rather than on purpose. They are genuinely different jobs, so they get
/// different names here instead of one function with a flag.
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// `mm:ss`, or `h:mm:ss` past the hour — a **duration**, as a stat.
///
/// Minutes are zero-padded so a column of these lines up and none of them
/// changes width as the clock runs: "07:42" above "12:05" reads as a table, and
/// a readout that shifts sideways every ten minutes is the one thing you must
/// not do to a number read in motion.
String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

/// `m:ss`, or `h:mm:ss` past the hour — a **position along a chart axis**.
///
/// Minutes are *not* padded here: an axis tick reads as a label rather than a
/// table cell, nothing beneath it needs to align, and "0:30 · 5:00 · 9:30" is
/// what a rider expects under a plot. Once an hour is on the clock the minutes
/// pad again, because "1:5:03" is not a time.
String formatClock(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '$m:${_two(s)}';
}
