part of 'polars.dart';

final class ExprDateTimeNameSpace {
  const ExprDateTimeNameSpace._(this._expr);
  final Expr _expr;

  Expr _component(String name) => _expr._function('dt.$name');
  Expr get year => _component('year');
  Expr get isoYear => _component('isoYear');
  Expr get month => _component('month');
  Expr get day => _component('day');
  Expr get ordinalDay => _component('ordinalDay');
  Expr get weekday => _component('weekday');
  Expr get week => _component('week');
  Expr get quarter => _component('quarter');
  Expr get hour => _component('hour');
  Expr get minute => _component('minute');
  Expr get second => _component('second');
  Expr get millisecond => _component('millisecond');
  Expr get microsecond => _component('microsecond');
  Expr get nanosecond => _component('nanosecond');
  Expr get date => _component('date');
  Expr get time => _component('time');
  Expr timestamp([TimeUnit unit = TimeUnit.microseconds]) =>
      _expr._function('dt.timestamp', options: {'timeUnit': unit.json});
  Expr format(String format) {
    if (format.isEmpty)
      throw ArgumentError.value(format, 'format', 'must not be empty');
    return _expr._function('dt.format', options: {'format': format});
  }

  Expr truncate(Object every) =>
      _expr._function('dt.truncate', arguments: [every]);
  Expr round(Object every) => _expr._function('dt.round', arguments: [every]);
  Expr offsetBy(Object by) => _expr._function('dt.offsetBy', arguments: [by]);
  Expr convertTimeZone(String timeZone) {
    if (timeZone.isEmpty) throw ArgumentError.value(timeZone, 'timeZone');
    return _expr._function(
      'dt.convertTimeZone',
      options: {'timeZone': timeZone},
    );
  }

  Expr get baseUtcOffset => _component('baseUtcOffset');
  Expr get dstOffset => _component('dstOffset');
}
