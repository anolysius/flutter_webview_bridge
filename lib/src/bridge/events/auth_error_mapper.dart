import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart'
    show GoogleSignInException, GoogleSignInExceptionCode;
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart'
    show
        AuthErrorCause,
        ClientErrorCause,
        KakaoApiException,
        KakaoAppsException,
        KakaoAuthException,
        KakaoClientException;
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show AuthorizationErrorCode, SignInWithAppleAuthorizationException;

/// SDK 내부 IO 실패는 표준 SocketException/TimeoutException 으로 표면화.
/// 3 SDK 공통 fallback — helper 들의 마지막 분기 전에 호출.
bool _isNetworkError(Object e) => e is SocketException || e is TimeoutException;

/// AUTH_ERROR contract 의 표준 code 상수.
/// webview 측 Sentry 그룹화 / dedup 의 SOT.
class AuthErrorCode {
  static const userCancelled = 'USER_CANCELLED';
  static const networkError = 'NETWORK_ERROR';
  static const sdkInitFailed = 'SDK_INIT_FAILED';
  static const invalidResponse = 'INVALID_RESPONSE';
  static const providerError = 'PROVIDER_ERROR';
  static const unknown = 'UNKNOWN';
}

/// Kakao SDK raw exception → AUTH_ERROR code.
String mapKakaoError(Object e) {
  if (e is PlatformException && e.code == 'CANCELED') {
    return AuthErrorCode.userCancelled;
  }
  if (e is KakaoClientException) {
    switch (e.reason) {
      case ClientErrorCause.cancelled:
        return AuthErrorCode.userCancelled;
      case ClientErrorCause.notSupported:
        return AuthErrorCode.sdkInitFailed;
      case ClientErrorCause.tokenNotFound:
      case ClientErrorCause.badParameter:
      case ClientErrorCause.illegalState:
      case ClientErrorCause.unknown:
        return AuthErrorCode.unknown;
    }
  }
  if (e is KakaoAuthException) {
    switch (e.error) {
      case AuthErrorCause.accessDenied:
        return AuthErrorCode.userCancelled;
      case AuthErrorCause.invalidClient:
      case AuthErrorCause.misconfigured:
        return AuthErrorCode.sdkInitFailed;
      case AuthErrorCause.serverError:
        return AuthErrorCode.providerError;
      default:
        return AuthErrorCode.providerError;
    }
  }
  if (e is KakaoApiException || e is KakaoAppsException) {
    return AuthErrorCode.providerError;
  }
  if (e is StateError && e.message == 'KAKAO_ID_TOKEN_MISSING') {
    return AuthErrorCode.invalidResponse;
  }
  if (_isNetworkError(e)) return AuthErrorCode.networkError;
  return AuthErrorCode.unknown;
}

String mapKakaoSafeCause(Object e) {
  if (e is PlatformException && e.code == 'CANCELED') return 'user_cancelled';
  if (e is KakaoClientException) {
    return switch (e.reason) {
      ClientErrorCause.cancelled => 'user_cancelled',
      ClientErrorCause.notSupported => 'unsupported',
      ClientErrorCause.tokenNotFound => 'token_not_found',
      ClientErrorCause.badParameter => 'bad_parameter',
      ClientErrorCause.illegalState => 'illegal_state',
      ClientErrorCause.unknown => 'unknown',
    };
  }
  if (e is KakaoAuthException) {
    return switch (e.error) {
      AuthErrorCause.accessDenied => 'user_cancelled',
      AuthErrorCause.invalidClient => 'invalid_client',
      AuthErrorCause.misconfigured => 'misconfigured',
      AuthErrorCause.serverError => 'provider_error',
      _ => 'provider_error',
    };
  }
  if (e is KakaoApiException || e is KakaoAppsException) {
    return 'provider_error';
  }
  if (e is StateError && e.message == 'KAKAO_ID_TOKEN_MISSING') {
    return 'id_token_missing';
  }
  if (_isNetworkError(e)) return 'network';
  return 'unknown';
}

/// Only reasons emitted by [mapKakaoSafeCause] are accepted. The public
/// [AuthError] contract remains backward-compatible; v3 tracing derives the
/// diagnostic field from its already allowlisted provider code.
String? safeNativeSdkCauseFromCode(String code) => const {
  'KAKAO_USER_CANCELLED': 'user_cancelled',
  'KAKAO_UNSUPPORTED': 'unsupported',
  'KAKAO_TOKEN_NOT_FOUND': 'token_not_found',
  'KAKAO_BAD_PARAMETER': 'bad_parameter',
  'KAKAO_ILLEGAL_STATE': 'illegal_state',
  'KAKAO_INVALID_CLIENT': 'invalid_client',
  'KAKAO_MISCONFIGURED': 'misconfigured',
  'KAKAO_PROVIDER_ERROR': 'provider_error',
  'KAKAO_ID_TOKEN_MISSING': 'id_token_missing',
  'KAKAO_NETWORK': 'network',
  'KAKAO_UNKNOWN': 'unknown',
}[code];

/// Google Sign-In raw exception → AUTH_ERROR code.
String mapGoogleError(Object e) {
  if (e is GoogleSignInException) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
        return AuthErrorCode.userCancelled;
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
      case GoogleSignInExceptionCode.uiUnavailable:
        return AuthErrorCode.sdkInitFailed;
      case GoogleSignInExceptionCode.unknownError:
        return AuthErrorCode.providerError;
      case GoogleSignInExceptionCode.interrupted:
      case GoogleSignInExceptionCode.userMismatch:
        return AuthErrorCode.unknown;
    }
  }
  if (_isNetworkError(e)) return AuthErrorCode.networkError;
  return AuthErrorCode.unknown;
}

/// Apple Sign-In raw exception → AUTH_ERROR code.
String mapAppleError(Object e) {
  if (e is SignInWithAppleAuthorizationException) {
    switch (e.code) {
      case AuthorizationErrorCode.canceled:
        return AuthErrorCode.userCancelled;
      case AuthorizationErrorCode.invalidResponse:
        return AuthErrorCode.invalidResponse;
      case AuthorizationErrorCode.failed:
        return AuthErrorCode.providerError;
      case AuthorizationErrorCode.notHandled:
      case AuthorizationErrorCode.notInteractive:
        return AuthErrorCode.sdkInitFailed;
      case AuthorizationErrorCode.unknown:
      case AuthorizationErrorCode.credentialExport:
      case AuthorizationErrorCode.credentialImport:
      case AuthorizationErrorCode.matchedExcludedCredential:
        return AuthErrorCode.unknown;
    }
  }
  if (_isNetworkError(e)) return AuthErrorCode.networkError;
  return AuthErrorCode.unknown;
}
