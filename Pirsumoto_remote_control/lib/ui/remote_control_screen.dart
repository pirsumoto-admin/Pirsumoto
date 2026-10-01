import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../remote/coordinate_mapper.dart';
import '../webrtc/controller_webrtc_session.dart';
import 'app_theme.dart';
import 'touch_feedback_overlay.dart';
import 'remote_keyboard_handler.dart';

class RemoteControlScreen extends StatefulWidget {
  final ControllerWebRtcSession session;
  final String deviceName;

  const RemoteControlScreen({
    super.key,
    required this.session,
    required this.deviceName,
  });

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  final GlobalKey<TouchFeedbackOverlayState> _touchOverlayKey = GlobalKey();

  Offset? _panStartLocal;
  Offset? _panCurrentLocal;
  Offset? _panStartNormalized;

  bool _isHumanControl = false;

  @override
  void dispose() {
    if (_isHumanControl) {
      widget.session.sendHandover('automation');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.neutral,
          appBar: AppBar(
            backgroundColor: AppColors.surface,
            elevation: 0,
            centerTitle: true,
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(1),
              child: Divider(height: 1, color: AppColors.border),
            ),
            leading: IconButton(
              icon: const Icon(
                Icons.chevron_left_rounded,
                size: 28,
                color: AppColors.onSurface,
              ),
              onPressed: () => Navigator.of(context).pop(),
            ),

            // Center: Device Name (e.g. xiaomi A30)
            title: Text(
              widget.deviceName,
              textDirection: TextDirection.ltr,
              style: GoogleFonts.heebo(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),

            // Physical top left (actions in RTL): Live Stream Indicator
            actions: [
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Center(child: _buildCameraIndicator()),
              ),
            ],
          ),
          body: SafeArea(
            child: RemoteKeyboardHandler(
              onSendText: (text) {
                if (_isHumanControl) widget.session.sendText(text);
              },
              onSendKey: (key) {
                if (_isHumanControl) widget.session.sendKey(key);
              },
              child: Builder(
                builder: (context) {
                  return Column(
                    children: [
                      // Video Stream Viewport
                      Expanded(
                        child: _buildVideoArea(context),
                      ),

                      // Fixed Bottom Toolbar (4 columns in RTL order)
                      _buildBottomToolbar(context),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCameraIndicator() {
    if (!widget.session.isConnected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.warningSoft,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              'מתחבר...',
              style: GoogleFonts.heebo(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.warning,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.errorSoft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_rounded,
            size: 14,
            color: AppColors.error,
          ),
          const SizedBox(width: 4),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.error,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'שידור חי',
            style: GoogleFonts.heebo(
              color: AppColors.error,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoArea(BuildContext context) {
    if (!widget.session.isConnected && !widget.session.isConnecting) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.signal_cellular_connected_no_internet_4_bar_rounded,
              size: 48,
              color: AppColors.secondary,
            ),
            const SizedBox(height: 14),
            Text(
              widget.session.errorMessage ?? 'החיבור הסתיים',
              style: GoogleFonts.heebo(color: AppColors.secondary, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => widget.session.connect(),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(
                'התחבר מחדש',
                style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primaryAction,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final containerSize = Size(constraints.maxWidth, constraints.maxHeight);
        final aspectRatio = widget.session.remoteAspectRatio;

        return Stack(
          alignment: Alignment.topCenter,
          children: [
            TouchFeedbackOverlay(
              key: _touchOverlayKey,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) {
                  if (!_isHumanControl) return;
                  _touchOverlayKey.currentState?.addTouchRipple(details.localPosition);
                },
                onTapUp: (details) {
                  if (!_isHumanControl) {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'יש ללחוץ על "קבלת שליטה" כדי לשלוט במכשיר',
                          style: GoogleFonts.heebo(color: Colors.black87),
                        ),
                        backgroundColor: AppColors.surfaceSubtle,
                        duration: const Duration(milliseconds: 1500),
                      ),
                    );
                    return;
                  }
                  final norm = CoordinateMapper.mapLocalToNormalized(
                    localPosition: details.localPosition,
                    containerSize: containerSize,
                    videoAspectRatio: aspectRatio,
                  );
                  if (norm != null) {
                    widget.session.sendTap(norm.dx, norm.dy);
                  }
                },
                onLongPressStart: (details) {
                  if (!_isHumanControl) return;
                  _touchOverlayKey.currentState?.addTouchRipple(details.localPosition);

                  final norm = CoordinateMapper.mapLocalToNormalized(
                    localPosition: details.localPosition,
                    containerSize: containerSize,
                    videoAspectRatio: aspectRatio,
                  );
                  if (norm != null) {
                    widget.session.sendLongPress(norm.dx, norm.dy, durationMs: 700);
                  }
                },
                onPanStart: (details) {
                  if (!_isHumanControl) return;
                  _panStartLocal = details.localPosition;
                  _panCurrentLocal = details.localPosition;
                  _panStartNormalized = CoordinateMapper.mapLocalToNormalized(
                    localPosition: details.localPosition,
                    containerSize: containerSize,
                    videoAspectRatio: aspectRatio,
                  );
                },
                onPanUpdate: (details) {
                  if (!_isHumanControl) return;
                  _panCurrentLocal = details.localPosition;
                },
                onPanEnd: (details) {
                  if (!_isHumanControl) return;
                  if (_panStartLocal != null && _panCurrentLocal != null) {
                    final totalDistance = (_panCurrentLocal! - _panStartLocal!).distance;
                    final velocity = details.velocity.pixelsPerSecond;

                    if (totalDistance >= 25.0 || velocity.distance >= 250.0) {
                      final endNormalized = CoordinateMapper.mapLocalToNormalized(
                        localPosition: _panCurrentLocal!,
                        containerSize: containerSize,
                        videoAspectRatio: aspectRatio,
                      );

                      if (_panStartNormalized != null && endNormalized != null) {
                        widget.session.sendSwipe(
                          _panStartNormalized!.dx,
                          _panStartNormalized!.dy,
                          endNormalized.dx,
                          endNormalized.dy,
                          durationMs: 250,
                        );
                      }
                    }
                  }

                  _panStartLocal = null;
                  _panCurrentLocal = null;
                  _panStartNormalized = null;
                },
                child: Container(
                  color: Colors.black,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: aspectRatio,
                      child: RTCVideoView(
                        widget.session.videoRenderer,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _handleClearAndResetSession() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(
          'ניקוי הצ\'אט ואתחול סשן',
          style: GoogleFonts.heebo(
            color: AppColors.onSurface,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Text(
          'פעולה זו תמחק את כל היסטוריית ההודעות בצ\'אט ותאתחל סשן חדש ונקי מול המכשיר.',
          style: GoogleFonts.heebo(color: AppColors.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'ביטול',
              style: GoogleFonts.heebo(color: AppColors.secondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'ניקוי ואתחול',
              style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final deviceId = widget.session.signaling.deviceId;

    // 1. Clear SharedPreferences local chat storage
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('chat_messages_$deviceId');
    } catch (e) {
      debugPrint('[RemoteControl] Error clearing local prefs: $e');
    }

    // 2. Clear Firestore messages for this device
    try {
      final msgs = await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(deviceId)
          .collection('messages')
          .get();
      if (msgs.docs.isNotEmpty) {
        const chunkSize = 400;
        for (var i = 0; i < msgs.docs.length; i += chunkSize) {
          final batch = FirebaseFirestore.instance.batch();
          final end =
              (i + chunkSize < msgs.docs.length)
                  ? i + chunkSize
                  : msgs.docs.length;
          for (var j = i; j < end; j++) {
            batch.delete(msgs.docs[j].reference);
          }
          await batch.commit();
        }
      }
    } catch (e) {
      debugPrint('[RemoteControl] Error clearing Firestore messages: $e');
    }

    // 3. Send reset command to receiver via WebRTC (if connected)
    try {
      widget.session.sendReset();
    } catch (_) {}

    // 4. Send reset instruction to Firestore so FirebaseChatReceiver resets as well
    try {
      final messageId = 'reset_${DateTime.now().millisecondsSinceEpoch}';
      await FirebaseFirestore.instance
          .collection('remote_chats')
          .doc(deviceId)
          .collection('messages')
          .doc(messageId)
          .set({
        'id': messageId,
        'sender': 'user',
        'type': 'reset',
        'text': '',
        'status': 'pending',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'הצ\'אט נוקה והסשן אותחל מחדש',
            style: GoogleFonts.heebo(color: Colors.black87),
          ),
          backgroundColor: AppColors.surfaceSubtle,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _buildBottomToolbar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(
          top: BorderSide(color: AppColors.border, width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // 1. Back (חזרה) - Physical Right in RTL
          _buildActionButton(
            icon: Icons.arrow_forward_rounded, // Right-pointing back arrow in RTL
            label: 'חזרה',
            color: _isHumanControl ? AppColors.onSurface : AppColors.secondary,
            onTap: () {
              if (!_isHumanControl) {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'יש ללחוץ על "קבלת שליטה" כדי לשלוט במכשיר',
                      style: GoogleFonts.heebo(color: Colors.black87),
                    ),
                    backgroundColor: AppColors.surfaceSubtle,
                    duration: const Duration(milliseconds: 1500),
                  ),
                );
                return;
              }
              widget.session.sendBack();
            },
          ),

          // 2. Control Pointer (קבלת שליטה / שחרור שליטה)
          _buildActionButton(
            icon: Icons.touch_app_rounded,
            label: _isHumanControl ? 'שחרור שליטה' : 'קבלת שליטה',
            color: _isHumanControl ? AppColors.primaryAction : AppColors.secondary,
            isHighlighted: _isHumanControl,
            onTap: () {
              final nextState = !_isHumanControl;
              setState(() {
                _isHumanControl = nextState;
              });
              widget.session.sendHandover(
                nextState ? 'remote_human' : 'automation',
              );
            },
          ),

          // 3. Clear (ניקוי) - Clean chat & reset session
          _buildActionButton(
            icon: Icons.delete_outline_rounded,
            label: 'ניקוי',
            color: AppColors.onSurface,
            onTap: _handleClearAndResetSession,
          ),

          // 4. Disconnect (ניתוק) - Physical Left in RTL
          _buildActionButton(
            icon: Icons.call_end_rounded,
            label: 'ניתוק',
            color: AppColors.error,
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: AppColors.surface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  title: Text(
                    'ניתוק חיבור',
                    style: GoogleFonts.heebo(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  content: Text(
                    'האם ברצונך לנתק את החיבור לשליטה מרחוק ולסגור את הסשן?',
                    style: GoogleFonts.heebo(color: AppColors.secondary),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text(
                        'ביטול',
                        style: GoogleFonts.heebo(color: AppColors.secondary),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.error,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        'ניתוק',
                        style: GoogleFonts.heebo(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );

              if (confirm == true && context.mounted) {
                final nav = Navigator.of(context);
                await widget.session.disconnect();
                nav.pop();
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = AppColors.onSurface,
    bool isHighlighted = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: isHighlighted
            ? BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              )
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 3),
            Text(
              label,
              style: GoogleFonts.heebo(
                color: color,
                fontSize: 12,
                fontWeight: isHighlighted ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
