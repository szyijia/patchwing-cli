import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/flutter_project.dart';
import '../engine/engine_manager.dart';
import '../config/patchwing_yaml.dart';
import '../flutter/flutter_detector.dart';

/// pw init — 在 Flutter 项目中初始化 Patchwing
///
/// 核心职责（参考 Shorebird 的 init + cache 结合）：
/// 1. 检查 Flutter 项目有效性（pubspec.yaml）
/// 2. 检测 Flutter 版本，写入 patchwing.yaml（flutter_version 字段）
/// 3. 按需下载对应版本的 Engine Artifact（~/.patchwing/engine/$VERSION/）
/// 4. 注册应用（如有认证）
/// 5. 生成 patchwing.yaml / shorebird.yaml
/// 6. 修改 pubspec.yaml 和 AndroidManifest.xml
class InitCommand extends Command<int> {
  final Logger logger;

  InitCommand({required this.logger}) {
    argParser
      ..addOption('name', abbr: 'n', help: '应用名称')
      ..addOption('package-id', help: '包名（如 com.example.myapp）')
      ..addOption('flutter-version', help: '强制指定 Flutter 版本（跳过自动检测）')
      ..addFlag('skip-engine', help: '跳过 Engine 下载（仅用于测试）', negatable: false);
  }

  @override
  String get name => 'init';

  @override
  String get description => '在当前 Flutter 项目中初始化 Patchwing';

  @override
  Future<int> run() async {
    final projectDir = Directory.current.path;
    final project = FlutterProject(projectDir);

    // 1. 检查是否是 Flutter 项目
    if (!project.isValid) {
      logger.err('当前目录不是 Flutter 项目（找不到 pubspec.yaml）');
      logger.info('请在 Flutter 项目根目录下运行 pw init');
      return 1;
    }

    // 检查是否已初始化
    final existingConfig = PatchwingYaml.load(projectDir);
    if (existingConfig != null) {
      final overwrite = logger.confirm('patchwing.yaml 已存在，是否覆盖？');
      if (!overwrite) {
        logger.info('已取消');
        return 0;
      }
    }

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Init                     ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');

    // 2. 检测 Flutter 版本
    final flutterVersion = await _detectFlutterVersion();
    if (flutterVersion == null) {
      logger.err('无法检测 Flutter 版本，请确保 flutter 命令可用');
      return 1;
    }
    logger.info('  🔧 检测到 Flutter 版本: $flutterVersion');

    // 3. 按需下载 Engine Artifact（核心改进）
    final skipEngine = argResults!['skip-engine'] as bool;
    if (!skipEngine) {
      final engineResult = await _ensureEngine(flutterVersion);
      if (engineResult == null) {
        logger.err('Engine Artifact 准备失败，初始化中断');
        logger.info('  可尝试: pw doctor --fix 修复环境问题');
        logger.info('  或添加 --skip-engine 跳过引擎下载（仅测试）');
        return 1;
      }
    } else {
      logger.warn('⚠️  已跳过 Engine Artifact 下载（--skip-engine）');
    }

    // 4. 获取包名 / 应用名称
    var packageId = argResults!['package-id'] as String?;
    packageId ??= project.applicationId;
    if (packageId == null || packageId.isEmpty) {
      packageId = logger.prompt('📦 包名 (如 com.example.myapp):');
    }

    var appName = argResults!['name'] as String?;
    appName ??= project.pubspec['name'] as String? ?? packageId;

    logger.info('');
    logger.info('  📱 应用名称: $appName');
    logger.info('  📦 包名: $packageId');
    logger.info('  🏷️  版本: ${project.version}');
    logger.info('  🔧 Flutter: $flutterVersion');
    logger.info('');

    // 5. 在服务端创建 App（如果已登录）
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

    // 6. 写入 patchwing.yaml（包含 flutter_version）
    final config = PatchwingYaml(
      appId: packageId,
      baseUrl: PatchwingConfig.getApiUrl(),
      flutterVersion: flutterVersion,
      releaseId: project.releaseId,
      serverAppId: serverAppId,
    );
    await config.save(projectDir);

    // 7. 写入 shorebird.yaml（updater 读取）
    project.writeShorebirdConfig(
      packageId: packageId,
      baseUrl: PatchwingConfig.getApiUrl(),
    );

    // 8. 自动修改 pubspec.yaml
    final pubspecModified = project.ensurePubspecAsset();
    if (pubspecModified) {
      logger.info('  📝 已自动修改 pubspec.yaml（添加 shorebird.yaml 为 asset）');
    }

    // 9. 自动修改 AndroidManifest.xml
    final manifestModified = project.ensureInternetPermission();
    if (manifestModified) {
      logger.info('  📝 已自动修改 AndroidManifest.xml（添加 INTERNET 权限）');
    }

    // 10. 完成提示
    logger.info('');
    logger.success('✅ Patchwing 初始化完成！');
    logger.info('');
    logger.info('  已生成:');
    logger.info('    • patchwing.yaml — 项目配置（含 Flutter $flutterVersion）');
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

  /// 检测 Flutter 版本
  /// 优先级：命令行参数 > 自动检测 > 失败
  Future<String?> _detectFlutterVersion() async {
    // 1. 命令行参数强制指定
    final cliVersion = argResults!['flutter-version'] as String?;
    if (cliVersion != null && cliVersion.isNotEmpty) {
      logger.info('  📌 使用命令行指定的 Flutter 版本: $cliVersion');
      return cliVersion;
    }

    // 2. 自动检测
    final detector = FlutterDetector();
    final detected = await detector.getFlutterVersion();
    if (detected != null) {
      return detected;
    }

    return null;
  }

  /// 确保 Engine Artifact 可用
  /// 返回下载成功的 engine 对应的 flutter 版本，失败返回 null
  Future<String?> _ensureEngine(String flutterVersion) async {
    final engineManager = EngineManager();

    // 检查是否已缓存
    if (engineManager.isCached(flutterVersion)) {
      logger.info('  ✓ Engine Artifact 已缓存');
      return flutterVersion;
    }

    // 未缓存，开始下载
    final progress =
        logger.progress('下载 Engine Artifact (Flutter $flutterVersion)');
    final success = await engineManager.ensureEngine(
      flutterVersion: flutterVersion,
      onProgress: (msg) => logger.detail(msg),
    );

    if (success != null) {
      progress.complete('Engine Artifact 就绪');
      return success;
    } else {
      progress.fail('Engine Artifact 下载失败');
      return null;
    }
  }
}
