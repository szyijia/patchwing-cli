// lib/src/cli_runner.dart
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import 'commands/delete_release_command.dart';
import 'commands/doctor_command.dart';
import 'commands/init_command.dart';
import 'commands/release_command.dart';
import 'commands/patch_command.dart';

/// Patchwing CLI 命令行运行器
class PatchwingCliRunner {
  late final Logger _logger;
  late final CommandRunner<int> _runner;

  PatchwingCliRunner() {
    _logger = Logger();
    _runner = CommandRunner<int>(
      'pw',
      '🦋 Patchwing - Flutter 热更新解决方案',
    )
      ..argParser.addFlag(
        'version',
        abbr: 'v',
        negatable: false,
        help: '打印当前版本',
      )
      ..addCommand(DoctorCommand(logger: _logger))
      ..addCommand(InitCommand(logger: _logger))
      ..addCommand(ReleaseCommand(logger: _logger))
      ..addCommand(PatchCommand(logger: _logger))
      ..addCommand(DeleteReleaseCommand(logger: _logger));
  }

  Future<void> run(List<String> args) async {
    try {
      final argResults = _runner.parse(args);

      if (argResults['version'] == true) {
        _logger.info('🦋 Patchwing CLI v0.1.0');
        return;
      }

      final exitCode =
          await _runner.runCommand(argResults) ?? ExitCode.success.code;

      if (exitCode != ExitCode.success.code) {
        exit(exitCode);
      }
    } on FormatException catch (e) {
      _logger
        ..err(e.message)
        ..info('')
        ..info(_runner.usage);
      exit(ExitCode.usage.code);
    } catch (e) {
      _logger.err('未知错误: $e');
      exit(ExitCode.software.code);
    }
  }
}
