import 'dart:async' show TimeoutException;
import 'dart:convert' show jsonDecode;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart' show GoogleSignInException;
import 'package:http/http.dart' as http show ClientException;
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart'
    show
        KakaoApiException,
        KakaoAppsException,
        KakaoAuthException,
        KakaoClientException;
import 'package:sign_in_with_apple/sign_in_with_apple.dart'
    show SignInWithAppleAuthorizationException;

/// 로그인 실패 원인 코드 (`failureCause`) — **1코드 = 1원인**.
///
/// 형식: `{SOURCE}_{STEP}_{REASON}` · `^[A-Z][A-Z0-9_]{0,63}$` (웹 `/api/log` sanitizer 와 동일).
/// REASON 은 SDK 가 정해 둔 enum 이름을 기계적으로 UPPER_SNAKE 로 바꾼 값에 예외 클래스
/// 접두사를 붙인 것이다. enum 을 손으로 나열하지 않으므로 SDK 가 enum 을 늘려도 새 원인이
/// 기존 코드에 합쳐지지 않는다. raw message 는 담지 않는다(개인정보·응답 원문 유입 방지).
///
/// 기존 `AuthErrorCode`(USER_CANCELLED 등)는 웹 화면 분기용 분류이고, 이 코드는 집계용 원인이다.
/// 여러 원인이 같은 분류(`resultCodeForFailureCause`)를 공유해도 원인 코드는 서로 다르다.

/// 카카오 로그인 단계. 같은 SDK 오류라도 단계가 다르면 다른 원인이다.
enum KakaoAuthStep {
  /// 카카오톡 앱 로그인 (`loginWithKakaoTalk`).
  talk('TALK'),

  /// 카카오톡 미설치 → 카카오계정 로그인 (`loginWithKakaoAccount`).
  account('ACCOUNT'),

  /// 카카오톡 로그인 실패 → 카카오계정 로그인으로 넘어간 뒤의 실패.
  fallback('FALLBACK'),

  /// 추가 동의 재로그인 (`loginWithNewScopes`).
  scopes('SCOPES'),

  /// 로그인은 끝났으나 id token 확보 단계.
  idToken('IDTOKEN');

  const KakaoAuthStep(this.code);
  final String code;
}

const _maxLength = 64;

/// `ASWebAuthenticationSessionError` 도메인. 카카오 iOS 플러그인은 이 도메인의 오류를 종류와
/// 상관없이 `PlatformException(CANCELED)` 로 뭉쳐 넘기고, 오류 번호는 `details` 의
/// `localizedDescription` 에만 남긴다 (kakao_flutter_sdk_common 1.10.0 `launchBrowser`).
const _webAuthDomain = 'WebAuthenticationSession';

/// `details` 에서 `ASWebAuthenticationSessionError` 번호를 읽는다.
///
/// 로케일에 따라 "error 1"/"오류 1" 처럼 단어가 바뀌므로 단어가 아니라 도메인명 뒤 첫 숫자로
/// 매칭한다 (Step 0 실측: ko `…WebAuthenticationSession 오류 1.)`, en `… error 1.)`).
/// 1 = 사용자 취소, 2 = presentationContextNotProvided, 3 = presentationContextInvalid.
int? parseWebAuthSessionErrorCode(Object? details) {
  if (details is! String) return null;
  final match = RegExp('$_webAuthDomain\\D*(\\d+)').firstMatch(details);
  return match == null ? null : int.tryParse(match.group(1)!);
}

String kakaoFailureCause(KakaoAuthStep step, Object error) =>
    _compose('KAKAO_${step.code}', _kakaoReason(error));

String googleFailureCause(Object error) => _compose(
  'GOOGLE_SIGN_IN',
  error is GoogleSignInException
      ? _upperSnake(error.code.name)
      : _commonReason(error),
);

String appleFailureCause(Object error) => _compose(
  'APPLE_AUTHORIZE',
  error is SignInWithAppleAuthorizationException
      ? _upperSnake(error.code.name)
      : _commonReason(error),
);

String _kakaoReason(Object error) {
  if (error is KakaoClientException) {
    return 'CLIENT_${_upperSnake(error.reason.name)}';
  }
  if (error is KakaoAuthException) {
    return 'AUTH_${_upperSnake(error.error.name)}';
  }
  if (error is KakaoApiException) return 'API_${_upperSnake(error.code.name)}';
  if (error is KakaoAppsException) {
    return 'APPS_${_upperSnake(error.code.name)}';
  }
  if (error is StateError && error.message == 'KAKAO_ID_TOKEN_MISSING') {
    return 'MISSING';
  }
  return _commonReason(error);
}

String _commonReason(Object error) {
  if (error is PlatformException) {
    if (error.code == 'CANCELED' &&
        error.details is String &&
        (error.details as String).contains(_webAuthDomain)) {
      final n = parseWebAuthSessionErrorCode(error.details);
      return n == null ? 'WEBAUTH_UNPARSED' : 'WEBAUTH_$n';
    }
    return 'PLATFORM_${_sanitize(error.code)}';
  }
  if (error is SocketException) return 'NETWORK_SOCKET';
  if (error is TimeoutException) return 'NETWORK_TIMEOUT';
  // package:http 는 연결 실패를 SocketException 이 아니라 ClientException 으로 감싼다.
  if (error is http.ClientException) return 'NETWORK_CLIENT';
  return 'UNEXPECTED_${_upperSnake(error.runtimeType.toString())}';
}

