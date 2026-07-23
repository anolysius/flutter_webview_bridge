dynamic adaptRefreshTokenRequestForStorage(dynamic data) {
  if (data is! Map || data['protocolVersion'] != 3) return data;
  return <Object?, Object?>{...data, 'protocolVersion': 2};
}

Map<String, Object?> restoreRefreshTokenResponseProtocol(
  Map<String, Object?> response,
  dynamic originalData,
) {
  if (originalData is! Map || originalData['protocolVersion'] != 3) {
    return response;
  }
  final payload = response['data'];
  if (payload is! Map) return response;
  return <String, Object?>{
    ...response,
    'data': <Object?, Object?>{...payload, 'protocolVersion': 3},
  };
}
