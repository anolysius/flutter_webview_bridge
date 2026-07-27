class AuthTraceCorrelation {
  const AuthTraceCorrelation({
    required this.requestId,
    required this.loginAttemptId,
    required this.authRevision,
    required this.protocolVersion,
    this.provider,
    this.documentId,
    this.predecessorAttemptId,
  });

  final String requestId;
  final String loginAttemptId;
  final int authRevision;
  final int protocolVersion;
  final String? provider;
  final String? documentId;
  final String? predecessorAttemptId;
}

class _AuthTraceCorrelationEntry {
  _AuthTraceCorrelationEntry(this.value, this.updatedAt);

  AuthTraceCorrelation value;
  DateTime updatedAt;
  DateTime? terminalAt;
}

/// Retains non-sensitive request/attempt correlation briefly after terminal so
/// an asynchronous JavaScript delivery receipt cannot lose its attempt ID when
/// the active auth transaction has already been invalidated.
class AuthTraceCorrelationCache {
  AuthTraceCorrelationCache({
    this.terminalGrace = const Duration(seconds: 120),
    this.maxEntries = 200,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration terminalGrace;
  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, _AuthTraceCorrelationEntry> _entries = {};

  void remember(AuthTraceCorrelation correlation) {
    final now = _now();
    _prune(now);
    final entry = _entries.remove(correlation.requestId);
    _entries[correlation.requestId] =
        (entry ?? _AuthTraceCorrelationEntry(correlation, now))
          ..value = correlation
          ..updatedAt = now
          ..terminalAt = null;
    _trimOldest();
  }

  AuthTraceCorrelation? resolve(String? requestId) {
    if (requestId == null || requestId.isEmpty) return null;
    final now = _now();
    _prune(now);
    return _entries[requestId]?.value;
  }

  void markTerminal(String? requestId) {
    if (requestId == null || requestId.isEmpty) return;
    final now = _now();
    _prune(now);
    final entry = _entries[requestId];
    if (entry != null) entry.terminalAt ??= now;
  }

  void clear() => _entries.clear();

  void _prune(DateTime now) {
    _entries.removeWhere((_, entry) {
      final terminalAt = entry.terminalAt;
      return terminalAt != null && now.difference(terminalAt) > terminalGrace;
    });
  }

  void _trimOldest() {
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}
