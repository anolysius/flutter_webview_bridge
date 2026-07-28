class AuthRecoveryGate {
  int _reloadCount = 0;
  bool _homeTokenBindConfirmed = false;
  bool _exhaustionReported = false;

  int get reloadCount => _reloadCount;
  bool get homeTokenBindConfirmed => _homeTokenBindConfirmed;

  void reset() {
    _reloadCount = 0;
    _homeTokenBindConfirmed = false;
    _exhaustionReported = false;
  }

  void confirmHomeTokenBind() {
    _homeTokenBindConfirmed = true;
  }

  bool tryConsumeRecovery({required bool requiresUnconfirmedHome}) {
    if ((requiresUnconfirmedHome && _homeTokenBindConfirmed) ||
        _reloadCount >= 1) {
      return false;
    }
    _reloadCount += 1;
    return true;
  }

  bool takeExhaustionSignal() {
    if (_exhaustionReported) return false;
    _exhaustionReported = true;
    return true;
  }
}
