import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/engine_artifact.dart';
import '../core/flutter_project.dart';

/// pw patch — 构建新版本并生成/上传补丁
class PatchCommand extends Command<int> {
  final Logger logger;

  PatchCommand({required this.logger}) {
    argParser
      ..addOption('app-dir', help: 'Flutter 项目目录（默认当前目录）')
      ..addOption('release-id', help: '目标 release ID（默认自动检测）')
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
      ..addOption('bsdiff-bin', help: 'bsdiff 工具路径')
      ..addFlag('no-upload', help: '跳过上传到服务端', negatable: false);
  }

  @override
  String get name => 'patch';

  @override
  String get description => '构建新版本并生成/上传热更新补丁';

  @override
  Future<int> run() async {
    final appDir = argResults!['app-dir'] as String? ?? Directory.current.path;
    final noUpload = argResults!['no-upload'] as bool;
    final platforms = AndroidAbis.parse(argResults!['platforms'] as String?);
    var localEngine = argResults!['local-engine'] as String?;
    var localEngineSrc = argResults!['local-engine-src'] as String?;
    var localEngineHost = argResults!['local-engine-host'] as String?;
    var bsdiffBin = argResults!['bsdiff-bin'] as String?;

    // 自动检测 engine artifact
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

    if (!project.isValid) {
      logger.err('找不到 Flutter 项目: $appDir');
      return 1;
    }

    final packageId = project.applicationId;
    if (packageId == null) {
      logger.err('无法从 build.gradle 提取 applicationId');
      return 1;
    }

    // 确定 release_id
    var releaseId = argResults!['release-id'] as String?;
    releaseId ??= project.releaseId;

    // 查找 bsdiff 工具
    bsdiffBin ??= _findBsdiff(appDir);
    if (bsdiffBin == null || !File(bsdiffBin).existsSync()) {
      logger.err('找不到 bsdiff 工具');
      logger.info('  请指定 --bsdiff-bin 参数，或确保 patchwing_bsdiff 在 PATH 中');
      return 1;
    }

    // 查找 baseline
    final baselineDir = p.join(appDir, '.patchwing', releaseId);

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Patch                    ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');
    logger.info('  📦 包名:       $packageId');
    logger.info('  🔖 Release ID: $releaseId');
    logger.info('  🏗️  架构:       ${platforms.map((p) => p.name).join(", ")}');
    logger.info('');

    // 对每个架构执行 patch
    for (final abi in platforms) {
      final abiLabel = platforms.length > 1 ? ' [${abi.name}]' : '';

      // 查找对应架构的 baseline
      // 先尝试新的多架构目录结构，再回退到旧的平坦结构
      var baselinePath = p.join(baselineDir, abi.name, 'libapp.so');
      if (!File(baselinePath).existsSync()) {
        // 回退到旧的平坦结构（兼容旧版本 release 产物）
        baselinePath = p.join(baselineDir, 'libapp.so');
      }

      if (!File(baselinePath).existsSync()) {
        logger.err('找不到 baseline (${abi.name}): $baselinePath');
        logger.info('  请先运行 pw release，或确认 --release-id 正确');
        return 1;
      }

      final baselineSha = FlutterProject.fileSha256(baselinePath);
      logger.info('  📄 Baseline$abiLabel: ${baselineSha.substring(0, 16)}...');

      // --- 1) 构建新版 APK ---
      final buildProgress = logger.progress('[1/5]$abiLabel 构建新版 release APK');
      String apkPath;
      try {
        final engineName = abi.engineDir;
        apkPath = await project.buildReleaseApk(
          localEngine: engineName,
          localEngineSrc: localEngineSrc,
          localEngineHost: localEngineHost,
          abi: abi,
        );
        buildProgress.complete('APK 构建完成');
      } catch (e) {
        buildProgress.fail('构建失败: $e');
        return 1;
      }

      // --- 2) 提取新版 libapp.so ---
      final extractProgress = logger.progress('[2/5]$abiLabel 提取新版 libapp.so');
      final workDir = p.join(appDir, '.patchwing', '.work', abi.name);
      String newLibappPath;
      try {
        newLibappPath = await project.extractLibapp(apkPath, workDir, abi: abi);
        extractProgress.complete('提取完成');
      } catch (e) {
        extractProgress.fail('提取失败: $e');
        return 1;
      }

      final newSha = FlutterProject.fileSha256(newLibappPath);
      final newSize = FlutterProject.fileSize(newLibappPath);

      // 检查是否相同
      if (newSha == baselineSha) {
        logger.warn('$abiLabel 新版 libapp.so 与 baseline 完全相同，无需生成 patch');
        logger.info('  请确认你已修改了 Dart 代码');
        _cleanup(workDir);
        continue;
      }

      // --- 3) 生成 bsdiff patch ---
      final diffProgress = logger.progress('[3/5]$abiLabel 生成 bsdiff patch');
      final patchId =
          '${baselineSha.substring(0, 8)}_${newSha.substring(0, 8)}';
      final patchDir = p.join(baselineDir, abi.name, 'patches', patchId);
      final patchPath = p.join(patchDir, 'patch.bin');

      try {
        Directory(patchDir).createSync(recursive: true);

        final sw = Stopwatch()..start();
        final result = await Process.run(bsdiffBin, [
          baselinePath,
          newLibappPath,
          patchPath,
        ]);
        sw.stop();

        if (result.exitCode != 0) {
          throw Exception('bsdiff 失败: ${result.stderr}');
        }

        final patchSize = FlutterProject.fileSize(patchPath);
        final ratio = (patchSize * 100 / newSize).toStringAsFixed(1);
        diffProgress.complete(
          'patch.bin: $patchSize bytes ($ratio%, 耗时 ${sw.elapsed.inSeconds}s)',
        );
      } catch (e) {
        diffProgress.fail('生成 patch 失败: $e');
        return 1;
      }

      final patchSha = FlutterProject.fileSha256(patchPath);
      final patchSize = FlutterProject.fileSize(patchPath);

      // --- 4) 保存元数据 ---
      final metaProgress = logger.progress('[4/5]$abiLabel 保存元数据');
      try {
        final metaContent = '''
{
  "patch_id": "$patchId",
  "abi": "${abi.name}",
  "from_sha256": "$baselineSha",
  "to_sha256": "$newSha",
  "to_size": $newSize,
  "algo": "bsdiff",
  "size": $patchSize,
  "patch_sha256": "$patchSha",
  "created_at": "${DateTime.now().toUtc().toIso8601String()}"
}
''';
        File(p.join(patchDir, 'meta.json')).writeAsStringSync(metaContent);
        metaProgress.complete('元数据已保存');
      } catch (e) {
        metaProgress.fail('保存失败: $e');
        return 1;
      }

      // --- 5) 上传到服务端 ---
      if (noUpload) {
        logger.info('[5/5]$abiLabel 跳过上传（--no-upload）');
      } else {
        final uploadProgress = logger.progress('[5/5]$abiLabel 上传 patch 到服务端');
        try {
          final client = ApiClient();

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
            }
          }

          if (serverAppId == null) {
            throw ApiException('找不到应用，请先运行 pw init');
          }

          final releases = await client.listReleases(serverAppId);
          final release = releases.firstWhere(
            (r) => (r as Map)['version'] == releaseId,
            orElse: () => null,
          );

          if (release == null) {
            throw ApiException('找不到 release: $releaseId，请先运行 pw release');
          }

          final serverReleaseId = (release as Map)['id'] as int;

          await client.createPatch(
            appId: serverAppId,
            releaseId: serverReleaseId,
            patchPath: patchPath,
            targetHash: newSha,
          );

          uploadProgress.complete('上传成功');
        } on ApiException catch (e) {
          uploadProgress.fail('上传失败: ${e.message}');
          return 1;
        } catch (e) {
          uploadProgress.fail('连接失败: $e');
          return 1;
        }
      }

