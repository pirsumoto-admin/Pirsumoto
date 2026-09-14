import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:google_fonts/google_fonts.dart';
import '../remote/coordinate_mapper.dart';
import '../webrtc/controller_webrtc_session.dart';
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
  Offset? _panLastDispatchedLocal;
  Offset? _panStartNormalized;

  bool _isHumanControl = true;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF0D1117),
          appBar: AppBar(
            backgroundColor: const Color(0xFF161B22),
            elevation: 0,
            leadingWidth: 90,
            leading: TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_ios_new, size: 14, color: Color(0xFF58A6FF)),
              label: Text(
                'צ\'אט',
                style: GoogleFonts.inter(
                  color: const Color(0xFF58A6FF),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.deviceName,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  widget.session.isConnected ? 'שליטה מרחוק פעילה' : 'מתחבר...',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: widget.session.isConnected
                        ? const Color(0xFF3FB950)
                        : Colors.amberAccent,
                  ),
                ),
              ],
            ),
            centerTitle: true,
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Center(child: _buildCameraIndicator()),
              ),
            ],
          ),
          body: SafeArea(
            child: RemoteKeyboardHandler(
              onSendText: (text) => widget.session.sendText(text),
              onSendKey: (key) => widget.session.sendKey(key),
              child: Builder(
                builder: (context) {
                  return Column(
                    children: [
                      Expanded(
                        child: _buildVideoArea(context),
                      ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC161B22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.session.isConnected
              ? const Color(0xFF238636)
              : Colors.amberAccent.withValues(alpha: 0.5),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: (widget.session.isConnected
                    ? const Color(0xFF238636)
                    : Colors.amberAccent)
                .withValues(alpha: 0.3),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_rounded,
            size: 16,
            color: widget.session.isConnected
                ? const Color(0xFF3FB950)
                : Colors.amberAccent,
          ),
          if (widget.session.isConnected && widget.session.pingMs > 0) ...[
            const SizedBox(width: 5),
            Text(
              '${widget.session.pingMs}ms',
              style: GoogleFonts.inter(
                color: const Color(0xFF8B949E),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
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
            const Icon(Icons.signal_cellular_connected_no_internet_4_bar,
                size: 48, color: Color(0xFF8B949E)),
            const SizedBox(height: 16),
            Text(
              widget.session.errorMessage ?? 'החיבור הסתיים',
              style: GoogleFonts.inter(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => widget.session.connect(),
              icon: const Icon(Icons.refresh),
              label: const Text('התחבר מחדש'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF238636),
                foregroundColor: Colors.white,
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

        return TouchFeedbackOverlay(
          key: _touchOverlayKey,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              // Trigger instant zero-latency visual touch ripple at local touch point
              _touchOverlayKey.currentState?.addTouchRipple(details.localPosition);
            },
            onTapUp: (details) {
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
              _panStartLocal = details.localPosition;
              _panCurrentLocal = details.localPosition;
              _panLastDispatchedLocal = details.localPosition;
              _panStartNormalized = CoordinateMapper.mapLocalToNormalized(
                localPosition: details.localPosition,
                containerSize: containerSize,
                videoAspectRatio: aspectRatio,
              );
            },
            onPanUpdate: (details) {
              _panCurrentLocal = details.localPosition;
              if (_panLastDispatchedLocal == null) {
                _panLastDispatchedLocal = details.localPosition;
                return;
              }

              final delta = details.localPosition - _panLastDispatchedLocal!;
              // Dispatch incremental drag every ~14 logical pixels of movement for direct-manipulation scroll
              if (delta.distance >= 14.0) {
                final fromNorm = CoordinateMapper.mapLocalToNormalized(
                  localPosition: _panLastDispatchedLocal!,
                  containerSize: containerSize,
                  videoAspectRatio: aspectRatio,
                );
                final toNorm = CoordinateMapper.mapLocalToNormalized(
                  localPosition: details.localPosition,
                  containerSize: containerSize,
                  videoAspectRatio: aspectRatio,
                );

                if (fromNorm != null && toNorm != null) {
                  widget.session.sendSwipe(
                    fromNorm.dx,
                    fromNorm.dy,
                    toNorm.dx.clamp(0.0, 1.0),
                    toNorm.dy.clamp(0.0, 1.0),
                    durationMs: 45,
                  );
                }
                _panLastDispatchedLocal = details.localPosition;
              }
            },
            onPanEnd: (details) {
              final velocity = details.velocity.pixelsPerSecond;
              // If the user flicked with significant velocity, dispatch a snappy fling
              if (velocity.distance > 120.0 && _panCurrentLocal != null) {
                final flingStartLocal = _panLastDispatchedLocal ?? _panCurrentLocal!;
                // Scale fling distance according to velocity
                final flingDistance = velocity * 0.18;
                final targetLocal = flingStartLocal + flingDistance;

                final fromNorm = CoordinateMapper.mapLocalToNormalized(
                  localPosition: flingStartLocal,
                  containerSize: containerSize,
                  videoAspectRatio: aspectRatio,
                );
                final toNorm = CoordinateMapper.mapLocalToNormalized(
                  localPosition: targetLocal,
                  containerSize: containerSize,
                  videoAspectRatio: aspectRatio,
                );

                if (fromNorm != null && toNorm != null) {
                  // Crisp 60-120ms gesture triggers Android's native smooth fling inertia
                  final durationMs = (10000.0 / velocity.distance).round().clamp(60, 120);
                  widget.session.sendSwipe(
                    fromNorm.dx,
                    fromNorm.dy,
                    toNorm.dx.clamp(0.0, 1.0),
                    toNorm.dy.clamp(0.0, 1.0),
                    durationMs: durationMs,
                  );
                }
              } else if (_panStartNormalized != null &&
                  _panStartLocal != null &&
                  _panCurrentLocal != null &&
                  _panLastDispatchedLocal == _panStartLocal) {
                // If it was a small quick drag that didn't trigger incremental threshold
                final dragDelta = _panCurrentLocal! - _panStartLocal!;
                if (dragDelta.distance >= 5.0) {
                  final toNorm = CoordinateMapper.mapLocalToNormalized(
                    localPosition: _panCurrentLocal!,
                    containerSize: containerSize,
                    videoAspectRatio: aspectRatio,
                  );
                  if (toNorm != null) {
                    widget.session.sendSwipe(
                      _panStartNormalized!.dx,
                      _panStartNormalized!.dy,
                      toNorm.dx.clamp(0.0, 1.0),
                      toNorm.dy.clamp(0.0, 1.0),
                      durationMs: 80,
                    );
                  }
                }
              }
              _panStartLocal = null;
              _panCurrentLocal = null;
              _panLastDispatchedLocal = null;
              _panStartNormalized = null;
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: aspectRatio,
                child: RTCVideoView(
                  widget.session.videoRenderer,
                  key: ValueKey<String>(
                    'rtc_remote_${widget.session.videoRenderer.textureId}_${widget.session.videoRenderer.srcObject?.id}',
                  ),
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBottomToolbar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF161B22),
        border: Border(
          top: BorderSide(color: Color(0xFF30363D), width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Device Back Button
          _buildActionButton(
            icon: Icons.arrow_back_rounded,
            label: 'חזור במכשיר',
            onTap: () => widget.session.sendBack(),
          ),

          // Device Home Button
          _buildActionButton(
            icon: Icons.home_rounded,
            label: 'בית',
            onTap: () => widget.session.sendHome(),
          ),

          // Native Keyboard Toggle
          _buildActionButton(
            icon: Icons.keyboard_rounded,
            label: 'מקלדת',
            onTap: () {
              RemoteKeyboardHandler.of(context)?.toggleKeyboard();
            },
          ),

          // Automation Handover Toggle
          _buildActionButton(
            icon: _isHumanControl ? Icons.smart_toy_outlined : Icons.touch_app_rounded,
            label: _isHumanControl ? 'העבר לבוט' : 'שליטה ידנית',
            color: _isHumanControl ? Colors.amberAccent : const Color(0xFF58A6FF),
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

          // Disconnect Button
          _buildActionButton(
            icon: Icons.power_settings_new,
            label: 'התנתק',
            color: Colors.redAccent,
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF161B22),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: const BorderSide(color: Color(0xFF30363D)),
                  ),
                  title: Text(
                    'ניתוק חיבור',
                    style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  content: Text(
                    'האם ברצונך לנתק את החיבור לשליטה מרחוק ולסגור את הסשן?',
                    style: GoogleFonts.inter(color: const Color(0xFFC9D1D9)),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text('ביטול', style: GoogleFonts.inter(color: const Color(0xFF8B949E))),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFDA3633),
                        foregroundColor: Colors.white,
                      ),
                      child: Text('התנתק', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
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
    Color color = Colors.white,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
