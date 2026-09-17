/// Centralized WebRTC ICE (STUN/TURN) server configuration for Pirsumoto.
class WebRtcIceConfig {
  /// External Static IP or domain of your GCP TURN VM
  static const String serverIp = '34.173.1.201';

  /// Listening port configured in coturn (default 3478)
  static const int port = 3478;

  /// Username configured in /etc/turnserver.conf
  static const String username = 'admin@pirsumoto.com';

  /// Password configured in /etc/turnserver.conf
  static const String credential = 'Metukit02!';

  /// Build standard ICE servers list (STUN + TURN over UDP and TCP)
  static List<Map<String, dynamic>> get defaultIceServers {
    final hasValidIp = serverIp.isNotEmpty && serverIp != 'YOUR_GCP_VM_IP';

    return [
      // Standard Google STUN servers (for direct P2P when not blocked by NAT)
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},

      // GCP TURN Relay (fallback for Cellular CGNAT & Symmetric NAT)
      if (hasValidIp) ...[
        {
          'urls': [
            'turn:$serverIp:$port?transport=udp',
            'turn:$serverIp:$port?transport=tcp',
          ],
          'username': username,
          'credential': credential,
        },
      ],
    ];
  }
}