/// 원인 코드 → `auth.terminal` 의 `resultCode` (KPI 분류 표, SSOT).
///
/// 사람의 행동으로만 생기는 원인만 `user_cancelled` 이고, 표에 없는 코드는 `code_failure` 로
/// 떨어진다 — 시스템 오류가 '취소'로 새어 KPI 에서 빠지는 일을 막는다.
String resultCodeForFailureCause(String cause) {
  if (_userCancelled.any((p) => p.hasMatch(cause))) return 'user_cancelled';
  if (cause.endsWith('_WEBAUTH_UNPARSED')) {
    return 'code_failure:unclassified_cancel';
  }
  if (_external.any((p) => p.hasMatch(cause))) {
    return 'excluded_external_failure';
  }
  return 'code_failure:native_auth_error';
}

final _userCancelled = [
  RegExp(r'^KAKAO_[A-Z]+_WEBAUTH_1$'),
  RegExp(r'^KAKAO_[A-Z]+_CLIENT_CANCELLED$'),
  RegExp(r'^KAKAO_[A-Z]+_AUTH_ACCESS_DENIED$'),
  // 카카오톡 기기 권한 요청 화면에서 뒤로 가기 (sign_in_kakao.dart 의 rethrow 분기).
  RegExp(r'^KAKAO_TALK_PLATFORM_CANCELED$'),
  RegExp(r'^GOOGLE_SIGN_IN_CANCELED$'),
  RegExp(r'^APPLE_AUTHORIZE_CANCELED$'),
];

final _external = [
  RegExp(r'_NETWORK_(SOCKET|TIMEOUT|CLIENT)$'),
  RegExp(r'^KAKAO_[A-Z]+_AUTH_SERVER_ERROR$'),
  RegExp(
    r'^KAKAO_[A-Z]+_API_(INTERNAL_ERROR|SERVER_TIME_OUT|UNDER_MAINTENANCE)$',
  ),
  RegExp(r'^KAKAO_[A-Z]+_APPS_INTERNAL_SERVER_ERROR$'),
];

/// camelCase / PascalCase → UPPER_SNAKE.
String _upperSnake(String name) => _sanitize(
  name.replaceAllMapped(
    RegExp(r'(?<=[a-z0-9])([A-Z])'),
    (m) => '_${m.group(1)}',
  ),
);

String _sanitize(String raw) => raw
    .toUpperCase()
    .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// 64자를 넘으면 앞부분 + 원문 해시로 줄여 서로 다른 원인이 잘려서 합쳐지지 않게 한다.
String _compose(String prefix, String reason) {
  final code = reason.isEmpty ? prefix : '${prefix}_$reason';
  if (code.length <= _maxLength) return code;
  final hash = _fnv1a(code).toRadixString(16).toUpperCase().padLeft(8, '0');
  return '${code.substring(0, _maxLength - 9)}_$hash';
}

int _fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// 서버 오류 envelope 의 오류 코드 (예 `A400-29`). allowlist 정규식·40자 상한을 통과한 값만.
/// user 서비스는 top-level `code`, 공통 envelope 은 `errorCode`(서비스 접두사 포함)에 싣는다.
final _serverErrorCodePattern = RegExp(
  r'^[A-Z]{0,12}[A-Z0-9]{1,8}-[A-Z0-9-]{1,16}$',
);

String? serverErrorCodeFromBody(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    for (final key in const ['errorCode', 'code']) {
      final value = decoded[key];
      if (value is String &&
          value.length <= 40 &&
          _serverErrorCodePattern.hasMatch(value)) {
        return value;
      }
    }
  } catch (_) {}
  return null;
}

/// 서버 교환 HTTP 실패 — `SSO_{STEP}_HTTP_{status}[_{serverErrorCode}]`.
String ssoHttpFailureCause(String step, int status, String? serverErrorCode) =>
    _compose(
      'SSO_${step}_HTTP_$status',
      serverErrorCode == null ? '' : _sanitize(serverErrorCode),
    );

/// 서버 교환 중 HTTP 응답 이전의 실패 (네트워크 등).
String ssoTransportFailureCause(String step, Object error) =>
    _compose('SSO_$step', _commonReason(error));

/// bridge 내부 단계의 미분류 예외 — `NATIVE_{STAGE}_{REASON}`. 예외 타입별로 분리된다.
String nativeFailureCause(String failureStage, Object error) =>
    _compose('NATIVE_${_sanitize(failureStage)}', _commonReason(error));

/// 원격 auth trace 로 내보내는 실패 진단 필드 allowlist (타입별). 웹 `/api/log` sanitizer 와 짝.
const authFailureTraceStringKeys = [
  'failureCause',
  'serverErrorCode',
  'fallbackFromCause',
  'appLifecycleState',
  'iosSceneActivationState',
  'osVersion',
  'deviceModel',
];
const authFailureTraceIntKeys = ['stepElapsedMs'];
const authFailureTraceBoolKeys = ['kakaoTalkInstalled', 'iosKeyWindowPresent'];
