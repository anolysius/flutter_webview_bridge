import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';

void main() {
  group('WebViewBridgeController service context facade', () {
    test('top-level web document navigation generation은 단조 증가한다', () {
      final controller = WebViewBridgeController();

      expect(controller.beginWebDocumentNavigation(), 1);
      expect(controller.beginWebDocumentNavigation(), 2);
      expect(controller.beginWebDocumentNavigation(), 3);
    });

    test(
      'legacy country update rewrites the stored API realm before validation',
      () {
        final controller = WebViewBridgeController();
        controller.updateServiceContext(
          serviceCountry: 'KR',
          apiBaseUrl: 'https://qa.api.sazo.kr',
        );

        expect(
          () => controller.updateServiceCountry('GLOBAL'),
          returnsNormally,
        );
        expect(controller.debugServiceCountry, 'GLOBAL');
        expect(controller.debugApiBaseUrl, 'https://qa.api.sazoshop.com');

        expect(() => controller.updateServiceCountry('KR'), returnsNormally);
        expect(controller.debugServiceCountry, 'KR');
        expect(controller.debugApiBaseUrl, 'https://qa.api.sazo.kr');
      },
    );

    test(
      'invalid direct country/API pair is rejected without corrupting facade state',
      () {
        final controller = WebViewBridgeController();
        controller.updateServiceContext(
          serviceCountry: 'KR',
          apiBaseUrl: 'https://api.sazo.kr',
        );

        expect(
          () => controller.updateServiceContext(
            serviceCountry: 'GLOBAL',
            apiBaseUrl: 'https://api.sazo.kr',
          ),
          throwsArgumentError,
        );
        expect(controller.debugServiceCountry, 'KR');
        expect(controller.debugApiBaseUrl, 'https://api.sazo.kr');
      },
    );
  });
}
