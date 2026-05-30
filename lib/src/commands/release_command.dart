import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/engine_artifact.dart';
import '../core/flutter_project.dart';

/// pw release — 构建并发布 baseline 版本
class ReleaseCommand extends Command<int> {
  final Logger logger;

  ReleaseCommand({required this.logger}) {
    argParser
      ..addOption('app-dir', help: 'Flutter 项目目录（默认当前目录）')
      ..addOption('platforms',
          help: '目标架构，逗号分隔（默认 arm64-v8a）',
          defaultsTo: 'arm64-v8a',
          allowed: [
            'arm64-v8a',
            'armeabi-v7a',
            'x86_64',
            'arm64',
            'arm',
            'x64'
          ])
      ..addOption('local-engine', help: 'local engine 名称')
      ..addOption('local-engine-src', help: 'local engine src 路径')
      ..addOption('local-engine-host', help: 'local engine host 名称')
      ..addFlag('no-upload', help: '跳过上传到服务端', negatable: false);
  }

  @override
  String get name => 'release';

  @override
  String get description => '构建并发布 baseline 版本';

  @override
  Future<int> run() async {
    final appDir = argResults!['app-dir'] as String? ?? Directory.current.path;
    final noUpload = argResults!['no-upload'] as bool;
    final platforms = AndroidAbis.parse(argResults!['platforms'] as String?);
    var localEngine = argResults!['local-engine'] as String?;
    var localEngineSrc = argResults!['local-engine-src'] as String?;
    var localEngineHost = argResults!['local-engine-host'] as String?;

    // 自动检测 engine artifact（如果用户没有手动指定）
    if (localEngine == null && localEngineSrc == null) {
      // 先尝试直接获取
      var engineArgs = EngineArtifact.getLocalEngineArgs();

      // 如果找不到，尝试自动检测版本并下载
      if (engineArgs == null) {
        final detectedVersion = EngineArtifact.detectFlutterVersion();
        final engineProgress = logger.progress(
            '检测到 Flutter ${detectedVersion ?? "未知"}，正在准备 Engine Artifact');
        final version = await EngineArtifact.ensureEngine(
          flutterVersion: detectedVersion,
          onProgress: (msg) => logger.detail(msg),
        );
        if (version != null) {
          engineArgs =
              EngineArtifact.getLocalEngineArgs(flutterVersion: version);
          engineProgress.complete('Engine Artifact 就绪 (Flutter $version)');
        } else {
          engineProgress.fail('Engine Artifact 不可用');
          logger.err('找不到 Patchwing Engine Artifact');
          logger.info('  当前 Flutter 版本: ${detectedVersion ?? "未知"}');
          logger
              .info('  支持的版本: ${EngineArtifact.supportedVersions.join(", ")}');
          logger.info('  请运行 pw doctor 查看安装指引');
          return 1;
        }
      }

      if (engineArgs != null) {
        localEngine = engineArgs['local-engine'];
        localEngineSrc = engineArgs['local-engine-src'];
        localEngineHost = engineArgs['local-engine-host'];
      }
    }

    final project = FlutterProject(appDir);

    // 验证项目
    if (!project.isValid) {
      logger.err('找不到 Flutter 项目: $appDir');
      return 1;
    }

    final packageId = project.applicationId;
    if (packageId == null) {
      logger.err('无法从 build.gradle 提取 applicationId');
      return 1;
    }

    final releaseId = project.releaseId;
    final version = project.version;

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Release                  ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');
    logger.info('  📦 包名:       $packageId');
    logger.info('  🏷️  版本:       $version');
    logger.info('  🔖 Release ID: $releaseId');
    logger.info('  🏗️  架构:       ${platforms.map((p) => p.name).join(", ")}');
    logger.info('');

    // --- 0) 先更新 shorebird.yaml（确保构建时打包正确的配置） ---
    final configProgress = logger.progress('[1/4] 更新配置文件');
    try {
      project.writeShorebirdConfig(
        packageId: packageId,
        baseUrl: PatchwingConfig.getApiUrl(),
      );
      configProgress.complete('shorebird.yaml 已更新');
    } catch (e) {
      configProgress.fail('更新配置失败: $e');
      return 1;
    }

    // --- 对每个架构执行构建、提取、上传 ---
    for (final abi in platforms) {
      final abiLabel = platforms.length > 1 ? ' [${abi.name}]' : '';

      // --- 1) 构建 APK ---
      final buildProgress = logger.progress('[2/4]$abiLabel 构建 release APK');
      String apkPath;
      try {
        // 多架构时需要为每个架构指定对应的 local-engine
        final engineName = abi.engineDir;
        apkPath = await project.buildReleaseApk(
          localEngine: engineName,
          localEngineSrc: localEngineSrc,
          localEngineHost: localEngineHost,
          abi: abi,
        );
        final size = FlutterProject.fileSize(apkPath);
        buildProgress.complete(
          'APK 构建完成 (${(size / 1024 / 1024).toStringAsFixed(1)} MB)',
        );
      } catch (e) {
        buildProgress.fail('构建失败: $e');
        return 1;
      }

      // --- 2) 提取 baseline libapp.so ---
      final extractProgress =
          logger.progress('[3/4]$abiLabel 提取 baseline libapp.so');
      final buildDir = p.join(appDir, '.patchwing', releaseId, abi.name);
      String baselinePath;
      try {
        baselinePath = await project.extractLibapp(apkPath, buildDir, abi: abi);
        final sha = FlutterProject.fileSha256(baselinePath);
        final size = FlutterProject.fileSize(baselinePath);
        extractProgress.complete(
          'libapp.so: $size bytes, sha256: ${sha.substring(0, 16)}...',
        );
      } catch (e) {
        extractProgress.fail('提取失败: $e');
        return 1;
      }

      // --- 3) 上传到服务端 ---
      if (noUpload) {
        logger.info('[4/4]$abiLabel 跳过上传（--no-upload）');
      } else {
        final uploadProgress =
            logger.progress('[4/4]$abiLabel 上传 baseline 到服务端');
        try {
          final client = ApiClient();

          // 获取 server_app_id
          final config = project.patchwingConfig;
          int? serverAppId = config?['server_app_id'] as int?;

          if (serverAppId == null) {
            final apps = await client.listApps();
            final app = apps.firstWhere(
              (a) => (a as Map)['package_id'] == packageId,
              orElse: () => null,
            );
            if (app != null) {
              serverAppId = (app as Map)['id'] as int;
            } else {
              final result = await client.createApp(
                name: packageId.split('.').last,
                packageId: packageId,
              );
              serverAppId = result['id'] as int;
            }
          }

          final result = await client.createRelease(
            appId: serverAppId,
            version: releaseId,
            baselinePath: baselinePath,
            flutterVersion: _getFlutterVersion(),
          );

          uploadProgress.complete('上传成功 (Release ID: ${result['id']})');
        } on ApiException catch (e) {
          uploadProgress.fail('上传失败: ${e.message}');
          return 1;
        } catch (e) {
          uploadProgress.fail('连接失败: $e');
          logger.info('  可稍后使用 --no-upload 跳过上传');
          return 1;
        }
      }

      // 保存 APK 到产物目录
      final distApk = p.join(buildDir, abi.apkSuffix);
      File(apkPath).copySync(distApk);
    }

    logger.info('');
    logger.success('✅ Release 完成！');
    logger.info('');
    logger.info('  Release ID:  $releaseId');
    logger.info('  架构:        ${platforms.map((p) => p.name).join(", ")}');
    logger.info('  产物目录:    ${p.join(appDir, '.patchwing', releaseId)}/');
    logger.info('');
    logger.info('  下一步: 修改代码后运行 pw patch');
    logger.info('');

    return 0;
  }

  String? _getFlutterVersion() {
    try {
      final result = Process.runSync('flutter', ['--version']);
      final output = result.stdout as String;
      final match = RegExp(r'Flutter (\S+)').firstMatch(output);
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }
}
