/// Ordering keys for siblings, compared as plain strings.
///
/// A key is a non-empty string of [sortKeyDigits] that does not end in `0`.
/// [sortKeyBetween] can always produce a key between two existing keys, so
/// inserting or moving an item never rewrites its siblings.
library;

const String sortKeyDigits = '0123456789abcdefghijklmnopqrstuvwxyz';
const int _base = sortKeyDigits.length;

bool isValidSortKey(String key) =>
    key.isNotEmpty &&
    !key.endsWith('0') &&
    key.split('').every(sortKeyDigits.contains);

/// Returns a key strictly between [before] and [after].
///
/// A null [before] means "first"; a null [after] means "last".
String sortKeyBetween(String? before, String? after) {
  for (final key in [before, after]) {
    if (key != null && !isValidSortKey(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid sort key');
    }
  }
  if (before != null && after != null && before.compareTo(after) >= 0) {
    throw ArgumentError('before ($before) must sort below after ($after)');
  }
  return _midpoint(before ?? '', after ?? '');
}

/// Returns [count] ascending keys after [after] (or from the start).
List<String> sortKeysAfter(String? after, int count) {
  final keys = <String>[];
  var previous = after;
  for (var i = 0; i < count; i++) {
    previous = sortKeyBetween(previous, null);
    keys.add(previous);
  }
  return keys;
}

// [a] is the lower bound ('' = start); [b] is the upper bound ('' = end).
String _midpoint(String a, String b) {
  var n = 0;
  while (n < b.length && (n < a.length ? a[n] : '0') == b[n]) {
    n++;
  }
  if (n > 0) {
    return b.substring(0, n) +
        _midpoint(n < a.length ? a.substring(n) : '', b.substring(n));
  }
  final digitA = a.isEmpty ? 0 : sortKeyDigits.indexOf(a[0]);
  final digitB = b.isEmpty ? _base : sortKeyDigits.indexOf(b[0]);
  if (digitB - digitA > 1) {
    return sortKeyDigits[(digitA + digitB) ~/ 2];
  }
  if (b.length > 1) return b[0];
  return sortKeyDigits[digitA] + _midpoint(a.isEmpty ? '' : a.substring(1), '');
}
