import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/duration_format.dart';

/// `core/duration_format.dart` had no direct coverage: the two duration writers
/// were only ever asserted through whatever screen happened to render them, and
/// [formatPace] arrived here from a 970-line UI file precisely so its edge cases
/// could be checked as arithmetic instead of by matching a string on a widget.

void main() {
  group('formatDuration — a duration, as a stat', () {
    test('pads the minutes so a column of these lines up', () {
      // The whole reason there are two writers: a readout that changes width
      // every ten minutes is the one thing you must not do to a number read in
      // motion.
      expect(formatDuration(0), '00:00');
      expect(formatDuration(462), '07:42');
      expect(formatDuration(725), '12:05');
    });

    test('grows an hours field rather than counting past 59 minutes', () {
      expect(formatDuration(3600), '1:00:00');
      expect(formatDuration(3903), '1:05:03');
      expect(formatDuration(36000), '10:00:00');
    });
  });

  group('formatClock — a position along an axis', () {
    test('does not pad the minutes: an axis tick is a label, not a cell', () {
      expect(formatClock(30), '0:30');
      expect(formatClock(300), '5:00');
      expect(formatClock(570), '9:30');
    });

    test('pads again past the hour, because "1:5:03" is not a time', () {
      expect(formatClock(3903), '1:05:03');
    });
  });

  group('formatPace — a rate wearing a duration’s clothes', () {
    test('is minutes per displayed unit, off moving time', () {
      // 30 minutes of moving time over 10 km is 3:00/km. The caller converts the
      // distance first, so this never has to know which unit it is pacing — the
      // same half hour over 6 miles is 5:00/mi by the same arithmetic.
      expect(formatPace(1800, 10), '3:00');
      expect(formatPace(1800, 6), '5:00');
    });

    test('says nothing rather than something wrong on a stub of a ride', () {
      // Under 50 m a single fix either way swings the figure by minutes.
      expect(formatPace(600, 0.049), '--:--');
      expect(formatPace(600, 0), '--:--');

      // No moving time at all would divide by zero.
      expect(formatPace(0, 12), '--:--');
      expect(formatPace(-5, 12), '--:--');
    });

    test('carries instead of rendering a sixtieth second', () {
      // `(secPerUnit % 60).round()` rounds *up* to 60 from 59.5 seconds. Without
      // the carry this reads "4:60", which is not a pace.
      //
      // 299.6 s/km: 4 minutes and 59.6 seconds.
      expect(formatPace(2996, 10), '5:00');

      // And the ordinary case just below the boundary still reads as 59.
      expect(formatPace(2994, 10), '4:59');
    });

    test('pads the seconds but not the minutes', () {
      // Same call as `formatClock`: this is a label beside a stat, not a column
      // cell, so nothing under it needs to align.
      expect(formatPace(600, 10), '1:00');
      expect(formatPace(63, 10), '0:06');
    });

    test('never prints a non-number at the rider', () {
      // The `isFinite` guard is belt-and-braces behind the 0.05 sentinel: a
      // distance that is not a number gets the sentinel, not `NaN`.
      expect(formatPace(1800, double.nan), '--:--');
    });
  });
}
