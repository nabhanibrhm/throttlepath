/// How this app writes a time: two elapsed durations and one rate.
///
/// The two durations were previously re-declared, identically, in nearly every
/// screen that shows a time, which is how they came to differ by accident rather
/// than on purpose. They are genuinely different jobs, so they get different
/// names here instead of one function with a flag.
///
/// [formatPace] is the odd one out and worth naming as such: it reads as `m:ss`
/// like the others but it is minutes *per distance unit*, not minutes elapsed.
/// It lives here because that is where a reader looks for `m:ss`, and because its
/// edge cases are arithmetic rather than presentation.
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

/// `m:ss` per displayed distance unit — a **rate**, not a duration.
///
/// [displayDistance] is already in the rider's unit (km or mi), so this returns
/// minutes per km or per mile without needing to know which. Computed against
/// *moving* time, so a long stop at a warung doesn't make the ride look slow.
///
/// `'--:--'` rather than a number in three cases, each a different way the answer
/// would be a lie:
///  - under 50 m ridden, where a second either way swings the figure by minutes;
///  - no moving time at all, which would divide by zero;
///  - a non-finite result, belt-and-braces for a distance that underflows the
///    first guard.
///
/// The `ss == 60` carry is not paranoia: `(secPerUnit % 60).round()` rounds *up*
/// to 60 for anything from 59.5 seconds, and `4:60` is not a pace.
String formatPace(int movingSeconds, double displayDistance) {
  if (displayDistance < 0.05 || movingSeconds <= 0) return '--:--';
  final secPerUnit = movingSeconds / displayDistance;
  if (!secPerUnit.isFinite) return '--:--';
  var mm = secPerUnit ~/ 60;
  var ss = (secPerUnit % 60).round();
  if (ss == 60) {
    ss = 0;
    mm += 1;
  }
  return '$mm:${_two(ss)}';
}
