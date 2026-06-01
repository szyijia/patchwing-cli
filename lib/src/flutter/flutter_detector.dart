import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Flutter SDK 版本检测器
/// 参考 Shorebird 的 shorebird_flutter.dart 实现，在 pw init/pw create 时
/// 检测项目所需的 Flutter 版本，以便按需下载对应的 Engine Artifact
class FlutterDetector {
  final String? _flutterCommand;

  /// 指定 Flutter 可执行文件路径（可选，查找 $PATH 中的 flutter）
  FlutterDetector({String? flutterCommand}) : _flutterCommand = flutterCommand;

  /// 获取实际的 flutter 可执行文件路径
  String get _flutter => _flutterCommand ?? 'flutter';

  /// 运行 flutter --version --machine 获取版本信息
  /// 返回包含 version、channel、repositoryUrl、frameworkRevision 等字段的 Map
  Future<Map<String, dynamic>?> detectVersion() async {
    try {
      final result = await Process.run(
        _flutter,
        ['--version', '--machine'],
        stdoutEncoding: utf8,
      );
      if (result.exitCode != 0) return null;

      final output = result.stdout.toString().trim();
      if (output.isEmpty) return null;

      final json = jsonDecode(output) as Map<String, dynamic>?;
      return json;
    } catch (e) {
      return null;
    }
  }

  /// 获取当前安装的 Flutter 版本号（如 3.24.5）
  Future<String?> getFlutterVersion() async {
    final data = await detectVersion();
    if (data == null) return null;

    // flutter --version --machine 输出:
    // { "frameworkVersion":"3.24.5", "channel":"stable", ... }
    final version = data['frameworkVersion'] as String?;
    if (version != null && version.isNotEmpty) return version;

    // 兼容旧格式
    return data['version'] as String?;
  }

  /// 获取 engine revision（用于精确匹配预编译 engine）
  Future<String?> getEngineRevision() async {
    final data = await detectVersion();
    if (data == null) return null;

    // --machine 输出:
    // { "engineRevision": "d8b9f24cfa6bcecfce06b6d5c44c236852b33c8b", ... }
    return data['engineRevision'] as String?;
  }

  /// 从 flutter SDK 的 bin/internal/engine.version 文件读取 engine revision
  /// 这是 Shorebird 的获取方式，更可靠
  static String? readEngineVersionFromSdk(String flutterSdkPath) {
    final engineVersionFile = File(
      p.join(flutterSdkPath, 'bin', 'internal', 'engine.version'),
    );
    if (!engineVersionFile.existsSync()) return null;
    try {
      return engineVersionFile.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  /// 从项目根目录查找 Flutter 版本（根据 .flutter-version / .fvmrc / pubspec.lock）
  /// 返回优先使用的版本号（无则返回 null，需要自动检测）
  static String? detectVersionFromProject(String projectDir) {
    // 1. 检查 FVM 配置
    final fvmRc = File(p.join(projectDir, '.fvmrc'));
    if (fvmRc.existsSync()) {
      try {
        final content = fvmRc.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return json['flutter'] as String?;
      } catch (_) {}
    }

    // 2. 检查 .flutter-version 文件
    final versionFile = File(p.join(projectDir, '.flutter-version'));
    if (versionFile.existsSync()) {
      return versionFile.readAsStringSync().trim();
    }

    return null;
  }

  /// 获取设备平台标识（与 EngineManager 的 platform 对应）
  static String get hostPlatform {
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
}
