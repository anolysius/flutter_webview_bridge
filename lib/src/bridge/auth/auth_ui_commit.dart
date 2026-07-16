enum AuthUiCommitRejection {
  invalidPayload,
  wrongRequest,
  wrongAttempt,
  staleRevision,
  hiddenDocument,
  authStateMismatch,
  dockMismatch,
  notHome,
}

class AuthUiCommitDecision {
  const AuthUiCommitDecision.accepted() : rejection = null;
  const AuthUiCommitDecision.rejected(this.rejection);

  final AuthUiCommitRejection? rejection;
  bool get isAccepted => rejection == null;
}

AuthUiCommitDecision validateAuthUiCommit({
  required dynamic data,
  required String? activeRequestId,
  required String? activeAuthSessionId,
  required int activeAuthRevision,
  required bool nativeIsHome,
  required bool webIsHome,
}) {
  if (data is! Map || data['protocolVersion'] != 2) {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.invalidPayload,
    );
  }
  if (activeRequestId != null && data['requestId'] != activeRequestId) {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.wrongRequest,
    );
  }
  if (activeAuthSessionId != null &&
      data['authSessionId'] != activeAuthSessionId) {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.wrongAttempt,
    );
  }
  if (data['authRevision'] != activeAuthRevision) {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.staleRevision,
    );
  }
  if (data['visibilityState'] != 'visible') {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.hiddenDocument,
    );
  }
  if (data['isAccessTokenBind'] != true || data['userIdsMatch'] != true) {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.authStateMismatch,
    );
  }
  if (data['dockModel'] != 'mypage' || data['dockHref'] != '/account') {
    return const AuthUiCommitDecision.rejected(
      AuthUiCommitRejection.dockMismatch,
    );
  }
  if (!nativeIsHome || !webIsHome) {
    return const AuthUiCommitDecision.rejected(AuthUiCommitRejection.notHome);
  }
  return const AuthUiCommitDecision.accepted();
}
