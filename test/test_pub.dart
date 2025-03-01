// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart=2.10

/// Test infrastructure for testing pub.
///
/// Unlike typical unit tests, most pub tests are integration tests that stage
/// some stuff on the file system, run pub, and then validate the results. This
/// library provides an API to build tests like that.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:async/async.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pub/src/entrypoint.dart';
import 'package:pub/src/exit_codes.dart' as exit_codes;
// TODO(rnystrom): Using "gitlib" as the prefix here is ugly, but "git" collides
// with the git descriptor method. Maybe we should try to clean up the top level
// scope a bit?
import 'package:pub/src/git.dart' as gitlib;
import 'package:pub/src/http.dart';
import 'package:pub/src/io.dart';
import 'package:pub/src/lock_file.dart';
import 'package:pub/src/log.dart' as log;
import 'package:pub/src/sdk.dart';
import 'package:pub/src/source_registry.dart';
import 'package:pub/src/system_cache.dart';
import 'package:pub/src/utils.dart';
import 'package:pub/src/validator.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart' hide fail;
import 'package:test/test.dart' as test show fail;
import 'package:test_process/test_process.dart';

import 'descriptor.dart' as d;
import 'descriptor_server.dart';
import 'package_server.dart';

export 'descriptor_server.dart';
export 'package_server.dart';

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// enabled.
Matcher isMinifiedDart2JSOutput =
    isNot(contains('// The code supports the following hooks'));

/// A [Matcher] that matches JavaScript generated by dart2js with minification
/// disabled.
Matcher isUnminifiedDart2JSOutput =
    contains('// The code supports the following hooks');

/// Converts [value] into a YAML string.
String yaml(value) => jsonEncode(value);

/// The path of the package cache directory used for tests, relative to the
/// sandbox directory.
const String cachePath = 'cache';

/// The path of the mock app directory used for tests, relative to the sandbox
/// directory.
const String appPath = 'myapp';

/// The path of the ".dart_tool/package_config.json" file in the mock app used
/// for tests, relative to the sandbox directory.
String packageConfigFilePath =
    p.join(appPath, '.dart_tool', 'package_config.json');

/// The entry from the `.dart_tool/package_config.json` file for [packageName].
Map<String, dynamic> packageSpec(String packageName) => json
    .decode(File(d.path(packageConfigFilePath)).readAsStringSync())['packages']
    .firstWhere((e) => e['name'] == packageName,
        orElse: () => null) as Map<String, dynamic>;

/// The suffix appended to a built snapshot.
final versionSuffix = testVersion ?? sdk.version;

