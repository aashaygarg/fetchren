import 'dart:convert';

/// A response body prepared for display.
class FormattedBody {
  const FormattedBody(this.text, {required this.isJson});

  final String text;

  /// True when [text] is pretty-printed JSON; false for the raw fallback.
  final bool isJson;
}

const JsonEncoder _prettyEncoder = JsonEncoder.withIndent('  ');

/// Pretty-prints [raw] when it is valid JSON, otherwise returns it unchanged.
///
/// JSON is attempted when [contentType] mentions `json` or the body looks like
/// a JSON object or array.
FormattedBody formatBody(String raw, {String? contentType}) {
  final trimmed = raw.trimLeft();
  if (trimmed.isEmpty) return FormattedBody(raw, isJson: false);
  final declaredJson = contentType?.toLowerCase().contains('json') ?? false;
  final looksJson = trimmed.startsWith('{') || trimmed.startsWith('[');
  if (declaredJson || looksJson) {
    try {
      return FormattedBody(
        _prettyEncoder.convert(jsonDecode(raw)),
        isJson: true,
      );
    } on FormatException {
      // Not valid JSON; show raw text.
    }
  }
  return FormattedBody(raw, isJson: false);
}
