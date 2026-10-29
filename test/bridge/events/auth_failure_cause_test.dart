import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_failure_cause.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

final _format = RegExp(r'^[A-Z][A-Z0-9_]{0,63}$');

/// 카카오 SDK 가 던질 수 있는 예외를 enum 전수로 만든다 (raw message 는 버려져야 한다).
List<Object> _allKakaoErrors() => [
  for (final c in ClientErrorCause.values)
    KakaoClientException(c, 'private provider text'),
  for (final c in AuthErrorCause.values)
    KakaoAuthException(c, 'private provider text'),
  for (final c in ApiErrorCause.values)
    KakaoApiException(c, 'private provider text'),
  for (final c in AppsErrorCause.values)
    KakaoAppsException(c, 'private provider text'),
  for (final n in [1, 2, 3])
    PlatformException(
      code: 'CANCELED',
      message: 'User canceled login.',
      details:
          '작업을 완료할 수 없습니다.(com.apple.AuthenticationServices.WebAuthenticationSession 오류 $n.)',
    ),
  PlatformException(code: 'CANCELED', details: 'no domain here'),
  PlatformException(code: 'OPEN_URL_ERROR'),
  PlatformException(code: 'REDIRECT_URL_MISMATCH'),
  PlatformException(code: 'EUNKNOWN'),
  const SocketException('no route'),
  TimeoutException('timeout'),
  StateError('KAKAO_ID_TOKEN_MISSING'),
];

