import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../core/flutter_project.dart';

/// pw patches — 列出补丁
class PatchesCommand extends Command<int> {
  final Logger logger;

  PatchesCommand({required this.logger}) {
    argParser
      ..addOption('app-id', help: '服务端 App ID')
      ..addOption('release-id', help: '服务端 Release ID');
  }

  @override
  String get name => 'patches';

  @override
  String get description => '列出指定 release 的所有补丁';

  @override
  Future<int> run() async {
    final client = ApiClient();

    // 获取 app_id 和 release_id
    int? appId;
    int? releaseId;

    final argAppId = argResults!['app-id'] as String?;
    final argReleaseId = argResults!['release-id'] as String?;

    if (argAppId != null) appId = int.tryParse(argAppId);
    if (argReleaseId != null) releaseId = int.tryParse(argReleaseId);

    // 从项目配置自动获取
    if (appId == null || releaseId == null) {
      final project = FlutterProject('.');
      final config = project.patchwingConfig;
      appId ??= config?['server_app_id'] as int?;

      if (appId != null && releaseId == null) {
        // 获取最新的 release
        try {
          final releases = await client.listReleases(appId);
          if (releases.isNotEmpty) {
            releaseId = (releases.first as Map)['id'] as int;
          }
        } catch (_) {}
      }
    }

    if (appId == null || releaseId == null) {
      logger.err('无法确定 App ID 或 Release ID');
      logger.info('  请指定 --app-id 和 --release-id');
      return 1;
    }

    try {
      final patches = await client.listPatches(appId, releaseId);

      if (patches.isEmpty) {
        logger.info('暂无补丁');
        return 0;
      }

      logger.info('');
      logger.info('  #  │ Status    │ Size      │ Hash            │ Created');
      logger.info(
        '  ───┼───────────┼───────────┼─────────────────┼──────────────',
      );

      for (final p in patches) {
        final map = p as Map<String, dynamic>;
        final number = map['number'].toString().padRight(2);
        final status = (map['status'] as String? ?? 'active').padRight(9);
        final size = '${map['patch_size']} B'.padRight(9);
        final hash = (map['patch_hash'] as String? ?? '').padRight(15);
        final hashShort = hash.length > 15 ? hash.substring(0, 15) : hash;
        final created = (map['created_at'] as String? ?? '').length >= 10
            ? (map['created_at'] as String).substring(0, 10)
            : '';
        logger.info('  $number │ $status │ $size │ $hashShort │ $created');
      }

      logger.info('');
      logger.info('  共 ${patches.length} 个补丁');
      logger.info('');

      return 0;
    } on ApiException catch (e) {
      logger.err('查询失败: ${e.message}');
      return 1;
    } catch (e) {
      logger.err('连接失败: $e');
      return 1;
    }
  }
}
