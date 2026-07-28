List<String> kakaoConsentScopesWithOpenId(List<String> scopes) {
  if (scopes.isEmpty) return const [];
  if (scopes.contains('openid')) return List<String>.of(scopes);
  return <String>[...scopes, 'openid'];
}

String? selectKakaoIdToken({
  required String? current,
  required String? reissued,
}) {
  if (reissued != null && reissued.isNotEmpty) return reissued;
  return current;
}