/// Enum identifying a pub command that can be run with a well-defined success
/// output.
class RunCommand {
  static final add = RunCommand(
      'add', RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'));
  static final get = RunCommand(
      'get', RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'));
  static final upgrade = RunCommand('upgrade', RegExp(r'''
(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)($|
\d+ packages? (has|have) newer versions incompatible with dependency constraints.
Try `dart pub outdated` for more information.$)'''));
  static final downgrade = RunCommand('downgrade',
      RegExp(r'(No dependencies changed\.|Changed \d+ dependenc(y|ies)!)$'));
  static final remove = RunCommand(
      'remove', RegExp(r'Got dependencies!|Changed \d+ dependenc(y|ies)!'));

  final String name;
  final RegExp success;
  RunCommand(this.name, this.success);
}

/// Runs the tests defined within [callback] using both pub get and pub upgrade.
///
/// Many tests validate behavior that is the same between pub get and
/// upgrade have the same behavior. Instead of duplicating those tests, this
/// takes a callback that defines get/upgrade agnostic tests and runs them
/// with both commands.
void forBothPubGetAndUpgrade(void Function(RunCommand) callback) {
  group(RunCommand.get.name, () => callback(RunCommand.get));
  group(RunCommand.upgrade.name, () => callback(RunCommand.upgrade));
}

/// Invokes the pub [command] and validates that it completes in an expected
/// way.
///
/// By default, this validates that the command completes successfully and
/// understands the normal output of a successful pub command. If [warning] is
/// given, it expects the command to complete successfully *and* print [warning]
/// to stderr. If [error] is given, it expects the command to *only* print
/// [error] to stderr. [output], [error], [silent], and [warning] may be
/// strings, [RegExp]s, or [Matcher]s.
///
/// If [exitCode] is given, expects the command to exit with that code.
// TODO(rnystrom): Clean up other tests to call this when possible.
Future<void> pubCommand(
  RunCommand command, {
  Iterable<String> args,
  output,
  error,
  silent,
  warning,
  int exitCode,
  Map<String, String> environment,
  String workingDirectory,
}) async {
  if (error != null && warning != null) {
    throw ArgumentError("Cannot pass both 'error' and 'warning'.");
  }

  var allArgs = [command.name];
  if (args != null) allArgs.addAll(args);

  output ??= command.success;

  if (error != null && exitCode == null) exitCode = 1;

  // No success output on an error.
  if (error != null) output = null;
  if (warning != null) error = warning;

  await runPub(
      args: allArgs,
      output: output,
      error: error,
      silent: silent,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory);
}

Future<void> pubAdd({
  Iterable<String> args,
  output,
  error,
  warning,
  int exitCode,
  Map<String, String> environment,
  String workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.add,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubGet({
  Iterable<String> args,
  output,
  error,
  warning,
  int exitCode,
  Map<String, String> environment,
  String workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.get,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubUpgrade(
        {Iterable<String> args,
        output,
        error,
        warning,
        int exitCode,
        Map<String, String> environment,
        String workingDirectory}) async =>
    await pubCommand(
      RunCommand.upgrade,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubDowngrade({
  Iterable<String> args,
  output,
  error,
  warning,
  int exitCode,
  Map<String, String> environment,
  String workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.downgrade,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

Future<void> pubRemove({
  Iterable<String> args,
  output,
  error,
  warning,
  int exitCode,
  Map<String, String> environment,
  String workingDirectory,
}) async =>
    await pubCommand(
      RunCommand.remove,
      args: args,
      output: output,
      error: error,
      warning: warning,
      exitCode: exitCode,
      environment: environment,
      workingDirectory: workingDirectory,
    );

/// Schedules starting the "pub [global] run" process and validates the
/// expected startup output.
///
/// If [global] is `true`, this invokes "pub global run", otherwise it does
/// "pub run".
///
/// Returns the `pub run` process.
Future<PubProcess> pubRun(
    {bool global = false,
    Iterable<String> args,
    Map<String, String> environment,
    bool verbose = true}) async {
  var pubArgs = global ? ['global', 'run'] : ['run'];
  pubArgs.addAll(args);
  var pub = await startPub(
    args: pubArgs,
    environment: environment,
    verbose: verbose,
  );

  // Loading sources and transformers isn't normally printed, but the pub test
  // infrastructure runs pub in verbose mode, which enables this.
  expect(pub.stdout, mayEmitMultiple(startsWith('Loading')));

  return pub;
}

/// Schedules starting the "pub run --v2" process and validates the
/// expected startup output.
///
/// Returns the `pub run` process.
Future<PubProcess> pubRunFromDartDev({Iterable<String> args}) async {
  final pub = await startPub(args: ['run', '--dart-dev-run', ...args]);

  // Loading sources and transformers isn't normally printed, but the pub test
  // infrastructure runs pub in verbose mode, which enables this.
  expect(pub.stdout, mayEmitMultiple(startsWith('Loading')));

  return pub;
}

/// Schedules renaming (moving) the directory at [from] to [to], both of which
/// are assumed to be relative to [d.sandbox].
void renameInSandbox(String from, String to) {
  renameDir(_pathInSandbox(from), _pathInSandbox(to));
}

/// Schedules creating a symlink at path [symlink] that points to [target],
/// both of which are assumed to be relative to [d.sandbox].
void symlinkInSandbox(String target, String symlink) {
  createSymlink(_pathInSandbox(target), _pathInSandbox(symlink));
}

/// Runs Pub with [args] and validates that its results match [output] (or
/// [outputJson]), [error], [silent] (for logs that are silent by default), and
/// [exitCode].
///
/// [output], [error], and [silent] can be [String]s, [RegExp]s, or [Matcher]s.
///
/// If [outputJson] is given, validates that pub outputs stringified JSON
/// matching that object, which can be a literal JSON object or any other
/// [Matcher].
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future<void> runPub(
    {List<String> args,
    output,
    error,
    outputJson,
    silent,
    int exitCode = exit_codes.SUCCESS,
    String workingDirectory,
    Map<String, String> environment}) async {
  // Cannot pass both output and outputJson.
  assert(output == null || outputJson == null);

  var pub = await startPub(
      args: args, workingDirectory: workingDirectory, environment: environment);
  await pub.shouldExit(exitCode);

  var actualOutput = (await pub.stdoutStream().toList()).join('\n');
  var actualError = (await pub.stderrStream().toList()).join('\n');
  var actualSilent = (await pub.silentStream().toList()).join('\n');

  var failures = <String>[];
  if (outputJson == null) {
    _validateOutput(failures, 'stdout', output, actualOutput);
  } else {
    _validateOutputJson(failures, 'stdout', outputJson, actualOutput);
  }

  _validateOutput(failures, 'stderr', error, actualError);
  _validateOutput(failures, 'silent', silent, actualSilent);

  if (failures.isNotEmpty) {
    test.fail(failures.join('\n'));
  }
}

/// Like [startPub], but runs `pub lish` in particular with [server] used both
/// as the OAuth2 server (with "/token" as the token endpoint) and as the
/// package server.
///
/// Any futures in [args] will be resolved before the process is started.
Future<PubProcess> startPublish(PackageServer server,
    {List<String> args}) async {
  var tokenEndpoint = Uri.parse(server.url).resolve('/token').toString();
  args = ['lish', ...?args];
  return await startPub(
      args: args,
      tokenEndpoint: tokenEndpoint,
      environment: {'PUB_HOSTED_URL': server.url});
}

/// Handles the beginning confirmation process for uploading a packages.
///
/// Ensures that the right output is shown and then enters "y" to confirm the
/// upload.
Future<void> confirmPublish(TestProcess pub) async {
  // TODO(rnystrom): This is overly specific and inflexible regarding different
  // test packages. Should validate this a little more loosely.
  await expectLater(
      pub.stdout, emits(startsWith('Publishing test_pkg 1.0.0 to ')));
  await expectLater(
      pub.stdout,
      emitsThrough(matches(
        r'^Do you want to publish [^ ]+ [^ ]+ (y/N)?',
      )));
  pub.stdin.writeln('y');
}

/// Resolves [path] relative to the package cache in the sandbox.
String pathInCache(String path) => p.join(d.sandbox, cachePath, path);

/// Gets the absolute path to [relPath], which is a relative path in the test
/// sandbox.
String _pathInSandbox(String relPath) => p.join(d.sandbox, relPath);

String testVersion = '0.1.2+3';

/// Gets the environment variables used to run pub in a test context.
Map<String, String> getPubTestEnvironment([String tokenEndpoint]) {
  var environment = {
    'CI': 'false', // unless explicitly given tests don't run pub in CI mode
    '_PUB_TESTING': 'true',
    'PUB_CACHE': _pathInSandbox(cachePath),
    'PUB_ENVIRONMENT': 'test-environment',

    // Ensure a known SDK version is set for the tests that rely on that.
    '_PUB_TEST_SDK_VERSION': testVersion
  };

  if (tokenEndpoint != null) {
    environment['_PUB_TEST_TOKEN_ENDPOINT'] = tokenEndpoint;
  }

  if (globalServer != null) {
    environment['PUB_HOSTED_URL'] = 'http://localhost:${globalServer.port}';
  }

  return environment;
}

/// The path to the root of pub's sources in the pub repo.
final String _pubRoot = (() {
  if (!fileExists(p.join('bin', 'pub.dart'))) {
    throw StateError(
        "Current working directory (${p.current} is not pub's root. Run tests from pub's root.");
  }
  return p.current;
})();

/// Starts a Pub process and returns a [PubProcess] that supports interaction
/// with that process.
///
/// Any futures in [args] will be resolved before the process is started.
///
/// If [environment] is given, any keys in it will override the environment
/// variables passed to the spawned process.
Future<PubProcess> startPub(
    {Iterable<String> args,
    String tokenEndpoint,
    String workingDirectory,
    Map<String, String> environment,
    bool verbose = true}) async {
  args ??= [];

  ensureDir(_pathInSandbox(appPath));

  // Find a Dart executable we can use to spawn. Use the same one that was
  // used to run this script itself.
  var dartBin = Platform.executable;

  // If the executable looks like a path, get its full path. That way we
  // can still find it when we spawn it with a different working directory.
  if (dartBin.contains(Platform.pathSeparator)) {
    dartBin = p.absolute(dartBin);
  }

  // If there's a snapshot for "pub" available we use it. If the snapshot is
  // out-of-date local source the tests will be useless, therefore it is
  // recommended to use a temporary file with a unique name for each test run.
  // Note: running tests without a snapshot is significantly slower, use
  // tool/test.dart to generate the snapshot.
  var pubPath = Platform.environment['_PUB_TEST_SNAPSHOT'] ?? '';
  if (pubPath.isEmpty || !fileExists(pubPath)) {
    pubPath = p.absolute(p.join(_pubRoot, 'bin/pub.dart'));
  }

  final dotPackagesPath = (await Isolate.packageConfig).toString();

  var dartArgs = ['--packages=$dotPackagesPath', '--enable-asserts'];
  dartArgs
    ..addAll([pubPath, if (verbose) '--verbose'])
    ..addAll(args);

  return await PubProcess.start(dartBin, dartArgs,
      environment: getPubTestEnvironment(tokenEndpoint)
        ..addAll(environment ?? {}),
      workingDirectory: workingDirectory ?? _pathInSandbox(appPath),
      description: args.isEmpty ? 'pub' : 'pub ${args.first}');
}

/// A subclass of [TestProcess] that parses pub's verbose logging output and
/// makes [stdout] and [stderr] work as though pub weren't running in verbose
/// mode.
class PubProcess extends TestProcess {
  StreamSplitter<Pair<log.Level, String>> get _logSplitter {
    __logSplitter ??= StreamSplitter(StreamGroup.merge([
      _outputToLog(super.stdoutStream(), log.Level.MESSAGE),
      _outputToLog(super.stderrStream(), log.Level.ERROR)
    ]));
    return __logSplitter;
  }

  StreamSplitter<Pair<log.Level, String>> __logSplitter;

  static Future<PubProcess> start(String executable, Iterable<String> arguments,
      {String workingDirectory,
      Map<String, String> environment,
      bool includeParentEnvironment = true,
      bool runInShell = false,
      String description,
      Encoding encoding,
      bool forwardStdio = false}) async {
    var process = await Process.start(executable, arguments.toList(),
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell);

    if (description == null) {
      var humanExecutable = p.isWithin(p.current, executable)
          ? p.relative(executable)
          : executable;
      description = '$humanExecutable ${arguments.join(' ')}';
    }

    encoding ??= utf8;
    return PubProcess(process, description,
        encoding: encoding, forwardStdio: forwardStdio);
  }

  /// This is protected.
  PubProcess(process, description,
      {Encoding encoding, bool forwardStdio = false})
      : super(process, description,
            encoding: encoding, forwardStdio: forwardStdio);

  final _logLineRegExp = RegExp(r'^([A-Z ]{4})[:|] (.*)$');
  final Map<String, log.Level> _logLevels = [
    log.Level.ERROR,
    log.Level.WARNING,
    log.Level.MESSAGE,
    log.Level.IO,
    log.Level.SOLVER,
    log.Level.FINE
  ].fold({}, (levels, level) {
    levels[level.name] = level;
    return levels;
  });

  Stream<Pair<log.Level, String>> _outputToLog(
      Stream<String> stream, log.Level defaultLevel) {
    log.Level lastLevel;
    return stream.map((line) {
      var match = _logLineRegExp.firstMatch(line);
      if (match == null) return Pair<log.Level, String>(defaultLevel, line);

      var level = _logLevels[match[1]] ?? lastLevel;
      lastLevel = level;
      return Pair<log.Level, String>(level, match[2]);
    });
  }

  @override
  Stream<String> stdoutStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first != log.Level.MESSAGE) return [];
      return [entry.last];
    });
  }

  @override
  Stream<String> stderrStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first != log.Level.ERROR && entry.first != log.Level.WARNING) {
        return [];
      }
      return [entry.last];
    });
  }

  /// A stream of log messages that are silent by default.
  Stream<String> silentStream() {
    return _logSplitter.split().expand((entry) {
      if (entry.first == log.Level.MESSAGE) return [];
      if (entry.first == log.Level.ERROR) return [];
      if (entry.first == log.Level.WARNING) return [];
      return [entry.last];
    });
  }
}

/// Fails the current test if Git is not installed.
///
/// We require machines running these tests to have git installed. This
/// validation gives an easier-to-understand error when that requirement isn't
/// met than just failing in the middle of a test when pub invokes git.
void ensureGit() {
  if (!gitlib.isInstalled) fail('Git must be installed to run this test.');
}

/// Creates a lock file for [package] without running `pub get`.
///
/// [dependenciesInSandBox] is a list of path dependencies to be found in the sandbox
/// directory.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
Future<void> createLockFile(String package,
    {Iterable<String> dependenciesInSandBox,
    Map<String, String> hosted}) async {
  var cache = SystemCache(rootDir: _pathInSandbox(cachePath));

  var lockFile = _createLockFile(cache.sources,
      sandbox: dependenciesInSandBox, hosted: hosted);

  await d.dir(package, [
    d.file('pubspec.lock', lockFile.serialize(null)),
    d.file(
      '.packages',
      lockFile.packagesFile(
        cache,
        entrypoint: package,
        relativeFrom: p.join(d.sandbox, package),
      ),
    )
  ]).create();
}

/// Like [createLockFile], but creates only a `.packages` file without a
/// lockfile.
Future<void> createPackagesFile(String package,
    {Iterable<String> dependenciesInSandBox,
    Map<String, String> hosted}) async {
  var cache = SystemCache(rootDir: _pathInSandbox(cachePath));
  var lockFile = _createLockFile(cache.sources,
      sandbox: dependenciesInSandBox, hosted: hosted);

  await d.dir(package, [
    d.file(
      '.packages',
      lockFile.packagesFile(
        cache,
        entrypoint: package,
        relativeFrom: d.sandbox,
      ),
    )
  ]).create();
}

/// Creates a lock file for [sources] without running `pub get`.
///
/// [sandbox] is a list of path dependencies to be found in the sandbox
/// directory.
///
/// [hosted] is a list of package names to version strings for dependencies on
/// hosted packages.
LockFile _createLockFile(SourceRegistry sources,
    {Iterable<String> sandbox, Map<String, String> hosted}) {
  var dependencies = {};

  if (sandbox != null) {
    for (var package in sandbox) {
      dependencies[package] = '../$package';
    }
  }

  var packages = dependencies.keys.map((name) {
    var dependencyPath = dependencies[name];
    return sources.path.idFor(name, Version(0, 0, 0), dependencyPath);
  }).toList();

  if (hosted != null) {
    hosted.forEach((name, version) {
      var id = sources.hosted.idFor(name, Version.parse(version));
      packages.add(id);
    });
  }

  return LockFile(packages);
}

/// Uses [client] as the mock HTTP client for this test.
///
/// Note that this will only affect HTTP requests made via http.dart in the
/// parent process.
void useMockClient(MockClient client) {
  var oldInnerClient = innerHttpClient;
  innerHttpClient = client;
  addTearDown(() {
    innerHttpClient = oldInnerClient;
  });
}

/// Describes a map representing a library package with the given [name],
/// [version], and [dependencies].
Map packageMap(
  String name,
  String version, [
  Map dependencies,
  Map devDependencies,
  Map environment,
]) {
  var package = <String, dynamic>{
    'name': name,
    'version': version,
    'homepage': 'http://pub.dartlang.org',
    'description': 'A package, I guess.'
  };

  if (dependencies != null) package['dependencies'] = dependencies;
  if (devDependencies != null) package['dev_dependencies'] = devDependencies;
  if (environment != null) package['environment'] = environment;
  return package;
}

/// Returns a Map in the format used by the pub.dartlang.org API to represent a
/// package version.
///
/// [pubspec] is the parsed pubspec of the package version. If [full] is true,
/// this returns the complete map, including metadata that's only included when
/// requesting the package version directly.
Map packageVersionApiMap(String hostedUrl, Map pubspec, {bool full = false}) {
  var name = pubspec['name'];
  var version = pubspec['version'];
  var map = {
    'pubspec': pubspec,
    'version': version,
    'archive_url': '$hostedUrl/packages/$name/versions/$version.tar.gz',
  };

  if (full) {
    map.addAll({
      'downloads': 0,
      'created': '2012-09-25T18:38:28.685260',
      'libraries': ['$name.dart'],
      'uploader': ['nweiz@google.com']
    });
  }

  return map;
}

/// Returns the name of the shell script for a binstub named [name].
///
/// Adds a ".bat" extension on Windows.
String binStubName(String name) => Platform.isWindows ? '$name.bat' : name;

/// Compares the [actual] output from running pub with [expected].
///
/// If [expected] is a [String], ignores leading and trailing whitespace
/// differences and tries to report the offending difference in a nice way.
///
/// If it's a [RegExp] or [Matcher], just reports whether the output matches.
void _validateOutput(
    List<String> failures, String pipe, expected, String actual) {
  if (expected == null) return;

  if (expected is String) {
    _validateOutputString(failures, pipe, expected, actual);
  } else {
    if (expected is RegExp) expected = matches(expected);
    expect(actual, expected);
  }
}

void _validateOutputString(
    List<String> failures, String pipe, String expected, String actual) {
  var actualLines = actual.split('\n');
  var expectedLines = expected.split('\n');

  // Strip off the last line. This lets us have expected multiline strings
  // where the closing ''' is on its own line. It also fixes '' expected output
  // to expect zero lines of output, not a single empty line.
  if (expectedLines.last.trim() == '') {
    expectedLines.removeLast();
  }

  var results = <String>[];
  var failed = false;

  // Compare them line by line to see which ones match.
  var length = max(expectedLines.length, actualLines.length);
  for (var i = 0; i < length; i++) {
    if (i >= actualLines.length) {
      // Missing output.
      failed = true;
      results.add('? ${expectedLines[i]}');
    } else if (i >= expectedLines.length) {
      // Unexpected extra output.
      failed = true;
      results.add('X ${actualLines[i]}');
    } else {
      var expectedLine = expectedLines[i].trim();
      var actualLine = actualLines[i].trim();

      if (expectedLine != actualLine) {
        // Mismatched lines.
        failed = true;
        results.add('X ${actualLines[i]}');
      } else {
        // Output is OK, but include it in case other lines are wrong.
        results.add('| ${actualLines[i]}');
      }
    }
  }

  // If any lines mismatched, show the expected and actual.
  if (failed) {
    failures.add('Expected $pipe:');
    failures.addAll(expectedLines.map((line) => '| $line'));
    failures.add('Got:');
    failures.addAll(results);
  }
}

/// Validates that [actualText] is a string of JSON that matches [expected],
/// which may be a literal JSON object, or any other [Matcher].
void _validateOutputJson(
    List<String> failures, String pipe, expected, String actualText) {
  Map actual;
  try {
    actual = jsonDecode(actualText);
  } on FormatException {
    failures.add('Expected $pipe JSON:');
    failures.add(expected);
    failures.add('Got invalid JSON:');
    failures.add(actualText);
  }

  // Remove dart2js's timing logs, which would otherwise cause tests to fail
  // flakily when compilation takes a long time.
  actual['log']?.removeWhere((entry) =>
      entry['level'] == 'Fine' &&
      entry['message'].startsWith('Not yet complete after'));

  // Match against the expectation.
  expect(actual, expected);
}

/// A function that creates a [Validator] subclass.
typedef ValidatorCreator = Validator Function(Entrypoint entrypoint);

/// Schedules a single [Validator] to run on the [appPath].
///
/// Returns a scheduled Future that contains the validator after validation.
Future<Validator> validatePackage(ValidatorCreator fn) async {
  var cache = SystemCache(rootDir: _pathInSandbox(cachePath));
  var validator = fn(Entrypoint(_pathInSandbox(appPath), cache));
  await validator.validate();
  return validator;
}

/// A matcher that matches a Pair.
Matcher pairOf(firstMatcher, lastMatcher) =>
    _PairMatcher(wrapMatcher(firstMatcher), wrapMatcher(lastMatcher));

class _PairMatcher extends Matcher {
  final Matcher _firstMatcher;
  final Matcher _lastMatcher;

