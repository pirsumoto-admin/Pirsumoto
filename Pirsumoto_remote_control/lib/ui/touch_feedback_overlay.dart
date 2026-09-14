import 'package:flutter/material.dart';

class TouchFeedbackItem {
  final Offset position;
  final DateTime createdAt;
  final Key key;

  TouchFeedbackItem({required this.position})
      : createdAt = DateTime.now(),
        key = UniqueKey();
}

class TouchFeedbackOverlay extends StatefulWidget {
  final Widget child;
  final Function(Offset localPosition)? onInstantTouch;

  const TouchFeedbackOverlay({
    super.key,
    required this.child,
    this.onInstantTouch,
  });

  @override
  State<TouchFeedbackOverlay> createState() => TouchFeedbackOverlayState();
}

class TouchFeedbackOverlayState extends State<TouchFeedbackOverlay> {
  final List<TouchFeedbackItem> _ripples = [];

  /// Trigger instant local touch ripple at position
  void addTouchRipple(Offset localPosition) {
    setState(() {
      _ripples.add(TouchFeedbackItem(position: localPosition));
    });

    widget.onInstantTouch?.call(localPosition);

    // Clean up ripple after animation
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) {
        setState(() {
          _ripples.removeWhere((item) =>
              DateTime.now().difference(item.createdAt).inMilliseconds > 300);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: Stack(
              children: _ripples.map((item) {
                return Positioned(
                  left: item.position.dx - 24,
                  top: item.position.dy - 24,
                  child: _TouchRippleAnimation(key: item.key),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _TouchRippleAnimation extends StatefulWidget {
  const _TouchRippleAnimation({super.key});

  @override
  State<_TouchRippleAnimation> createState() => _TouchRippleAnimationState();
}

class _TouchRippleAnimationState extends State<_TouchRippleAnimation>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _scaleAnimation = Tween<double>(begin: 0.3, end: 1.6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    _opacityAnimation = Tween<double>(begin: 0.9, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _opacityAnimation.value,
          child: Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.cyanAccent.withValues(alpha: 0.4),
                border: Border.all(
                  color: Colors.cyanAccent,
                  width: 2.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.cyanAccent.withValues(alpha: 0.6),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
