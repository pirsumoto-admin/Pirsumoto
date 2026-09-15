import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_theme.dart';

class ChatMessageBubble extends StatelessWidget {
  final bool isUser;
  final String time;
  final bool isUploading;
  final Widget child;

  const ChatMessageBubble({
    super.key,
    required this.isUser,
    required this.time,
    required this.child,
    this.isUploading = false,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        width: constraints.maxWidth,
        child: Align(
          // Physical edges stay the same in Hebrew and English layouts.
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 5),
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.72),
            decoration: BoxDecoration(
              color: isUser ? AppColors.primarySoft : AppColors.surface,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16),
              ),
              border: isUser ? null : Border.all(color: AppColors.border),
              boxShadow: [
                BoxShadow(
                  color: AppColors.onSurface.withValues(alpha: 0.035),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            padding: const EdgeInsets.all(10),
            child: Column(
              textDirection: TextDirection.ltr,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                child,
                const SizedBox(height: 4),
                Row(
                  textDirection: TextDirection.ltr,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isUploading)
                      const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: AppColors.primaryAction,
                        ),
                      )
                    else
                      const Icon(
                        Icons.done_all_rounded,
                        size: 15,
                        color: AppColors.primaryAction,
                      ),
                    const SizedBox(width: 4),
                    Text(
                      time,
                      textDirection: TextDirection.ltr,
                      style: GoogleFonts.heebo(
                        fontSize: 11,
                        color: AppColors.secondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
