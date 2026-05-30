import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/flutter_project.dart';

/// pw status — 显示当前项目状态
class StatusCommand extends Command<int> {
  final Logger logger;

  StatusCommand({required this.logger});

  @override
  String get name => 'status';

  @override
  String get description => '显示当前项目的 Patchwing 状态';

  @override
  Future<int> run() async {
    final projectDir = Directory.current.path;
    final project = FlutterProject(projectDir);

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Status                   ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');

    // 项目信息
    if (!project.isValid) {
      logger.warn('  ⚠️  当前目录不是 Flutter 项目');
      return 0;
    }

    logger.info('  📁 项目目录: $projectDir');
    logger.info('  📦 包名:     ${project.applicationId ?? "未知"}');
    logger.info('  🏷️  版本:     ${project.version}');
    logger.info('');

    // Patchwing 配置
    final config = project.patchwingConfig;
    if (config == null) {
      logger.warn('  ⚠️  未初始化 Patchwing（运行 pw init）');
    } else {
      logger.info('  📋 Patchwing 配置:');
      logger.info('     app_id:        ${config['app_id']}');
      logger.info('     server_app_id: ${config['server_app_id'] ?? "未设置"}');
      logger.info('');
    }

    // 认证状态
    final creds = PatchwingConfig.loadCredentials();
    if (creds == null) {
      logger.warn('  🔒 未登录（运行 pw login）');
    } else {
      logger.info('  🔓 已登录:');
      logger.info('     邮箱:    ${creds['email']}');
      logger.info('     API URL: ${creds['api_url']}');
      logger.info('');
    }

    // 本地产物
    final patchwingDir = Directory(p.join(projectDir, '.patchwing'));
    if (patchwingDir.existsSync()) {
      logger.info('  📦 本地产物:');
      final releases = patchwingDir.listSync().whereType<Directory>().where(
        (d) => !p.basename(d.path).startsWith('.'),
      );
      for (final dir in releases) {
        final name = p.basename(dir.path);
        final patchesDir = Directory(p.join(dir.path, 'patches'));
        final patchCount = patchesDir.existsSync()
            ? patchesDir.listSync().length
            : 0;
        logger.info('     $name ($patchCount patches)');
      }
      logger.info('');
    }

    // 服务端状态
    if (creds != null) {
      final progress = logger.progress('检查服务端连接');
      try {
        final client = ApiClient();
        final healthy = await client.healthCheck();
        if (healthy) {
          progress.complete('服务端连接正常');
        } else {
          progress.fail('服务端无响应');
        }
      } catch (e) {
        progress.fail('连接失败: $e');
      }
    }

    logger.info('');
    return 0;
  }
}
