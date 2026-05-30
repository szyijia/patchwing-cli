import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import 'commands/create_command.dart';
import 'commands/doctor_command.dart';
import 'commands/init_command.dart';
import 'commands/login_command.dart';
import 'commands/logout_command.dart';
import 'commands/patch_command.dart';
import 'commands/patches_command.dart';
import 'commands/release_command.dart';
import 'commands/releases_command.dart';
import 'commands/status_command.dart';

/// Patchwing CLI 主入口
class PatchwingCliRunner {
  final Logger _logger = Logger();

  Future<void> run(List<String> args) async {
    final runner = CommandRunner<int>(
      'pw',
      'Patchwing — Flutter 热更新 CLI 工具\n'
          '  用法: pw <command> [options]',
    );

    // 注册子命令
    runner.addCommand(LoginCommand(logger: _logger));
    runner.addCommand(LogoutCommand(logger: _logger));
    runner.addCommand(CreateCommand(logger: _logger));
    runner.addCommand(InitCommand(logger: _logger));
    runner.addCommand(ReleaseCommand(logger: _logger));
    runner.addCommand(PatchCommand(logger: _logger));
    runner.addCommand(ReleasesCommand(logger: _logger));
    runner.addCommand(PatchesCommand(logger: _logger));
    runner.addCommand(StatusCommand(logger: _logger));
    runner.addCommand(DoctorCommand(logger: _logger));

    try {
      final exitCode = await runner.run(args) ?? 0;
      exit(exitCode);
    } on UsageException catch (e) {
      _logger.err(e.message);
      _logger.info(e.usage);
      exit(64);
    } catch (e) {
      _logger.err('$e');
      exit(1);
    }
  }
}
