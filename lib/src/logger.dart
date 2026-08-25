import 'dart:io';

/// Minimal stderr logger. Everything the user asked for goes to stdout via the
/// reporters; progress and diagnostics go to stderr so `--format json > f.json`
/// stays clean.
class Logger {
  Logger({required this.verbose, IOSink? sink}) : _sink = sink ?? stderr;

  final bool verbose;
  final IOSink _sink;

  void trace(String message) {
    if (verbose) _sink.writeln('  $message');
  }

  void info(String message) => _sink.writeln(message);

  void warn(String message) => _sink.writeln('warning: $message');

  void error(String message) => _sink.writeln('error: $message');
}
