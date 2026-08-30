import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:args/args.dart';

double crapScore(int complexity, double coverage) {
  if (complexity < 1) throw ArgumentError.value(complexity, 'complexity');
  if (!coverage.isFinite || coverage < 0 || coverage > 1) {
    throw ArgumentError.value(coverage, 'coverage');
  }
  return (complexity * complexity * math.pow(1 - coverage, 3) + complexity)
      .toDouble();
}

final class LineCoverage {
  LineCoverage(this.files);
  final Map<String, Map<int, int>> files;

  static LineCoverage parse(String input, {required String repository}) {
    final files = <String, Map<int, int>>{};
    String? source;
    for (final raw in const LineSplitter().convert(input)) {
      if (raw.startsWith('SF:')) {
        source = _canonical(raw.substring(3), repository);
        files.putIfAbsent(source, () => <int, int>{});
      } else if (raw.startsWith('DA:') && source != null) {
        final fields = raw.substring(3).split(',');
        if (fields.length < 2) throw FormatException('Invalid DA record: $raw');
        final line = int.tryParse(fields[0]);
        final hits = int.tryParse(fields[1]);
        if (line == null || line < 1 || hits == null || hits < 0) {
          throw FormatException('Invalid DA record: $raw');
        }
        files[source]![line] = (files[source]![line] ?? 0) + hits;
      }
    }
    return LineCoverage(files);
  }
}

final class FunctionScore {
  FunctionScore({
    required this.name,
    required this.file,
    required this.line,
    required this.complexity,
    required this.coverage,
    this.parameterCount = 0,
  }) : crap = crapScore(complexity, coverage);

  final String name;
  final String file;
  final int line;
  final int complexity;
  final double coverage;
  final int parameterCount;
  final double crap;

  /// A source-location-independent identity suitable for checked-in baselines.
  String get key => '$file::$name/$parameterCount';

  Map<String, Object> toJson({String? ratchetStatus}) => {
    'key': key,
    'name': name,
    'file': file,
    'line': line,
    'complexity': complexity,
    'parameter_count': parameterCount,
    'coverage': double.parse(coverage.toStringAsFixed(6)),
    'crap': double.parse(crap.toStringAsFixed(3)),
    if (ratchetStatus != null) 'ratchet_status': ratchetStatus,
  };
}

final class RatchetResult {
  RatchetResult({
    required this.statusByKey,
    required this.newViolations,
    required this.regressedViolations,
    required this.baselineDebt,
    required this.staleBaselineKeys,
  });

  final Map<String, String> statusByKey;
  final List<FunctionScore> newViolations;
  final List<FunctionScore> regressedViolations;
  final List<FunctionScore> baselineDebt;
  final List<String> staleBaselineKeys;

  bool get passed => newViolations.isEmpty && regressedViolations.isEmpty;
}

RatchetResult evaluateRatchet(
  Iterable<FunctionScore> scores,
  double threshold,
  Map<String, double> baseline,
) {
  final byKey = <String, FunctionScore>{};
  for (final score in scores) {
    if (byKey.containsKey(score.key)) {
      throw FormatException('Duplicate function key: ${score.key}');
    }
    byKey[score.key] = score;
  }
  final statuses = <String, String>{};
  final newViolations = <FunctionScore>[];
  final regressions = <FunctionScore>[];
  final debt = <FunctionScore>[];
  for (final score in scores) {
    final ceiling = baseline[score.key];
    if (score.crap <= threshold) {
      statuses[score.key] = 'pass';
    } else if (ceiling == null) {
      statuses[score.key] = 'new_violation';
      newViolations.add(score);
    } else if (score.crap > ceiling) {
      statuses[score.key] = 'regressed_violation';
      regressions.add(score);
    } else {
      statuses[score.key] = 'baseline_debt';
      debt.add(score);
    }
  }
  final stale =
      baseline.keys
          .where((key) => byKey[key] == null || byKey[key]!.crap <= threshold)
          .toList()
        ..sort();
  return RatchetResult(
    statusByKey: statuses,
    newViolations: newViolations,
    regressedViolations: regressions,
    baselineDebt: debt,
    staleBaselineKeys: stale,
  );
}

final class _ComplexityVisitor extends RecursiveAstVisitor<void> {
  int complexity = 1;

  @override
  void visitIfStatement(IfStatement node) {
    complexity++;
    super.visitIfStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    complexity++;
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    complexity++;
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    complexity++;
    super.visitDoStatement(node);
  }

