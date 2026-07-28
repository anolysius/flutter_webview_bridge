const int legacyAuthProtocolVersion = 2;
const int currentAuthProtocolVersion = 3;
const String criticalAuthDeliveryAckCapability = 'criticalAuthDeliveryAck';

const Set<String> requiredAuthProtocolV3Capabilities = {
  'softConvergenceDeadline',
  'onboardingHandoff',
  'reauthRequiredCommit',
};

const Set<String> authProtocolV3Capabilities = {
  ...requiredAuthProtocolV3Capabilities,
  criticalAuthDeliveryAckCapability,
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
