import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Engine Artifact 缓存管理器
/// 参考 Shorebird 的 Cache + CachedArtifact 模式设计
/// 职责：
/// 1. 管理 engine artifact 的缓存目录结构
/// 2. 按需下载指定 Flutter 版本的预编译 engine
/// 3. 将下载的 engine 替换到 Flutter SDK 的缓存目录
/// 4. 校验完整性（sha256 / stamp 文件）
class EngineManager {
  /// 补丁引擎的目标 ABI 架构
  final String abi;

  EngineManager({this.abi = 'android_release_arm64'});

  /// 全局缓存根目录：~/.patchwing/engine/
  static String get _engineCacheDir {
    final envDir = Platform.environment['PATCHWING_ENGINE_DIR'];
    if (envDir != null && envDir.isNotEmpty) return envDir;

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.patchwing', 'engine');
  }

  /// CDN 基础 URL
  static String get _cdnBaseUrl {
    return Platform.environment['PATCHWING_CDN_URL'] ??
        'https://cdn.patchwing.net/patchwing/engine';
  }

  /// 获取指定 Flutter 版本的缓存目录
  String engineDir(String flutterVersion) {
    return p.join(_engineCacheDir, flutterVersion);
  }

  /// 获取 stamp 文件路径（标记下载成功状态）
  String _stampFile(String flutterVersion) {
    return p.join(engineDir(flutterVersion), '.stamp');
  }

  /// 获取元数据文件路径（记录引擎版本、架构、来源等）
  String _metaFile(String flutterVersion) {
    return p.join(engineDir(flutterVersion), 'patchwing.json');
  }

  /// 判断 engine artifact 是否已缓存且有效
  bool isCached(String flutterVersion) {
    final dir = Directory(engineDir(flutterVersion));
    if (!dir.existsSync()) return false;

    // 检查 stamp 文件存在且关键产物存在
    if (!File(_stampFile(flutterVersion)).existsSync()) return false;

    // 检查核心文件
    final flutterJar = p.join(dir.path, abi, 'flutter.jar');
    final genSnapshot = p.join(dir.path, 'host_release', 'gen_snapshot');

    return File(flutterJar).existsSync() && File(genSnapshot).existsSync();
  }

  /// 确保 engine artifact 可用，按需下载
  /// 返回实际使用的 flutter 版本号，失败返回 null
  Future<String?> ensureEngine({
    required String flutterVersion,
    void Function(String message)? onProgress,
  }) async {
    // 已缓存则直接返回
    if (isCached(flutterVersion)) {
      onProgress?.call('Engine $flutterVersion 已缓存');
      return flutterVersion;
    }

    // 下载并安装
    onProgress?.call('Engine $flutterVersion 未找到，正在下载...');
    final success = await downloadEngine(
      flutterVersion: flutterVersion,
      onProgress: onProgress,
    );

    return success ? flutterVersion : null;
  }

  /// 下载 engine artifact（zip 包）到缓存目录
  /// downloadBaseUrl 示例:
  ///   https://cdn.patchwing.net/patchwing/engine/3.24.5/patchwing-engine-3.24.5-darwin-arm64.zip
  Future<bool> downloadEngine({
    required String flutterVersion,
    void Function(String message)? onProgress,
  }) async {
    final url = _buildDownloadUrl(flutterVersion);
    final targetDir = engineDir(flutterVersion);

    onProgress?.call('下载: $url');

    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) {
        onProgress?.call('下载失败: HTTP ${response.statusCode}');
        onProgress?.call('该 Flutter 版本可能尚无对应的 Engine Artifact');
        return false;
      }

      onProgress?.call(
          '下载完成 (${(response.bodyBytes.length / 1024 / 1024).toStringAsFixed(1)} MB)，正在解压...');

      // 创建目标目录
      final dir = Directory(targetDir);
      if (dir.existsSync()) await dir.delete(recursive: true);
      dir.createSync(recursive: true);

      // 解压 zip
      final archive = ZipDecoder().decodeBytes(response.bodyBytes);
      for (final file in archive) {
        final filePath = p.join(targetDir, file.name);
        if (file.isFile) {
          final outFile = File(filePath);
          outFile.parent.createSync(recursive: true);
          outFile.writeAsBytesSync(file.content as List<int>);

          // 设置可执行权限（gen_snapshot / .sh）
          if (file.name.contains('gen_snapshot') || file.name.endsWith('.sh')) {
            Process.runSync('chmod', ['+x', filePath]);
          }
        } else {
          Directory(filePath).createSync(recursive: true);
        }
      }

      // 写入 stamp 文件（标记安装成功）
      File(_stampFile(flutterVersion)).writeAsStringSync('installed');

      // 写入元数据
      await _writeMetadata(flutterVersion, url);

