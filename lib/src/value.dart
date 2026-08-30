import 'dart:convert';

Object? freezeJson(Object? value) => switch (value) {
  Map<Object?, Object?> map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries)
      entry.key as String: freezeJson(entry.value),
  }),
  Iterable<Object?> values => List<Object?>.unmodifiable(
    values.map(freezeJson),
  ),
  null || bool() || num() || String() => value,
  _ => throw ArgumentError.value(value, 'value', 'is not a JSON value'),
};

bool jsonEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (i) => jsonEquals(a[i], b[i]),
        ).every((value) => value);
  }
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && jsonEquals(a[key], b[key]));
  }
  return a == b;
}

int jsonHash(Object? value) => switch (value) {
  List values => Object.hashAll(values.map(jsonHash)),
  Map values => Object.hashAll(
    (values.keys.cast<String>().toList()..sort()).map(
      (key) => Object.hash(key, jsonHash(values[key])),
    ),
  ),
  _ => value.hashCode,
};

String canonicalJson(Object? value) =>
    jsonEncode(_canonical(freezeJson(value)));

Object? _canonical(Object? value) => switch (value) {
  Map values => {
    for (final key in values.keys.cast<String>().toList()..sort())
      key: _canonical(values[key]),
  },
  List values => values.map(_canonical).toList(growable: false),
  _ => value,
};
