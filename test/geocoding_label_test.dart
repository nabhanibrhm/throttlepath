import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';
import 'package:throttlepath/services/geocoding_service.dart';

/// How a reverse-geocoded placemark becomes the short "subdistrict, city" label
/// under a ride. The lookup itself needs the platform Geocoder and a network;
/// this formatting does not, so it is the one part of that service a test can
/// hold still.

Placemark place({
  String locality = '',
  String subLocality = '',
  String subAdministrativeArea = '',
  String administrativeArea = '',
}) =>
    Placemark(
      locality: locality,
      subLocality: subLocality,
      subAdministrativeArea: subAdministrativeArea,
      administrativeArea: administrativeArea,
    );

void main() {
  test('subdistrict and city, with the Indonesian prefixes stripped', () {
    expect(
      GeocodingService.labelOf(place(
        locality: 'Kecamatan Jatiasih',
        subAdministrativeArea: 'Kota Bekasi',
      )),
      'Jatiasih, Bekasi',
    );
  });

  test('the English suffix form normalises to the same name as the prefix form',
      () {
    // The bug this pins: the same spot, geocoded twice three metres apart, came
    // back as "Sukabumi Regency" once and "Kabupaten Sukabumi" the other time, so
    // a trip appeared to change city while the rider stood still.
    final suffix = GeocodingService.labelOf(place(
      locality: 'Ciracap',
      subAdministrativeArea: 'Sukabumi Regency',
    ));
    final prefix = GeocodingService.labelOf(place(
      locality: 'Ciracap',
      subAdministrativeArea: 'Kabupaten Sukabumi',
    ));
    expect(suffix, 'Ciracap, Sukabumi');
    expect(suffix, prefix, reason: 'the two spellings must converge');
  });

  test('a doubled-up admin field reduces all the way', () {
    expect(
      GeocodingService.labelOf(place(
        locality: 'Ciemas',
        subAdministrativeArea: 'Kabupaten Sukabumi Regency',
      )),
      'Ciemas, Sukabumi',
    );
  });

  test('"Kota Administrasi" wins over a bare "Kota"', () {
    expect(
      GeocodingService.labelOf(place(
        locality: 'Menteng',
        subAdministrativeArea: 'Kota Administrasi Jakarta Pusat',
      )),
      'Menteng, Jakarta Pusat',
    );
  });

  test('city and subdistrict collapse when they are the same place', () {
    expect(
      GeocodingService.labelOf(place(
        locality: 'Tangerang',
        subAdministrativeArea: 'Kota Tangerang',
      )),
      'Tangerang',
    );
  });

  test('subLocality stands in when there is no locality', () {
    expect(
      GeocodingService.labelOf(place(
        subLocality: 'Sundawenang',
        subAdministrativeArea: 'Kabupaten Sukabumi',
      )),
      'Sundawenang, Sukabumi',
    );
  });

  test('province is the last resort, never the first choice', () {
    expect(
      GeocodingService.labelOf(place(administrativeArea: 'Jawa Barat')),
      'Jawa Barat',
    );
    expect(
      GeocodingService.labelOf(place(
        subAdministrativeArea: 'Kabupaten Sukabumi',
        administrativeArea: 'Jawa Barat',
      )),
      'Sukabumi',
    );
  });

  test('a placemark with nothing usable returns null, not an empty label', () {
    expect(GeocodingService.labelOf(place()), isNull);
    // A field that is *only* an admin word must not survive as an empty string.
    expect(GeocodingService.labelOf(place(subAdministrativeArea: 'Regency')),
        isNull);
  });
}
