import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/ui/analog_speed_gauge.dart';

void main() {
  group('AnalogSpeedGauge.scaleFor', () {
    test('a standstill still gets the minimum dial, not a zero-width one', () {
      expect(AnalogSpeedGauge.scaleFor(0), 60);
    });

    test('slow rides stay on the minimum dial', () {
      expect(AnalogSpeedGauge.scaleFor(12), 60);
      expect(AnalogSpeedGauge.scaleFor(59.9), 60);
      expect(AnalogSpeedGauge.scaleFor(60), 60);
    });

    test('the top rounds up to the next step once the peak passes it', () {
      expect(AnalogSpeedGauge.scaleFor(60.1), 80);
      expect(AnalogSpeedGauge.scaleFor(75), 80);
      expect(AnalogSpeedGauge.scaleFor(80), 80);
      expect(AnalogSpeedGauge.scaleFor(81), 100);
    });

    test('a fast ride keeps headroom above its own peak', () {
      // The fastest ride in the DB so far.
      final scale = AnalogSpeedGauge.scaleFor(107.5);
      expect(scale, 120);
      expect(scale, greaterThan(107.5));
    });

    test('the scale never shrinks as the peak grows', () {
      var previous = 0.0;
      for (var peak = 0.0; peak <= 200; peak += 3.7) {
        final scale = AnalogSpeedGauge.scaleFor(peak);
        expect(scale, greaterThanOrEqualTo(previous));
        expect(scale, greaterThanOrEqualTo(peak));
        previous = scale;
      }
    });

    test('ticks land on whole numbers — the dial is always a multiple of 20', () {
      for (final peak in [0.0, 33.3, 61.0, 99.9, 140.0, 155.5]) {
        expect(AnalogSpeedGauge.scaleFor(peak) % 20, 0);
      }
    });
  });
}
