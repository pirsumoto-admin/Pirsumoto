import "lib/services/p2p_auto_publish_launcher.dart";

void main() {
  final Map<String, String> data = {
    "govIl": "false",
    "maker": "Toyota",
    "test_until": "",
  };
  final p = P2PAutoPublishLauncher.buildPublishData(data);
  print(p.govIl);
}
