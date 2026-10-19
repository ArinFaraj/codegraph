// What a command-line argument names: a file, a directory or a symbol.
import 'outline.dart';
import 'symbols.dart';

/// What an argument names. Decided once, here, for every verb that takes
/// "a file, a directory or a symbol".
sealed class Arg {}

class FileArg extends Arg {
  FileArg(this.path);
  final String path;
}

class DirArg extends Arg {
  DirArg(this.path);
  final String path;
}

class SymbolArg extends Arg {
  SymbolArg(this.query);
  final String query;
}

class ChoiceArg extends Arg {
  ChoiceArg(this.candidates);
  final List<String> candidates;
}

/// `x.dart` and anything with a `/` is a path; a bare word is a symbol, or a
/// directory when [directories] is on and `lib/<w>`, `lib/features/<w>` or
/// `packages/<w>` exists.
Arg classifyArg(OutlineIndex idx, String arg, {required bool directories}) {
  final files = fileCandidates(idx.workspace, idx.files.keys, arg);
  final dirs = directories ? _dirCandidates(idx, arg) : const <String>[];
  if (arg.endsWith('.dart')) {
    return files.length == 1 ? FileArg(files.single) : ChoiceArg(files);
  }
  if (arg.contains('/')) {
    if (dirs.length == 1) return DirArg(dirs.single);
    return files.length == 1 ? FileArg(files.single) : ChoiceArg(files);
  }
  if (dirs.length == 1) return DirArg(dirs.single);
  if (dirs.length > 1) return ChoiceArg(dirs);
  return SymbolArg(arg);
}

List<String> _dirCandidates(OutlineIndex idx, String arg) {
  final clean = arg.endsWith('/') ? arg.substring(0, arg.length - 1) : arg;
  final rel = idx.workspace.relativeOrNull(clean);
  bool hasFiles(String dir) => idx.files.keys.any((p) => p.startsWith('$dir/'));
  if (rel != null && hasFiles(rel)) return [rel];
  if (clean.contains('/')) return const [];
  return [
    for (final dir in ['lib/$clean', 'lib/features/$clean', 'packages/$clean'])
      if (hasFiles(dir)) dir,
  ];
}
