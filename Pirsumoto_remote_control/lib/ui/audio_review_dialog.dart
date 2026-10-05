import 'package:flutter/material.dart';
import 'package:publication_protocol/publication_protocol.dart';

const audioReviewFields = [
  'license_plate',
  'maker',
  'trim',
  'model',
  'year',
  'fuel_type',
  'gear_type',
  'month',
  'price',
  'km',
  'hand',
  'previous_ownership',
  'current_ownership',
  'color',
  'test_year',
  'test_month',
  'engine_capacity',
  'phone',
  'city',
  'area',
  'contact_name',
  'vehicle_condition',
  'description',
  'no_test',
  'clean_title',
  'highlights',
];

class AudioReviewDialog extends StatefulWidget {
  final String transcript;
  final Map<String, dynamic> fields;

  const AudioReviewDialog({
    super.key,
    required this.transcript,
    required this.fields,
  });

  @override
  State<AudioReviewDialog> createState() => _AudioReviewDialogState();
}

class _AudioReviewDialogState extends State<AudioReviewDialog> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  bool _empty = false;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final key in audioReviewFields)
        key: TextEditingController(text: widget.fields[key]?.toString() ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _approve() {
    final values = {
      for (final entry in _controllers.entries)
        if (entry.value.text.trim().isNotEmpty)
          entry.key: entry.value.text.trim(),
    };
    setState(() => _empty = values.isEmpty);
    if (!_formKey.currentState!.validate() || values.isEmpty) return;
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('אישור פרטי ההקלטה'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'בדוק ותקן את הפרטים לפני האישור. שדות שלא נאמרו נשארו ריקים.',
                  ),
                  if (widget.fields.isEmpty)
                    const Text(
                      'לא זוהו פרטים בוודאות. אפשר למלא אותם כאן או לבטל ולהקליט שוב.',
                    ),
                  const SizedBox(height: 12),
                  ExpansionTile(
                    title: const Text('התמליל המקורי'),
                    children: [SelectableText(widget.transcript)],
                  ),
                  for (final key in audioReviewFields)
                    if (key == 'clean_title')
                      CheckboxListTile(
                        title: Text(vehicleFieldLabels[key]!),
                        value: _controllers[key]!.text == 'כן',
                        onChanged: (checked) => setState(() {
                          _controllers[key]!.text = checked == true
                              ? 'כן'
                              : 'לא';
                        }),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TextFormField(
                          key: ValueKey('audio_field_$key'),
                          controller: _controllers[key],
                          decoration: InputDecoration(
                            labelText: vehicleFieldLabels[key] ?? key,
                          ),
                          textDirection:
                              ['license_plate', 'phone'].contains(key)
                              ? TextDirection.ltr
                              : TextDirection.rtl,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return null;
                            }
                            final errors = VehicleSchema.errors({
                              key: value.trim(),
                            });
                            return errors.isEmpty ? null : errors.first;
                          },
                        ),
                      ),
                  if (_empty) const Text('יש למלא לפחות פרט אחד לפני האישור.'),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ביטול'),
          ),
          FilledButton(onPressed: _approve, child: const Text('אישור והמשך')),
        ],
      ),
    );
  }
}
