import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_protocol_negotiation.dart';

void main() {
  test('old web v2 request remains v2', () {
    expect(
      negotiateAuthProtocolVersion(const {'protocolVersion': 2}),
      legacyAuthProtocolVersion,
    );
  });

  test('v2 offer with complete capabilities negotiates v3', () {
    expect(
      negotiateAuthProtocolVersion(const {
        'protocolVersion': 2,
        'maxProtocolVersion': 3,
        'authCapabilities': [
          'softConvergenceDeadline',
          'onboardingHandoff',
          'reauthRequiredCommit',
        ],
      }),
      currentAuthProtocolVersion,
    );
  });

  test('missing one capability safely falls back to v2', () {
    expect(
      negotiateAuthProtocolVersion(const {
        'protocolVersion': 2,
        'maxProtocolVersion': 3,
        'authCapabilities': ['softConvergenceDeadline', 'onboardingHandoff'],
      }),
      legacyAuthProtocolVersion,
    );
  });

  test('legacy v1 producer remains v1', () {
    expect(negotiateAuthProtocolVersion(const {'protocolVersion': 1}), 1);
  });
}
