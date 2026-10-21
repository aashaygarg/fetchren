import 'dart:math';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:test/test.dart';

void main() {
  test('first key and keys at either end', () {
    final middle = sortKeyBetween(null, null);
    expect(isValidSortKey(middle), isTrue);
    expect(sortKeyBetween(null, middle).compareTo(middle), lessThan(0));
    expect(sortKeyBetween(middle, null).compareTo(middle), greaterThan(0));
  });

  test('handles adjacent digits and shared prefixes', () {
    for (final (a, b) in [
      ('1', '2'),
      ('a', 'a1'),
      ('az', 'b'),
      (null, '01'),
      (null, '1'),
      ('zz', null),
    ]) {
      final key = sortKeyBetween(a, b);
      expect(isValidSortKey(key), isTrue, reason: '$a..$b -> $key');
      if (a != null) expect(a.compareTo(key), lessThan(0), reason: key);
      if (b != null) expect(key.compareTo(b), lessThan(0), reason: key);
    }
  });

  test('rejects invalid or out-of-order bounds', () {
    expect(() => sortKeyBetween('b', 'a'), throwsArgumentError);
    expect(() => sortKeyBetween('a', 'a'), throwsArgumentError);
    expect(() => sortKeyBetween('a0', null), throwsArgumentError);
    expect(() => sortKeyBetween('A', null), throwsArgumentError);
    expect(() => sortKeyBetween('', null), throwsArgumentError);
  });

  test('sortKeysAfter returns ascending keys', () {
    final keys = sortKeysAfter(null, 50);
    expect(keys, [...keys]..sort());
    expect(keys.toSet(), hasLength(50));
  });

  test('random insertions always land strictly between neighbours', () {
    final random = Random(42);
    final keys = <String>[];
    for (var i = 0; i < 2000; i++) {
      final index = random.nextInt(keys.length + 1);
      final before = index == 0 ? null : keys[index - 1];
      final after = index == keys.length ? null : keys[index];
      final key = sortKeyBetween(before, after);
      expect(isValidSortKey(key), isTrue);
      keys.insert(index, key);
    }
    expect(keys, [...keys]..sort(), reason: 'list order matches string order');
    expect(keys.toSet(), hasLength(keys.length));
  });

  test('repeated insertion at the front stays valid', () {
    var first = sortKeyBetween(null, null);
    for (var i = 0; i < 200; i++) {
      final key = sortKeyBetween(null, first);
      expect(key.compareTo(first), lessThan(0));
      first = key;
    }
  });
}
