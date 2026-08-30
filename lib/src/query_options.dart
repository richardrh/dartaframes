part of 'polars.dart';

/// Polars 0.55.2 execution engines.
enum ExecutionEngine {
  auto('auto'),
  inMemory('in-memory'),
  streaming('streaming');

  const ExecutionEngine(this.wireName);
  final String wireName;
}

/// Overrides selected Polars 0.55.2 optimizer flags.
///
/// Null fields retain Polars' default for that flag.
final class OptimizerOptions {
  const OptimizerOptions({
    this.projectionPushdown,
    this.predicatePushdown,
    this.clusterWithColumns,
    this.typeCoercion,
    this.simplifyExpression,
    this.typeCheck,
    this.slicePushdown,
    this.commonSubplanElimination,
    this.commonSubexpressionElimination,
    this.rowEstimate,
    this.fastProjection,
    this.checkOrderObserve,
    this.sortCollapse,
    this.partitionHive,
  });

  final bool? projectionPushdown;
  final bool? predicatePushdown;
  final bool? clusterWithColumns;
  final bool? typeCoercion;
  final bool? simplifyExpression;
  final bool? typeCheck;
  final bool? slicePushdown;
  final bool? commonSubplanElimination;
  final bool? commonSubexpressionElimination;
  final bool? rowEstimate;
  final bool? fastProjection;
  final bool? checkOrderObserve;
  final bool? sortCollapse;
  final bool? partitionHive;

  Map<String, Object?> _toJson() => {
    if (projectionPushdown != null) 'projectionPushdown': projectionPushdown,
    if (predicatePushdown != null) 'predicatePushdown': predicatePushdown,
    if (clusterWithColumns != null) 'clusterWithColumns': clusterWithColumns,
    if (typeCoercion != null) 'typeCoercion': typeCoercion,
    if (simplifyExpression != null) 'simplifyExpression': simplifyExpression,
    if (typeCheck != null) 'typeCheck': typeCheck,
    if (slicePushdown != null) 'slicePushdown': slicePushdown,
    if (commonSubplanElimination != null)
      'commonSubplanElimination': commonSubplanElimination,
    if (commonSubexpressionElimination != null)
      'commonSubexpressionElimination': commonSubexpressionElimination,
    if (rowEstimate != null) 'rowEstimate': rowEstimate,
    if (fastProjection != null) 'fastProjection': fastProjection,
    if (checkOrderObserve != null) 'checkOrderObserve': checkOrderObserve,
    if (sortCollapse != null) 'sortCollapse': sortCollapse,
    if (partitionHive != null) 'partitionHive': partitionHive,
  };
}

final class ExecutionOptions {
  const ExecutionOptions({
    this.engine = ExecutionEngine.auto,
    this.optimizer = const OptimizerOptions(),
  });

  final ExecutionEngine engine;
  final OptimizerOptions optimizer;

  Map<String, Object?> _toJson() => {
    if (engine != ExecutionEngine.auto) 'engine': engine.wireName,
    ...optimizer._toJson(),
  };
}

enum ExplainFormat {
  plain('plain'),
  tree('tree'),
  logicalDot('dot');

  const ExplainFormat(this.wireName);
  final String wireName;
}

/// A Polars duration string such as `15m`, `2h30m`, `1d`, or `10i`.
///
/// Calendar units (`d`, `w`, `mo`, `q`, and `y`) retain Polars calendar
/// semantics. `i` is the integer-index unit used by dynamic and rolling groups.
final class PolarsDuration {
  const PolarsDuration(this.value);

  final String value;

  String _toWire(String field) {
    if (!RegExp(r'^-?(?:[0-9]+(?:ns|us|ms|s|m|h|d|w|mo|q|y|i))+$')
        .hasMatch(value)) {
      throw ArgumentError.value(value, field, 'invalid Polars duration');
    }
    return value;
  }

  @override
  String toString() => value;
}

enum JoinMode {
  inner('inner'),
  left('left'),
  right('right'),
  full('full'),
  outer('outer'),
  semi('semi'),
  anti('anti'),
  cross('cross');

  const JoinMode(this.wireName);
  final String wireName;
}

enum JoinValidation {
  manyToMany('manyToMany'),
  manyToOne('manyToOne'),
  oneToMany('oneToMany'),
  oneToOne('oneToOne');

  const JoinValidation(this.wireName);
  final String wireName;
}

enum JoinMaintainOrder {
  none('none'),
  left('left'),
  right('right'),
  leftRight('leftRight'),
  rightLeft('rightLeft');

  const JoinMaintainOrder(this.wireName);
  final String wireName;
}

/// Typed ordinary join options.
///
/// A null [coalesce] preserves Polars' join-specific default. This differs from
/// the legacy [LazyFrame.join] default, which deliberately remains `false`.
final class JoinOptions {
  const JoinOptions({
    this.mode = JoinMode.inner,
    this.suffix = '_right',
    this.coalesce,
    this.nullsEqual = false,
    this.validation = JoinValidation.manyToMany,
    this.maintainOrder = JoinMaintainOrder.none,
    this.allowParallel = true,
    this.forceParallel = false,
  });

  final JoinMode mode;
  final String suffix;
  final bool? coalesce;
  final bool nullsEqual;
  final JoinValidation validation;
  final JoinMaintainOrder maintainOrder;
  final bool allowParallel;
  final bool forceParallel;

  Map<String, Object?> _toJson() {
    if (forceParallel && !allowParallel) {
      throw ArgumentError('forceParallel requires allowParallel');
    }
    return {
      'how': mode.wireName,
      'suffix': suffix,
      'coalesce': coalesce,
      'nullsEqual': nullsEqual,
      'validation': validation.wireName,
      'maintainOrder': maintainOrder.wireName,
      'allowParallel': allowParallel,
      'forceParallel': forceParallel,
    };
  }
}

