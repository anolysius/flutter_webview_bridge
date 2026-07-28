import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/kakao_token_policy.dart';

void main() {
  group('kakaoConsentScopesWithOpenId', () {
    test('추가 동의가 없으면 새 로그인 요청을 만들지 않는다', () {
      expect(kakaoConsentScopesWithOpenId(const []), isEmpty);
    });

    test('추가 동의 요청에 openid를 한 번만 포함한다', () {
      expect(
        kakaoConsentScopesWithOpenId(const ['account_email', 'profile']),
        const ['account_email', 'profile', 'openid'],
      );
      expect(
        kakaoConsentScopesWithOpenId(const ['account_email', 'openid']),
        const ['account_email', 'openid'],
      );
    });
  });

  group('selectKakaoIdToken', () {
    test('새 ID token이 있으면 최신 token을 사용한다', () {
      expect(
        selectKakaoIdToken(current: 'initial', reissued: 'reissued'),
        'reissued',
      );
    });

    test('새 ID token이 비어도 기존 정상 token을 보존한다', () {
      expect(selectKakaoIdToken(current: 'initial', reissued: null), 'initial');
      expect(selectKakaoIdToken(current: 'initial', reissued: ''), 'initial');
    });

    test('어느 응답에도 ID token이 없으면 null을 유지한다', () {
      expect(selectKakaoIdToken(current: null, reissued: null), isNull);
    });
  });
}
