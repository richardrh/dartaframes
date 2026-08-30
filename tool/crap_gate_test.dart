import 'dart:io';
import 'dart:convert';

import 'package:test/test.dart';

import 'crap_gate.dart' as gate;

void main() {
  group('formula', () {
    test('matches conventional CRAP equation boundaries', () {
      expect(gate.crapScore(5, 1), 5);
      expect(gate.crapScore(5, 0), 30);
      expect(gate.crapScore(10, .5), 22.5);
    });

    test('rejects invalid inputs', () {
      expect(() => gate.crapScore(0, .5), throwsArgumentError);
      expect(() => gate.crapScore(1, -0.01), throwsArgumentError);
      expect(() => gate.crapScore(1, double.nan), throwsArgumentError);
    });
  });

  test('LCOV parser combines records and rejects malformed DA data', () {
    final coverage = gate.LineCoverage.parse(
      'SF:lib/a.dart\nDA:2,0\nDA:2,3\nend_of_record\n',
      repository: '/repo',
    );
    expect(coverage.files['/repo/lib/a.dart'], {2: 3});
    expect(
      () => gate.LineCoverage.parse(
        'SF:x.dart\nDA:nope,1\n',
        repository: '/repo',
      ),
      throwsFormatException,
    );
    expect(
      () => gate.LineCoverage.parse('SF:x.dart\nDA:0,1\n', repository: '/repo'),
      throwsFormatException,
    );
    expect(
      () =>
          gate.LineCoverage.parse('SF:x.dart\nDA:1,-1\n', repository: '/repo'),
      throwsFormatException,
    );
  });

  test('AST complexity, line coverage, nested closure, and threshold', () {
    const source = '''
int choose(int x) {
  if (x > 0 && x < 10) return x;
  final nested = () { if (x == 99) return 1; return 0; };
  return nested();
}
''';
    final coverage = gate.LineCoverage.parse(
      'SF:sample.dart\nDA:2,1\nDA:3,1\nDA:4,0\nDA:5,0\n',
      repository: '/repo',
    );
    final scores = gate.scoreDartSource(
      source: source,
      path: '/repo/sample.dart',
      repository: '/repo',
      coverage: coverage,
    );
    expect(scores.single.complexity, 3);
    expect(scores.single.coverage, .5);
    expect(scores.single.crap, closeTo(4.125, .0001));
    expect(gate.thresholdFails(scores, 4), isTrue);
    expect(gate.thresholdFails(scores, scores.single.crap), isFalse);
  });

  test('counts switch-expression alternatives', () {
    const source =
        'String label(int x) => switch (x) { 0 => "zero", _ => "other" };';
    final scores = gate.scoreDartSource(
      source: source,
      path: '/repo/sample.dart',
      repository: '/repo',
      coverage: gate.LineCoverage.parse(
        'SF:sample.dart\nDA:1,1\n',
        repository: '/repo',
      ),
    );
    expect(scores.single.complexity, 3);
    expect(scores.single.coverage, 1);
  });

  group('baseline ratchet', () {
    gate.FunctionScore score(String name, int complexity, double coverage) =>
        gate.FunctionScore(
          name: name,
          file: 'lib/a.dart',
          line: 1,
          complexity: complexity,
          coverage: coverage,
        );

    test('new unbaselined debt and regressions fail', () {
      final fresh = score('fresh', 2, 0); // CRAP 6.
      final regressed = score('regressed', 2, 0);
      final result = gate.evaluateRatchet(
        [fresh, regressed],
        5,
        {regressed.key: 5.9},
      );
      expect(result.passed, isFalse);
      expect(result.newViolations, [fresh]);
      expect(result.regressedViolations, [regressed]);
    });

    test('threshold and ceiling equality pass, as do improvements', () {
      final atThreshold = score('atThreshold', 5, 0); // CRAP 30.
      final atCeiling = score('atCeiling', 2, 0); // CRAP 6.
      final improved = score('improved', 2, .5); // CRAP 2.5.
      final thresholdResult = gate.evaluateRatchet([atThreshold], 30, {});
      expect(thresholdResult.passed, isTrue);

      final ceilingResult = gate.evaluateRatchet(
        [atCeiling, improved],
        5,
        {atCeiling.key: 6, improved.key: 100},
      );
      expect(ceilingResult.passed, isTrue);
      expect(ceilingResult.newViolations, isEmpty);
      expect(ceilingResult.regressedViolations, isEmpty);
      expect(ceilingResult.baselineDebt, [atCeiling]);
      expect(ceilingResult.staleBaselineKeys, [improved.key]);

      final debt = score('debt', 2, 0);
      final improvedButAboveThreshold = gate.evaluateRatchet(
        [debt],
        5,
        {debt.key: 7},
      );
      expect(improvedButAboveThreshold.passed, isTrue);
      expect(improvedButAboveThreshold.baselineDebt, [debt]);
    });

    test('stale entries are reported without hiding new debt', () {
      final fresh = score('fresh', 2, 0);
      final result = gate.evaluateRatchet(
        [fresh],
        5,
        {'lib/gone.dart::gone': 9},
      );
      expect(result.passed, isFalse);
      expect(result.newViolations, [fresh]);
      expect(result.staleBaselineKeys, ['lib/gone.dart::gone']);
    });

    test('duplicate function identities are rejected', () {
      final duplicate = score('same', 2, 0);
      expect(
        () => gate.evaluateRatchet([duplicate, duplicate], 5, const {}),
        throwsFormatException,
      );
    });
  });

  test('markdown escapes function pipes and limits the worst table', () {
    final scores = [
      gate.FunctionScore(
        name: 'a|b',
        file: 'lib/a.dart',
        line: 1,
        complexity: 2,
        coverage: 0,
      ),
      gate.FunctionScore(
        name: 'second',
        file: 'lib/a.dart',
        line: 2,
        complexity: 1,
        coverage: 1,
      ),
    ];
    final markdown = gate.markdownSummary(scores, 30, worst: 1);
    expect(markdown, contains(r'`a\|b`'));
    expect(markdown, isNot(contains('`second`')));
  });

  test('CLI rejects invalid options without reading inputs', () async {
    expect(await gate.run(['--threshold=nan']), 64);
    expect(await gate.run(['--worst=0']), 64);
    expect(await gate.run(['--unknown']), 64);
  });

  test('CLI reports new, regressed, debt, and stale baseline state', () async {
    final temp = Directory.systemTemp.createTempSync('crap-gate-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    Directory('${temp.path}/lib').createSync();
    File('${temp.path}/lib/a.dart').writeAsStringSync(
      'int regressed() => 1;\nint fresh() => 2;\nint debt() => 3;\n',
    );
    File('${temp.path}/empty.info').writeAsStringSync('TN:\n');
    File('${temp.path}/baseline.json').writeAsStringSync(
      jsonEncode({
        'schema_version': 1,
        'functions': {
          'lib/a.dart::regressed/0': 1.5,
          'lib/a.dart::debt/0': 2,
          'lib/gone.dart::gone': 3,
        },
      }),
    );
    final previous = Directory.current;
    Directory.current = temp;
    try {
      final result = await gate.run([
        '--coverage=empty.info',
        '--source=lib',
        '--threshold=1',
        '--baseline=baseline.json',
        '--json=out/report.json',
        '--markdown=out/report.md',
      ]);
      expect(result, 1);
      expect(
        File('out/report.json').readAsStringSync(),
        allOf(
          contains('"new_violation_count": 1'),
          contains('"regressed_violation_count": 1'),
          contains('"baseline_debt_count": 1'),
          contains('"stale_baseline_keys"'),
          contains('"ratchet_status": "new_violation"'),
          contains('"ratchet_status": "regressed_violation"'),
          contains('"ratchet_status": "baseline_debt"'),
        ),
      );
      expect(
        File('out/report.md').readAsStringSync(),
        allOf(
          contains('new_violation'),
          contains('regressed_violation'),
          contains('baseline_debt'),
          contains('Stale baseline entries'),
        ),
      );
    } finally {
      Directory.current = previous;
    }
  });
}
