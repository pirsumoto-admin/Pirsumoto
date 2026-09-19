import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' as intl;
import 'app_theme.dart';
import 'chat_session_manager.dart';
import 'whatsapp_chat_screen.dart';
import '../webrtc/controller_webrtc_session.dart';
import '../database/sqlite_database_helper.dart';
import '../services/remote_llm_service.dart';

class ChatSessionsListScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final ControllerWebRtcSession? session;

  const ChatSessionsListScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    this.session,
  });

  @override
  State<ChatSessionsListScreen> createState() => _ChatSessionsListScreenState();
}

class _ChatSessionsListScreenState extends State<ChatSessionsListScreen> {
  List<ChatSession> _sessions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() => _isLoading = true);
    final sessions = await ChatSessionManager.getSessions(widget.deviceId);
    if (mounted) {
      setState(() {
        _sessions = sessions;
        _isLoading = false;
      });
    }
    _runLlmExtraction(sessions);
  }

  Future<void> _runLlmExtraction(List<ChatSession> currentSessions) async {
    bool updated = false;
    for (var session in currentSessions) {
      if (session.licensePlate.isEmpty) {
        final messages = await SqliteDatabaseHelper.instance.getMessages(session.id);
        if (messages.isNotEmpty) {
          final extracted = await RemoteLlmService.extractLicensePlate(messages);
          if (extracted != null && extracted.isNotEmpty) {
            session.licensePlate = extracted;
            await ChatSessionManager.saveSession(session);
            updated = true;
          }
        }
      }
    }
    if (updated && mounted) {
      final refreshed = await ChatSessionManager.getSessions(widget.deviceId);
      setState(() {
        _sessions = refreshed;
      });
    }
  }

  Future<void> _deleteSession(String sessionId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'מחיקת שיחה',
          style: GoogleFonts.heebo(color: AppColors.onSurface, fontWeight: FontWeight.bold),
          textDirection: TextDirection.rtl,
        ),
        content: Text(
          'האם אתה בטוח שברצונך למחוק שיחה זו?',
          style: GoogleFonts.heebo(color: AppColors.secondary),
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('ביטול', style: GoogleFonts.heebo(color: AppColors.secondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: Text('מחק', style: GoogleFonts.heebo(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ChatSessionManager.deleteSession(widget.deviceId, sessionId);
      _loadSessions();
    }
  }

  void _openChat(String? sessionId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => WhatsAppChatScreen(
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          session: widget.session,
          sessionId: sessionId,
        ),
      ),
    ).then((_) => _loadSessions()); // Reload on return in case of updates
  }

  String _formatStatus(ChatSessionStatus status) {
    switch (status) {
      case ChatSessionStatus.running:
        return 'בתהליך';
      case ChatSessionStatus.waiting:
        return 'ממתין';
      case ChatSessionStatus.done:
        return 'הסתיים';
    }
  }

  Color _getStatusColor(ChatSessionStatus status) {
    switch (status) {
      case ChatSessionStatus.running:
        return Colors.blue;
      case ChatSessionStatus.waiting:
        return Colors.orange;
      case ChatSessionStatus.done:
        return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.neutral,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: Text(
          'שיחות - ${widget.deviceName}',
          style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
        ),
        centerTitle: true,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _sessions.isEmpty
              ? Center(
                  child: Text(
                    'אין שיחות פעילות.\nלחץ על ה- + כדי להתחיל שיחה חדשה.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.heebo(color: AppColors.secondary, fontSize: 16),
                    textDirection: TextDirection.rtl,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final dateStr = intl.DateFormat('dd/MM/yyyy HH:mm')
                        .format(DateTime.fromMillisecondsSinceEpoch(session.startTimestamp));
                    
                    return Card(
                      color: AppColors.surface,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        onTap: () => _openChat(session.id),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              session.licensePlate.isNotEmpty ? 'רישוי: ${session.licensePlate}' : 'שיחה חדשה',
                              style: GoogleFonts.heebo(
                                color: AppColors.onSurface,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                              textDirection: TextDirection.rtl,
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: _getStatusColor(session.status).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                _formatStatus(session.status),
                                style: GoogleFonts.heebo(
                                  color: _getStatusColor(session.status),
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                dateStr,
                                style: GoogleFonts.heebo(color: AppColors.secondary, fontSize: 12),
                              ),
                              if (session.lastMessage != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    session.lastMessage!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.heebo(color: AppColors.secondary),
                                    textDirection: TextDirection.rtl,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        leading: IconButton(
                          icon: const Icon(Icons.delete, color: AppColors.error),
                          onPressed: () => _deleteSession(session.id),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openChat(null), // null creates a new session
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat, // Bottom right in RTL
    );
  }
}
