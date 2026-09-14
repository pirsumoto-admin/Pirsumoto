import 'dart:convert';

class RemoteProtocolConstants {
  static const String channelCommands = 'remoteCommands';
  static const String channelPointer = 'remotePointer';
  static const String channelChat = 'remoteChat';

  static const String typeTap = 'tap';
  static const String typeLongPress = 'long_press';
  static const String typeSwipe = 'swipe';
  static const String typeKey = 'key';
  static const String typeText = 'text';
  static const String typePointerMove = 'pointer_move';
  static const String typeScroll = 'scroll';
  static const String typePing = 'ping';
  static const String typePong = 'pong';
  static const String typeHandover = 'handover';
  static const String typeDisconnect = 'disconnect';
  static const String typeDimensions = 'screen_dimensions';

  static const String typeChatText = 'chat_text';
  static const String typeChatMediaChunk = 'chat_media_chunk';
  static const String typeChatReply = 'chat_reply';
  static const String typeChatStatus = 'chat_status';

  static const String keyBack = 'BACK';
  static const String keyHome = 'HOME';
  static const String keyRecents = 'RECENTS';
  static const String keyEnter = 'ENTER';
  static const String keyBackspace = 'BACKSPACE';
}

abstract class RemoteCommand {
  final String type;
  const RemoteCommand(this.type);

  Map<String, dynamic> toJson();

  String encode() => jsonEncode(toJson());

