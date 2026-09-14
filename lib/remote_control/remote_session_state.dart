enum RemoteSessionState {
  offline,
  connecting,
  idle,
  sessionRequested,
  connectingWebRTC,
  active,
  disconnecting,
}

enum InputOwner {
  automation,
  remoteHuman,
}

class RemoteSessionInfo {
  final RemoteSessionState state;
  final InputOwner inputOwner;
  final String? activeSessionId;
  final String? controllerId;
  final DateTime? connectedAt;
  final String? lastError;

  const RemoteSessionInfo({
    this.state = RemoteSessionState.offline,
    this.inputOwner = InputOwner.automation,
    this.activeSessionId,
    this.controllerId,
    this.connectedAt,
    this.lastError,
  });

  RemoteSessionInfo copyWith({
    RemoteSessionState? state,
    InputOwner? inputOwner,
    String? activeSessionId,
    String? controllerId,
    DateTime? connectedAt,
    String? lastError,
  }) {
    return RemoteSessionInfo(
      state: state ?? this.state,
      inputOwner: inputOwner ?? this.inputOwner,
      activeSessionId: activeSessionId ?? this.activeSessionId,
      controllerId: controllerId ?? this.controllerId,
      connectedAt: connectedAt ?? this.connectedAt,
      lastError: lastError,
    );
  }
}
