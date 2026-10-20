import 'package:fetchren/src/http/body_formatter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pretty-prints JSON objects', () {
    final result = formatBody('{"a":1,"b":[true,null]}');
    expect(result.isJson, isTrue);
    expect(result.text, '{\n  "a": 1,\n  "b": [\n    true,\n    null\n  ]\n}');
  });

  test('pretty-prints JSON arrays', () {
    final result = formatBody('[1,2]');
    expect(result.isJson, isTrue);
    expect(result.text, '[\n  1,\n  2\n]');
  });

  test('formats JSON scalars when the content type says JSON', () {
    final result = formatBody('42', contentType: 'application/json');
    expect(result.isJson, isTrue);
    expect(result.text, '42');
  });

  test('does not treat plain-text scalars as JSON', () {
    final result = formatBody('42', contentType: 'text/plain');
    expect(result.isJson, isFalse);
    expect(result.text, '42');
  });

  test('falls back to raw text for invalid JSON', () {
    const raw = '{"broken": ';
    final result = formatBody(raw, contentType: 'application/json');
    expect(result.isJson, isFalse);
    expect(result.text, raw);
  });

  test('returns non-JSON bodies unchanged', () {
    const html = '<html><body>Hi</body></html>';
    final result = formatBody(html, contentType: 'text/html');
    expect(result.isJson, isFalse);
    expect(result.text, html);
  });

  test('handles empty bodies', () {
    final result = formatBody('', contentType: 'application/json');
    expect(result.isJson, isFalse);
    expect(result.text, '');
  });
}
