import 'dart:convert';

import 'package:http/http.dart' as http;

/// SSO 토큰 교환을 네이티브(Dart HTTP)에서 수행한다 (B2).
///
/// 배경: 카카오 앱 전환 복귀 후 WKWebView WebContent 프로세스가 throttle/suspend 되어
/// web 의 토큰 교환(fetch/XHR)이 1.4s/7s/frozen 으로 극단 변동 → 콜드스타트 1st 로그인 실패.
/// Dart HTTP 는 WKWebView 와 무관하므로 throttle 영향 0 → 교환을 네이티브로 이전한다.
///
/// 2-step (web 흐름과 동일):
///  1) POST {base}/api/user/auth/{provider}/id-token  body {idToken, profile, persist}
///       → 응답 top-level `refreshToken`
///  2) POST {base}/api/user/auth/token/refresh  (device 헤더) body {refreshToken}
///       → 응답 `data.accessToken` / `data.refreshToken` (device-bound 최종)
enum SsoProvider { kakao, google, apple }

class SsoExchangeResult {
  final String accessToken;
  final String refreshToken;

  const SsoExchangeResult({
    required this.accessToken,
    required this.refreshToken,
  });
}

class SsoExchangeException implements Exception {
  final String message;
  final String failureStage;
  final String failureCode;
  final bool externalFailure;
  final int? statusCode;
  final String? semanticReason;
  const SsoExchangeException(
    this.message, {
    required this.failureStage,
    required this.failureCode,
    this.externalFailure = false,
    this.statusCode,
    this.semanticReason,
  });

  @override
  String toString() => 'SsoExchangeException: $message';
}

class SsoExchange {
  /// 예: https://qa.api.sazo.kr (flavor 별 — bridge init 으로 주입).
  final String apiBaseUrl;

  /// API 도메인 타입 (KR 앱 = sazo-korea-shop). web koAxios 가 x-domain-type 으로 항상 전송.
  final String domainType;

  final http.Client? client;

  const SsoExchange({
    required this.apiBaseUrl,
    this.domainType = 'sazo-korea-shop',
    this.client,
  });

  String _idTokenPath(SsoProvider provider) {
    switch (provider) {
      case SsoProvider.kakao:
        return '/api/user/auth/kakao/id-token';
      case SsoProvider.google:
        return '/api/user/auth/google/id-token';
      case SsoProvider.apple:
        return '/api/user/auth/apple/id-token';
    }
  }

  Map<String, String> _baseHeaders() => {
    'Content-Type': 'application/json',
    'x-domain-type': domainType,
    'Accept-Language': 'ko-KR,ko;q=0.9',
  };

  Future<http.Response> _post(
    Uri url, {
    required Map<String, String> headers,
    Object? body,
  }) {
    final injectedClient = client;
    if (injectedClient != null) {
      return injectedClient.post(url, headers: headers, body: body);
    }
    return http.post(url, headers: headers, body: body);
  }

  Future<http.Response> _get(Uri url, {required Map<String, String> headers}) {
    final injectedClient = client;
    if (injectedClient != null) {
      return injectedClient.get(url, headers: headers);
    }
    return http.get(url, headers: headers);
  }

  /// [deviceHeaders] 는 x-sazo-app-id / x-sazo-app-os / x-sazo-app-version / x-sazo-device-id.
  /// refresh 교환이 device-bound access token 발급에 사용한다.
  Future<SsoExchangeResult> exchange({
    required SsoProvider provider,
    required String idToken,
    Map<String, Object?>? profile,
    bool persist = false,
    required Map<String, String> deviceHeaders,
  }) async {
    // 1) id-token 교환 → refreshToken
    final idRes = await _post(
      Uri.parse('$apiBaseUrl${_idTokenPath(provider)}'),
      headers: {..._baseHeaders(), ...deviceHeaders},
      body: jsonEncode({
        'idToken': idToken,
        'profile': profile ?? <String, Object?>{},
        'persist': persist,
      }),
    );
    if (idRes.statusCode < 200 || idRes.statusCode >= 300) {
      throw SsoExchangeException(
        'id-token HTTP ${idRes.statusCode}',
        failureStage: 'id_token_exchange',
        failureCode: 'SSO_ID_TOKEN_HTTP',
        externalFailure: _isExternalStatus(idRes.statusCode),
        statusCode: idRes.statusCode,
      );
    }
    final Map<String, dynamic> idBody;
    try {
      idBody = _decode(idRes.body);
    } on FormatException {
      throw const SsoExchangeException(
        'id-token response invalid JSON',
        failureStage: 'id_token_exchange',
        failureCode: 'SSO_ID_TOKEN_INVALID_RESPONSE',
      );
    }
    final refreshToken = idBody['refreshToken'] as String?;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw const SsoExchangeException(
        'id-token response missing refreshToken',
        failureStage: 'id_token_exchange',
        failureCode: 'SSO_ID_TOKEN_MISSING_REFRESH',
      );
    }

