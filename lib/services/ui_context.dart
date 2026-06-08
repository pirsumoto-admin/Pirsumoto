import 'dart:convert';
import 'dart:typed_data';

// ── AxElement ─────────────────────────────────────────────────────────────────

/// A single interactive element extracted from the WebView DOM.
/// Coordinates are in CSS pixels (viewport-relative, same coordinate space
/// as document.elementFromPoint / getBoundingClientRect).
class AxElement {
  final String? id;
  final String role;
  final String label;
  final String? value;
  final double x; // CSS px, element center
  final double y; // CSS px, element center
  final bool visible;

  const AxElement({
    this.id,
    required this.role,
    required this.label,
    this.value,
    required this.x,
    required this.y,
    required this.visible,
  });

  factory AxElement.fromJson(Map<String, dynamic> json) => AxElement(
    id: json['id'] as String?,
    role: (json['role'] as String?) ?? 'unknown',
    label: (json['label'] as String?) ?? '',
    value: json['value'] as String?,
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    visible: (json['visible'] as bool?) ?? false,
  );

  @override
  String toString() =>
      'AxElement(role=$role label="$label" value="$value" id=$id x=$x y=$y visible=$visible)';
}

// ── ViewportState ─────────────────────────────────────────────────────────────

class ViewportState {
  final double scrollX;
  final double scrollY;
  final double scale;

  const ViewportState({
    required this.scrollX,
    required this.scrollY,
    required this.scale,
  });
}

// ── UIContext ─────────────────────────────────────────────────────────────────

/// Combined snapshot of the WebView at a single moment in time.
/// [screenshot] is the raw PNG bytes (physical-pixel resolution).
/// [axTree] contains every visible interactive element with CSS coordinates.
/// [viewport] holds current scroll position and device pixel ratio.
class UIContext {
  final Uint8List screenshot;
  final List<AxElement> axTree;
  final ViewportState viewport;

  UIContext({
    required this.screenshot,
    required this.axTree,
    required this.viewport,
  });

  /// Base-64 encoded screenshot for passing to an LLM vision endpoint.
  String get base64Screenshot => base64Encode(screenshot);

  /// Finds all visible elements whose label matches [query], exact matches first.
  ///
  /// Supports `|`-separated alternatives (e.g. "יד שניה|שניה").
  /// Matching is case-insensitive and ignores whitespace.
  /// Exact matches are returned before substring (contains) matches so that
  /// "כחול בהיר" is preferred over "כחול בהיר מטאלי".
  List<AxElement> findAllByLabel(String query, {bool visibleOnly = true}) {
    final options = query.contains('|') ? query.split('|') : [query];
    final normalized =
        options
            .map((o) => o.trim().replaceAll(RegExp(r'\s+'), '').toLowerCase())
            .toList();

    final exactMatches = <AxElement>[];
    final containsMatches = <AxElement>[];

    for (final el in axTree) {
      if (visibleOnly && !el.visible) continue;
      final elNorm = el.label.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final valNorm =
          (el.value ?? '').replaceAll(RegExp(r'\s+'), '').toLowerCase();

      if (normalized.any((opt) => elNorm == opt || valNorm == opt)) {
        exactMatches.add(el);
      } else if (normalized.any(
        (opt) =>
            opt.isNotEmpty && (elNorm.contains(opt) || valNorm.contains(opt)),
      )) {
        containsMatches.add(el);
      }
    }

    exactMatches.addAll(containsMatches);
    return exactMatches;
  }

  /// Finds the first visible element whose label matches [query].
  ///
  /// Delegates to [findAllByLabel]; exact matches are preferred over substrings.
  AxElement? findByLabel(String query, {bool visibleOnly = true}) {
    final all = findAllByLabel(query, visibleOnly: visibleOnly);
    return all.isEmpty ? null : all.first;
  }

  /// Finds a text/search input by [placeholder] substring or by exact [id].
  AxElement? findInput({String? placeholder, String? id}) {
    const inputRoles = {
      'text',
      'input',
      'textarea',
      'search',
      'number',
      'tel',
      'textbox',
      'combobox',
    };
    for (final el in axTree) {
      if (!inputRoles.contains(el.role)) continue;
      if (id != null && el.id == id) return el;
      if (placeholder != null) {
        final norm = el.label.toLowerCase();
        if (norm.contains(placeholder.toLowerCase())) return el;
      }
    }
    return null;
  }
}
