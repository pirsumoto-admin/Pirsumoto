import 'package:flutter/material.dart';
import 'remote_receiver_service.dart';
import 'remote_session_state.dart';

/// A subtle, non-intrusive status pill displayed at the top of the screen
/// when an active remote control session is running.
///
/// This serves two critical purposes:
/// 1. Security & transparency: User clearly sees their phone is being remotely managed.
/// 2. Stream liveness: The gentle pulse animation keeps Android's VirtualDisplay active
///    and prevents MediaCodec hardware encoders from timing out during static screens.
class RemoteControlActiveBanner extends StatefulWidget {
  const RemoteControlActiveBanner({super.key});

  @override
  State<RemoteControlActiveBanner> createState() => _RemoteControlActiveBannerState();
}

class _RemoteControlActiveBannerState extends State<RemoteControlActiveBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = RemoteControlReceiverService.instance.manager;
    if (manager == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final isActive = manager.sessionInfo.state == RemoteSessionState.active;
        if (!isActive) return const SizedBox.shrink();

        return Positioned(
          top: MediaQuery.paddingOf(context).top + 8,
          right: 16,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => manager.terminateSession(),
              borderRadius: BorderRadius.circular(20),
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xCC161B22),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF238636), width: 1.2),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF238636).withValues(alpha: 0.35),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, _) {
                    return Icon(
                      Icons.videocam_rounded,
                      size: 16,
                      color: Color.fromRGBO(
                        35,
                        134,
                        54,
                        _pulseAnimation.value,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