enum AsOfStrategy {
  backward('backward'),
  forward('forward'),
  nearest('nearest');

  const AsOfStrategy(this.wireName);
  final String wireName;
}

final class AsOfJoinOptions {
  const AsOfJoinOptions({
    this.strategy = AsOfStrategy.backward,
    this.tolerance,
    this.leftBy,
    this.rightBy,
    this.allowEqual = true,
    this.checkSortedness = true,
    this.suffix = '_right',
    this.coalesce,
    this.allowParallel = true,
    this.forceParallel = false,
  });

  final AsOfStrategy strategy;
  final PolarsDuration? tolerance;
  final List<String>? leftBy;
  final List<String>? rightBy;
  final bool allowEqual;
  final bool checkSortedness;
  final String suffix;
  final bool? coalesce;
  final bool allowParallel;
  final bool forceParallel;

  Map<String, Object?> _toJson() {
    final left = leftBy == null ? null : _validatedNames(leftBy!, 'leftBy');
    final right = rightBy == null ? null : _validatedNames(rightBy!, 'rightBy');
    if ((left == null) != (right == null) ||
        (left != null && left.length != right!.length)) {
      throw ArgumentError('leftBy and rightBy must have equal lengths');
    }
    if (forceParallel && !allowParallel) {
      throw ArgumentError('forceParallel requires allowParallel');
    }
    return {
      'strategy': strategy.wireName,
      if (tolerance != null) 'tolerance': tolerance!._toWire('tolerance'),
      if (left != null) 'leftBy': left,
      if (right != null) 'rightBy': right,
      'allowEqual': allowEqual,
      'checkSortedness': checkSortedness,
      'suffix': suffix,
      'coalesce': coalesce,
      'allowParallel': allowParallel,
      'forceParallel': forceParallel,
    };
  }
}

final class JoinWhereOptions {
  const JoinWhereOptions({
    this.suffix = '_right',
    this.allowParallel = true,
    this.forceParallel = false,
  });

  final String suffix;
  final bool allowParallel;
  final bool forceParallel;

  Map<String, Object?> _toJson() {
    if (forceParallel && !allowParallel) {
      throw ArgumentError('forceParallel requires allowParallel');
    }
    return {
      'suffix': suffix,
      'allowParallel': allowParallel,
      'forceParallel': forceParallel,
    };
  }
}

enum ClosedWindow {
  left('left'),
  right('right'),
  both('both'),
  none('none');

  const ClosedWindow(this.wireName);
  final String wireName;
}

enum DynamicGroupLabel {
  left('left'),
  right('right'),
  dataPoint('dataPoint');

  const DynamicGroupLabel(this.wireName);
  final String wireName;
}

enum DynamicGroupStartBy {
  windowBound('windowBound'),
  dataPoint('dataPoint'),
  monday('monday'),
  tuesday('tuesday'),
  wednesday('wednesday'),
  thursday('thursday'),
  friday('friday'),
  saturday('saturday'),
  sunday('sunday');

  const DynamicGroupStartBy(this.wireName);
  final String wireName;
}

final class DynamicGroupByOptions {
  const DynamicGroupByOptions({
    required this.every,
    this.period,
    this.offset,
    this.closed = ClosedWindow.left,
    this.label = DynamicGroupLabel.left,
    this.includeBoundaries = false,
    this.startBy = DynamicGroupStartBy.windowBound,
  });

  final PolarsDuration every;
  final PolarsDuration? period;
  final PolarsDuration? offset;
  final ClosedWindow closed;
  final DynamicGroupLabel label;
  final bool includeBoundaries;
  final DynamicGroupStartBy startBy;

  Map<String, Object?> _toJson() => {
    'every': every._toWire('every'),
    if (period != null) 'period': period!._toWire('period'),
    if (offset != null) 'offset': offset!._toWire('offset'),
    'closed': closed.wireName,
    'label': label.wireName,
    'includeBoundaries': includeBoundaries,
    'startBy': startBy.wireName,
  };
}

final class RollingGroupByOptions {
  const RollingGroupByOptions({
    required this.period,
    this.offset,
    this.closed = ClosedWindow.right,
  });

  final PolarsDuration period;
  final PolarsDuration? offset;
  final ClosedWindow closed;

  Map<String, Object?> _toJson() => {
    'period': period._toWire('period'),
    if (offset != null) 'offset': offset!._toWire('offset'),
    'closed': closed.wireName,
  };
}

enum WindowMapping {
  groupsToRows('groupsToRows'),
  explode('explode'),
  join('join');

  const WindowMapping(this.wireName);
  final String wireName;
}

final class WindowOrderOptions {
  const WindowOrderOptions({
    this.descending = false,
    this.nullsLast = false,
    this.maintainOrder = false,
    this.multithreaded = true,
  });

  final bool descending;
  final bool nullsLast;
  final bool maintainOrder;
  final bool multithreaded;

  Map<String, Object?> _toJson() => {
    'orderDescending': descending,
    'orderNullsLast': nullsLast,
    'orderMaintainOrder': maintainOrder,
    'orderMultithreaded': multithreaded,
  };
}

final class WindowOptions {
  const WindowOptions({
    this.mapping = WindowMapping.groupsToRows,
    this.order = const WindowOrderOptions(),
  });

  final WindowMapping mapping;
  final WindowOrderOptions order;

  Map<String, Object?> _toJson() => {
    'mapping': mapping.wireName,
    ...order._toJson(),
  };
}
