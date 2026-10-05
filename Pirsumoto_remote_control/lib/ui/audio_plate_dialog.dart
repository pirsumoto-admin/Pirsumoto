import 'package:flutter/material.dart';

/// Only the identifier is confirmed here. Listing details are edited inline
/// after government data has been fetched for this plate.
class AudioPlateDialog extends StatefulWidget {
  final String plate;
  final List<String> candidates;
  const AudioPlateDialog({
    super.key,
    this.plate = '',
    this.candidates = const [],
  });

  @override
  State<AudioPlateDialog> createState() => _AudioPlateDialogState();
}

class _AudioPlateDialogState extends State<AudioPlateDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final normalized = widget.plate.replaceAll(RegExp(r'\D'), '');
    _controller = TextEditingController(text: normalized);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.rtl,
    child: AlertDialog(
      title: const Text('אישור מספר רישוי'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_controller.text.isNotEmpty &&
                  !RegExp(r'^\d{7,8}$').hasMatch(_controller.text)) ...[
                const Text(
                  'זוהה מספר רישוי חלקי. אפשר להוסיף או לתקן ספרות במספר שנמצא, עד לקבלת 7 או 8 ספרות.',
                ),
                const SizedBox(height: 12),
              ],
              if (_controller.text.isEmpty && widget.candidates.isEmpty) ...[
                const Text(
                  'לא זוהה מספר רישוי מלא של 7 או 8 ספרות. יש להזין את המספר המלא לאישור.',
                ),
                const SizedBox(height: 12),
              ],
              if (widget.candidates.length > 1) ...[
                const Text(
                  'זוהו כמה מספרים אפשריים. בחר את מספר הרישוי הנכון או הזן אותו ידנית:',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final plate in widget.candidates)
                      ChoiceChip(
                        label: Text(plate, textDirection: TextDirection.ltr),
                        selected: _controller.text == plate,
                        onSelected: (_) =>
                            setState(() => _controller.text = plate),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const ValueKey('audio_license_plate'),
                controller: _controller,
                autofocus: true,
                textDirection: TextDirection.ltr,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(labelText: 'מספר רישוי'),
                validator: (text) =>
                    RegExp(
                      r'^\d{7,8}$',
                    ).hasMatch((text ?? '').replaceAll(RegExp(r'\D'), ''))
                    ? null
                    : 'יש להזין מספר רישוי בן 7 או 8 ספרות',
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('ביטול'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.pop(
                context,
                _controller.text.replaceAll(RegExp(r'\D'), ''),
              );
            }
          },
          child: const Text('אישור והמשך'),
        ),
      ],
    ),
  );
}
