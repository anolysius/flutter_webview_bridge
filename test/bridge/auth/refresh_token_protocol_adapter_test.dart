import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/refresh_token_protocol_adapter.dart';

void main() {
  test('v3 storage request만 v2 adapter를 거쳐 correlation을 보존한다', () {
    final original = <String, Object?>{
      'protocolVersion': 3,
      'requestId': 'request-1',
      'authSessionId': 'attempt-1',
    };

    expect(adaptRefreshTokenRequestForStorage(original), {
      ...original,
      'protocolVersion': 2,
    });
    expect(original['protocolVersion'], 3);
  });

  test('v3 response protocol만 복원하고 v2/legacy shape은 그대로 둔다', () {
    final response = <String, Object?>{
      'type': 'REFRESH_TOKEN_READ',
      'data': <String, Object?>{
        'status': 'found',
        'protocolVersion': 2,
        'requestId': 'request-1',
      },
    };

    expect(
      restoreRefreshTokenResponseProtocol(response, {
        'protocolVersion': 3,
      })['data'],
      {
        'status': 'found',
        'protocolVersion': 3,
        'requestId': 'request-1',
      },
    );
    expect(
      identical(
        restoreRefreshTokenResponseProtocol(response, {
          'protocolVersion': 2,
        }),
        response,
      ),
      isTrue,
    );
  });
}
