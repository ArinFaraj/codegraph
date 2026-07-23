// One lightweight graph worker per workspace.
//
// The IDE already owns a long-lived resolved analyzer. This worker does not
// duplicate it: it watches filesystem events and refreshes only Codegraph's
// fast, untracked syntax index. Exact semantic operations keep their existing
// one-shot analyzer path.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'engine.dart' as engine;
import 'model.dart';

const _statePath = '.dart_tool/codegraph/daemon.json';
const _debounce = Duration(milliseconds: 350);
const _connectTimeout = Duration(seconds: 1);
const _syncTimeout = Duration(seconds: 20);
const _reconcileInterval = Duration(seconds: 30);

Future<bool> syncIfRunning() async =>
    (await _request('sync', timeout: _syncTimeout))?['ok'] == true;

Future<int> run(List<String> args) async {
  if (args.contains('status')) {
    final state = _readState();
    final active = (await _request('ping'))?['ok'] == true;
    if (!active && (state == null || !_processAlive(state.pid))) {
      _removeStaleState();
    }
    stdout.writeln(active
        ? 'codegraph daemon: running (port ${state?.port})'
        : 'codegraph daemon: stopped');
    return active ? 0 : 1;
  }
  if (args.contains('stop')) {
    final state = _readState();
    final stopped = (await _request('stop'))?['ok'] == true;
    if (!stopped && (state == null || !_processAlive(state.pid))) {
      _removeStaleState();
    }
    return 0;
  }
  if (!Directory('lib').existsSync()) {
    stderr.writeln('run from the package root (no lib/ here)');
    return 66;
  }
  if ((await _request('ping'))?['ok'] == true) {
    stdout.writeln('codegraph daemon already running for this workspace');
    return 0;
  }

  final token = '$pid-${DateTime.now().microsecondsSinceEpoch}';
  if (!_claimState(token)) {
    stdout.writeln('codegraph daemon is already starting for this workspace');
    return 0;
  }

  ServerSocket server;
  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  } catch (_) {
    _removeOwnedState(token);
    rethrow;
  }
  final workspace = _workspace();
  _writeState(_DaemonState(
    workspace: workspace,
    token: token,
    pid: pid,
    port: server.port,
  ));

  var stopping = false;
  var builtDigest = _freshGraphDigest();
  var dirty = builtDigest == null;
  Future<void>? refreshInFlight;

  Future<void> refresh({bool reconcile = false}) async {
    final active = refreshInFlight;
    if (active != null) return active;
    if (!dirty && !reconcile) return;
    final work = () async {
      final digest = engine.statDigest();
      if (digest == builtDigest) {
        dirty = false;
        return;
      }
      await Isolate.run(engine.buildRuntime);
      // Trust the digest embedded in the graph that was actually published,
      // not a new post-build scan. If source changes between publication and
      // here, the next reconcile must compare against the older graph digest
      // and rebuild rather than accidentally blessing unseen source.
      builtDigest = _graphDigest();
      dirty = builtDigest == null;
    }();
    refreshInFlight = work;
    try {
      await work;
    } catch (error, stack) {
      dirty = true;
      stderr.writeln('codegraph daemon refresh failed: $error');
      stderr.writeln(stack);
      rethrow;
    } finally {
      if (identical(refreshInFlight, work)) refreshInFlight = null;
    }
  }

  void refreshInBackground({bool reconcile = false}) {
    unawaited(
      refresh(reconcile: reconcile).catchError((_) {
        // refresh already logged the failure. Keep the worker alive so a later
        // filesystem event or explicit sync can retry.
      }),
    );
  }

  Timer? debounce;
  final watch = Directory.current.watch(recursive: true).listen(
    (event) {
      if (!_isSourceInput(workspace, event.path)) return;
      dirty = true;
      debounce?.cancel();
      debounce = Timer(_debounce, refreshInBackground);
    },
    onError: (_) {
      // Query-time and periodic reconciliation remain the correctness
      // fallback if the host filesystem watcher fails.
      dirty = true;
    },
  );
  final reconcile = Timer.periodic(
    _reconcileInterval,
    (_) => refreshInBackground(reconcile: true),
  );

  if (builtDigest == null) await refresh();
  stdout.writeln('codegraph daemon listening on 127.0.0.1:${server.port}');

  await for (final socket in server) {
    unawaited(() async {
      try {
        final request = await _readRequest(socket);
        if (request['token'] != token) {
          socket.writeln(jsonEncode({'ok': false, 'error': 'stale token'}));
          await socket.flush();
          return;
        }
        switch (request['op']) {
          case 'stop':
            stopping = true;
            socket.writeln(jsonEncode({'ok': true}));
            await socket.flush();
            await server.close();
          case 'sync':
            debounce?.cancel();
            // Filesystem events can arrive just after a command connects.
            // Reconcile the stat digest on every explicit sync; the watcher is
            // an eager background trigger, not the correctness boundary.
            await refresh(reconcile: true);
            socket.writeln(jsonEncode({'ok': true}));
            await socket.flush();
          case 'ping':
            socket.writeln(jsonEncode({'ok': true}));
            await socket.flush();
          default:
            socket.writeln(jsonEncode({'ok': false, 'error': 'unknown op'}));
            await socket.flush();
        }
      } catch (_) {
        // A malformed or abandoned local client cannot take down the worker.
      } finally {
        socket.destroy();
      }
    }());
    if (stopping) break;
  }

  debounce?.cancel();
  reconcile.cancel();
  await watch.cancel();
  _removeOwnedState(token);
  return 0;
}

