part of 'polars.dart';

enum RankMethod {
  average('average'),
  min('min'),
  max('max'),
  dense('dense'),
  ordinal('ordinal');

  const RankMethod(this.wireName);
  final String wireName;
}

enum InterpolationMethod {
  linear('linear'),
  nearest('nearest');

  const InterpolationMethod(this.wireName);
  final String wireName;
}

enum DiffNullBehavior {
  ignore('ignore'),
  drop('drop');

  const DiffNullBehavior(this.wireName);
  final String wireName;
}

final class RollingOptions {
  const RollingOptions({
    required this.windowSize,
    this.minPeriods = 1,
    this.weights,
    this.center = false,
  });

  final int windowSize;
  final int minPeriods;
  final List<double>? weights;
  final bool center;

  Map<String, Object?> _toJson() {
    if (windowSize < 1) {
      throw RangeError.value(windowSize, 'windowSize', 'must be positive');
    }
    if (minPeriods < 0 || minPeriods > windowSize) {
      throw RangeError.range(minPeriods, 0, windowSize, 'minPeriods');
    }
    final copiedWeights = weights == null
        ? null
        : List<double>.unmodifiable(weights!);
    if (copiedWeights != null) {
      if (copiedWeights.length != windowSize) {
        throw ArgumentError.value(
          weights,
          'weights',
          'length must equal windowSize',
        );
      }
      if (copiedWeights.any((value) => !value.isFinite)) {
        throw ArgumentError.value(weights, 'weights', 'must be finite');
      }
    }
    return {
      'windowSize': windowSize,
      'minPeriods': minPeriods,
      if (copiedWeights != null) 'weights': copiedWeights,
      'center': center,
    };
  }
}

final class EwmOptions {
  const EwmOptions({
    this.alpha = 0.5,
    this.adjust = true,
    this.bias = false,
    this.minPeriods = 1,
    this.ignoreNulls = true,
  });

  final double alpha;
  final bool adjust;
  final bool bias;
  final int minPeriods;
  final bool ignoreNulls;

  Map<String, Object?> _toJson() {
    if (!alpha.isFinite || alpha <= 0 || alpha > 1) {
      throw RangeError.range(alpha, 0, 1, 'alpha');
    }
    if (minPeriods < 0) {
      throw RangeError.value(minPeriods, 'minPeriods', 'must be unsigned');
    }
    return {
      'alpha': alpha,
      'adjust': adjust,
      'bias': bias,
      'minPeriods': minPeriods,
      'ignoreNulls': ignoreNulls,
    };
  }
}
