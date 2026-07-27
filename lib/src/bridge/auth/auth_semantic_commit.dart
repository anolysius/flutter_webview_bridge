enum AuthSemanticCommitKind { onboardingReady, reauthRequired }

enum AuthSemanticCommitRejection {
  invalidPayload,
  protocolMismatch,
  wrongRequest,
  wrongAttempt,
  staleRevision,
  hiddenDocument,
  wrongRoute,
  authStateMismatch,
  dockMismatch,
}

class AuthSemanticCommitDecision {
  const AuthSemanticCommitDecision.accepted() : rejection = null;
  const AuthSemanticCommitDecision.rejected(this.rejection);

  final AuthSemanticCommitRejection? rejection;
  bool get isAccepted => rejection == null;
}

AuthSemanticCommitDecision validateAuthSemanticCommit({
  required AuthSemanticCommitKind kind,
  required dynamic data,
  required int activeProtocolVersion,
  required String? activeRequestId,
  required String? activeAuthSessionId,
  required int activeAuthRevision,
  required bool nativeRouteMatches,
  required bool webRouteMatches,
}) {
  if (data is! Map) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.invalidPayload,
    );
  }
  if (activeProtocolVersion < 3 || data['protocolVersion'] != 3) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.protocolMismatch,
    );
  }
  if (data['requestId'] != activeRequestId) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.wrongRequest,
    );
  }
  if (data['authSessionId'] != activeAuthSessionId) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.wrongAttempt,
    );
  }
  if (data['authRevision'] != activeAuthRevision) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.staleRevision,
    );
  }
  if (data['visibilityState'] != 'visible') {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.hiddenDocument,
    );
  }
  if (!nativeRouteMatches || !webRouteMatches) {
    return const AuthSemanticCommitDecision.rejected(
      AuthSemanticCommitRejection.wrongRoute,
    );
  }
  if (kind == AuthSemanticCommitKind.reauthRequired) {
    if (data['isAccessTokenBind'] != false) {
      return const AuthSemanticCommitDecision.rejected(
        AuthSemanticCommitRejection.authStateMismatch,
      );
    }
    if (data['dockModel'] != 'login' || data['dockHref'] != '/auth/signin') {
      return const AuthSemanticCommitDecision.rejected(
        AuthSemanticCommitRejection.dockMismatch,
      );
    }
  }
  return const AuthSemanticCommitDecision.accepted();
}