int? _freshGraphDigest() {
  final stored = _graphDigest();
  if (stored == null) return null;
  return stored == engine.statDigest() ? stored : null;
}

int? _graphDigest() {
  if (!File('docs/maps/code_graph.json').existsSync()) return null;
  return Graph.load()?.stats['statDigest'];
}

bool _isSourceInput(String workspace, String absolutePath) {
  final root = '$workspace/';
  if (!absolutePath.startsWith(root)) return false;
  final path = absolutePath.substring(root.length).replaceAll('\\', '/');
  if (const {
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    '.dart_tool/package_config.json',
  }.contains(path)) {
    return true;
  }
  if (RegExp(r'^packages/[^/]+/pubspec\.yaml$').hasMatch(path)) return true;
  if (!path.endsWith('.dart')) return false;
  return RegExp(
    r'^(lib|test|integration_test|patrol_test)/|'
    r'^packages/[^/]+/(lib|test|integration_test|patrol_test)/',
  ).hasMatch(path);
}

Future<Map<String, dynamic>?> _request(
  String op, {
  Duration timeout = _connectTimeout,
}) async {
  final state = _readState();
  if (state == null || state.workspace != _workspace() || state.port == null) {
    return null;
  }
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      state.port!,
      timeout: _connectTimeout,
    );
    socket.writeln(jsonEncode({'op': op, 'token': state.token}));
    final line = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(timeout);
    return (jsonDecode(line) as Map).cast<String, dynamic>();
  } catch (_) {
    return null;
  } finally {
    socket?.destroy();
  }
}

Future<Map<String, dynamic>> _readRequest(Socket socket) async {
  final line = await socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first
      .timeout(const Duration(seconds: 1));
  return (jsonDecode(line) as Map).cast<String, dynamic>();
}

String _workspace() => Directory.current.resolveSymbolicLinksSync();

File _stateFile() => File(_statePath);

_DaemonState? _readState() {
  try {
    return _DaemonState.fromJson(
      (jsonDecode(_stateFile().readAsStringSync()) as Map)
          .cast<String, dynamic>(),
    );
  } catch (_) {
    return null;
  }
}

void _writeState(_DaemonState state) {
  final file = _stateFile()..parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(state.toJson()));
}

bool _claimState(String token) {
  final file = _stateFile()..parent.createSync(recursive: true);
  if (file.existsSync()) {
    final state = _readState();
    if (state != null && _processAlive(state.pid)) return false;
    final age = DateTime.now().difference(file.statSync().modified);
    if (age < const Duration(seconds: 5)) return false;
    _removeStaleState();
  }
  try {
    file.createSync(exclusive: true);
    _writeState(_DaemonState(
      workspace: _workspace(),
      token: token,
      pid: pid,
    ));
    return true;
  } on FileSystemException {
    return false;
  }
}

bool _processAlive(int processId) {
  if (processId <= 0) return false;
  try {
    if (Platform.isWindows) {
      final result = Process.runSync(
        'tasklist',
        ['/FI', 'PID eq $processId', '/NH'],
      );
      return result.exitCode == 0 &&
          result.stdout.toString().contains('$processId');
    }
    return Process.runSync('kill', ['-0', '$processId']).exitCode == 0;
  } catch (_) {
    // If the platform cannot check a PID, retain the state rather than risk
    // starting a duplicate worker.
    return true;
  }
}

void _removeOwnedState(String token) {
  if (_readState()?.token != token) return;
  _removeStaleState();
}

void _removeStaleState() {
  final file = _stateFile();
  if (!file.existsSync()) return;
  try {
    file.deleteSync();
  } catch (_) {}
}

class _DaemonState {
  const _DaemonState({
    required this.workspace,
    required this.token,
    required this.pid,
    this.port,
  });

  factory _DaemonState.fromJson(Map<String, dynamic> json) => _DaemonState(
        workspace: json['workspace'] as String,
        token: json['token'] as String,
        pid: json['pid'] as int,
        port: json['port'] as int?,
      );

  final String workspace;
  final String token;
  final int pid;
  final int? port;

  Map<String, dynamic> toJson() => {
        'format': 1,
        'workspace': workspace,
        'token': token,
        'pid': pid,
        if (port != null) 'port': port,
      };
}
