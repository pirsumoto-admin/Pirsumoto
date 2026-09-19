import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class TextLocation {
  final String text;
  final double minX, minY, maxX, maxY;
  final double centerX, centerY;
  final int confidence;
  /// True when this location came from the Shadow AxTree (CSS element center),
  /// false when it came from OCR (physical-px text-label position).
  /// Phase actions use this to skip OCR-specific y-offsets.
  final bool fromAxTree;

  TextLocation({
    required this.text,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.confidence,
    this.fromAxTree = false,
  })  : centerX = (minX + maxX) / 2,
        centerY = (minY + maxY) / 2;

  @override
  String toString() =>
      'TextLocation("$text" bbox[$minX,$minY,$maxX,$maxY] center($centerX,$centerY) axTree=$fromAxTree)';
}

class OcrService {
  static const _apiKey = 'AIzaSyCtTgvlKOOrVTTWAQOD_-PWL26tCYg5nr8';
  static const _url =
      'https://vision.googleapis.com/v1/images:annotate?key=$_apiKey';

  /// Finds text in [imageBytes] matching [searchText] (supports | for multi-option).
  /// [targetInstance] is 1-based (1 = first match).
  Future<TextLocation?> findTextLocation(
    Uint8List imageBytes,
    String searchText, {
    int targetInstance = 1,
  }) async {
    final base64Image = base64Encode(imageBytes);
    final response = await _callVisionApi(base64Image);
    if (response == null) return null;
    return _parseVisionResponse(response, searchText, targetInstance);
  }

  /// Finds a multi-word phrase in [imageBytes] using Y-proximity matching.
  Future<TextLocation?> findMultiWordPhrase(
    Uint8List imageBytes,
    String phrase, {
    int targetInstance = 1,
  }) async {
    final words = phrase.trim().split(RegExp(r'\s+'));
    if (words.length < 2) {
      return findTextLocation(imageBytes, phrase,
          targetInstance: targetInstance);
    }

    final base64Image = base64Encode(imageBytes);
    final response = await _callVisionApi(base64Image);
    if (response == null) return null;
    return _parseMultiWordResponse(response, words, targetInstance);
  }

  /// Extracts full text from [imageBytes] using Google Cloud Vision API.
  Future<String?> extractFullText(Uint8List imageBytes) async {
    debugPrint(
      '[OcrService] 📸 extractFullText called with ${imageBytes.length} bytes of image data',
    );
    if (imageBytes.isEmpty) {
      debugPrint('[OcrService] ⚠️ Image bytes are empty (0 bytes). Returning null.');
      return null;
    }
    final base64Image = base64Encode(imageBytes);
    final response = await _callVisionApi(base64Image);
    if (response == null) {
      debugPrint('[OcrService] ⚠️ Vision API returned null decoded map.');
      return null;
    }
    final annotations =
        (response['responses'] as List?)?.firstOrNull?['textAnnotations']
            as List?;
    if (annotations != null && annotations.isNotEmpty) {
      final desc = (annotations[0] as Map)['description'] as String?;
      debugPrint(
        '[OcrService] 💡 Text description extracted from textAnnotations (length: ${desc?.length ?? 0}):\n$desc',
      );
      return desc;
    }
    debugPrint(
      '[OcrService] ⚠️ No textAnnotations found in Vision API response.',
    );
    return null;
  }

  // ── API call ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>?> _callVisionApi(String base64Image) async {
    try {
      debugPrint(
        '[OcrService] 🚀 Posting to Vision API (Base64 length: ${base64Image.length} chars)...',
      );
      final body = jsonEncode({
        'requests': [
          {
            'image': {'content': base64Image},
            'features': [
              {'type': 'DOCUMENT_TEXT_DETECTION', 'model': 'builtin/latest'}
            ],
          }
        ]
      });

      final res = await http.post(
        Uri.parse(_url),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      debugPrint('[OcrService] 📥 HTTP Status: ${res.statusCode}');
      debugPrint(
        '[OcrService] 📥 Raw Response Body:\n${res.body.length > 2000 ? "${res.body.substring(0, 2000)}... (truncated)" : res.body}',
      );

      if (res.statusCode != 200) {
        debugPrint(
          '[OcrService] ❌ Vision API error ${res.statusCode}: ${res.body}',
        );
        return null;
      }

      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      return decoded;
    } catch (e, st) {
      debugPrint('[OcrService] ❌ Vision API call failed: $e\n$st');
      return null;
    }
  }

  // ── Single / multi-option parsing ──────────────────────────────────────────

  TextLocation? _parseVisionResponse(
    Map<String, dynamic> json,
    String searchText,
    int targetInstance,
  ) {
    try {
      final annotations = _getAnnotations(json);
      if (annotations == null) return null;

      final searchOptions = searchText.contains('|')
          ? searchText.split('|')
          : [searchText];
      final normalizedOptions = searchOptions
          .map((o) => o.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase())
          .toList();

      int currentInstance = 0;
      for (int i = 1; i < annotations.length; i++) {
        final annotation = annotations[i] as Map<String, dynamic>;
        final text = (annotation['description'] as String?) ?? '';
        final normalized = text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

        final matched = normalizedOptions
            .any((opt) => normalized == opt || normalized.contains(opt));

        if (matched) {
          currentInstance++;
          if (currentInstance == targetInstance) {
            final loc = _extractLocation(annotation, text);
            if (loc != null) {
              debugPrint('[OcrService] MATCH[$i]: "$text" (instance #$currentInstance) '
                  'center(${loc.centerX.toStringAsFixed(0)}, ${loc.centerY.toStringAsFixed(0)})');
            }
            return loc;
          }
        }
      }

      debugPrint('[OcrService] "$searchText" instance #$targetInstance not found '
          '(found $currentInstance total)');
      return null;
    } catch (e, st) {
      debugPrint('[OcrService] parseVisionResponse error: $e\n$st');
      return null;
    }
  }