    // 2) refresh 교환 → device-bound accessToken (+ 갱신 refreshToken)
    return refreshToAccess(
      refreshToken: refreshToken,
      deviceHeaders: deviceHeaders,
    );
  }

  /// 자동로그인 / 401 갱신 전용 — 저장된 refreshToken 으로 device-bound accessToken 발급.
  /// SSO 교환 2-step 중 step 2 (`POST /api/user/auth/token/refresh`) 단독 수행.
  ///
  /// 배경(Fix A): 새 home document(throttle 로 Next hard-nav fallback 생성)의 자동로그인이
  /// web HTTP refresh 교환에 의존해 throttle 로 hang → 로그아웃. Dart HTTP 는 throttle 무관이라
  /// 교환을 네이티브로 이전한다. 응답 `data.refreshToken` 이 갱신되면 그 값을, 없으면 입력 토큰 유지.
  Future<SsoExchangeResult> refreshToAccess({
    required String refreshToken,
    required Map<String, String> deviceHeaders,
  }) async {
    final rfRes = await _post(
      Uri.parse('$apiBaseUrl/api/user/auth/token/refresh'),
      headers: {..._baseHeaders(), ...deviceHeaders},
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    if (rfRes.statusCode < 200 || rfRes.statusCode >= 300) {
      throw SsoExchangeException(
        'refresh HTTP ${rfRes.statusCode}',
        failureStage: 'refresh_exchange',
        failureCode: 'SSO_REFRESH_HTTP',
        externalFailure: _isExternalStatus(rfRes.statusCode),
        statusCode: rfRes.statusCode,
        semanticReason: _refreshSemanticReason(rfRes.body),
      );
    }
    final Map<String, dynamic> rfBody;
    try {
      rfBody = _decode(rfRes.body);
    } on FormatException {
      throw const SsoExchangeException(
        'refresh response invalid JSON',
        failureStage: 'refresh_exchange',
        failureCode: 'SSO_REFRESH_INVALID_RESPONSE',
      );
    }
    final data = rfBody['data'];
    final accessToken = data is Map ? data['accessToken'] as String? : null;
    final finalRefresh =
        (data is Map ? data['refreshToken'] as String? : null) ?? refreshToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw const SsoExchangeException(
        'refresh response missing accessToken',
        failureStage: 'refresh_exchange',
        failureCode: 'SSO_REFRESH_MISSING_ACCESS',
      );
    }
    return SsoExchangeResult(
      accessToken: accessToken,
      refreshToken: finalRefresh,
    );
  }

  /// 로그인 직후 me(내정보)를 네이티브에서 직접 GET 한다.
  /// web 의 me fetch(`/api/user/user-me`)가 카카오 앱전환 복귀 throttle 로 hang 하여 홈이
  /// 간헐적 로그아웃 UI 로 보이는 것을 우회 — Dart HTTP 는 WKWebView throttle 무관.
  ///
  /// 실패는 **non-fatal** — null 반환 시 web 이 기존 me fetch 로 fallback (회귀 안전).
  /// [accessToken] 은 `X-SAZO-Authorization` 헤더에 **raw**(Bearer prefix 없음 — web koAxios 동일).
  /// 응답은 top-level `UserUserResponseDto`({id,email,names,...}) — 그대로 web me 캐시에 주입.
  Future<Map<String, dynamic>?> fetchMe({
    required String accessToken,
    required Map<String, String> deviceHeaders,
  }) async {
    try {
      final res = await _get(
        Uri.parse('$apiBaseUrl/api/user/user-me'),
        headers: {
          ..._baseHeaders(),
          // me 는 web koAxios 경로 — domain 헤더명이 x-sazo-domain-type. 호환 위해 둘 다 전송.
          'x-sazo-domain-type': domainType,
          // raw access token (web koAxios: config.headers['X-SAZO-Authorization'] = token)
          'X-SAZO-Authorization': accessToken,
          ...deviceHeaders,
        },
      );
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final body = _decode(res.body);
      // 정상 me 는 top-level id 보유. 일부 게이트의 {data:{...}} 래핑도 방어적으로 처리.
      if (body['id'] != null) return body;
      final data = body['data'];
      if (data is Map<String, dynamic> && data['id'] != null) return data;
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decode(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  String? _refreshSemanticReason(String body) {
    try {
      final decoded = jsonDecode(body);
      final code = decoded is Map ? decoded['code'] : null;
      return switch (code) {
        'A400-10' => 'refresh_token_expired',
        'A400-11' => 'refresh_token_invalid',
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  bool _isExternalStatus(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;
}
