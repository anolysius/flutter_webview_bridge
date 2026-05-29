/// OAuth SDK (Kakao / Google / Apple) 실패 시 webview 로 통보될 표준 exception.
///
/// sign_in_*.dart 의 catch 안에서 raw SDK exception 을 [auth_error_mapper.dart]
/// 로 code enum 으로 분류한 뒤 [throw AuthError] 하면, bridge.dart 의 catch
/// 가 `e is AuthError` 분기에서 `{type:'AUTH_ERROR', data:{code, message}}`
/// payload 를 webview 로 송신한다.
///
/// contract: docs/push-token-contract.md (동일 monorepo) — W-1 spec.
class AuthError implements Exception {
  /// 표준화된 error code — webview 측 Sentry 그룹화 / dedup 용.
  /// enum: USER_CANCELLED / NETWORK_ERROR / SDK_INIT_FAILED /
  ///       INVALID_RESPONSE / PROVIDER_ERROR / UNKNOWN
  final String code;

  /// 디버깅용 raw message (사용자 노출 X). SDK 가 던진 exception 의 toString().
  final String message;

  const AuthError(this.code, this.message);

  @override
  String toString() => 'AuthError($code): $message';
}
