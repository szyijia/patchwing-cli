import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/flutter_project.dart';

/// pw init — 在 Flutter 项目中初始化 Patchwing
class InitCommand extends Command<int> {
  final Logger logger;

  InitCommand({required this.logger}) {
    argParser
      ..addOption('name', abbr: 'n', help: '应用名称')
      ..addOption('package-id', help: '包名（如 com.example.myapp）');
  }

  @override
  String get name => 'init';

  @override
  String get description => '在当前 Flutter 项目中初始化 Patchwing';

  @override
  Future<int> run() async {
    final projectDir = Directory.current.path;
    final project = FlutterProject(projectDir);

    // 检查是否是 Flutter 项目
    if (!project.isValid) {
      logger.err('当前目录不是 Flutter 项目（找不到 pubspec.yaml）');
      return 1;
    }

    // 检查是否已初始化
    final existingConfig = project.patchwingConfig;
    if (existingConfig != null) {
      final overwrite = logger.confirm('patchwing.yaml 已存在，是否覆盖？');
      if (!overwrite) {
        logger.info('已取消');
        return 0;
      }
    }

    // 获取包名
    var packageId = argResults!['package-id'] as String?;
    packageId ??= project.applicationId;
    if (packageId == null || packageId.isEmpty) {
      packageId = logger.prompt('📦 包名 (如 com.example.myapp):');
    }

    // 获取应用名称
    var appName = argResults!['name'] as String?;
    appName ??= project.pubspec['name'] as String? ?? packageId;

    logger.info('');
    logger.info('  📱 应用名称: $appName');
    logger.info('  📦 包名: $packageId');
    logger.info('  🏷️  版本: ${project.version}');
    logger.info('');

    // 在服务端创建 App（如果已登录）
    int? serverAppId;
    final apiKey = PatchwingConfig.getApiKey();
    if (apiKey != null) {
      final progress = logger.progress('在服务端注册应用...');
      try {
        final client = ApiClient();
        final result = await client.createApp(
          name: appName,
          packageId: packageId,
        );
        serverAppId = result['id'] as int?;
        progress.complete('应用已注册 (ID: $serverAppId)');
      } on ApiException catch (e) {
        if (e.statusCode == 409) {
          progress.complete('应用已存在');
          // 尝试从列表中获取 ID
          try {
            final apps = await ApiClient().listApps();
            final app = apps.firstWhere(
              (a) => (a as Map)['package_id'] == packageId,
              orElse: () => null,
            );
            if (app != null) {
              serverAppId = (app as Map)['id'] as int?;
            }
          } catch (_) {}
        } else {
          progress.fail('注册失败: ${e.message}');
        }
      } catch (e) {
        progress.fail('连接失败（可稍后重试）');
      }
    } else {
      logger.warn('未登录，跳过服务端注册。请先运行: pw login');
    }

    // 写入 patchwing.yaml
    project.writePatchwingConfig(
      appId: packageId,
      packageId: packageId,
      serverAppId: serverAppId,
    );

    // 写入 shorebird.yaml（updater 读取）
    project.writeShorebirdConfig(
      packageId: packageId,
      baseUrl: PatchwingConfig.getApiUrl(),
    );

    // 自动修改 pubspec.yaml（添加 shorebird.yaml 为 flutter asset）
    final pubspecModified = project.ensurePubspecAsset();
    if (pubspecModified) {
      logger.info('  📝 已自动修改 pubspec.yaml（添加 shorebird.yaml 为 asset）');
    }

    // 自动修改 AndroidManifest.xml（添加 INTERNET 权限）
    final manifestModified = project.ensureInternetPermission();
    if (manifestModified) {
      logger.info('  📝 已自动修改 AndroidManifest.xml（添加 INTERNET 权限）');
    }

    logger.info('');
    logger.success('✅ Patchwing 初始化完成！');
    logger.info('');
    logger.info('  已生成:');
    logger.info('    • patchwing.yaml — 项目配置');
    logger.info('    • shorebird.yaml — updater 配置');
    if (pubspecModified) {
      logger.info('    • pubspec.yaml — 已添加 shorebird.yaml asset');
    }
    if (manifestModified) {
      logger.info('    • AndroidManifest.xml — 已添加 INTERNET 权限');
    }
    logger.info('');
    logger.info('  下一步:');
    logger.info('    pw release  — 发布 baseline 版本');
    logger.info('');

    return 0;
  }
}
