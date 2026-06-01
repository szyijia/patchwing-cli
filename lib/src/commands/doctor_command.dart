import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/config.dart';
import '../engine/engine_manager.dart';
import '../config/patchwing_yaml.dart';
import '../flutter/flutter_detector.dart';

/// pw doctor — 检查 Patchwing 开发环境和 Engine Artifact
///
/// 核心职责：
/// 1. 检查 Flutter 版本
/// 2. 检查 patchwing.yaml 是否存在及 flutter_version 字段
/// 3. 检查 Engine Artifact 是否匹配当前 flutter_version
/// 4. 支持 --fix 自动下载缺失的 Engine
/// 5. 检查认证、bsdiff 工具、服务端连接等
class DoctorCommand extends Command<int> {
  final Logger logger;

  DoctorCommand({required this.logger}) {
    argParser.addFlag('fix',
        help: '自动修复问题（如下载缺失的 Engine Artifact）', negatable: false);
  }

  @override
  String get name => 'doctor';

  @override
  String get description => '检查 Patchwing 开发环境';

  @override
  Future<int> run() async {
    final autoFix = argResults!['fix'] as bool;

    logger.info('');
    logger.info('╔══════════════════════════════════════════╗');
    logger.info('║       Patchwing Doctor                   ║');
    logger.info('╚══════════════════════════════════════════╝');
    logger.info('');

    var allGood = true;

    // 1. Flutter 环境
    allGood &= await _checkFlutter();

    // 2. 项目配置（patchwing.yaml + flutter_version）
    allGood &= await _checkProjectConfig();

    // 3. Engine Artifact（支持自动修复）
    allGood &= await _checkEngineArtifact(autoFix: autoFix);

    // 4. bsdiff 工具
    allGood &= _checkBsdiff();

    // 5. 认证状态
    allGood &= _checkAuth();

    // 6. 服务端连接
    allGood &= await _checkServer();

    // 7. 已缓存引擎列表
    _listCachedEngines();

    logger.info('');
    if (allGood) {
      logger.success('✅ 所有检查通过！');
    } else {
      logger.warn('⚠️  部分检查未通过，请按提示修复');
      if (!autoFix) {
        logger.info('  💡 提示: 运行 pw doctor --fix 可自动修复部分问题');
      }
    }
    logger.info('');

    return allGood ? 0 : 1;
  }

  Future<bool> _checkFlutter() async {
    final progress = logger.progress('检查 Flutter');
    try {
      final detector = FlutterDetector();
      final version = await detector.getFlutterVersion();
      if (version != null) {
        // 同时获取 engine revision
        final engineRev = await detector.getEngineRevision();
        progress.complete(
            'Flutter $version (engine: ${engineRev?.substring(0, 16)}...)');
        return true;
      }
    } catch (_) {}
    progress.fail('Flutter 未安装或不在 PATH 中');
    return false;
  }

  Future<bool> _checkProjectConfig() async {
    logger.info('  📄 项目配置:');
    final projectDir = Directory.current.path;
    final config = PatchwingYaml.load(projectDir);

    if (config == null) {
      logger.info('    ✗ 未找到 patchwing.yaml，请先运行 pw init');
      return false;
    }

    logger.info('    ✓ patchwing.yaml');
    logger.info('    ✓ app_id: ${config.appId}');
    logger.info('    ✓ base_url: ${config.baseUrl}');

    if (config.flutterVersion != null) {
      logger.info('    ✓ flutter_version: ${config.flutterVersion}');
    } else {
      logger.warn('    ⚠️ flutter_version 未设置（建议运行 pw init 重新初始化）');
    }

    return true;
  }

