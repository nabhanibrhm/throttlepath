import 'package:geocoding/geocoding.dart';

/// Best-effort reverse geocoding for ride start/end place names.
///
/// Online-only (the platform Geocoder needs network). Every failure — offline,
/// no result, platform error, or timeout — resolves to `null`, so callers
/// persist a place name when one is available and simply omit it otherwise. The
/// app stays offline-first: place names are a nicety, never a requirement.
class GeocodingService {
  const GeocodingService._();

  /// Cap each lookup so a slow/unreachable geocoder can't hang the caller.
  static const Duration _timeout = Duration(seconds: 8);

  /// How many times to try a single lookup. Android's platform `Geocoder` is
  /// rate-limited and often fails a call that's fired right after another
  /// ("Service not Available" / empty result), which is exactly what left rides
  /// with only one of the two place names. A couple of backed-off retries ride
  /// that out.
  static const int _maxAttempts = 3;

  /// Base delay between retries (grows linearly per attempt).
  static const Duration _retryBackoff = Duration(milliseconds: 400);

  /// Reverse-geocodes [lat]/[lon] to a short, human place label (e.g.
  /// "Jatiasih, Bekasi"), or `null` if it can't be resolved. Retries transient
  /// failures (rate-limit / timeout / empty) with backoff; a resolved placemark
  /// that simply has no useful field returns `null` without retrying.
  static Future<String?> placeName(double lat, double lon) async {
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      if (attempt > 0) await Future.delayed(_retryBackoff * attempt);
      try {
        final placemarks =
            await placemarkFromCoordinates(lat, lon).timeout(_timeout);
        if (placemarks.isEmpty) continue; // often a transient rate-limit — retry
        return _label(placemarks.first);
      } catch (_) {
        // offline / no service / rate-limited / timeout — retry, then give up.
      }
    }
    return null; // best-effort: never a hard requirement.
  }

  /// Builds a "subdistrict, city" label (e.g. "Jatiasih, Bekasi" /
  /// "Menteng, Jakarta Pusat").
  ///
  /// Android's Geocoder maps Indonesian addresses like so (verified on-device):
  /// `subLocality` = kelurahan/desa (too granular — skipped), `locality` =
  /// kecamatan (the subdistrict we want), `subAdministrativeArea` = kota/
  /// kabupaten (the city), `administrativeArea` = province. Each field may carry
  /// an admin-type prefix ("Kota Bekasi", "Kecamatan Jatiasih") which we strip
  /// down to the bare name.
  ///
  /// Falls back gracefully: if only one level resolves, that one is returned;
  /// duplicate parts collapse to a single name; a placemark with no useful field
  /// returns `null`.
  static String? _label(Placemark p) {
    final subdistrict = _clean(_firstNonBlank([p.locality, p.subLocality]));
    final city = _clean(_firstNonBlank([p.subAdministrativeArea]));

    if (subdistrict != null && city != null && subdistrict != city) {
      return '$subdistrict, $city';
    }
    // Only one level (or they're identical) — prefer the city, then subdistrict,
    // then province as an absolute last resort.
    return city ?? subdistrict ?? _clean(_firstNonBlank([p.administrativeArea]));
  }

  /// Leading Indonesian administrative-type words to drop, so a field like
  /// "Kota Bekasi" / "Kabupaten Bekasi" / "Kecamatan Jatiasih" becomes just the
  /// place name. Longest/most-specific first so "Kota Administrasi …" wins over
  /// a bare "Kota".
  static final RegExp _adminPrefix = RegExp(
    r'^(kota administrasi|kabupaten|kota|kecamatan|kelurahan|desa|provinsi|'
    r'kab\.|kec\.|kel\.)\s+',
    caseSensitive: false,
  );

  /// Strips the admin-type prefix from [name] and trims it; returns `null` if
  /// nothing meaningful is left.
  static String? _clean(String? name) {
    if (name == null) return null;
    final v = name.replaceFirst(_adminPrefix, '').trim();
    return v.isEmpty ? null : v;
  }

  /// First trimmed, non-empty value in [candidates] (the platform leaves unknown
  /// fields as empty strings rather than null), or `null` if none qualify.
  static String? _firstNonBlank(List<String?> candidates) {
    for (final candidate in candidates) {
      final v = candidate?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}