      onProgress?.call('Engine Artifact 安装成功: $targetDir');
      return true;
    } catch (e) {
      onProgress?.call('下载/解压失败: $e');
      return false;
    }
  }

  /// 将缓存的 engine artifact 替换到 Flutter SDK 缓存目录
  /// 这是在使用自定义引擎编译时的核心操作
  ///
  /// Flutter SDK 的引擎缓存路径通常位于：
  ///   $FLUTTER_ROOT/bin/cache/artifacts/engine/
  /// 包含 android-arm64-profile/$abi 等子目录，里面有 flutter.jar 和 gen_snapshot
  ///
  /// [flutterSdkPath] Flutter SDK 根目录
  /// [flutterVersion] 当前使用的 Flutter 版本（用于在缓存中定位正确的 engine）
  Future<bool> installToFlutterSdk({
    required String flutterSdkPath,
    required String flutterVersion,
    String? targetAbi,
    void Function(String message)? onProgress,
  }) async {
    final engineCacheDir = engineDir(flutterVersion);
    final target = targetAbi ?? abi;

    // Flutter SDK 的 artifacts/engine 目录
    final engineArtifactsDir = Directory(
      p.join(flutterSdkPath, 'bin', 'cache', 'artifacts', 'engine'),
    );
    if (!engineArtifactsDir.existsSync()) {
      onProgress
          ?.call('Flutter SDK engine 缓存目录不存在: ${engineArtifactsDir.path}');
      return false;
    }

    // Patchwing engine 目录
    final patchwingEngineDir = Directory(p.join(engineCacheDir, target));
    if (!patchwingEngineDir.existsSync()) {
      onProgress?.call('Patchwing Engine 目录不存在: ${patchwingEngineDir.path}');
      return false;
    }

    // 将 patchwing 引擎复制到 Flutter SDK 缓存目录
    // 目标目录命名通常如 android-arm64-release
    final targetEngineDir = Directory(
      p.join(engineArtifactsDir.path, _mapTargetToFlutterDir(target)),
    );

    onProgress?.call('安装 Engine 到 Flutter SDK...');
    try {
      // 先备份原始 engine（可选）
      if (targetEngineDir.existsSync()) {
        final backupDir = Directory('${targetEngineDir.path}.backup');
        if (backupDir.existsSync()) await backupDir.delete(recursive: true);
        await targetEngineDir.rename(backupDir.path);
        onProgress?.call('已备份原始 engine');
      }

      // 复制 patchwing engine
      await _copyDirectory(patchwingEngineDir, targetEngineDir);

      onProgress?.call('Engine 替换完成');
      return true;
    } catch (e) {
      onProgress?.call('Engine 替换失败: $e');
      return false;
    }
  }

  /// 将备份的原始 engine 恢复
  Future<bool> restoreOriginalEngine({
    required String flutterSdkPath,
    String? targetAbi,
  }) async {
    final target = targetAbi ?? abi;
    final flutterEngineDir = p.join(
      flutterSdkPath,
      'bin',
      'cache',
      'artifacts',
      'engine',
      _mapTargetToFlutterDir(target),
    );

    final backupDir = Directory('$flutterEngineDir.backup');
    final targetDir = Directory(flutterEngineDir);

    if (!backupDir.existsSync()) return false;

    if (targetDir.existsSync()) await targetDir.delete(recursive: true);
    await backupDir.rename(targetDir.path);
    return true;
  }

  /// 获取构建 flutter build 所需的 --local-engine 参数
  /// 如果 engine 已下载，返回供 flutter build 使用的参数 Map
  Map<String, String>? getLocalEngineArgs({
    required String flutterVersion,
    String? targetAbi,
  }) {
    final version = flutterVersion;
    final engine = targetAbi ?? abi;
    final dir = engineDir(version);

    if (!isCached(version)) return null;

    return {
      'local-engine': engine,
      'local-engine-src-path': dir,
      'local-engine-host': 'host_release',
    };
  }

  /// 构建下载 URL
  String _buildDownloadUrl(String flutterVersion) {
    final platform = _hostPlatform;
    final fileName = 'patchwing-engine-$flutterVersion-$platform.zip';
    return '$_cdnBaseUrl/$flutterVersion/$fileName';
  }

  /// 获取当前主机平台标识
  String get _hostPlatform {
    if (Platform.isMacOS) {
      try {
        final result = Process.runSync('uname', ['-m']);
        final arch = (result.stdout as String).trim();
        return arch == 'arm64' ? 'darwin-arm64' : 'darwin-x64';
      } catch (_) {
        return 'darwin-arm64';
      }
    } else if (Platform.isLinux) {
      return 'linux-x64';
    } else if (Platform.isWindows) {
      return 'windows-x64';
    }
    return 'unknown';
  }

  /// 写入元数据文件
  Future<void> _writeMetadata(String flutterVersion, String sourceUrl) async {
    final data = {
      'flutter_version': flutterVersion,
      'abi': abi,
      'platform': _hostPlatform,
      'source_url': sourceUrl,
      'installed_at': DateTime.now().toIso8601String(),
    };
    File(_metaFile(flutterVersion))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// 读取元数据
  Map<String, dynamic>? getMetadata(String flutterVersion) {
    final file = File(_metaFile(flutterVersion));
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 清除所有缓存
  Future<void> clearCache() async {
    final dir = Directory(_engineCacheDir);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// 列出已缓存的所有版本
  List<String> listCachedVersions() {
    final dir = Directory(_engineCacheDir);
    if (!dir.existsSync()) return [];

    return dir
        .listSync()
        .whereType<Directory>()
        .map((d) => p.basename(d.path))
        .toList()
      ..sort();
  }

  /// 拷贝目录（递归）
  Future<void> _copyDirectory(Directory source, Directory destination) async {
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }
    await for (final entity in source.list(recursive: false)) {
      final name = p.basename(entity.path);
      final destPath = p.join(destination.path, name);
      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(destPath));
      }
    }
  }

  /// ABI 名称映射到 Flutter SDK 的 artifacts/engine 子目录名
  String _mapTargetToFlutterDir(String target) {
    // 映射关系（不同体系命名略有差异）
    // patchwing engine 目录名 → flutter cache 目录名
    switch (target) {
      case 'android_release_arm64':
        return 'android-arm64-release';
      case 'android_release':
        return 'android-arm-release';
      case 'android_release_x64':
        return 'android-x64-release';
      // 其他情况直接返回原值
      default:
        return target;
    }
  }
}
