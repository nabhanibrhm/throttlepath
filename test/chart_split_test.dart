import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/ui/chart_math.dart';

/// `splitAndDownsample` is what stops a chart series sloping straight across a GPS
/// blackout. On a *time* axis a dead zone is a long horizontal stretch, and one
/// `LineChartBarData` has no notion of a discontinuity — it just joins the spots on
/// either side, asserting a climb and a speed that were never measured.
void main() {
  List<FlSpot> ramp(int count, {double from = 0}) =>
      [for (var i = 0; i < count; i++) FlSpot(from + i, from + i)];

  group('splitAndDownsample', () {
    test('returns one piece when there are no breaks', () {
      final pieces = splitAndDownsample(ramp(50), const [], 300);
      expect(pieces, hasLength(1));
      expect(pieces.single, hasLength(50));
    });

    test('cuts at each break, keeping every point', () {
      final pieces = splitAndDownsample(ramp(100), const [30, 70], 300);
      expect(pieces.map((p) => p.length), [30, 40, 30]);
      // Nothing is lost — the pieces still cover the whole series.
      expect(pieces.expand((p) => p).length, 100);
    });

    test('the pieces do not span the break', () {
      // The whole point: the last x before a break and the first x after it must
      // land in *different* bars, so no line is drawn between them.
      final pieces = splitAndDownsample(ramp(100), const [40], 300);
      expect(pieces.first.last.x, 39);
      expect(pieces.last.first.x, 40);
    });

    test('splits the point budget instead of handing it to each piece', () {
      // A per-piece cap would multiply the per-frame paint cost by the number of
      // blackouts — exactly what kChartMaxPoints exists to bound.
      final pieces = splitAndDownsample(ramp(1000), const [500], 300);
      expect(pieces, hasLength(2));
      final total = pieces.fold(0, (sum, p) => sum + p.length);
      expect(total, lessThanOrEqualTo(310),
          reason: 'the budget is for the series, not per piece');
    });

    test('allocates the budget in proportion to each piece', () {
      final pieces = splitAndDownsample(ramp(1000), const [900], 300);
      // 90% of the samples, so ~90% of the budget.
      expect(pieces.first.length, closeTo(270, 15));
      expect(pieces.last.length, closeTo(30, 15));
    });

    test('never emits a one-point piece it could not draw', () {
      // A single stranded fix between two blackouts. It must survive with enough
      // points to be a line, and must not be silently dropped.
      final pieces = splitAndDownsample(ramp(1000), const [499, 500], 300);
      expect(pieces, hasLength(3));
      for (final piece in pieces) {
        expect(piece.length, greaterThanOrEqualTo(1));
      }
    });

    test('is empty-safe', () {
      expect(splitAndDownsample(const [], const [], 300), isEmpty);
      expect(splitAndDownsample(const [], const [5], 300), isEmpty);
    });

    test('ignores a break at index zero rather than emitting an empty piece', () {
      final pieces = splitAndDownsample(ramp(20), const [0], 300);
      expect(pieces, hasLength(1));
      expect(pieces.single, hasLength(20));
    });
  });
}