      // 清理临时文件
      _cleanup(workDir);
    }

    logger.info('');
    logger.success('✅ Patch 完成！');
    logger.info('');
    logger.info('  Release ID:  $releaseId');
    logger.info('  架构:        ${platforms.map((p) => p.name).join(", ")}');
    logger.info('  产物目录:    $baselineDir/');
    logger.info('');
    logger.info('  用户手机将在下次启动时自动应用此补丁 🎉');
    logger.info('');

    return 0;
  }

  /// 查找 bsdiff 工具
  String? _findBsdiff(String appDir) {
    // 1. 项目根目录的 bsdiff/patchwing_bsdiff
    final projectRoot = _findProjectRoot(appDir);
    if (projectRoot != null) {
      final path = p.join(projectRoot, 'bsdiff', 'patchwing_bsdiff');
      if (File(path).existsSync()) return path;
    }

    // 2. 环境变量
    final envPath = Platform.environment['PATCHWING_BSDIFF_BIN'];
    if (envPath != null && File(envPath).existsSync()) return envPath;

    // 3. PATH 中查找
    try {
      final result = Process.runSync('which', ['patchwing_bsdiff']);
      if (result.exitCode == 0) {
        return (result.stdout as String).trim();
      }
    } catch (_) {}

    return null;
  }

  /// 向上查找项目根目录（包含 bsdiff/ 目录的）
  String? _findProjectRoot(String dir) {
    var current = dir;
    for (var i = 0; i < 5; i++) {
      if (Directory(p.join(current, 'bsdiff')).existsSync()) {
        return current;
      }
      final parent = p.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    return null;
  }

  void _cleanup(String dir) {
    try {
      Directory(dir).deleteSync(recursive: true);
    } catch (_) {}
  }
}
