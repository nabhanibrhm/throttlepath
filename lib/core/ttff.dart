/// How long a GPS lock usually takes on this phone.
///
/// The acquiring screen can say "12s" on its own, but a rider has no idea
/// whether 12s is nearly there or already wrong. A figure measured on their own
/// phone, in their own usual starting spots, is the only honest reference — a
/// number baked into the app would be a guess about someone else's hardware.
library;

import 'dart:math' as math;

/// Samples kept, oldest dropped first. Ten is enough to shrug off one bad cold
/// start in an underground car park, and short enough that moving somewhere with
/// a different sky corrects the figure within a week of riding.
const int kTtffSampleWindow = 10;

/// Below this the median is one or two rides' luck rather than a habit, and a
/// confident "usually about 4s" is worse than showing nothing.
const int kMinTtffSamples = 3;

/// Bounds on what counts as a time-to-first-fix. Zero and negatives are nonsense
/// from the platform; past ten minutes we are no longer measuring an acquisition
/// the rider sat through, so it would only poison the median.
const int _minPlausibleMillis = 1;
const int _maxPlausibleMillis = 10 * 60 * 1000;

/// [samples] plus [millis], trimmed to the newest [kTtffSampleWindow].
///
/// Returns the *same list instance* when the reading is implausible, so a caller
/// can skip the write with `identical`.
List<int> withTtffSample(List<int> samples, int millis) {
  if (millis < _minPlausibleMillis || millis > _maxPlausibleMillis) {
    return samples;
  }
  final next = [...samples, millis];
  if (next.length <= kTtffSampleWindow) return next;
  return next.sublist(next.length - kTtffSampleWindow);
}

/// The median of [samples], or null while there are too few to mean anything.
///
/// Median, not mean: one two-minute start under a metal roof would drag an
/// average well past anything the rider is actually going to wait through, and
/// the point of the figure is to set an expectation they can trust.
int? typicalTtffMillis(List<int> samples) {
  if (samples.length < kMinTtffSamples) return null;
  final sorted = [...samples]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return ((sorted[mid - 1] + sorted[mid]) / 2).round();
}

/// `Usually about 18s`, or null when there is not enough history to say.
String? typicalTtffLabel(List<int> samples) {
  final millis = typicalTtffMillis(samples);
  if (millis == null) return null;
  // A warm receiver really can lock inside a second, and "about 0s" reads as a
  // bug rather than as good news.
  final seconds = math.max(1, (millis / 1000).round());
  return 'Usually about ${seconds}s';
}
