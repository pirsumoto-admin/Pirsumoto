import '../database/sqlite_database_helper.dart';

enum ChatSessionStatus { running, waiting, done }

class ChatSession {
  final String id;
  final String deviceId;
  String licensePlate;
  final int startTimestamp;
  ChatSessionStatus status;
  String? lastMessage;

  ChatSession({
    required this.id,
    required this.deviceId,
    this.licensePlate = '',
    required this.startTimestamp,
    this.status = ChatSessionStatus.running,
    this.lastMessage,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deviceId': deviceId,
      'licensePlate': licensePlate,
      'startTimestamp': startTimestamp,
      'status': status.name,
      'lastMessage': lastMessage,
    };
  }

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: json['id'] as String,
      deviceId: json['deviceId'] as String,
      licensePlate: json['licensePlate'] as String? ?? '',
      startTimestamp: json['startTimestamp'] as int,
      status: ChatSessionStatus.values.firstWhere(
        (e) => e.name == (json['status'] as String? ?? 'running'),
        orElse: () => ChatSessionStatus.running,
      ),
      lastMessage: json['lastMessage'] as String?,
    );
  }
}

class ChatSessionManager {
  static Future<List<ChatSession>> getSessions(String deviceId) async {
    return await SqliteDatabaseHelper.instance.getSessions(deviceId);
  }

  static Future<void> saveSession(ChatSession session) async {
    await SqliteDatabaseHelper.instance.insertSession(session);
  }

  static Future<void> deleteSession(String deviceId, String sessionId) async {
    await SqliteDatabaseHelper.instance.deleteSession(sessionId);
  }
  
  static Future<ChatSession?> getNextWaitingSession(String deviceId) async {
    final sessions = await getSessions(deviceId);
    try {
      return sessions.firstWhere((s) => s.status == ChatSessionStatus.waiting);
    } catch (e) {
      return null; // None found
    }
  }
}
