import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Engine Artifact 管理
class EngineArtifact {
  /// 默认 Flutter 版本
  static const String defaultFlutterVersion = '3.44.0';

  /// 支持的 Flutter 版本列表（有对应 engine artifact 的版本）
  static const List<String> supportedVersions = [
    '3.44.0',
  ];

  /// Engine artifact 下载 URL 模板
  static String get downloadBaseUrl {
    return Platform.environment['PATCHWING_ENGINE_URL'] ??
        'https://zhi.songzb.com/apk/patchwing/engine';
  }

  /// Engine artifact 本地存储目录
  static String get engineBaseDir {
    final envDir = Platform.environment['PATCHWING_ENGINE_DIR'];
    if (envDir != null && envDir.isNotEmpty) return envDir;

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.patchwing', 'engine');
  }

  /// 获取指定版本的 engine 目录
  static String engineDir(String flutterVersion) {
    return p.join(engineBaseDir, flutterVersion);
  }

  /// 自动检测当前系统安装的 Flutter 版本
  static String? detectFlutterVersion() {
    try {
      final result = Process.runSync('flutter', ['--version']);
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final match = RegExp(r'Flutter (\S+)').firstMatch(output);
        return match?.group(1);
      }
    } catch (_) {}
    return null;
  }

  /// 获取当前应该使用的 Flutter 版本
  /// 优先级: 环境变量 > 自动检测 > 默认版本
  static String getEffectiveVersion() {
    // 1. 环境变量指定
    final envVersion = Platform.environment['PATCHWING_FLUTTER_VERSION'];
    if (envVersion != null && envVersion.isNotEmpty) return envVersion;

    // 2. 自动检测
    final detected = detectFlutterVersion();
    if (detected != null) {
      // 检查是否有对应的 engine（精确匹配或主版本匹配）
      final matched = _findBestMatchVersion(detected);
      if (matched != null) return matched;
    }

    // 3. 默认版本
    return defaultFlutterVersion;
  }

  /// 查找最佳匹配的 engine 版本
  /// 优先精确匹配，其次匹配主版本号（如 3.44.x 匹配 3.44.0）
  static String? _findBestMatchVersion(String flutterVersion) {
    // 精确匹配
    if (supportedVersions.contains(flutterVersion)) {
      return flutterVersion;
    }

    // 主版本匹配（如 3.44.1 → 3.44.0）
    final parts = flutterVersion.split('.');
    if (parts.length >= 2) {
      final majorMinor = '${parts[0]}.${parts[1]}';
      for (final v in supportedVersions) {
        if (v.startsWith('$majorMinor.')) return v;
      }
    }

    return null;
  }

  /// 检查 engine artifact 是否已安装
  static bool isInstalled({String? flutterVersion}) {
    final version = flutterVersion ?? getEffectiveVersion();
    final dir = engineDir(version);

    // 检查关键文件
    final flutterJar = p.join(dir, 'android_release_arm64', 'flutter.jar');
    final genSnapshot = p.join(dir, 'host_release', 'gen_snapshot');

    return File(flutterJar).existsSync() && File(genSnapshot).existsSync();
  }

  /// 确保 engine artifact 可用（自动检测版本 + 自动下载）
  /// 返回实际使用的 Flutter 版本，失败返回 null
  static Future<String?> ensureEngine({
    String? flutterVersion,
    void Function(String message)? onProgress,
  }) async {
    final version = flutterVersion ?? getEffectiveVersion();

    // 已安装则直接返回
    if (isInstalled(flutterVersion: version)) {
      return version;
    }

    // 检查 vendor 目录（开发模式）
    if (_findVendorEnginePath() != null) {
      return version;
    }

    // 尝试下载
    onProgress?.call('Engine artifact 未找到，正在下载 (Flutter $version)...');
    final success = await downloadEngine(
      flutterVersion: version,
      onProgress: onProgress,
    );

    return success ? version : null;
  }

  /// 下载并安装 engine artifact
  static Future<bool> downloadEngine({
    String? flutterVersion,
    void Function(String message)? onProgress,
  }) async {
    final version = flutterVersion ?? getEffectiveVersion();
    final url = getDownloadUrl(flutterVersion: version);
    final targetDir = engineDir(version);

    onProgress?.call('下载: $url');

    try {
      // 下载 zip 文件
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        onProgress?.call('下载失败: HTTP ${response.statusCode}');
        onProgress?.call('URL: $url');
        onProgress?.call('');
        onProgress?.call('该 Flutter 版本 ($version) 可能尚无对应的 engine artifact。');
        onProgress?.call('支持的版本: ${supportedVersions.join(", ")}');
        return false;
      }

      onProgress?.call(
          '下载完成 (${(response.bodyBytes.length / 1024 / 1024).toStringAsFixed(1)} MB)，正在解压...');

      // 创建目标目录
      Directory(targetDir).createSync(recursive: true);

      // 解压 zip
      final archive = ZipDecoder().decodeBytes(response.bodyBytes);
      for (final file in archive) {
        final filePath = p.join(targetDir, file.name);
        if (file.isFile) {
          final outFile = File(filePath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(file.content as List<int>);

          // 设置可执行权限（gen_snapshot 等）
          if (file.name.contains('gen_snapshot') || file.name.endsWith('.sh')) {
            Process.runSync('chmod', ['+x', filePath]);
          }
        } else {
          Directory(filePath).createSync(recursive: true);
        }
      }

      // 验证安装
      if (isInstalled(flutterVersion: version)) {
        onProgress?.call('Engine artifact 安装成功: $targetDir');
        return true;
      } else {
        onProgress?.call('解压完成但验证失败，请检查 zip 包内容');
        return false;
      }
    } catch (e) {
      onProgress?.call('下载/解压失败: $e');
      return false;
    }
  }

  /// 获取 flutter.jar 路径（支持指定架构）
  static String? getFlutterJarPath(
      {String? flutterVersion, String? engineName}) {
    final version = flutterVersion ?? getEffectiveVersion();
    final engine = engineName ?? 'android_release_arm64';

    // 1. 检查 ~/.patchwing/engine/
    final standardPath = p.join(engineDir(version), engine, 'flutter.jar');
    if (File(standardPath).existsSync()) return standardPath;

    // 2. 检查 vendor 目录（开发模式）
    final vendorPath = _findVendorEnginePath();
    if (vendorPath != null) {
      final jar = p.join(vendorPath, 'out', engine, 'flutter.jar');
      if (File(jar).existsSync()) return jar;
    }

    return null;
  }

  /// 获取 local-engine 参数（供 flutter build 使用）
  /// [engineName] 可指定架构对应的 engine 目录名，如 android_release_arm64
  static Map<String, String>? getLocalEngineArgs(
      {String? flutterVersion, String? engineName}) {
    final version = flutterVersion ?? getEffectiveVersion();
    final engine = engineName ?? 'android_release_arm64';

    // 1. 检查 vendor 目录（开发模式）
    final vendorPath = _findVendorEnginePath();
    if (vendorPath != null) {
      return {
        'local-engine': engine,
        'local-engine-src': vendorPath,
        'local-engine-host': 'host_release',
      };
    }

    // 2. 检查 ~/.patchwing/engine/
    final dir = engineDir(version);
    if (Directory(dir).existsSync()) {
      return {
        'local-engine': engine,
        'local-engine-src': dir,
        'local-engine-host': 'host_release',
      };
    }

    return null;
  }

  /// 获取 engine artifact 元数据
  static Map<String, dynamic>? getMetadata({String? flutterVersion}) {
    final version = flutterVersion ?? getEffectiveVersion();
    final metaFile = File(p.join(engineDir(version), 'patchwing.json'));
    if (!metaFile.existsSync()) return null;
    try {
      return jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 获取当前平台标识
  static String get currentPlatform {
    if (Platform.isMacOS) {
      // 检测 ARM vs x86
      final result = Process.runSync('uname', ['-m']);
      final arch = (result.stdout as String).trim();
      return arch == 'arm64' ? 'darwin-arm64' : 'darwin-x64';
    } else if (Platform.isLinux) {
      return 'linux-x64';
    } else if (Platform.isWindows) {
      return 'windows-x64';
    }
    return 'unknown';
  }

  /// 获取下载 URL
  static String getDownloadUrl({String? flutterVersion}) {
    final version = flutterVersion ?? getEffectiveVersion();
    final platform = currentPlatform;
    return '$downloadBaseUrl/$version/patchwing-engine-$version-$platform.zip';
  }

  /// 查找 vendor engine 路径（开发模式）
  static String? _findVendorEnginePath() {
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
}
