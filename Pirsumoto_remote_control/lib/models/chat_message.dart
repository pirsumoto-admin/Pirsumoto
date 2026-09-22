enum ChatSender { user, bot }

class ChatMessageItem {
  final String id;
  final ChatSender sender;
  final String text;
  final String? mediaType; // 'image', 'audio', 'video'
  final String? localFilePath;
  final String? mediaUrl;
  final String? caption;
  final DateTime timestamp;
  double uploadProgress;
  bool isUploading;
  Duration? audioDuration;

  ChatMessageItem({
    required this.id,
    required this.sender,
    this.text = '',
    this.mediaType,
    this.localFilePath,
    this.mediaUrl,
    this.caption,
    required this.timestamp,
    this.uploadProgress = 1.0,
    this.isUploading = false,
    this.audioDuration,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender == ChatSender.user ? 'user' : 'bot',
      'text': text,
      'mediaType': mediaType,
      'localFilePath': localFilePath,
      'mediaUrl': mediaUrl,
      'caption': caption,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'audioDurationMs': audioDuration?.inMilliseconds,
    };
  }

  factory ChatMessageItem.fromJson(Map<String, dynamic> json) {
    return ChatMessageItem(
      id:
          json['id'] as String? ??
          'msg_${DateTime.now().microsecondsSinceEpoch}',
      sender: _readSender(json),
      text: json['text'] as String? ?? '',
      mediaType: json['mediaType'] as String?,
      localFilePath: json['localFilePath'] as String?,
      mediaUrl: json['mediaUrl'] as String?,
      caption: json['caption'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        json['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ),
      uploadProgress: 1.0,
      isUploading: false,
      audioDuration: json['audioDurationMs'] != null
          ? Duration(milliseconds: json['audioDurationMs'] as int)
          : null,
    );
  }

  static ChatSender _readSender(Map<String, dynamic> json) {
    // Keep explicit authorship, including user messages quoting the bot.
    if (json['sender'] == 'user') return ChatSender.user;
    if (json['sender'] == 'bot') return ChatSender.bot;
    for (final field in ['isFromUser', 'fromUser']) {
      if (json[field] is bool) {
        return json[field] == true ? ChatSender.user : ChatSender.bot;
      }
    }

    // Recover authorship in older saved messages without sender metadata.
    final text = (json['text'] as String? ?? '').trimLeft();
    if (RegExp(r'^🤖\s*פירסומוטו').hasMatch(text)) return ChatSender.bot;
    final id = json['id'] as String? ?? '';
    if (['msg_', 'img_', 'vid_', 'audio_'].any(id.startsWith)) {
      return ChatSender.user;
    }
    return ChatSender.bot;
  }
}
