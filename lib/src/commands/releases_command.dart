import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../core/flutter_project.dart';

/// pw releases — 列出发布版本
class ReleasesCommand extends Command<int> {
  final Logger logger;

  ReleasesCommand({required this.logger}) {
    argParser.addOption('app-id', help: '服务端 App ID');
  }

  @override
  String get name => 'releases';

  @override
  String get description => '列出应用的所有发布版本';

  @override
  Future<int> run() async {
    final client = ApiClient();

    // 获取 app_id
    int? appId;
    final argAppId = argResults!['app-id'] as String?;
    if (argAppId != null) {
      appId = int.tryParse(argAppId);
    } else {
      // 从当前项目配置获取
      final project = FlutterProject('.');
      final config = project.patchwingConfig;
      appId = config?['server_app_id'] as int?;

      if (appId == null) {
        // 尝试通过 package_id 查找
        final packageId = project.applicationId;
        if (packageId != null) {
          try {
            final apps = await client.listApps();
            final app = apps.firstWhere(
              (a) => (a as Map)['package_id'] == packageId,
              orElse: () => null,
            );
            if (app != null) appId = (app as Map)['id'] as int;
          } catch (_) {}
        }
      }
    }

    if (appId == null) {
      logger.err('无法确定 App ID，请指定 --app-id 或在项目目录中运行');
      return 1;
    }

    try {
      final releases = await client.listReleases(appId);

      if (releases.isEmpty) {
        logger.info('暂无发布版本');
        return 0;
      }

      logger.info('');
      logger.info('  ID  │ Version        │ ABI          │ Status  │ Created');
      logger.info(
        '  ────┼────────────────┼──────────────┼─────────┼──────────────',
      );

      for (final r in releases) {
        final map = r as Map<String, dynamic>;
        final id = map['id'].toString().padRight(3);
        final version = (map['version'] as String).padRight(14);
        final abi = (map['abi'] as String? ?? 'arm64-v8a').padRight(12);
        final status = (map['status'] as String? ?? 'active').padRight(7);
        final created = (map['created_at'] as String? ?? '').substring(0, 10);
        logger.info('  $id │ $version │ $abi │ $status │ $created');
      }

      logger.info('');
      logger.info('  共 ${releases.length} 个版本');
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
