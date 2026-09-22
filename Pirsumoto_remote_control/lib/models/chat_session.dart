import 'dart:convert';

enum ChatSessionStatus {
  draft,
  waiting,
  running,
  done,
  error,
  preparing,
  paused,
  canceling,
  canceled,
  failed,
}

class ChatSession {
  final String id;
  final String deviceId;
  String licensePlate;
  final int startTimestamp;
  ChatSessionStatus status;
  String? lastMessage;
  Map<String, String> vehicleData;
  List<String> imagePaths;
  int? expectedImageCount;
  bool isReadyToPublish;

  ChatSession({
    required this.id,
    required this.deviceId,
    this.licensePlate = '',
    required this.startTimestamp,
    this.status = ChatSessionStatus.draft,
    this.lastMessage,
    Map<String, String>? vehicleData,
    List<String>? imagePaths,
    this.expectedImageCount,
    this.isReadyToPublish = false,
  }) : vehicleData = vehicleData ?? {},
       imagePaths = imagePaths ?? [];

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deviceId': deviceId,
      'licensePlate': licensePlate,
      'startTimestamp': startTimestamp,
      'status': status.name,
      'lastMessage': lastMessage,
      'vehicleDataJson': jsonEncode(vehicleData),
      'imagePathsJson': jsonEncode(imagePaths),
      'expectedImageCount': expectedImageCount,
      'isReadyToPublish': isReadyToPublish ? 1 : 0,
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    Map<String, String> vData = {};
    if (json['vehicleDataJson'] is String &&
        (json['vehicleDataJson'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(json['vehicleDataJson'] as String);
        if (decoded is Map) {
          vData = decoded.map(
            (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
          );
        }
      } catch (_) {}
    }

    List<String> imgs = [];
    if (json['imagePathsJson'] is String &&
        (json['imagePathsJson'] as String).isNotEmpty) {
      try {
        final decoded = jsonDecode(json['imagePathsJson'] as String);
        if (decoded is List) {
          imgs = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    return ChatSession(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      licensePlate: json['licensePlate'] as String? ?? '',
      startTimestamp: json['startTimestamp'] as int,
      status: ChatSessionStatus.values.firstWhere(
        (e) => e.name == (json['status'] as String? ?? 'draft'),
        orElse: () => ChatSessionStatus.draft,
      ),
      lastMessage: json['lastMessage'] as String?,
      vehicleData: vData,
      imagePaths: imgs,
      expectedImageCount: json['expectedImageCount'] as int?,
      isReadyToPublish:
          json['isReadyToPublish'] == 1 || json['isReadyToPublish'] == true,
    );
  }
}
