import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/engine_artifact.dart';

/// pw doctor — 检查环境和 engine artifact
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

    // 1. Flutter
    allGood &= await _checkFlutter();

    // 2. bsdiff 工具
    allGood &= _checkBsdiff();

    // 3. Engine Artifact（支持自动修复）
    allGood &= await _checkEngineArtifact(autoFix: autoFix);

    // 4. 认证状态
    allGood &= _checkAuth();

    // 5. 服务端连接
    allGood &= await _checkServer();

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
      final result = await Process.run('flutter', ['--version']);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final match = RegExp(r'Flutter (\S+)').firstMatch(output);
        final version = match?.group(1) ?? '未知';
        progress.complete('Flutter $version');
        return true;
      }
    } catch (_) {}
    progress.fail('Flutter 未安装或不在 PATH 中');
    return false;
  }

  bool _checkBsdiff() {
    // 查找 bsdiff 工具
    final locations = [
      Platform.environment['PATCHWING_BSDIFF_BIN'],
      p.join(Directory.current.path, 'bsdiff', 'patchwing_bsdiff'),
      // 向上查找
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
        logger.info('  ✓ bsdiff: $loc');
        return true;
      }
    }

    // 检查 PATH
    try {
      final result = Process.runSync('which', ['patchwing_bsdiff']);
      if (result.exitCode == 0) {
        logger.info('  ✓ bsdiff: ${(result.stdout as String).trim()}');
        return true;
      }
    } catch (_) {}

    logger.info('  ✗ bsdiff: 未找到 patchwing_bsdiff');
    logger.info('    设置 PATCHWING_BSDIFF_BIN 环境变量或将其加入 PATH');
    return false;
  }

  Future<bool> _checkEngineArtifact({bool autoFix = false}) async {
    final detectedVersion = EngineArtifact.detectFlutterVersion();
    final effectiveVersion = EngineArtifact.getEffectiveVersion();

    logger.info(
        '  ℹ Flutter 版本: ${detectedVersion ?? "未检测到"} → Engine 版本: $effectiveVersion');

    // 检查是否已安装
    if (EngineArtifact.isInstalled(flutterVersion: effectiveVersion)) {
      final dir = EngineArtifact.engineDir(effectiveVersion);
      logger.info('  ✓ Engine: $dir');
      return true;
    }

    // 检查 vendor 目录（开发模式）
    final vendorEngine = _findVendorEngine();
    if (vendorEngine != null) {
      logger.info('  ✓ Engine: $vendorEngine (vendor)');
      return true;
    }

    // 未安装
    if (autoFix) {
      // 自动下载
      final progress =
          logger.progress('下载 Engine Artifact (Flutter $effectiveVersion)');
      final success = await EngineArtifact.downloadEngine(
        flutterVersion: effectiveVersion,
        onProgress: (msg) => logger.detail(msg),
      );
      if (success) {
        progress.complete('Engine Artifact 安装成功');
        return true;
      } else {
        progress.fail('Engine Artifact 下载失败');
        logger
            .info('    支持的版本: ${EngineArtifact.supportedVersions.join(", ")}');
        logger.info(
            '    下载地址: ${EngineArtifact.getDownloadUrl(flutterVersion: effectiveVersion)}');
        return false;
      }
    }

    logger.info('  ✗ Engine Artifact: 未找到 (需要 Flutter $effectiveVersion)');
    logger.info('    运行 pw doctor --fix 自动下载');
    logger.info(
        '    或手动下载: ${EngineArtifact.getDownloadUrl(flutterVersion: effectiveVersion)}');
    logger.info('    解压到: ${EngineArtifact.engineDir(effectiveVersion)}');
    return false;
  }

  String? _findVendorEngine() {
    var dir = Directory.current.path;
    for (var i = 0; i < 5; i++) {
      final engineSrc = p.join(dir, 'vendor', 'flutter', 'engine', 'src');
      if (Directory(engineSrc).existsSync()) return engineSrc;
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    return null;
  }

  bool _checkAuth() {
    final creds = PatchwingConfig.loadCredentials();
    if (creds != null) {
      logger.info('  ✓ 已登录: ${creds['email']}');
      return true;
    }

    // 检查环境变量
    final apiKey = Platform.environment['PATCHWING_API_KEY'];
    if (apiKey != null && apiKey.isNotEmpty) {
      logger.info('  ✓ 认证: 使用环境变量 PATCHWING_API_KEY');
      return true;
    }

    logger.info('  ✗ 未登录（运行 pw login）');
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
}
