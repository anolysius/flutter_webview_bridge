import 'auth_protocol_negotiation.dart';

Map<String, Object?>? buildPendingReauthReplay({
  required bool ownsActiveAutomaticLease,
  required bool isAwaitingTerminal,
  required String? activeAuthSessionId,
  required int activeAuthRevision,
  required String? semanticReason,
  required dynamic requestData,
}) {
  if (!ownsActiveAutomaticLease ||
      !isAwaitingTerminal ||
      activeAuthSessionId == null ||
      activeAuthSessionId.isEmpty ||
      semanticReason == null ||
      semanticReason.isEmpty ||
      activeAuthRevision < 0 ||
      requestData is! Map ||
      negotiateAuthProtocolVersion(requestData) < currentAuthProtocolVersion) {
    return null;
  }

  final requestId = requestData['requestId'];
  final documentId = requestData['documentId'];
  if (requestId is! String ||
      requestId.isEmpty ||
      documentId is! String ||
      documentId.isEmpty) {
    return null;
  }

  return <String, Object?>{
    'protocolVersion': currentAuthProtocolVersion,
    'authCapabilities': negotiateAuthProtocolCapabilities(
      requestData,
    ).toList(growable: false),
    'requestId': requestId,
    'authSessionId': activeAuthSessionId,
    'documentId': documentId,
    if (requestData['pageGeneration'] is int)
      'pageGeneration': requestData['pageGeneration'] as int,
    'authRevision': activeAuthRevision,
    'provider': 'AUTO_REFRESH',
    'journey': 'auto_refresh',
    'semanticReason': semanticReason,
  };
}