  // ── Multi-word phrase parsing ───────────────────────────────────────────────

  TextLocation? _parseMultiWordResponse(
    Map<String, dynamic> json,
    List<String> words,
    int targetInstance,
  ) {
    try {
      final annotations = _getAnnotations(json);
      if (annotations == null) return null;

      const yProximityThreshold = 20.0;
      const maxIndexGap = 3;

      final normalizedWords = words
          .map((w) => w.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase())
          .toList();

      int currentInstance = 0;

      for (int i = 1; i < annotations.length; i++) {
        final firstAnnotation = annotations[i] as Map<String, dynamic>;
        final firstText = (firstAnnotation['description'] as String?) ?? '';
        final normalizedFirst =
            firstText.replaceAll(RegExp(r'\s+'), '').toLowerCase();

        if (normalizedFirst != normalizedWords[0]) continue;

        final firstLoc = _extractLocation(firstAnnotation, firstText);
        if (firstLoc == null) continue;

        final firstWordY = firstLoc.centerY;
        bool allFound = true;
        int lastMatchIndex = i;
        final wordLocations = <TextLocation>[firstLoc];

        for (int wordIdx = 1; wordIdx < words.length; wordIdx++) {
          bool foundWord = false;
          final searchEnd =
              (lastMatchIndex + maxIndexGap + 1).clamp(0, annotations.length);

          for (int j = lastMatchIndex + 1; j < searchEnd; j++) {
            final candidateAnnotation =
                annotations[j] as Map<String, dynamic>;
            final candidateText =
                (candidateAnnotation['description'] as String?) ?? '';
            final candidateLoc =
                _extractLocation(candidateAnnotation, candidateText);
            if (candidateLoc == null) continue;

            if ((candidateLoc.centerY - firstWordY).abs() >
                yProximityThreshold) {
              continue;
            }

            final normalizedCandidate =
                candidateText.replaceAll(RegExp(r'\s+'), '').toLowerCase();
            if (normalizedCandidate == normalizedWords[wordIdx]) {
              wordLocations.add(candidateLoc);
              lastMatchIndex = j;
              foundWord = true;
              break;
            }
          }

          if (!foundWord) {
            allFound = false;
            break;
          }
        }

        if (allFound) {
          currentInstance++;
          if (currentInstance == targetInstance) {
            double minX = double.infinity,
                minY = double.infinity,
                maxX = double.negativeInfinity,
                maxY = double.negativeInfinity;
            for (final loc in wordLocations) {
              if (loc.minX < minX) minX = loc.minX;
              if (loc.minY < minY) minY = loc.minY;
              if (loc.maxX > maxX) maxX = loc.maxX;
              if (loc.maxY > maxY) maxY = loc.maxY;
            }
            final combined = TextLocation(
              text: words.join(' '),
              minX: minX,
              minY: minY,
              maxX: maxX,
              maxY: maxY,
              confidence: 100,
            );
            debugPrint('[OcrService] MULTI-WORD MATCH: "${words.join(' ')}" '
                '(instance #$currentInstance) center(${combined.centerX.toStringAsFixed(0)}, '
                '${combined.centerY.toStringAsFixed(0)})');
            return combined;
          }
        }
      }

      debugPrint('[OcrService] Multi-word "${words.join(' ')}" instance #$targetInstance '
          'not found (found $currentInstance total)');
      return null;
    } catch (e, st) {
      debugPrint('[OcrService] parseMultiWordResponse error: $e\n$st');
      return null;
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  List<dynamic>? _getAnnotations(Map<String, dynamic> json) {
    final responses = json['responses'] as List?;
    if (responses == null || responses.isEmpty) return null;
    final first = responses[0] as Map<String, dynamic>;
    final annotations = first['textAnnotations'] as List?;
    if (annotations == null || annotations.isEmpty) return null;
    return annotations;
  }

  TextLocation? _extractLocation(
      Map<String, dynamic> annotation, String text) {
    try {
      final boundingPoly = annotation['boundingPoly'] as Map<String, dynamic>?;
      if (boundingPoly == null) return null;

      final vertices = boundingPoly['vertices'] as List?;
      if (vertices == null) return null;

      double minX = double.infinity,
          minY = double.infinity,
          maxX = double.negativeInfinity,
          maxY = double.negativeInfinity;

      for (final v in vertices) {
        final vertex = v as Map<String, dynamic>;
        final x = (vertex['x'] as num?)?.toDouble() ?? 0;
        final y = (vertex['y'] as num?)?.toDouble() ?? 0;
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }

      final confidence =
          (annotation['confidence'] as num?)?.toInt() ?? 0;

      return TextLocation(
        text: text,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        confidence: confidence,
      );
    } catch (e) {
      debugPrint('[OcrService] extractLocation error: $e');
      return null;
    }
  }
}
