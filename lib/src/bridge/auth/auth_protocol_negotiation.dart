const int legacyAuthProtocolVersion = 2;
const int currentAuthProtocolVersion = 3;

const Set<String> authProtocolV3Capabilities = {
  'softConvergenceDeadline',
  'onboardingHandoff',
  'reauthRequiredCommit',
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

  return offersV3 && capabilities.containsAll(authProtocolV3Capabilities)
      ? currentAuthProtocolVersion
      : legacyAuthProtocolVersion;
}