  @override
  void visitCatchClause(CatchClause node) {
    complexity++;
    super.visitCatchClause(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    complexity++;
    super.visitConditionalExpression(node);
  }

  @override
  void visitSwitchCase(SwitchCase node) {
    complexity++;
    super.visitSwitchCase(node);
  }

  @override
  void visitSwitchPatternCase(SwitchPatternCase node) {
    complexity++;
    super.visitSwitchPatternCase(node);
  }

  @override
  void visitSwitchExpressionCase(SwitchExpressionCase node) {
    complexity++;
    super.visitSwitchExpressionCase(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    if (node.operator.lexeme == '&&' || node.operator.lexeme == '||') {
      complexity++;
    }
    super.visitBinaryExpression(node);
  }

  // A closure is a separate function. Do not charge its decisions to its owner.
  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

List<FunctionScore> scoreDartSource({
  required String source,
  required String path,
  required String repository,
  required LineCoverage coverage,
}) {
  final parsed = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  final lineInfo = LineInfo.fromContent(source);
  final canonical = _canonical(path, repository);
  final display = _relative(canonical, repository);
  final lineHits = coverage.files[canonical] ?? const <int, int>{};
  final output = <FunctionScore>[];

  void add(String name, FunctionBody body, int offset, int parameterCount) {
    final visitor = _ComplexityVisitor();
    body.accept(visitor);
    final first = lineInfo.getLocation(body.offset).lineNumber;
    final last = lineInfo
        .getLocation(math.max(body.offset, body.end - 1))
        .lineNumber;
    final measured = lineHits.entries
        .where((entry) => entry.key >= first && entry.key <= last)
        .toList();
    final covered = measured.where((entry) => entry.value > 0).length;
    final ratio = measured.isEmpty ? 0.0 : covered / measured.length;
    output.add(
      FunctionScore(
        name: name,
        file: display,
        line: lineInfo.getLocation(offset).lineNumber,
        complexity: visitor.complexity,
        coverage: ratio,
        parameterCount: parameterCount,
      ),
    );
  }

  void addMembers(String owner, Iterable<ClassMember> members) {
    for (final member in members) {
      if (member is MethodDeclaration) {
        add(
          '$owner.${member.name.lexeme}',
          member.body,
          member.offset,
          member.parameters?.parameters.length ?? 0,
        );
      } else if (member is ConstructorDeclaration) {
        final suffix = member.name == null ? '' : '.${member.name!.lexeme}';
        add(
          '$owner$suffix',
          member.body,
          member.offset,
          member.parameters.parameters.length,
        );
      }
    }
  }

  for (final declaration in parsed.unit.declarations) {
    if (declaration is FunctionDeclaration) {
      add(
        declaration.name.lexeme,
        declaration.functionExpression.body,
        declaration.offset,
        declaration.functionExpression.parameters?.parameters.length ?? 0,
      );
    } else if (declaration is ClassDeclaration) {
      addMembers(
        declaration.namePart.typeName.lexeme,
        declaration.body.members,
      );
    } else if (declaration is MixinDeclaration) {
      addMembers(declaration.name.lexeme, declaration.body.members);
    } else if (declaration is ExtensionDeclaration) {
      addMembers(
        declaration.name?.lexeme ?? '<unnamed extension@${declaration.offset}>',
        declaration.body.members,
      );
    } else if (declaration is EnumDeclaration) {
      addMembers(
        declaration.namePart.typeName.lexeme,
        declaration.body.members,
      );
    }
  }
  return output;
}

bool thresholdFails(Iterable<FunctionScore> scores, double threshold) =>
    scores.any((score) => score.crap > threshold);

String markdownSummary(
  List<FunctionScore> scores,
  double threshold, {
  RatchetResult? ratchet,
  Map<String, double> baseline = const {},
  int worst = 20,
}) {
  final ordered = [...scores]..sort((a, b) => b.crap.compareTo(a.crap));
  final result = ratchet ?? evaluateRatchet(scores, threshold, baseline);
  final buffer = StringBuffer()
    ..writeln('# CRAP quality gate')
    ..writeln()
    ..writeln(
      '**${result.passed ? 'PASS' : 'FAIL'}** — ${result.newViolations.length} new and ${result.regressedViolations.length} regressed violation(s); ${result.baselineDebt.length} known baseline debt item(s).',
    )
    ..writeln()
    ..writeln(
      'Unbaselined functions fail above CRAP ${_number(threshold)}; baselined functions fail only above their ceiling. Equality passes.',
    )
    ..writeln()
    ..writeln(
      '| Status | Function | Location | Complexity | Coverage | CRAP | Ceiling |',
    )
    ..writeln('|---|---|---:|---:|---:|---:|---:|');
  for (final score in ordered.take(worst)) {
    final status = result.statusByKey[score.key] ?? 'pass';
    buffer.writeln(
      '| $status | `${score.name.replaceAll('|', r'\|')}` | `${score.file}:${score.line}` | ${score.complexity} | ${(score.coverage * 100).toStringAsFixed(1)}% | ${score.crap.toStringAsFixed(3)} | ${baseline[score.key]?.toString() ?? '—'} |',
    );
  }
  if (result.staleBaselineKeys.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Stale baseline entries')
      ..writeln()
      ..writeln(
        'These entries no longer identify debt above the threshold and should be removed:',
      );
    for (final key in result.staleBaselineKeys) {
      buffer.writeln('- `$key`');
    }
  }
  return buffer.toString();
}

Future<int> run(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('coverage', defaultsTo: 'coverage/lcov.info')
    ..addMultiOption('source', defaultsTo: const ['lib'])
    ..addOption(
      'threshold',
      defaultsTo: Platform.environment['CRAP_THRESHOLD'] ?? '30',
    )
    ..addOption(
      'baseline',
      defaultsTo:
          Platform.environment['CRAP_BASELINE'] ?? 'tool/crap_baseline.json',
      help: 'Checked-in CRAP ceiling baseline (required).',
    )
    ..addOption('json', defaultsTo: 'coverage/crap.json')
    ..addOption('markdown', defaultsTo: 'coverage/crap.md')
    ..addOption('worst', defaultsTo: '20');
  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    return 64;
  }
  final threshold = double.tryParse(args.option('threshold')!);
  final worst = int.tryParse(args.option('worst')!);
  if (threshold == null ||
      !threshold.isFinite ||
      threshold < 1 ||
      worst == null ||
      worst < 1) {
    stderr.writeln('--threshold must be finite and >= 1; --worst must be >= 1');
    return 64;
  }
  final repository = Directory.current.absolute.path;
  try {
    final lcov = LineCoverage.parse(
      await File(args.option('coverage')!).readAsString(),
      repository: repository,
    );
    final baselineJson = jsonDecode(
      await File(args.option('baseline')!).readAsString(),
    );
    if (baselineJson is! Map<String, dynamic> ||
        baselineJson['schema_version'] != 1 ||
        baselineJson['functions'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid CRAP baseline schema');
    }
    final baseline = <String, double>{};
    for (final entry
        in (baselineJson['functions'] as Map<String, dynamic>).entries) {
      final value = entry.value;
      if (entry.key.isEmpty ||
          value is! num ||
          !value.toDouble().isFinite ||
          value <= threshold) {
        throw FormatException(
          'Baseline ceiling for "${entry.key}" must be finite and > threshold',
        );
      }
      baseline[entry.key] = value.toDouble();
    }
    final scores = <FunctionScore>[];
    for (final rootName in args.multiOption('source')) {
      final root = Directory(rootName);
      if (!root.existsSync())
        throw FileSystemException('Source directory does not exist', rootName);
      final files =
          root
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        scores.addAll(
          scoreDartSource(
            source: await file.readAsString(),
            path: file.absolute.path,
            repository: repository,
            coverage: lcov,
          ),
        );
      }
    }
    scores.sort((a, b) => b.crap.compareTo(a.crap));
    final ratchet = evaluateRatchet(scores, threshold, baseline);
    final violations =
        ratchet.newViolations.length + ratchet.regressedViolations.length;
    final report = {
      'schema_version': 2,
      'language': 'dart',
      'formula': 'complexity^2 * (1 - coverage)^3 + complexity',
      'threshold': threshold,
      'policy': 'fail when an unbaselined function has CRAP > threshold or a baselined function has CRAP > its ceiling; equality passes',
      'baseline': args.option('baseline'),
      'passed': ratchet.passed,
      'function_count': scores.length,
      'violation_count': violations,
      'new_violation_count': ratchet.newViolations.length,
      'regressed_violation_count': ratchet.regressedViolations.length,
      'baseline_debt_count': ratchet.baselineDebt.length,
      'stale_baseline_keys': ratchet.staleBaselineKeys,
      'baseline_ceilings': baseline,
      'functions': scores
          .map(
            (score) =>
                score.toJson(ratchetStatus: ratchet.statusByKey[score.key]),
          )
          .toList(),
    };
    final jsonFile = File(args.option('json')!);
    final markdownFile = File(args.option('markdown')!);
    jsonFile.parent.createSync(recursive: true);
    markdownFile.parent.createSync(recursive: true);
    await jsonFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    await markdownFile.writeAsString(
      markdownSummary(
        scores,
        threshold,
        ratchet: ratchet,
        baseline: baseline,
        worst: worst,
      ),
    );
    stdout.write(
      markdownSummary(
        scores,
        threshold,
        ratchet: ratchet,
        baseline: baseline,
        worst: worst,
      ),
    );
    return ratchet.passed ? 0 : 1;
  } on Object catch (error) {
    stderr.writeln('CRAP gate input error: $error');
    return 2;
  }
}

String _canonical(String path, String repository) {
  final absolute = File(path).isAbsolute
      ? File(path).absolute.path
      : File('$repository/$path').absolute.path;
  return absolute.replaceAll('\\', '/');
}

String _relative(String path, String repository) {
  final root = repository
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  return path.startsWith('$root/') ? path.substring(root.length + 1) : path;
}

String _number(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();

Future<void> main(List<String> arguments) async {
  exitCode = await run(arguments);
}
