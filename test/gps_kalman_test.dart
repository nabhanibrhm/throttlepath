import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:throttlepath/core/gps_kalman.dart';

void main() {
  const metersPerDegLat = 111320.0;

  group('GpsKalmanFilter', () {
    test('is uninitialised until the first fix', () {
      final kf = GpsKalmanFilter();
      expect(kf.isInitialised, isFalse);
      kf.update(lat: 0, lon: 0, accuracyMeters: 5, timeMs: 0);
      expect(kf.isInitialised, isTrue);
    });

    test('first fix seeds position exactly and zero speed', () {
      final kf = GpsKalmanFilter();
      kf.update(lat: -6.2, lon: 106.8, accuracyMeters: 5, timeMs: 0);
      final (lat, lon) = kf.position;
      expect(lat, closeTo(-6.2, 1e-9));
      expect(lon, closeTo(106.8, 1e-9));
      expect(kf.speedKmh, closeTo(0, 1e-9));
    });

    test('a stationary noisy rider reads near-zero speed', () {
      final kf = GpsKalmanFilter();
      final rnd = math.Random(42);
      for (var i = 0; i < 60; i++) {
        // ±4 m of position noise around a fixed point, position-only (no Doppler)
        final dLat = (rnd.nextDouble() - 0.5) * 8 / metersPerDegLat;
        final dLon = (rnd.nextDouble() - 0.5) * 8 / metersPerDegLat;
        kf.update(
          lat: 0 + dLat,
          lon: 0 + dLon,
          accuracyMeters: 5,
          timeMs: i * 1000.0,
        );
      }
      // Jitter must not masquerade as real movement.
      expect(kf.speedKmh, lessThan(5));
    });

    test('constant eastward motion converges to the true speed', () {
      final kf = GpsKalmanFilter();
      const speedMps = 10.0; // 36 km/h due east
      const metersPerDegLon = metersPerDegLat; // at the equator, cos(0) = 1
      for (var i = 0; i < 40; i++) {
        final east = speedMps * i; // metres east after i seconds
        kf.update(
          lat: 0,
          lon: east / metersPerDegLon,
          accuracyMeters: 5,
          timeMs: i * 1000.0,
        );
      }
      // Position-only, so it takes a few fixes to settle; 5% tolerance.
      expect(kf.speedKmh, closeTo(36, 36 * 0.05));
      final (lat, _) = kf.position;
      expect(lat, closeTo(0, 1e-4)); // no northward drift
    });

    test('fusing Doppler velocity locks on faster than position alone', () {
      final withDoppler = GpsKalmanFilter();
      final positionOnly = GpsKalmanFilter();
      const speedMps = 20.0; // 72 km/h due east
      const metersPerDegLon = metersPerDegLat;
      for (var i = 0; i < 6; i++) {
        final lon = (speedMps * i) / metersPerDegLon;
        withDoppler.update(
          lat: 0,
          lon: lon,
          accuracyMeters: 5,
          timeMs: i * 1000.0,
          speed: speedMps,
          speedAccuracy: 1,
          headingDegrees: 90, // due east
        );
        positionOnly.update(
          lat: 0,
          lon: lon,
          accuracyMeters: 5,
          timeMs: i * 1000.0,
        );
      }
      // With Doppler the velocity state should be much closer to truth early on.
      final dopplerErr = (withDoppler.speedKmh - 72).abs();
      final posErr = (positionOnly.speedKmh - 72).abs();
      expect(dopplerErr, lessThan(posErr));
      expect(withDoppler.speedKmh, closeTo(72, 72 * 0.1));
    });

    test('reset() forces a fresh re-seed', () {
      final kf = GpsKalmanFilter();
      kf.update(lat: 1, lon: 1, accuracyMeters: 5, timeMs: 0);
      kf.reset();
      expect(kf.isInitialised, isFalse);
      kf.update(lat: 2, lon: 2, accuracyMeters: 5, timeMs: 1000);
      final (lat, lon) = kf.position;
      expect(lat, closeTo(2, 1e-9));
      expect(lon, closeTo(2, 1e-9));
    });

    group('smoothed heading', () {
      // Read off the filter's own velocity vector, which is what makes the live
      // lean estimate on the Record screen viable — differencing raw positions is
      // far too noisy to point a needle at.

      /// Feeds a straight run on [bearing] at [speedMps] and returns the filter.
      GpsKalmanFilter runStraight(double bearing, {double speedMps = 20}) {
        final kf = GpsKalmanFilter();
        final rad = bearing * math.pi / 180.0;
        final metersPerDegLon = metersPerDegLat * math.cos(0.0);
        for (var i = 0; i < 40; i++) {
          final north = math.cos(rad) * speedMps * i;
          final east = math.sin(rad) * speedMps * i;
          kf.update(
            lat: north / metersPerDegLat,
            lon: east / metersPerDegLon,
            accuracyMeters: 5,
            timeMs: i * 1000.0,
            speed: speedMps,
            speedAccuracy: 0.5,
            headingDegrees: bearing,
          );
        }
        return kf;
      }

      test('reports the course being travelled', () {
        for (final bearing in [0.0, 45.0, 90.0, 180.0, 270.0]) {
          final got = runStraight(bearing).headingDegrees;
          // Compare as a circular difference so 359.9 vs 0 is not a 360 error.
          var diff = (got - bearing).abs() % 360.0;
          if (diff > 180) diff = 360 - diff;
          expect(diff, lessThan(3.0), reason: 'bearing $bearing read as $got');
        }
      });

      test('always reports a positive bearing, never a negative one', () {
        // atan2 returns (-pi, pi]; a course of 270 must read 270, not -90, or the
        // wraparound maths downstream would see a phantom half-turn.
        expect(runStraight(270).headingDegrees, greaterThanOrEqualTo(0));
        expect(runStraight(270).headingDegrees, lessThan(360));
      });

      test('is safe to read before any fix', () {
        expect(GpsKalmanFilter().headingDegrees, isNotNaN);
      });
    });
  });
}