void main() {
  group('kakaoFailureCause — 1코드=1원인', () {
    test('서로 다른 (예외, enum, 단계) 입력은 서로 다른 코드가 된다 (enum 전수)', () {
      final errors = _allKakaoErrors();
      final seen = <String, String>{};
      for (final step in KakaoAuthStep.values) {
        for (final e in errors) {
          final cause = kakaoFailureCause(step, e);
          final input = '${step.name}/${e.runtimeType}/$e';
          expect(
            seen.containsKey(cause),
            isFalse,
            reason: '$cause 가 ${seen[cause]} 와 $input 에 중복',
          );
          seen[cause] = input;
        }
      }
      expect(seen.length, KakaoAuthStep.values.length * errors.length);
    });

    test('모든 코드는 64자 이하·대문자 형식이고 raw message 를 담지 않는다', () {
      for (final step in KakaoAuthStep.values) {
        for (final e in _allKakaoErrors()) {
          final cause = kakaoFailureCause(step, e);
          expect(cause, matches(_format), reason: cause);
          expect(cause, isNot(contains('PRIVATE')));
        }
      }
    });

    test('같은 이름의 enum 도 예외 클래스 접두사로 구분된다', () {
      final auth = kakaoFailureCause(
        KakaoAuthStep.talk,
        KakaoAuthException(AuthErrorCause.accessDenied, 'x'),
      );
      final api = kakaoFailureCause(
        KakaoAuthStep.talk,
        KakaoApiException(ApiErrorCause.accessDenied, 'x'),
      );
      expect(auth, 'KAKAO_TALK_AUTH_ACCESS_DENIED');
      expect(api, 'KAKAO_TALK_API_ACCESS_DENIED');
    });

    test('이번 장애의 세 원인은 각각 다른 코드다', () {
      PlatformException webAuth(int n) => PlatformException(
        code: 'CANCELED',
        details:
            'The operation couldn’t be completed. (com.apple.AuthenticationServices.WebAuthenticationSession error $n.)',
      );
      final causes = {
        kakaoFailureCause(KakaoAuthStep.account, webAuth(1)),
        kakaoFailureCause(KakaoAuthStep.fallback, webAuth(2)),
        kakaoFailureCause(KakaoAuthStep.fallback, webAuth(3)),
        kakaoFailureCause(
          KakaoAuthStep.talk,
          KakaoClientException(ClientErrorCause.cancelled, 'x'),
        ),
        kakaoFailureCause(
          KakaoAuthStep.talk,
          KakaoAuthException(AuthErrorCause.accessDenied, 'x'),
        ),
      };
      expect(causes, {
        'KAKAO_ACCOUNT_WEBAUTH_1',
        'KAKAO_FALLBACK_WEBAUTH_2',
        'KAKAO_FALLBACK_WEBAUTH_3',
        'KAKAO_TALK_CLIENT_CANCELLED',
        'KAKAO_TALK_AUTH_ACCESS_DENIED',
      });
    });

    test('네트워크·id token 누락·미분류 예외도 단계별로 구분된다', () {
      expect(
        kakaoFailureCause(
          KakaoAuthStep.talk,
          const SocketException('no route'),
        ),
        'KAKAO_TALK_NETWORK_SOCKET',
      );
      expect(
        kakaoFailureCause(KakaoAuthStep.account, TimeoutException('t')),
        'KAKAO_ACCOUNT_NETWORK_TIMEOUT',
      );
      expect(
        kakaoFailureCause(
          KakaoAuthStep.idToken,
          StateError('KAKAO_ID_TOKEN_MISSING'),
        ),
        'KAKAO_IDTOKEN_MISSING',
      );
      expect(
        kakaoFailureCause(KakaoAuthStep.scopes, const FormatException('x')),
        'KAKAO_SCOPES_UNEXPECTED_FORMAT_EXCEPTION',
      );
    });
  });

  group('parseWebAuthSessionErrorCode', () {
    test('로케일에 상관없이 도메인명 뒤 첫 숫자를 읽는다 (Step 0 실측 원문)', () {
      expect(
        parseWebAuthSessionErrorCode(
          '작업을 완료할 수 없습니다.(com.apple.AuthenticationServices.WebAuthenticationSession 오류 1.)',
        ),
        1,
      );
      expect(
        parseWebAuthSessionErrorCode(
          'The operation couldn’t be completed. (com.apple.AuthenticationServices.WebAuthenticationSession error 3.)',
        ),
        3,
      );
    });

    test('도메인이 없거나 문자열이 아니면 null', () {
      expect(parseWebAuthSessionErrorCode('User canceled'), isNull);
      expect(parseWebAuthSessionErrorCode(null), isNull);
      expect(parseWebAuthSessionErrorCode(42), isNull);
    });

    test('도메인은 있지만 숫자가 없으면 UNPARSED 코드', () {
      expect(
        kakaoFailureCause(
          KakaoAuthStep.account,
          PlatformException(
            code: 'CANCELED',
            details:
                'com.apple.AuthenticationServices.WebAuthenticationSession',
          ),
        ),
        'KAKAO_ACCOUNT_WEBAUTH_UNPARSED',
      );
    });
  });

  group('googleFailureCause / appleFailureCause', () {
    test('구글 enum 전수가 서로 다른 코드가 된다', () {
      final causes = {
        for (final c in GoogleSignInExceptionCode.values)
          googleFailureCause(GoogleSignInException(code: c)),
      };
      expect(causes.length, GoogleSignInExceptionCode.values.length);
      expect(
        googleFailureCause(
          const GoogleSignInException(code: GoogleSignInExceptionCode.canceled),
        ),
        'GOOGLE_SIGN_IN_CANCELED',
      );
      for (final c in causes) {
        expect(c, matches(_format));
      }
    });

    test('애플 enum 전수가 서로 다른 코드가 된다', () {
      final causes = {
        for (final c in AuthorizationErrorCode.values)
          appleFailureCause(
            SignInWithAppleAuthorizationException(code: c, message: 'x'),
          ),
      };
      expect(causes.length, AuthorizationErrorCode.values.length);
      expect(
        appleFailureCause(
          const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.matchedExcludedCredential,
            message: 'x',
          ),
        ),
        'APPLE_AUTHORIZE_MATCHED_EXCLUDED_CREDENTIAL',
      );
    });

    test('SDK 예외가 아닌 실패도 공급자별로 구분된다', () {
      expect(
        googleFailureCause(TimeoutException('t')),
        'GOOGLE_SIGN_IN_NETWORK_TIMEOUT',
      );
      expect(
        appleFailureCause(const SocketException('x')),
        'APPLE_AUTHORIZE_NETWORK_SOCKET',
      );
      expect(
        googleFailureCause(Exception('x')),
        'GOOGLE_SIGN_IN_UNEXPECTED_EXCEPTION',
      );
    });
  });

  group('resultCodeForFailureCause — KPI 분류 표', () {
    test('사람의 행동으로만 생기는 원인만 user_cancelled', () {
      for (final cause in [
        'KAKAO_ACCOUNT_WEBAUTH_1',
        'KAKAO_FALLBACK_WEBAUTH_1',
        'KAKAO_TALK_AUTH_ACCESS_DENIED',
        'KAKAO_TALK_CLIENT_CANCELLED',
        'KAKAO_TALK_PLATFORM_CANCELED',
        'GOOGLE_SIGN_IN_CANCELED',
        'APPLE_AUTHORIZE_CANCELED',
      ]) {
        expect(
          resultCodeForFailureCause(cause),
          'user_cancelled',
          reason: cause,
        );
      }
    });

    test('창을 못 띄운 실패는 취소가 아니라 code_failure', () {
      expect(
        resultCodeForFailureCause('KAKAO_FALLBACK_WEBAUTH_3'),
        'code_failure:native_auth_error',
      );
      expect(
        resultCodeForFailureCause('KAKAO_ACCOUNT_WEBAUTH_2'),
        'code_failure:native_auth_error',
      );
    });

    test('판별 불가 취소는 별도 버킷', () {
      expect(
        resultCodeForFailureCause('KAKAO_ACCOUNT_WEBAUTH_UNPARSED'),
        'code_failure:unclassified_cancel',
      );
    });

    test('네트워크와 공급자 서버 오류는 외부 실패', () {
      for (final cause in [
        'KAKAO_TALK_NETWORK_SOCKET',
        'GOOGLE_SIGN_IN_NETWORK_TIMEOUT',
        'KAKAO_TALK_AUTH_SERVER_ERROR',
        'KAKAO_SCOPES_API_INTERNAL_ERROR',
        'KAKAO_SCOPES_API_SERVER_TIME_OUT',
        'KAKAO_SCOPES_API_UNDER_MAINTENANCE',
        'KAKAO_TALK_APPS_INTERNAL_SERVER_ERROR',
      ]) {
        expect(
          resultCodeForFailureCause(cause),
          'excluded_external_failure',
          reason: cause,
        );
      }
    });

    test('표에 없는 코드는 code_failure 로 떨어진다', () {
      for (final cause in [
        'KAKAO_TALK_PLATFORM_OPEN_URL_ERROR',
        'KAKAO_TALK_AUTH_MISCONFIGURED',
        'APPLE_AUTHORIZE_NOT_HANDLED',
        'GOOGLE_SIGN_IN_INTERRUPTED',
        'SOMETHING_NEW',
      ]) {
        expect(
          resultCodeForFailureCause(cause),
          'code_failure:native_auth_error',
          reason: cause,
        );
      }
    });
  });
}
