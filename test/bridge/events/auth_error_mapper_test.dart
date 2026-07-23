import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error_mapper.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
  test('AuthError keeps only the explicit normalized native SDK code', () {
    const error = AuthError(
      AuthErrorCode.providerError,
      'raw provider message',
      nativeSdkErrorCode: 'KAKAO_PROVIDER_ERROR',
    );
    expect(error.nativeSdkErrorCode, 'KAKAO_PROVIDER_ERROR');
  });

  group('mapKakaoError', () {
    test('PlatformException CANCELED → USER_CANCELLED', () {
      final e = PlatformException(code: 'CANCELED');
      expect(mapKakaoError(e), AuthErrorCode.userCancelled);
    });

    test('KakaoClientException(cancelled) → USER_CANCELLED', () {
      final e = KakaoClientException(ClientErrorCause.cancelled, 'user x');
      expect(mapKakaoError(e), AuthErrorCode.userCancelled);
    });

    test('KakaoClientException(notSupported) → SDK_INIT_FAILED', () {
      final e = KakaoClientException(ClientErrorCause.notSupported, 'no app');
      expect(mapKakaoError(e), AuthErrorCode.sdkInitFailed);
    });

    test('KakaoAuthException(accessDenied) → USER_CANCELLED', () {
      final e = KakaoAuthException(AuthErrorCause.accessDenied, 'user denied');
      expect(mapKakaoError(e), AuthErrorCode.userCancelled);
    });

    test('KakaoAuthException(misconfigured) → SDK_INIT_FAILED', () {
      final e = KakaoAuthException(AuthErrorCause.misconfigured, 'bad config');
      expect(mapKakaoError(e), AuthErrorCode.sdkInitFailed);
    });

    test('KakaoAuthException(serverError) → PROVIDER_ERROR', () {
      final e = KakaoAuthException(AuthErrorCause.serverError, '5xx');
      expect(mapKakaoError(e), AuthErrorCode.providerError);
    });

    test('모든 Kakao auth enum은 allowlisted safe cause로만 축약된다', () {
      const allowed = {
        'user_cancelled',
        'invalid_client',
        'misconfigured',
        'provider_error',
      };
      for (final cause in AuthErrorCause.values) {
        final mapped = mapKakaoSafeCause(
          KakaoAuthException(cause, 'private provider text'),
        );
        expect(allowed, contains(mapped), reason: cause.name);
        expect(mapped, isNot(contains('private')));
      }
    });

    test('SocketException → NETWORK_ERROR', () {
      expect(
        mapKakaoError(const SocketException('no route')),
        AuthErrorCode.networkError,
      );
    });

    test('generic Exception → UNKNOWN', () {
      expect(mapKakaoError(Exception('???')), AuthErrorCode.unknown);
    });

    test('명시적 id token 누락은 INVALID_RESPONSE + safe cause로 보존한다', () {
      final error = StateError('KAKAO_ID_TOKEN_MISSING');
      expect(mapKakaoError(error), AuthErrorCode.invalidResponse);
      expect(mapKakaoSafeCause(error), 'id_token_missing');
    });

    test('Kakao client reason을 raw message 없이 allowlisted cause로 구분한다', () {
      const expected = {
        ClientErrorCause.cancelled: 'user_cancelled',
        ClientErrorCause.notSupported: 'unsupported',
        ClientErrorCause.tokenNotFound: 'token_not_found',
        ClientErrorCause.badParameter: 'bad_parameter',
        ClientErrorCause.illegalState: 'illegal_state',
        ClientErrorCause.unknown: 'unknown',
      };
      expect(expected.keys.toSet(), ClientErrorCause.values.toSet());
      for (final entry in expected.entries) {
        expect(
          mapKakaoSafeCause(
            KakaoClientException(entry.key, 'private provider text'),
          ),
          entry.value,
        );
      }
    });

    test('allowlisted native code만 safe cause로 복원한다', () {
      expect(
        safeNativeSdkCauseFromCode('KAKAO_ID_TOKEN_MISSING'),
        'id_token_missing',
      );
      expect(
        safeNativeSdkCauseFromCode('KAKAO_PRIVATE_PROVIDER_TEXT'),
        isNull,
      );
      expect(safeNativeSdkCauseFromCode('GOOGLE_UNKNOWN'), isNull);
    });
  });

  group('mapGoogleError', () {
    test('GoogleSignInException(canceled) → USER_CANCELLED', () {
      const e = GoogleSignInException(code: GoogleSignInExceptionCode.canceled);
      expect(mapGoogleError(e), AuthErrorCode.userCancelled);
    });

    test(
      'GoogleSignInException(clientConfigurationError) → SDK_INIT_FAILED',
      () {
        const e = GoogleSignInException(
          code: GoogleSignInExceptionCode.clientConfigurationError,
        );
        expect(mapGoogleError(e), AuthErrorCode.sdkInitFailed);
      },
    );

    test('GoogleSignInException(unknownError) → PROVIDER_ERROR', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.unknownError,
      );
      expect(mapGoogleError(e), AuthErrorCode.providerError);
    });

    test('GoogleSignInException(interrupted) → UNKNOWN', () {
      const e = GoogleSignInException(
        code: GoogleSignInExceptionCode.interrupted,
      );
      expect(mapGoogleError(e), AuthErrorCode.unknown);
    });

    test('TimeoutException → NETWORK_ERROR', () {
      expect(
        mapGoogleError(TimeoutException('timeout')),
        AuthErrorCode.networkError,
      );
    });

    test('generic Exception → UNKNOWN', () {
      expect(mapGoogleError(Exception('???')), AuthErrorCode.unknown);
    });
  });

  group('mapAppleError', () {
    test(
      'SignInWithAppleAuthorizationException(canceled) → USER_CANCELLED',
      () {
        const e = SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.canceled,
          message: 'user x',
        );
        expect(mapAppleError(e), AuthErrorCode.userCancelled);
      },
    );

    test(
      'SignInWithAppleAuthorizationException(invalidResponse) → INVALID_RESPONSE',
      () {
        const e = SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.invalidResponse,
          message: 'bad',
        );
        expect(mapAppleError(e), AuthErrorCode.invalidResponse);
      },
    );

    test('SignInWithAppleAuthorizationException(failed) → PROVIDER_ERROR', () {
      const e = SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.failed,
        message: 'apple error',
      );
      expect(mapAppleError(e), AuthErrorCode.providerError);
    });

    test(
      'SignInWithAppleAuthorizationException(notHandled) → SDK_INIT_FAILED',
      () {
        const e = SignInWithAppleAuthorizationException(
          code: AuthorizationErrorCode.notHandled,
          message: 'not handled',
        );
        expect(mapAppleError(e), AuthErrorCode.sdkInitFailed);
      },
    );

    test('SignInWithAppleAuthorizationException(unknown) → UNKNOWN', () {
      const e = SignInWithAppleAuthorizationException(
        code: AuthorizationErrorCode.unknown,
        message: 'unknown',
      );
      expect(mapAppleError(e), AuthErrorCode.unknown);
    });

    test('SocketException → NETWORK_ERROR', () {
      expect(
        mapAppleError(const SocketException('no route')),
        AuthErrorCode.networkError,
      );
    });

    test('generic Exception → UNKNOWN', () {
      expect(mapAppleError(Exception('???')), AuthErrorCode.unknown);
    });
  });
}
