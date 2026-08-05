import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/ttff.dart';

void main() {
  group('withTtffSample', () {
    test('appends newest last', () {
      expect(withTtffSample(const [1000, 2000], 3000), [1000, 2000, 3000]);
    });

    test('drops the oldest once the window is full', () {
      final full = List.generate(kTtffSampleWindow, (i) => (i + 1) * 1000);
      final next = withTtffSample(full, 99_000);

      expect(next.length, kTtffSampleWindow);
      expect(next.first, 2000, reason: 'the 1000ms sample aged out');
      expect(next.last, 99_000);
    });

    test('rejects implausible readings by identity, so no write follows', () {
      const samples = [12_000, 18_000];
      // The controller skips persisting when the list comes back unchanged, and
      // it checks that with `identical` — equality would not distinguish a
      // rejected sample from a coincidentally equal list.
      expect(identical(withTtffSample(samples, 0), samples), isTrue);
      expect(identical(withTtffSample(samples, -1), samples), isTrue);
      expect(
        identical(withTtffSample(samples, 10 * 60 * 1000 + 1), samples),
        isTrue,
      );
      expect(identical(withTtffSample(samples, 1), samples), isFalse);
      expect(
        identical(withTtffSample(samples, 10 * 60 * 1000), samples),
        isFalse,
      );
    });
  });

  group('typicalTtffMillis', () {
    test('withholds a figure below the sample floor', () {
      expect(typicalTtffMillis(const []), isNull);
      for (var n = 1; n < kMinTtffSamples; n++) {
        expect(typicalTtffMillis(List.filled(n, 12_000)), isNull);
      }
      expect(typicalTtffMillis(List.filled(kMinTtffSamples, 12_000)), 12_000);
    });

    test('is a median, so one dreadful cold start does not set the tone', () {
      expect(typicalTtffMillis(const [12_000, 90_000, 18_000]), 18_000);
      // The mean here is 40s — twice what the rider actually waits for.
      expect(typicalTtffMillis(const [12_000, 90_000, 18_000]),
          lessThan(40_000));
    });

    test('averages the middle pair on an even count', () {
      expect(typicalTtffMillis(const [10_000, 20_000, 30_000, 41_000]), 25_000);
    });

    test('does not disturb the caller\'s list', () {
      final samples = [30_000, 10_000, 20_000];
      typicalTtffMillis(samples);
      expect(samples, [30_000, 10_000, 20_000]);
    });
  });

  group('typicalTtffLabel', () {
    test('rounds to whole seconds', () {
      expect(typicalTtffLabel(List.filled(3, 18_400)), 'Usually about 18s');
      expect(typicalTtffLabel(List.filled(3, 18_600)), 'Usually about 19s');
    });

    test('a sub-second lock reads as 1s, never "about 0s"', () {
      expect(typicalTtffLabel(List.filled(3, 300)), 'Usually about 1s');
    });

    test('is null while there is nothing to claim', () {
      expect(typicalTtffLabel(const []), isNull);
      expect(typicalTtffLabel(const [18_000]), isNull);
    });
  });
}
