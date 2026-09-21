import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _liveUpdatesSub;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _listenToLiveUpdates();
  }

  @override
  void dispose() {
    _liveUpdatesSub?.cancel();
    super.dispose();
  }

  void _listenToLiveUpdates() {
    // Only listen to recent status updates
    final timestampLimit = DateTime.now().millisecondsSinceEpoch - 10000;
    
    _liveUpdatesSub = FirebaseFirestore.instance
        .collection('remote_chats')
        .doc(widget.deviceId)
        .collection('messages')
        .where('timestamp', isGreaterThan: timestampLimit)
        .snapshots()
        .listen((snapshot) async {
      bool needsReload = false;
      
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          if (data == null) continue;
          
          final type = data['type'] as String?;
          if (type == 'status') {
            final sessionId = data['sessionId'] as String?;
            if (sessionId == null) continue;
            
            final statusType = data['statusType'] as String?;
            final text = data['text'] as String?;
            
            final session = await SqliteDatabaseHelper.instance.getSession(sessionId);
            if (session != null) {
              if (statusType == 'started') {
                session.status = ChatSessionStatus.running;
                session.lastMessage = text ?? 'בתהליך פרסום';
              } else if (statusType == 'finished') {
                session.status = ChatSessionStatus.done;
                session.lastMessage = text ?? 'הושלם';
                
                // Auto advance queue
                await ChatSessionManager.advanceQueueAndStartNext(widget.deviceId, session: widget.session);
              } else if (statusType == 'stopped') {
                session.status = ChatSessionStatus.done; // or canceled
                session.lastMessage = text ?? 'הופסק';
                
                // Auto advance queue
                await ChatSessionManager.advanceQueueAndStartNext(widget.deviceId, session: widget.session);
              } else if (statusType == 'stuck') {
                session.status = ChatSessionStatus.error;
                session.lastMessage = text ?? 'נתקע';
              }
              
              await ChatSessionManager.saveSession(session);
              needsReload = true;
            }
          }
        }
      }
      
      if (needsReload && mounted) {
        _loadSessions();
      }
    });
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

  Future<void> _cancelSession(ChatSession session) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          'ביטול פרסום',
          style: GoogleFonts.heebo(color: AppColors.onSurface, fontWeight: FontWeight.bold),
          textDirection: TextDirection.rtl,
        ),
        content: Text(
          'האם אתה בטוח שברצונך לבטל את תהליך הפרסום עבור שיחה זו?',
          style: GoogleFonts.heebo(color: AppColors.secondary),
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('חזור', style: GoogleFonts.heebo(color: AppColors.secondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.warning),
            child: Text('בטל פרסום', style: GoogleFonts.heebo(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final wasRunning = session.status == ChatSessionStatus.running;
      session.status = ChatSessionStatus.done;
      session.lastMessage = 'הפרסום בוטל';
      await ChatSessionManager.saveSession(session);

      // Send cancel / reset command to remote device
      try {
        await FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(widget.deviceId)
            .collection('messages')
            .add({
              'id': 'cancel_${DateTime.now().millisecondsSinceEpoch}',
              'sessionId': session.id,
              'sender': 'user',
              'senderName': 'Remote User',
              'text': 'ביטול',
              'type': 'message',
              'status': 'pending',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'createdAt': FieldValue.serverTimestamp(),
            });
        
        if (wasRunning) {
          await FirebaseFirestore.instance
              .collection('remote_chats')
              .doc(widget.deviceId)
              .collection('messages')
              .add({
                'id': 'reset_${DateTime.now().millisecondsSinceEpoch}',
                'sessionId': session.id,
                'sender': 'user',
                'type': 'reset',
                'status': 'pending',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'createdAt': FieldValue.serverTimestamp(),
              });
        }
      } catch (e) {
        debugPrint('[ChatSessions] Error sending cancel command to Firestore: $e');
      }

      if (wasRunning && widget.session?.isConnected == true) {
        try {
          widget.session!.sendChatMessage('ביטול', senderName: 'Remote User');
          widget.session!.sendReset();
        } catch (_) {}
      }

      // Advance queue to next waiting session
      final nextSession = await ChatSessionManager.advanceQueueAndStartNext(
        widget.deviceId,
        session: widget.session,
      );

      if (mounted) {
        if (nextSession != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'הפרסום בוטל. מתחיל פרסום עבור הרכב הבא בתור: ${nextSession.licensePlate.isNotEmpty ? nextSession.licensePlate : nextSession.id}',
                textDirection: TextDirection.rtl,
              ),
              backgroundColor: AppColors.primary,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('הפרסום בוטל בהצלחה.', textDirection: TextDirection.rtl),
              backgroundColor: AppColors.surface,
            ),
          );
        }
      }

      _loadSessions();
    }
  }

  Future<void> _deleteSession(ChatSession session) async {
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
      final wasRunning = session.status == ChatSessionStatus.running;
      await ChatSessionManager.deleteSession(widget.deviceId, session.id);
      
      try {
        await FirebaseFirestore.instance
            .collection('remote_chats')
            .doc(widget.deviceId)
            .collection('messages')
            .add({
              'id': 'del_${DateTime.now().millisecondsSinceEpoch}',
              'sessionId': session.id,
              'sender': 'user',
              'type': 'delete_session',
              'status': 'pending',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'createdAt': FieldValue.serverTimestamp(),
            });

        if (wasRunning) {
          await FirebaseFirestore.instance
              .collection('remote_chats')
              .doc(widget.deviceId)
              .collection('messages')
              .add({
                'id': 'cancel_${DateTime.now().millisecondsSinceEpoch}',
                'sessionId': session.id,
                'sender': 'user',
                'senderName': 'Remote User',
                'text': 'ביטול',
                'type': 'message',
                'status': 'pending',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'createdAt': FieldValue.serverTimestamp(),
              });
        }
      } catch (e) {
        debugPrint('[ChatSessions] Error sending delete command to Firestore: $e');
      }

      if (wasRunning && widget.session?.isConnected == true) {
        try {
          widget.session!.sendChatMessage('ביטול', senderName: 'Remote User');
          widget.session!.sendReset();
        } catch (_) {}
      }

      // If the deleted session was running (or queue can advance), start next in line
      final nextSession = await ChatSessionManager.advanceQueueAndStartNext(
        widget.deviceId,
        session: widget.session,
      );

      if (mounted) {
        if (nextSession != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'השיחה נמחקה. מתחיל פרסום עבור הרכב הבא בתור: ${nextSession.licensePlate.isNotEmpty ? nextSession.licensePlate : nextSession.id}',
                textDirection: TextDirection.rtl,
              ),
              backgroundColor: AppColors.primary,
            ),
          );
        }
      }

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
      case ChatSessionStatus.draft:
        return 'טיוטה';
      case ChatSessionStatus.running:
        return 'בתהליך';
      case ChatSessionStatus.waiting:
        return 'ממתין';
      case ChatSessionStatus.done:
        return 'הסתיים';
      case ChatSessionStatus.error:
        return 'שגיאה / נתקע';
    }
  }

  Color _getStatusColor(ChatSessionStatus status) {
    switch (status) {
      case ChatSessionStatus.draft:
        return Colors.blueGrey;
      case ChatSessionStatus.running:
        return Colors.blue;
      case ChatSessionStatus.waiting:
        return Colors.orange;
      case ChatSessionStatus.done:
        return Colors.green;
      case ChatSessionStatus.error:
        return AppColors.error;
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
                        leading: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (session.status == ChatSessionStatus.running ||
                                session.status == ChatSessionStatus.waiting)
                              IconButton(
                                icon: const Icon(Icons.cancel_outlined, color: AppColors.warning),
                                tooltip: 'ביטול פרסום',
                                onPressed: () => _cancelSession(session),
                              ),
                            if (session.status == ChatSessionStatus.waiting &&
                                !_sessions.any((s) => s.status == ChatSessionStatus.running))
                              IconButton(
                                icon: const Icon(Icons.play_arrow_rounded, color: AppColors.success),
                                tooltip: 'התחל פרסום',
                                onPressed: () async {
                                  await ChatSessionManager.startSession(widget.deviceId, session.id, session: widget.session);
                                  _loadSessions();
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, color: AppColors.error),
                              tooltip: 'מחיקת שיחה',
                              onPressed: () => _deleteSession(session),
                            ),
                          ],
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
