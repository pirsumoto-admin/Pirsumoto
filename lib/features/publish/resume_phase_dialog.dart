import 'package:flutter/material.dart';

Future<T?> selectResumePhase<T extends Enum>(
  BuildContext context, {
  required List<T> phases,
  required T current,
  required String Function(T) label,
}) {
  final start = (current.index - 2).clamp(0, phases.length - 1);
  return showDialog<T>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: const Text(
            'מאיזה שלב להמשיך?',
            textDirection: TextDirection.rtl,
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children:
                  phases
                      .skip(start)
                      .map(
                        (phase) => ListTile(
                          title: Text(
                            label(phase),
                            textDirection: TextDirection.rtl,
                          ),
                          selected: phase == current,
                          onTap: () => Navigator.of(context).pop(phase),
                        ),
                      )
                      .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('השאר מושהה'),
            ),
          ],
        ),
  );
}
