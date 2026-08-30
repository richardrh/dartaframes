import 'package:dartaframes_polars/dartaframes_polars.dart';
import 'package:test/test.dart';

void main() {
  test('Polars exposes a zero-argument native-assets factory', () {
    final Polars Function() constructor = Polars.native;
    expect(constructor, isA<Polars Function()>());
  });
}
