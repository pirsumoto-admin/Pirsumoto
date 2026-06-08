import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'ocr_service.dart';
import 'ui_context.dart';

// ── Result ────────────────────────────────────────────────────────────────────

class ValidationResult {
  final bool success;
  final String reason;

  /// True when result came from LLM (not rule-based).
  final bool usedLlm;

  const ValidationResult({
    required this.success,
    required this.reason,
    this.usedLlm = false,
  });

  @override
  String toString() =>
      'ValidationResult(success=$success usedLlm=$usedLlm reason="$reason")';
}

// ── Rule spec ─────────────────────────────────────────────────────────────────

/// Declarative rule for what must be true after a phase completes.
class PhaseRule {
  /// Text that must appear somewhere in the UI (AxTree or OCR).
  final String? mustContain;

  /// Text that must NOT be visible (e.g. dropdown dismissed).
  final String? mustNotContain;

  /// LLM fallback question, asked only when rule-based checks are inconclusive.
  final String? llmQuestion;

  const PhaseRule({
    this.mustContain,
    this.mustNotContain,
    this.llmQuestion,
  });
}

// ── Validator ─────────────────────────────────────────────────────────────────

class PhaseValidator {
  final OcrService ocrService;

  /// Anthropic API key for LLM escalation.
  /// Set to null to use rule-based validation only.
  final String? anthropicApiKey;

  static const _llmModel = 'claude-haiku-4-5-20251001';

  const PhaseValidator({
    required this.ocrService,
    this.anthropicApiKey,
  });

  // ── Public entry point ─────────────────────────────────────────────────────

  /// Validate [context] against [rule].
  /// Returns success if mustContain is found and mustNotContain is absent.
  /// Escalates to LLM when rule checks are inconclusive and a key is set.
  Future<ValidationResult> validate(UIContext context, PhaseRule rule) async {
    if (rule.mustContain != null) {
      final result = await _checkPresent(context, rule.mustContain!);
      if (!result.success) {
        if (anthropicApiKey != null && rule.llmQuestion != null) {
          final llm = await _askLlm(context.screenshot, rule.llmQuestion!);
          debugPrint('[Validator] LLM escalation: $llm');
          return llm;
        }
        return result;
      }
    }

    if (rule.mustNotContain != null) {
      final result = _checkAbsent(context, rule.mustNotContain!);
      if (!result.success) {
        if (anthropicApiKey != null && rule.llmQuestion != null) {
          final llm = await _askLlm(context.screenshot, rule.llmQuestion!);
          debugPrint('[Validator] LLM escalation: $llm');
          return llm;
        }
        return result;
      }
    }

    return const ValidationResult(success: true, reason: 'All rules passed');
  }

  // ── Rule checks ────────────────────────────────────────────────────────────

  Future<ValidationResult> _checkPresent(
    UIContext context,
    String text,
  ) async {
    final axHit = context.findByLabel(text, visibleOnly: false);
    if (axHit != null) {
      return ValidationResult(
          success: true,
          reason: 'AxTree: "${axHit.label}" found (visible=${axHit.visible})');
    }
    final ocrHit = await ocrService.findTextLocation(context.screenshot, text);
    if (ocrHit != null) {
      return ValidationResult(success: true, reason: 'OCR: "$text" found');
    }
    return ValidationResult(
        success: false, reason: '"$text" not found in AxTree or OCR');
  }

  ValidationResult _checkAbsent(UIContext context, String text) {
    final axHit = context.findByLabel(text, visibleOnly: true);
    if (axHit != null) {
      return ValidationResult(
          success: false,
          reason: '"$text" still visible — element not dismissed');
    }
    return ValidationResult(
        success: true, reason: '"$text" not visible — correctly dismissed');
  }

  // ── LLM escalation ─────────────────────────────────────────────────────────

  Future<ValidationResult> _askLlm(
    List<int> screenshot,
    String question,
  ) async {
    try {
      final b64 = base64Encode(screenshot);
      final body = jsonEncode({
        'model': _llmModel,
        'max_tokens': 128,
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': 'image/png',
                  'data': b64,
                }
              },
              {
                'type': 'text',
                'text':
                    'Answer YES or NO only, then one short reason (max 20 words).\n$question',
              }
            ]
          }
        ]
      });

      final res = await http.post(
        Uri.parse('https://api.anthropic.com/v1/messages'),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': anthropicApiKey!,
          'anthropic-version': '2023-06-01',
        },
        body: body,
      );

      if (res.statusCode != 200) {
        debugPrint('[Validator] LLM error ${res.statusCode}: ${res.body}');
        return ValidationResult(
            success: false,
            reason: 'LLM API error ${res.statusCode}',
            usedLlm: true);
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final text = (decoded['content'] as List?)
              ?.whereType<Map>()
              .where((c) => c['type'] == 'text')
              .map((c) => c['text'] as String)
              .join(' ')
              .trim() ??
          '';

      final success = text.trim().toUpperCase().startsWith('YES');
      return ValidationResult(success: success, reason: text, usedLlm: true);
    } catch (e, st) {
      debugPrint('[Validator] LLM call failed: $e\n$st');
      return ValidationResult(
          success: false, reason: 'LLM exception: $e', usedLlm: true);
    }
  }
}
