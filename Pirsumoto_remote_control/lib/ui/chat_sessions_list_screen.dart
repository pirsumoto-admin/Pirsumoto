import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:publication_protocol/publication_protocol.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../signaling/controller_signaling.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'app_theme.dart';
import 'chat_session_manager.dart';
import 'remote_control_screen.dart';
import 'whatsapp_chat_screen.dart';

class ChatSessionsListScreen extends StatefulWidget {
  final String deviceId, deviceName;
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
  StreamSubscription? _sub;
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};
  @override
  void initState() {
    super.initState();
    ChatSessionManager.watchDevice(widget.deviceId);
    _sub = ChatSessionManager.changes
        .where((d) => d == widget.deviceId)
        .listen((_) => _load());
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sessions = await ChatSessionManager.getSessions(widget.deviceId);
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _act(ChatSession session, Future<void> Function() action) async {
    if (_busy.contains(session.id)) return;
    setState(() => _busy.add(session.id));
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(session.id));
    }
  }

  void _open(String? id) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => WhatsAppChatScreen(
              deviceId: widget.deviceId,
              deviceName: widget.deviceName,
              session: widget.session,
              sessionId: id,
            ),
          ),
        )
        .then((_) => _load());
  }

  Future<void> _switchToRemoteControl() async {
    ControllerWebRtcSession? session = widget.session;
    if (session == null || !session.isConnected) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('מתחבר לשליטה מרחוק במסך (WebRTC)...'),
            duration: Duration(seconds: 2),
            backgroundColor: Color(0xFF1F2C34),
          ),
        );
        final user = FirebaseAuth.instance.currentUser;
        final controllerId =
            user?.displayName ??
            'Controller_${DateTime.now().millisecondsSinceEpoch % 1000}';
        final signaling = ControllerSignalingClient(
          deviceId: widget.deviceId,
          controllerId: controllerId,
        );
        session = ControllerWebRtcSession(
          signaling: signaling,
          sessionType: 'remote_control',
        );
        await session.initRenderer();
        session.connect();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('שגיאה בהתחברות לשליטה מרחוק: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RemoteControlScreen(
          session: session!,
          deviceName: widget.deviceName,
          ownsSession: true,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _confirmCancelAndDeleteAllNonActive(
    List<ChatSession> nonActiveSessions,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'מחיקת שיחות לא פעילות',
          textDirection: TextDirection.rtl,
        ),
        content: Text(
          'האם לבטל ולמחוק ${nonActiveSessions.length} שיחות שאינן פעילות בריצה?\nפעולה זו תמחק טיוטות ושיחות שהסתיימו, שנכשלו או שבוטלו.',
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ביטול'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('מחק הכל'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _loading = true);
    int deleted = 0;
    try {
      for (final s in nonActiveSessions) {
        try {
          await ChatSessionManager.deleteSession(widget.deviceId, s.id);
          deleted++;
        } catch (e) {
          debugPrint('[ChatSessionsList] Error deleting session ${s.id}: $e');
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('נמחקו $deleted שיחות לא פעילות'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        await _load();
      }
    }
  }

  String _label(ChatSessionStatus s) => switch (s) {
    ChatSessionStatus.draft => 'טיוטה',
    ChatSessionStatus.waiting => 'ממתין בתור',
    ChatSessionStatus.preparing => 'מכין תמונות',
    ChatSessionStatus.running => 'מפרסם',
    ChatSessionStatus.paused => 'מושהה',
    ChatSessionStatus.error => 'נתקע — נדרשת בדיקה',
    ChatSessionStatus.canceling => 'מבטל — ממתין לאישור',
    ChatSessionStatus.canceled => 'בוטל',
    ChatSessionStatus.failed => 'נכשל',
    ChatSessionStatus.done => 'פורסם',
  };

  (Color, Color, Color) _statusColors(ChatSessionStatus s) => switch (s) {
    ChatSessionStatus.draft => (
      AppColors.surfaceSubtle,
      AppColors.border,
      AppColors.secondary,
    ),
    ChatSessionStatus.waiting => (
      AppColors.warningSoft,
      AppColors.warning,
      AppColors.warning,
    ),
    ChatSessionStatus.preparing => (
      AppColors.primarySoft,
      AppColors.primary,
      AppColors.primaryAction,
    ),
    ChatSessionStatus.running => (
      AppColors.successSoft,
      AppColors.success,
      AppColors.success,
    ),
    ChatSessionStatus.paused => (
      AppColors.warningSoft,
      AppColors.warning,
      AppColors.warning,
    ),
    ChatSessionStatus.error => (
      AppColors.errorSoft,
      AppColors.error,
      AppColors.error,
    ),
    ChatSessionStatus.canceling => (
      AppColors.warningSoft,
      AppColors.warning,
      AppColors.warning,
    ),
    ChatSessionStatus.canceled => (
      AppColors.offlineSoft,
      AppColors.offline,
      AppColors.offline,
    ),
    ChatSessionStatus.failed => (
      AppColors.errorSoft,
      AppColors.error,
      AppColors.error,
    ),
    ChatSessionStatus.done => (
      Color(0xFFE8F1FC),
      AppColors.focus,
      AppColors.focus,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final nonActiveSessions = _sessions.where((s) {
      final r = ChatSessionManager.request(widget.deviceId, s.id);
      final isRunning =
          r != null &&
          !PublicationState.terminal.contains(r['state']) &&
          r['state'] != 'canceled';
      return !isRunning;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('בקשות פרסום — ${widget.deviceName}'),
        actions: [
          if (nonActiveSessions.isNotEmpty)
            IconButton(
              tooltip: 'בטל ומחק שיחות לא פעילות',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () =>
                  _confirmCancelAndDeleteAllNonActive(nonActiveSessions),
            ),
          IconButton(
            tooltip: 'ייבוא היסטוריה מהגרסה הקודמת',
            icon: const Icon(Icons.history),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                final count = await ChatSessionManager.importLegacyDevice(
                  widget.deviceId,
                );
                if (mounted) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'יובאו $count שיחות. בקשות ישנות לא מופעלות מחדש.',
                      ),
                    ),
                  );
                }
                await _load();
              } catch (e) {
                if (mounted) {
                  messenger.showSnackBar(SnackBar(content: Text('$e')));
                }
              }
            },
          ),
        ],
      ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => _open(null),
      child: const Icon(Icons.add),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(child: Text(_error!))
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: _sessions.isEmpty ? 1 : _sessions.length,
              itemBuilder: (context, index) {
                if (_sessions.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text('אין בקשות. לחץ + להוספת רכב.'),
                  );
                }
                final s = _sessions[index],
                    r = ChatSessionManager.request(
                      widget.deviceId,
                      _sessions[index].id,
                    );
                final status = ChatSessionManager.effectiveStatus(s, r);
                final isRunning =
                    r != null &&
                    !PublicationState.terminal.contains(r['state']) &&
                    r['state'] != 'canceled';
                final canStart = ChatSessionManager.canStartPublication(
                  s,
                  status,
                );
                final title = [
                  s.vehicleData['maker'],
                  s.vehicleData['model'],
                  s.vehicleData['year'],
                ].whereType<String>().join(' ');
                final (statusBg, statusBorder, statusText) = _statusColors(
                  status,
                );
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  elevation: 0.5,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppColors.border, width: 0.8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _open(s.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Left side: Vehicle info and details
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${s.licensePlate.isEmpty ? 'רכב חדש' : s.licensePlate}  $title',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${s.vehicleData['price'] ?? '—'} ₪ · ${s.vehicleData['km'] ?? '—'} ק״מ',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.secondary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (s.lastMessage != null &&
                                    s.lastMessage!.trim().isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    s.lastMessage!.trim(),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.secondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Right side: Status badge on top, trash/action buttons below
                          if (_busy.contains(s.id))
                            const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: statusBg,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: statusBorder,
                                      width: 1,
                                    ),
                                  ),
                                  child: Text(
                                    status == ChatSessionStatus.waiting
                                        ? ChatSessionManager.queueLabel(
                                            widget.deviceId,
                                            s.id,
                                          )
                                        : _label(status),
                                    style: TextStyle(
                                      color: statusText,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isRunning) ...[
                                      Tooltip(
                                        message: 'שליטה מרחוק במסך',
                                        child: TextButton.icon(
                                          icon: const Icon(
                                            Icons.screen_share_outlined,
                                            color: AppColors.onSurface,
                                            size: 15,
                                          ),
                                          label: Text(
                                            'שליטה',
                                            style: GoogleFonts.heebo(
                                              color: AppColors.onSurface,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            backgroundColor:
                                                AppColors.surfaceSubtle,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              side: const BorderSide(
                                                color: AppColors.border,
                                              ),
                                            ),
                                          ),
                                          onPressed: _switchToRemoteControl,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Tooltip(
                                        message: 'עצור פרסום',
                                        child: TextButton.icon(
                                          icon: const Icon(
                                            Icons.stop_circle_outlined,
                                            color: AppColors.error,
                                            size: 15,
                                          ),
                                          label: Text(
                                            'עצור',
                                            style: GoogleFonts.heebo(
                                              color: AppColors.error,
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3,
                                            ),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            backgroundColor:
                                                AppColors.errorSoft,
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              side: BorderSide(
                                                color: AppColors.error
                                                    .withValues(alpha: 0.3),
                                              ),
                                            ),
                                          ),
                                          onPressed: () => _act(
                                            s,
                                            () => ChatSessionManager.control(
                                              widget.deviceId,
                                              s.id,
                                              'cancel',
                                            ),
                                          ),
                                        ),
                                      ),
                                    ] else ...[
                                      if (canStart) ...[
                                        Tooltip(
                                          message:
                                              status == ChatSessionStatus.done
                                              ? 'פרסם שוב'
                                              : 'התחל פרסום',
                                          child: TextButton.icon(
                                            icon: const Icon(
                                              Icons.play_circle_outline_rounded,
                                              color: AppColors.success,
                                              size: 15,
                                            ),
                                            label: Text(
                                              status == ChatSessionStatus.done
                                                  ? 'פרסם שוב'
                                                  : 'התחל',
                                              style: GoogleFonts.heebo(
                                                color: AppColors.success,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: TextButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                                  ),
                                              minimumSize: Size.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              backgroundColor:
                                                  status ==
                                                      ChatSessionStatus.done
                                                  ? AppColors.warningSoft
                                                  : AppColors.successSoft,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                side: BorderSide(
                                                  color: AppColors.success
                                                      .withValues(alpha: 0.3),
                                                ),
                                              ),
                                            ),
                                            onPressed: _busy.contains(s.id)
                                                ? null
                                                : () => _act(
                                                    s,
                                                    () =>
                                                        ChatSessionManager.startPublication(
                                                          widget.deviceId,
                                                          s,
                                                        ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      if (status != ChatSessionStatus.canceled) ...[
                                        Tooltip(
                                          message: 'בטל שיחה/פרסום',
                                          child: TextButton.icon(
                                            icon: const Icon(
                                              Icons.cancel_outlined,
                                              color: AppColors.offline,
                                              size: 15,
                                            ),
                                            label: Text(
                                              'בטל',
                                              style: GoogleFonts.heebo(
                                                color: AppColors.offline,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            style: TextButton.styleFrom(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 8,
                                                    vertical: 3,
                                              ),
                                              minimumSize: Size.zero,
                                              tapTargetSize:
                                                  MaterialTapTargetSize
                                                      .shrinkWrap,
                                              backgroundColor:
                                                  AppColors.surfaceSubtle,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                side: const BorderSide(
                                                  color: AppColors.border,
                                                ),
                                              ),
                                            ),
                                            onPressed: _busy.contains(s.id)
                                                ? null
                                                : () => _act(
                                                    s,
                                                    () =>
                                                        ChatSessionManager.control(
                                                          widget.deviceId,
                                                          s.id,
                                                          'cancel',
                                                        ),
                                                  ),
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      IconButton(
                                        tooltip: 'מחק',
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          color: AppColors.error,
                                        ),
                                        iconSize: 20,
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.all(4),
                                        constraints: const BoxConstraints(
                                          minWidth: 32,
                                          minHeight: 32,
                                        ),
                                        onPressed: _busy.contains(s.id)
                                            ? null
                                            : () => _act(
                                                s,
                                                () =>
                                                    ChatSessionManager.deleteSession(
                                                      widget.deviceId,
                                                      s.id,
                                                    ),
                                              ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
    );
  }
}