  Future<bool> _checkEngineArtifact({bool autoFix = false}) async {
    final projectDir = Directory.current.path;
    final config = PatchwingYaml.load(projectDir);

    // 确定要检查的 flutter 版本
    String? flutterVersion;
    if (config?.flutterVersion != null) {
      flutterVersion = config!.flutterVersion;
      logger.info('  🔧 Engine Artifact (项目指定: $flutterVersion)');
    } else {
      // 从系统检测
      final detector = FlutterDetector();
      flutterVersion = await detector.getFlutterVersion();
      logger.info('  🔧 Engine Artifact (系统检测: ${flutterVersion ?? "未知"})');
    }

    if (flutterVersion == null) {
      logger.info('    ✗ 无法确定 Flutter 版本');
      return false;
    }

    final engineManager = EngineManager();

    if (engineManager.isCached(flutterVersion)) {
      // 已缓存
      final meta = engineManager.getMetadata(flutterVersion);
      final cacheDir = engineManager.engineDir(flutterVersion);
      logger.info('    ✓ 已缓存: $cacheDir');
      if (meta != null) {
        final installedAt = meta['installed_at'] as String?;
        final abi = meta['abi'] as String?;
        logger.info('      ABI: $abi, 安装时间: $installedAt');
      }
      return true;
    }

    // 未安装
    if (autoFix) {
      final progress =
          logger.progress('下载 Engine Artifact (Flutter $flutterVersion)');
      final success = await engineManager.downloadEngine(
        flutterVersion: flutterVersion,
        onProgress: (msg) => logger.detail(msg),
      );
      if (success) {
        progress.complete('Engine Artifact 安装成功');
        return true;
      } else {
        progress.fail('Engine Artifact 下载失败');
        logger.info('      请检查 CDN 可用性或手动放置 engine 到缓存目录');
        return false;
      }
    }

    logger.info('    ✗ Engine Artifact 未找到 (需要 Flutter $flutterVersion)');
    logger.info('      运行 pw doctor --fix 自动下载');
    logger.info('      或运行 pw init 重新初始化');
    return false;
  }

  bool _checkBsdiff() {
    logger.info('  📦 bsdiff 工具:');

    final locations = [
      Platform.environment['PATCHWING_BSDIFF_BIN'],
      p.join(Directory.current.path, 'bsdiff', 'patchwing_bsdiff'),
      ...List.generate(3, (i) {
        var dir = Directory.current.path;
        for (var j = 0; j <= i; j++) {
          dir = p.dirname(dir);
        }
        return p.join(dir, 'bsdiff', 'patchwing_bsdiff');
      }),
    ];

    for (final loc in locations) {
      if (loc != null && File(loc).existsSync()) {
        logger.info('    ✓ $loc');
        return true;
      }
    }

    try {
      final result = Process.runSync('which', ['patchwing_bsdiff']);
      if (result.exitCode == 0) {
        logger.info('    ✓ ${(result.stdout as String).trim()}');
        return true;
      }
    } catch (_) {}

    logger.info('    ✗ 未找到 patchwing_bsdiff');
    logger.info('      设置 PATCHWING_BSDIFF_BIN 环境变量或将其加入 PATH');
    return false;
  }

  bool _checkAuth() {
    logger.info('  🔑 认证状态:');
    final creds = PatchwingConfig.loadCredentials();
    if (creds != null) {
      logger.info('    ✓ 已登录: ${creds['email']}');
      return true;
    }

    final apiKey = Platform.environment['PATCHWING_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      logger.info('    ✓ 使用环境变量 PATCHWING_API_KEY');
      return true;
    }

    logger.info('    ✗ 未登录');
    logger.info('      运行 pw login 登录');
    return false;
  }

  Future<bool> _checkServer() async {
    final apiUrl = PatchwingConfig.getApiUrl();
    final progress = logger.progress('检查服务端 ($apiUrl)');
    try {
      final client = ApiClient();
      final healthy = await client.healthCheck();
      if (healthy) {
        progress.complete('服务端连接正常');
        return true;
      }
    } catch (_) {}
    progress.fail('服务端无响应');
    return false;
  }

  void _listCachedEngines() {
    final engineManager = EngineManager();
    final versions = engineManager.listCachedVersions();
    if (versions.isNotEmpty) {
      logger.info('  💾 已缓存 Engine:');
      for (final v in versions) {
        logger.info('    • $v');
      }
    }
  }
}
