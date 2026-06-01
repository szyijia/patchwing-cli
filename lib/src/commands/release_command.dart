import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/flutter_project.dart';
import '../engine/engine_manager.dart';
import '../config/patchwing_yaml.dart';
import '../flutter/flutter_detector.dart';

/// pw release — 构建并发布 baseline 版本
///
/// 核心职责：
/// 1. 从 patchwing.yaml 读取 flutter_version（项目绑定的版本）
/// 2. 使用 EngineManager 获取对应版本引擎的 local-engine 参数
/// 3. 构建 release APK
/// 4. 提取 libapp.so 上传到服务端
///
/// 跨版本补丁支持：
/// - 使用 --patch-from 指定来源 release，可以生成从任意旧版本到新版本的 patch
/// - 不指定时，默认只对当前 release 生成 baseline（无 patch）
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
      ..addOption('local-engine', help: 'local engine 名称（手动指定）')
      ..addOption('local-engine-src', help: 'local engine src 路径（手动指定）')
      ..addOption('local-engine-host', help: 'local engine host 名称（手动指定）')
      ..addOption('patch-from',
          help: '来源 release ID，指定后生成从该版本到当前版本的 patch\n'
              '例: --patch-from 1.0.0_1')
      ..addOption('bsdiff-bin', help: 'bsdiff 工具路径')
      ..addFlag('force', help: '如果版本已存在，强制删除旧版本后重新发布', negatable: false)
      ..addFlag('no-upload', help: '跳过上传到服务端', negatable: false)
      ..addFlag('skip-engine-check',
          help: '跳过 Engine Artifact 检查', negatable: false);
  }

  @override
  String get name => 'release';

  @override
  String get description => '构建并发布 baseline 版本';

  @override
  Future<int> run() async {
    final appDir = argResults!['app-dir'] as String? ?? Directory.current.path;
    final noUpload = argResults!['no-upload'] as bool;
    final skipEngineCheck = argResults!['skip-engine-check'] as bool;
    final force = argResults!['force'] as bool;
    final patchFrom = argResults!['patch-from'] as String?;
    var bsdiffBin = argResults!['bsdiff-bin'] as String?;
    final platforms = AndroidAbis.parse(argResults!['platforms'] as String?);

    var localEngine = argResults!['local-engine'] as String?;
    var localEngineSrc = argResults!['local-engine-src'] as String?;
    var localEngineHost = argResults!['local-engine-host'] as String?;

    final project = FlutterProject(appDir);

    // 验证项目
    if (!project.isValid) {
      logger.err('找不到 Flutter 项目: $appDir');
      return 1;
    }

    // 读取项目配置
    final config = PatchwingYaml.load(appDir);
    if (config == null) {
      logger.err('未找到 patchwing.yaml，请先运行 pw init');
      return 1;
    }

    final packageId = project.applicationId;
    if (packageId == null) {
      logger.err('无法从 build.gradle 提取 applicationId');
      return 1;
    }

    // 确定要使用的 Flutter 版本
    String? flutterVersion;
    if (config.flutterVersion != null) {
      flutterVersion = config.flutterVersion;
      logger.detail('使用 project flutter_version: $flutterVersion');
    } else {
      // 自动检测
      final detector = FlutterDetector();
      flutterVersion = await detector.getFlutterVersion();
      logger
          .warn('patchwing.yaml 未指定 flutter_version，使用检测到的版本: $flutterVersion');
    }

    final releaseId = project.releaseId;
    final version = project.version;
    final isCrossVersionPatch = patchFrom != null;

    // 提前检查远程是否有同名 release
    if (!noUpload) {
      final duplicationCheck = logger.progress('检查版本是否已存在');
      try {
        final client = ApiClient();
        int? serverAppId = config.serverAppId;

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

        if (serverAppId != null) {
          final releases = await client.listReleases(serverAppId);
          final existingReleases = releases
              .where(
                (r) => (r as Map)['version'] == releaseId,
              )
              .toList();

          if (existingReleases.isNotEmpty) {
            duplicationCheck.complete('版本已存在');
            if (force) {
              logger.warn('⚠️  版本 $releaseId 已存在，--force 将删除旧版本后重建');
            } else {
              logger.err('版本 $releaseId 已存在');
              logger.info('');
              logger.info('  如需重新发布，请使用 --force 参数:');
              logger.info('    pw release --force');
              logger.info('');
              logger.info('  或使用新的版本号：');
              logger.info('    pubspec.yaml 中增加 build number 后重新发布');
              return 1;
            }
          } else {
            duplicationCheck.complete('版本可用');
          }
        } else {
          duplicationCheck.complete('新应用');
        }
      } catch (e) {
        duplicationCheck.fail('检查失败: $e');
      }
    }

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Release                  ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');
    logger.info('  📦 包名:       $packageId');
    logger.info('  🏷️  版本:       $version');
    logger.info('  🔖 Release ID: $releaseId');
    logger.info('  🔧 Flutter:    $flutterVersion');
    logger.info('  🏗️  架构:       ${platforms.map((p) => p.name).join(", ")}');
    if (isCrossVersionPatch) {
      logger.info('  📎 Patch From: $patchFrom (跨版本 patch)');
    }
    logger.info('');

    // 查找 bsdiff 工具（如果需要生成 patch）
    if (isCrossVersionPatch) {
      bsdiffBin ??= _findBsdiff(appDir);
      if (bsdiffBin == null || !File(bsdiffBin).existsSync()) {
        logger.err('找不到 bsdiff 工具，无法生成 patch');
        logger.info('  请指定 --bsdiff-bin 参数，或确保 patchwing_bsdiff 在 PATH 中');
        return 1;
      }
    }

    // 自动获取 engine 参数（如果用户没有手动指定）
    if (localEngine == null && localEngineSrc == null && !skipEngineCheck) {
      final engineProgress =
          logger.progress('准备 Engine Artifact (Flutter $flutterVersion)');

      final engineManager = EngineManager();
      final engineArgs =
          engineManager.getLocalEngineArgs(flutterVersion: flutterVersion!);

      if (engineArgs != null) {
        localEngine = engineArgs['local-engine'];
        localEngineSrc = engineArgs['local-engine-src-path'];
        localEngineHost = engineArgs['local-engine-host'];
        engineProgress.complete('Engine Artifact 就绪 (路径: $localEngineSrc)');
      } else {
        // 尝试自动下载
        final ensured = await engineManager.ensureEngine(
          flutterVersion: flutterVersion,
          onProgress: (msg) => logger.detail(msg),
        );

        if (ensured != null) {
          final args =
              engineManager.getLocalEngineArgs(flutterVersion: ensured);
          if (args != null) {
            localEngine = args['local-engine'];
            localEngineSrc = args['local-engine-src-path'];
            localEngineHost = args['local-engine-host'];
            engineProgress
                .complete('Engine Artifact 下载并准备就绪 (Flutter $ensured)');
          } else {
            engineProgress.fail('Engine Artifact 路径错误');
            return 1;
          }
        } else {
          engineProgress.fail('Engine Artifact 不可用');
          logger.err('找不到 Patchwing Engine Artifact');
          logger.info('  Flutter 版本: $flutterVersion');
          logger.info('  运行 pw doctor --fix 自动下载');
          logger.info('  或运行 pw init 重新初始化');
          return 1;
        }
      }
    } else if (skipEngineCheck) {
      logger.warn('⚠️  已跳过 Engine Artifact 检查（--skip-engine-check）');
    }

    // --- 0) 先更新 shorebird.yaml ---
    final configProgress =
        logger.progress('[1/${isCrossVersionPatch ? 5 : 4}] 更新配置文件');
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

      // 多架构时调整 engine name
      var currentLocalEngine = localEngine;
      if (platforms.length > 1) {
        currentLocalEngine = abi.engineDir;
      }

      // --- 1) 构建 APK ---
      final buildProgress = logger.progress(
          '[2/${isCrossVersionPatch ? 5 : 4}]$abiLabel 构建 release APK');
      String apkPath;
      try {
        apkPath = await project.buildReleaseApk(
          localEngine: currentLocalEngine,
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

      // --- 2) 提取当前 release 的 libapp.so ---
      final extractProgress = logger
          .progress('[3/${isCrossVersionPatch ? 5 : 4}]$abiLabel 提取 libapp.so');
      final buildDir = p.join(appDir, '.patchwing', releaseId, abi.name);
      String targetLibappPath;
      try {
        targetLibappPath =
            await project.extractLibapp(apkPath, buildDir, abi: abi);
        final sha = FlutterProject.fileSha256(targetLibappPath);
        final size = FlutterProject.fileSize(targetLibappPath);
        extractProgress.complete(
          'libapp.so: $size bytes, sha256: ${sha.substring(0, 16)}...',
        );
      } catch (e) {
        extractProgress.fail('提取失败: $e');
        return 1;
      }

      // --- 3) 上传到服务端（baseline） ---
      int? serverReleaseId;
      if (noUpload) {
        logger.info(
            '[4/${isCrossVersionPatch ? 5 : 4}]$abiLabel 跳过上传（--no-upload）');
      } else {
        final uploadProgress = logger.progress(
            '[4/${isCrossVersionPatch ? 5 : 4}]$abiLabel 上传 baseline 到服务端');
        try {
          final client = ApiClient();
          int? serverAppId = config.serverAppId;

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
            baselinePath: targetLibappPath,
            flutterVersion: flutterVersion,
            abi: abi.name,
            force: force,
          );

          serverReleaseId = result['id'] as int?;
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

      // --- 4) 跨版本 patch 生成 ---
      if (isCrossVersionPatch) {
        final patchResult = await _generateCrossVersionPatch(
          appDir: appDir,
          packageId: packageId,
          abi: abi,
          abiLabel: abiLabel,
          releaseId: releaseId,
          patchFrom: patchFrom,
          targetLibappPath: targetLibappPath,
          bsdiffBin: bsdiffBin!,
          serverReleaseId: serverReleaseId,
          noUpload: noUpload,
        );
        if (patchResult != 0) return patchResult;
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
    if (isCrossVersionPatch) {
      logger.info('  Patch From:  $patchFrom → $releaseId');
    }
    logger.info('');
    if (!isCrossVersionPatch) {
      logger.info('  下一步: 修改代码后运行 pw patch');
    }
    logger.info('');

    return 0;
  }

  /// 生成跨版本 patch
  Future<int> _generateCrossVersionPatch({
    required String appDir,
    required String packageId,
    required AndroidAbi abi,
    required String abiLabel,
    required String releaseId,
    required String patchFrom,
    required String targetLibappPath,
    required String bsdiffBin,
    int? serverReleaseId,
    required bool noUpload,
  }) async {
    // 查找来源 release 的 baseline
    final sourceBaselineDir = p.join(appDir, '.patchwing', patchFrom, abi.name);
    var sourceBaselinePath = p.join(sourceBaselineDir, 'libapp.so');

    // 本地不存在则从服务端下载
    if (!File(sourceBaselinePath).existsSync()) {
      final downloadProgress =
          logger.progress('[5/5]$abiLabel 下载 baseline ($patchFrom)');
      try {
        final client = ApiClient();
        int? serverAppId = PatchwingYaml.load(appDir)?.serverAppId;

        if (serverAppId != null) {
          final releases = await client.listReleases(serverAppId);
          final sourceRelease = releases.firstWhere(
            (r) => (r as Map)['version'] == patchFrom,
            orElse: () => null,
          );

          if (sourceRelease != null) {
            final path = (sourceRelease as Map)['base_so_path'] as String?;
            if (path != null) {
              final url = '${client.baseUrl}/api/v1/files/$path';
              await client.downloadFile(url, sourceBaselinePath);
            }
          }
        }

        if (File(sourceBaselinePath).existsSync()) {
          downloadProgress.complete('下载完成');
        } else {
          downloadProgress.fail('找不到来源 baseline');
          logger.err('无法在本地或服务端找到 release $patchFrom 的 baseline');
          logger.info('  本地路径: $sourceBaselinePath');
          logger.info('  请先运行 pw release 构建该版本');
          return 1;
        }
      } catch (e) {
        downloadProgress.fail('下载失败: $e');
        return 1;
      }
    }

    final sourceSha = FlutterProject.fileSha256(sourceBaselinePath);
    final targetSha = FlutterProject.fileSha256(targetLibappPath);

    // 检查是否相同
    if (sourceSha == targetSha) {
      logger.warn('$abiLabel 来源与目标版本完全相同，无需生成 patch');
      return 0;
    }

    // 生成 bsdiff patch
    final diffProgress = logger.progress('[5/5]$abiLabel 生成跨版本 patch');
    final patchId = '${patchFrom}_${releaseId}_${abi.name}';
    final patchDir = p.join(
      appDir,
      '.patchwing',
      releaseId,
      abi.name,
      'patches',
      patchId,
    );
    final patchPath = p.join(patchDir, 'patch.bin');

    try {
      Directory(patchDir).createSync(recursive: true);

      final sw = Stopwatch()..start();
      final result = await Process.run(bsdiffBin, [
        sourceBaselinePath,
        targetLibappPath,
        patchPath,
      ]);
      sw.stop();

      if (result.exitCode != 0) {
        throw Exception('bsdiff 失败: ${result.stderr}');
      }

      final patchSize = FlutterProject.fileSize(patchPath);
      final targetSize = FlutterProject.fileSize(targetLibappPath);
      final ratio = (patchSize * 100 / targetSize).toStringAsFixed(1);
      diffProgress.complete(
        'patch.bin: $patchSize bytes ($ratio%, 耗时 ${sw.elapsed.inSeconds}s)',
      );
    } catch (e) {
      diffProgress.fail('生成 patch 失败: $e');
      return 1;
    }

    final patchSha = FlutterProject.fileSha256(patchPath);
    final patchSize = FlutterProject.fileSize(patchPath);

    // 保存元数据
    final metaPath = p.join(patchDir, 'meta.json');
    final metaContent = '''
{
  "patch_id": "$patchId",
  "abi": "${abi.name}",
  "source_version": "$patchFrom",
  "target_version": "$releaseId",
  "from_sha256": "$sourceSha",
  "to_sha256": "$targetSha",
  "to_size": ${FlutterProject.fileSize(targetLibappPath)},
  "algo": "bsdiff",
  "size": $patchSize,
  "patch_sha256": "$patchSha",
  "is_cross_version": true,
  "created_at": "${DateTime.now().toUtc().toIso8601String()}"
}
''';
    File(metaPath).writeAsStringSync(metaContent);

    // 上传到服务端
    if (!noUpload && serverReleaseId != null) {
      final uploadProgress = logger.progress('[5/5]$abiLabel 上传跨版本 patch');
      try {
        final client = ApiClient();
        int? serverAppId = PatchwingYaml.load(appDir)?.serverAppId;

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

        if (serverAppId != null) {
          // 查找来源 release 的 server ID
          final releases = await client.listReleases(serverAppId);
          final sourceRelease = releases.firstWhere(
            (r) => (r as Map)['version'] == patchFrom,
            orElse: () => null,
          );
          int? sourceReleaseServerId;
          if (sourceRelease != null) {
            sourceReleaseServerId = (sourceRelease as Map)['id'] as int?;
          }

          await client.createPatch(
            appId: serverAppId,
            releaseId: serverReleaseId,
            patchPath: patchPath,
            targetHash: targetSha,
            sourceReleaseId: sourceReleaseServerId,
          );
          uploadProgress.complete('上传成功');
        }
      } on ApiException catch (e) {
        uploadProgress.fail('上传失败: ${e.message}');
        return 1;
      } catch (e) {
        uploadProgress.fail('连接失败: $e');
        return 1;
      }
    }

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
}