  _PairMatcher(this._firstMatcher, this._lastMatcher);

  @override
  bool matches(item, Map matchState) {
    if (item is! Pair) return false;
    return _firstMatcher.matches(item.first, matchState) &&
        _lastMatcher.matches(item.last, matchState);
  }

  @override
  Description describe(Description description) {
    return description.addAll('(', ', ', ')', [_firstMatcher, _lastMatcher]);
  }
}

/// Returns a matcher that asserts that a string contains [times] distinct
/// occurrences of [pattern], which must be a regular expression pattern.
Matcher matchesMultiple(String pattern, int times) {
  var buffer = StringBuffer(pattern);
  for (var i = 1; i < times; i++) {
    buffer.write(r'(.|\n)*');
    buffer.write(pattern);
  }
  return matches(buffer.toString());
}

/// A [StreamMatcher] that matches multiple lines of output.
StreamMatcher emitsLines(String output) => emitsInOrder(output.split('\n'));

Iterable<String> _filter(List<String> input) {
  return input
      // Downloading order is not deterministic, so to avoid flakiness we filter
      // out these lines.
      .where((line) => !line.startsWith('Downloading '))
      // Any paths in output should be relative to the sandbox and with forward
      // slashes to be stable across platforms.
      .map((line) {
    line = line
        .replaceAll(d.sandbox, r'$SANDBOX')
        .replaceAll(Platform.pathSeparator, '/');
    if (globalPackageServer != null) {
      line = line.replaceAll(globalPackageServer.port.toString(), '\$PORT');
    }
    return line;
  });
}

/// Runs `pub outdated [args]` and appends the output to [buffer].
Future<void> runPubIntoBuffer(
  List<String> args,
  StringBuffer buffer, {
  Map<String, String> environment,
  String workingDirectory,
}) async {
  final process = await startPub(
    args: args,
    environment: environment,
    workingDirectory: workingDirectory,
  );
  final exitCode = await process.exitCode;

  buffer.writeln(_filter([
    '\$ pub ${args.join(' ')}',
    ...await process.stdout.rest.toList(),
  ]).join('\n'));
  for (final line in _filter(await process.stderr.rest.toList())) {
    buffer.writeln('[ERR] $line');
  }
  if (exitCode != 0) {
    buffer.writeln('[Exit code] $exitCode');
  }
  buffer.write('\n');
}
