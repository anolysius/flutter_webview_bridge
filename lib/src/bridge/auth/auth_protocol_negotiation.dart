const int legacyAuthProtocolVersion = 2;
const int currentAuthProtocolVersion = 3;
const String criticalAuthDeliveryAckCapability = 'criticalAuthDeliveryAck';
const String webSessionImportCapability = 'webSessionImport';

/// 콜드 스타트 자동 복구(auto_refresh)를 홈이 아닌 첫 화면(푸시·딥링크)에서도 끝낼 수 있다.
///
/// 웹이 이 값을 알리면, 자동 복구 토큰을 읽은 그 문서(같은 `documentId`, 인증 화면 제외)에서 온
/// 확인(`REFRESH_TOKEN_WRITE`)과 최종 완료(`AUTH_UI_COMMITTED`)를 홈에서 온 것과 같이 받는다.
/// 알리지 않은 웹에는 지금처럼 홈만 인정한다. 직접 로그인·회원가입·웹 세션 가져오기는 해당 없음.
const String autoRefreshDocumentCommitCapability = 'autoRefreshDocumentCommit';

const Set<String> requiredAuthProtocolV3Capabilities = {
  'softConvergenceDeadline',
  'onboardingHandoff',
  'reauthRequiredCommit',
};

const Set<String> authProtocolV3Capabilities = {
  ...requiredAuthProtocolV3Capabilities,
  criticalAuthDeliveryAckCapability,
  webSessionImportCapability,
  autoRefreshDocumentCommitCapability,
};

int authProtocolVersionOf(dynamic data) =>
    data is Map && data['protocolVersion'] is int
    ? data['protocolVersion'] as int
    : 1;

/// Negotiates v3 only when the web producer explicitly advertises every v3
/// capability. This keeps a new bridge runtime-safe with a rolled-back v2 web.
int negotiateAuthProtocolVersion(dynamic data) {
  final base = authProtocolVersionOf(data);
  if (base < legacyAuthProtocolVersion || data is! Map) return base;

  final maxVersion = data['maxProtocolVersion'];
  final rawCapabilities = data['authCapabilities'];
  final capabilities = rawCapabilities is List
      ? rawCapabilities.whereType<String>().toSet()
      : const <String>{};
  final offersV3 =
      base >= currentAuthProtocolVersion ||
      (maxVersion is int && maxVersion >= currentAuthProtocolVersion);

  return offersV3 &&
          capabilities.containsAll(requiredAuthProtocolV3Capabilities)
      ? currentAuthProtocolVersion
      : legacyAuthProtocolVersion;
}

Set<String> negotiateAuthProtocolCapabilities(dynamic data) {
  if (negotiateAuthProtocolVersion(data) < currentAuthProtocolVersion ||
      data is! Map) {
    return const <String>{};
  }
  final rawCapabilities = data['authCapabilities'];
  final offered = rawCapabilities is List
      ? rawCapabilities.whereType<String>().toSet()
      : const <String>{};
  return offered.intersection(authProtocolV3Capabilities);
}

bool supportsCriticalAuthDeliveryAck(dynamic data) =>
    negotiateAuthProtocolCapabilities(
      data,
    ).contains(criticalAuthDeliveryAckCapability);

Map<String, Object?> authProtocolCapabilityResponse(dynamic data) {
  if (data is! Map || data['authCapabilities'] is! List) {
    return const <String, Object?>{};
  }
  final version = negotiateAuthProtocolVersion(data);
  return <String, Object?>{
    'authProtocolVersion': version,
    if (version >= currentAuthProtocolVersion)
      'authCapabilities': negotiateAuthProtocolCapabilities(
        data,
      ).toList(growable: false),
  };
}
