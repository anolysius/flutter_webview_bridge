import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error_mapper.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
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

    test('generic Exception → UNKNOWN', () {
      expect(mapKakaoError(Exception('???')), AuthErrorCode.unknown);
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

    test('generic Exception → UNKNOWN', () {
      expect(mapAppleError(Exception('???')), AuthErrorCode.unknown);
    });
  });
}
