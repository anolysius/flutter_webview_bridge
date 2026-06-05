import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/service_country.dart';

/// APP-300 R5 — serviceCountry 브릿지 이벤트.
void main() {
  group('queryResponse', () {
    test('주입된 country 응답', () {
      final r = ServiceCountryEvent().queryResponse('GLOBAL');
      expect(r['type'], 'SERVICE_COUNTRY_QUERY');
      expect((r['data'] as Map)['serviceCountry'], 'GLOBAL');
    });
    test('null → KR 기본값', () {
      final r = ServiceCountryEvent().queryResponse(null);
      expect((r['data'] as Map)['serviceCountry'], 'KR');
    });
  });

  group('parseRequestedCountry', () {
    final e = ServiceCountryEvent();
    test('Map {serviceCountry}', () {
      expect(e.parseRequestedCountry({'serviceCountry': 'GLOBAL'}), 'GLOBAL');
    });
    test('Map {country} alias', () {
      expect(e.parseRequestedCountry({'country': 'kr'}), 'KR');
    });
    test('String', () {
      expect(e.parseRequestedCountry('global'), 'GLOBAL');
    });
    test('빈/미인식 → null', () {
      expect(e.parseRequestedCountry(''), isNull);
      expect(e.parseRequestedCountry({}), isNull);
      expect(e.parseRequestedCountry(null), isNull);
    });
  });
}