  static RemoteCommand? decode(String rawJson) {
    try {
      final map = jsonDecode(rawJson) as Map<String, dynamic>;
      final type = map['type'] as String?;
      switch (type) {
        case RemoteProtocolConstants.typeTap:
          return RemoteTapCommand(
            x: (map['x'] as num).toDouble(),
            y: (map['y'] as num).toDouble(),
          );
        case RemoteProtocolConstants.typeLongPress:
          return RemoteLongPressCommand(
            x: (map['x'] as num).toDouble(),
            y: (map['y'] as num).toDouble(),
            durationMs: (map['duration'] as num?)?.toInt() ?? 700,
          );
        case RemoteProtocolConstants.typeSwipe:
          return RemoteSwipeCommand(
            startX: (map['startX'] as num).toDouble(),
            startY: (map['startY'] as num).toDouble(),
            endX: (map['endX'] as num).toDouble(),
            endY: (map['endY'] as num).toDouble(),
            durationMs: (map['duration'] as num?)?.toInt() ?? 300,
          );
        case RemoteProtocolConstants.typeKey:
          return RemoteKeyCommand(
            key: map['key'] as String? ?? '',
          );
        case RemoteProtocolConstants.typeText:
          return RemoteTextCommand(
            text: map['text'] as String? ?? '',
          );
        case RemoteProtocolConstants.typePing:
          return RemotePingCommand(
            clientTimestamp: (map['t'] as num).toInt(),
          );
        case RemoteProtocolConstants.typePong:
          return RemotePongCommand(
            clientTimestamp: (map['t'] as num).toInt(),
          );
        case RemoteProtocolConstants.typePointerMove:
          return RemotePointerMoveCommand(
            x: (map['x'] as num).toDouble(),
            y: (map['y'] as num).toDouble(),
          );
        case RemoteProtocolConstants.typeScroll:
          return RemoteScrollCommand(
            deltaX: (map['deltaX'] as num?)?.toDouble() ?? 0.0,
            deltaY: (map['deltaY'] as num?)?.toDouble() ?? 0.0,
          );
        case RemoteProtocolConstants.typeHandover:
          return RemoteHandoverCommand(
            owner: map['owner'] as String? ?? 'remote_human',
          );
        case RemoteProtocolConstants.typeDisconnect:
          return RemoteDisconnectCommand();
        case RemoteProtocolConstants.typeDimensions:
          return RemoteDimensionsCommand(
            width: (map['width'] as num).toInt(),
            height: (map['height'] as num).toInt(),
            density: (map['density'] as num?)?.toDouble() ?? 1.0,
          );
        case RemoteProtocolConstants.typeChatText:
          return RemoteChatTextMessage(
            id: map['id'] as String? ?? '',
            text: map['text'] as String? ?? '',
            senderName: map['senderName'] as String?,
            timestamp: (map['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
        case RemoteProtocolConstants.typeChatMediaChunk:
          return RemoteChatMediaChunk(
            mediaId: map['mediaId'] as String? ?? '',
            messageId: map['messageId'] as String? ?? '',
            mediaType: map['mediaType'] as String? ?? 'image',
            fileName: map['fileName'] as String? ?? '',
            mimeType: map['mimeType'] as String?,
            chunkIndex: (map['chunkIndex'] as num?)?.toInt() ?? 0,
            totalChunks: (map['totalChunks'] as num?)?.toInt() ?? 1,
            data: map['data'] as String? ?? '',
            caption: map['caption'] as String?,
            timestamp: (map['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
        case RemoteProtocolConstants.typeChatReply:
          return RemoteChatReplyMessage(
            id: map['id'] as String? ?? '',
            replyToId: map['replyToId'] as String?,
            text: map['text'] as String? ?? '',
            timestamp: (map['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
        case RemoteProtocolConstants.typeChatStatus:
          return RemoteChatStatusMessage(
            status: map['status'] as String? ?? '',
            text: map['text'] as String? ?? '',
            timestamp: (map['timestamp'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

class RemoteTapCommand extends RemoteCommand {
  final double x; // Normalized 0.0 - 1.0
  final double y; // Normalized 0.0 - 1.0

  const RemoteTapCommand({required this.x, required this.y})
      : super(RemoteProtocolConstants.typeTap);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'x': x,
        'y': y,
      };
}

class RemoteLongPressCommand extends RemoteCommand {
  final double x;
  final double y;
  final int durationMs;

  const RemoteLongPressCommand({
    required this.x,
    required this.y,
    this.durationMs = 700,
  }) : super(RemoteProtocolConstants.typeLongPress);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'x': x,
        'y': y,
        'duration': durationMs,
      };
}

class RemoteSwipeCommand extends RemoteCommand {
  final double startX;
  final double startY;
  final double endX;
  final double endY;
  final int durationMs;

  const RemoteSwipeCommand({
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
    this.durationMs = 300,
  }) : super(RemoteProtocolConstants.typeSwipe);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'startX': startX,
        'startY': startY,
        'endX': endX,
        'endY': endY,
        'duration': durationMs,
      };
}

class RemoteKeyCommand extends RemoteCommand {
  final String key;

  const RemoteKeyCommand({required this.key})
      : super(RemoteProtocolConstants.typeKey);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'key': key,
      };
}

class RemoteTextCommand extends RemoteCommand {
  final String text;

  const RemoteTextCommand({required this.text})
      : super(RemoteProtocolConstants.typeText);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'text': text,
      };
}

class RemotePingCommand extends RemoteCommand {
  final int clientTimestamp;

  const RemotePingCommand({required this.clientTimestamp})
      : super(RemoteProtocolConstants.typePing);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        't': clientTimestamp,
      };
}

class RemotePongCommand extends RemoteCommand {
  final int clientTimestamp;

  const RemotePongCommand({required this.clientTimestamp})
      : super(RemoteProtocolConstants.typePong);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        't': clientTimestamp,
      };
}

class RemotePointerMoveCommand extends RemoteCommand {
  final double x;
  final double y;

  const RemotePointerMoveCommand({required this.x, required this.y})
      : super(RemoteProtocolConstants.typePointerMove);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'x': x,
        'y': y,
      };
}

class RemoteScrollCommand extends RemoteCommand {
  final double deltaX;
  final double deltaY;

  const RemoteScrollCommand({required this.deltaX, required this.deltaY})
      : super(RemoteProtocolConstants.typeScroll);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'deltaX': deltaX,
        'deltaY': deltaY,
      };
}

class RemoteHandoverCommand extends RemoteCommand {
  final String owner; // 'automation' or 'remote_human'

  const RemoteHandoverCommand({required this.owner})
      : super(RemoteProtocolConstants.typeHandover);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'owner': owner,
      };
}

class RemoteDisconnectCommand extends RemoteCommand {
  const RemoteDisconnectCommand()
      : super(RemoteProtocolConstants.typeDisconnect);

  @override
  Map<String, dynamic> toJson() => {'type': type};
}

class RemoteDimensionsCommand extends RemoteCommand {
  final int width;
  final int height;
  final double density;

  const RemoteDimensionsCommand({
    required this.width,
    required this.height,
    required this.density,
  }) : super(RemoteProtocolConstants.typeDimensions);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'width': width,
        'height': height,
        'density': density,
      };
}

class RemoteChatTextMessage extends RemoteCommand {
  final String id;
  final String text;
  final String? senderName;
  final int timestamp;

  const RemoteChatTextMessage({
    required this.id,
    required this.text,
    this.senderName,
    required this.timestamp,
  }) : super(RemoteProtocolConstants.typeChatText);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'text': text,
        if (senderName != null) 'senderName': senderName,
        'timestamp': timestamp,
      };
}

class RemoteChatMediaChunk extends RemoteCommand {
  final String mediaId;
  final String messageId;
  final String mediaType; // 'image', 'audio', 'video'
  final String fileName;
  final String? mimeType;
  final int chunkIndex;
  final int totalChunks;
  final String data; // Base64 chunk
  final String? caption;
  final int timestamp;

  const RemoteChatMediaChunk({
    required this.mediaId,
    required this.messageId,
    required this.mediaType,
    required this.fileName,
    this.mimeType,
    required this.chunkIndex,
    required this.totalChunks,
    required this.data,
    this.caption,
    required this.timestamp,
  }) : super(RemoteProtocolConstants.typeChatMediaChunk);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'mediaId': mediaId,
        'messageId': messageId,
        'mediaType': mediaType,
        'fileName': fileName,
        if (mimeType != null) 'mimeType': mimeType,
        'chunkIndex': chunkIndex,
        'totalChunks': totalChunks,
        'data': data,
        if (caption != null) 'caption': caption,
        'timestamp': timestamp,
      };
}

class RemoteChatReplyMessage extends RemoteCommand {
  final String id;
  final String? replyToId;
  final String text;
  final int timestamp;

  const RemoteChatReplyMessage({
    required this.id,
    this.replyToId,
    required this.text,
    required this.timestamp,
  }) : super(RemoteProtocolConstants.typeChatReply);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        if (replyToId != null) 'replyToId': replyToId,
        'text': text,
        'timestamp': timestamp,
      };
}

class RemoteChatStatusMessage extends RemoteCommand {
  final String status; // 'typing', 'transcribing', 'validating', 'publishing', 'done', 'error'
  final String text;
  final int timestamp;

  const RemoteChatStatusMessage({
    required this.status,
    required this.text,
    required this.timestamp,
  }) : super(RemoteProtocolConstants.typeChatStatus);

  @override
  Map<String, dynamic> toJson() => {
        'type': type,
        'status': status,
        'text': text,
        'timestamp': timestamp,
      };
}
