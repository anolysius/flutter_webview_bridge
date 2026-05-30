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
  const SsoExchangeException(this.message);

  @override
  String toString() => 'SsoExchangeException: $message';
}

class SsoExchange {
  /// 예: https://qa.api.sazo.kr (flavor 별 — bridge init 으로 주입).
  final String apiBaseUrl;

  /// API 도메인 타입 (KR 앱 = sazo-korea-shop). web koAxios 가 x-domain-type 으로 항상 전송.
  final String domainType;

  const SsoExchange({
    required this.apiBaseUrl,
    this.domainType = 'sazo-korea-shop',
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
    final idRes = await http.post(
      Uri.parse('$apiBaseUrl${_idTokenPath(provider)}'),
      headers: _baseHeaders(),
      body: jsonEncode({
        'idToken': idToken,
        'profile': profile ?? <String, Object?>{},
        'persist': persist,
      }),
    );
    if (idRes.statusCode < 200 || idRes.statusCode >= 300) {
      throw SsoExchangeException(
        'id-token ${idRes.statusCode}: ${_preview(idRes.body)}',
      );
    }
    final idBody = _decode(idRes.body);
    final refreshToken = idBody['refreshToken'] as String?;
    if (refreshToken == null || refreshToken.isEmpty) {
      throw SsoExchangeException(
        'id-token 응답 refreshToken 부재: ${_preview(idRes.body)}',
      );
    }

    // 2) refresh 교환 → device-bound accessToken (+ 갱신 refreshToken)
    final rfRes = await http.post(
      Uri.parse('$apiBaseUrl/api/user/auth/token/refresh'),
      headers: {..._baseHeaders(), ...deviceHeaders},
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    if (rfRes.statusCode < 200 || rfRes.statusCode >= 300) {
      throw SsoExchangeException(
        'refresh ${rfRes.statusCode}: ${_preview(rfRes.body)}',
      );
    }
    final rfBody = _decode(rfRes.body);
    final data = rfBody['data'];
    final accessToken = data is Map ? data['accessToken'] as String? : null;
    final finalRefresh =
        (data is Map ? data['refreshToken'] as String? : null) ?? refreshToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw SsoExchangeException(
        'refresh 응답 accessToken 부재: ${_preview(rfRes.body)}',
      );
    }
    return SsoExchangeResult(
      accessToken: accessToken,
      refreshToken: finalRefresh,
    );
  }

  Map<String, dynamic> _decode(String body) {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  String _preview(String body) =>
      body.length <= 200 ? body : '${body.substring(0, 200)}…';
}
