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

  test('new optional capability is not required for existing v3 web', () {
    const existingWeb = {
      'protocolVersion': 2,
      'maxProtocolVersion': 3,
      'authCapabilities': [
        'softConvergenceDeadline',
        'onboardingHandoff',
        'reauthRequiredCommit',
      ],
    };

    expect(
      negotiateAuthProtocolVersion(existingWeb),
      currentAuthProtocolVersion,
    );
    expect(
      negotiateAuthProtocolCapabilities(existingWeb),
      requiredAuthProtocolV3Capabilities,
    );
    expect(supportsCriticalAuthDeliveryAck(existingWeb), isFalse);
  });

  test('critical delivery ACK is selected only when web offers it', () {
    const newWeb = {
      'protocolVersion': 2,
      'maxProtocolVersion': 3,
      'authCapabilities': [
        'softConvergenceDeadline',
        'onboardingHandoff',
        'reauthRequiredCommit',
        'criticalAuthDeliveryAck',
      ],
    };

    expect(
      negotiateAuthProtocolCapabilities(newWeb),
      authProtocolV3Capabilities,
    );
    expect(supportsCriticalAuthDeliveryAck(newWeb), isTrue);
    expect(authProtocolCapabilityResponse(newWeb), {
      'authProtocolVersion': 3,
      'authCapabilities': authProtocolV3Capabilities.toList(growable: false),
    });
  });

  test('legacy DEVICE_INFO without auth offer gets no additive response', () {
    expect(
      authProtocolCapabilityResponse(const {'authContextProtocolVersion': 1}),
      isEmpty,
    );
  });

  test('legacy v1 producer remains v1', () {
    expect(negotiateAuthProtocolVersion(const {'protocolVersion': 1}), 1);
  });
}
