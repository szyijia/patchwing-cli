import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Android ABI 架构定义
class AndroidAbi {
  final String name; // 如 arm64-v8a
  final String flutterPlatform; // 如 android-arm64
  final String engineDir; // 如 android_release_arm64
  final String apkSuffix; // 如 app-arm64-v8a-release.apk
  final String libDir; // APK 中的 lib 目录，如 lib/arm64-v8a

  const AndroidAbi({
    required this.name,
    required this.flutterPlatform,
    required this.engineDir,
    required this.apkSuffix,
    required this.libDir,
  });

  @override
  String toString() => name;
}

/// 支持的 Android ABI 架构列表
class AndroidAbis {
  static const arm64 = AndroidAbi(
    name: 'arm64-v8a',
    flutterPlatform: 'android-arm64',
    engineDir: 'android_release_arm64',
    apkSuffix: 'app-arm64-v8a-release.apk',
    libDir: 'lib/arm64-v8a',
  );

  static const arm = AndroidAbi(
    name: 'armeabi-v7a',
    flutterPlatform: 'android-arm',
    engineDir: 'android_release',
    apkSuffix: 'app-armeabi-v7a-release.apk',
    libDir: 'lib/armeabi-v7a',
  );

  static const x64 = AndroidAbi(
    name: 'x86_64',
    flutterPlatform: 'android-x64',
    engineDir: 'android_release_x64',
    apkSuffix: 'app-x86_64-release.apk',
    libDir: 'lib/x86_64',
  );

  /// 所有支持的架构
  static const all = [arm64, arm, x64];

  /// 默认架构（仅 arm64）
  static const defaults = [arm64];

  /// 根据名称查找架构
  static AndroidAbi? fromName(String name) {
    switch (name) {
      case 'arm64-v8a':
      case 'android-arm64':
      case 'arm64':
        return arm64;
      case 'armeabi-v7a':
      case 'android-arm':
      case 'arm':
        return arm;
      case 'x86_64':
      case 'android-x64':
      case 'x64':
        return x64;
      default:
        return null;
    }
  }

  /// 解析逗号分隔的架构列表
  static List<AndroidAbi> parse(String? platforms) {
    if (platforms == null || platforms.isEmpty) return defaults;
    final result = <AndroidAbi>[];
    for (final name in platforms.split(',')) {
      final abi = fromName(name.trim());
      if (abi != null) result.add(abi);
    }
    return result.isEmpty ? defaults : result;
  }
}

/// Flutter 项目工具类
class FlutterProject {
  final String projectDir;

  FlutterProject(this.projectDir);

  /// 检查是否是有效的 Flutter 项目
  bool get isValid => File(p.join(projectDir, 'pubspec.yaml')).existsSync();

  /// 读取 pubspec.yaml
  Map<String, dynamic> get pubspec {
    final file = File(p.join(projectDir, 'pubspec.yaml'));
    final content = file.readAsStringSync();
    final yaml = loadYaml(content) as YamlMap;
    return Map<String, dynamic>.from(yaml);
  }

  /// 获取应用版本
  String get version => pubspec['version'] as String? ?? '0.0.1+1';

  /// 获取 release_id（将 + 替换为 _）
  String get releaseId => version.replaceAll('+', '_');

  /// 获取 applicationId（从 build.gradle 提取）
  String? get applicationId {
    // 尝试 build.gradle.kts
    var gradleFile = File(p.join(projectDir, 'android/app/build.gradle.kts'));
    if (!gradleFile.existsSync()) {
      gradleFile = File(p.join(projectDir, 'android/app/build.gradle'));
    }
    if (!gradleFile.existsSync()) return null;

    final content = gradleFile.readAsStringSync();
    // 匹配 applicationId = "xxx" 或 applicationId "xxx"
    final regex = RegExp(r'applicationId\s*=?\s*"([^"]+)"');
    final match = regex.firstMatch(content);
    return match?.group(1);
  }

  /// 读取 patchwing.yaml（项目级配置）
  Map<String, dynamic>? get patchwingConfig {
    final file = File(p.join(projectDir, 'patchwing.yaml'));
    if (!file.existsSync()) return null;
    try {
      final yaml = loadYaml(file.readAsStringSync()) as YamlMap;
      return Map<String, dynamic>.from(yaml);
    } catch (_) {
      return null;
    }
  }

  /// 写入 patchwing.yaml
  void writePatchwingConfig({
    required String appId,
    required String packageId,
    int? serverAppId,
  }) {
    final content = '''
# Patchwing 项目配置
# 由 `pw init` 自动生成

app_id: "$packageId"
base_url: "${Platform.environment['PATCHWING_API_URL'] ?? 'http://localhost:8080'}"
release_id: "$releaseId"
${serverAppId != null ? 'server_app_id: $serverAppId' : '# server_app_id: <创建后自动填入>'}
''';
    File(p.join(projectDir, 'patchwing.yaml')).writeAsStringSync(content);
  }

  /// 同时更新 shorebird.yaml（updater 读取的配置）
  void writeShorebirdConfig({
    required String packageId,
    required String baseUrl,
  }) {
    final content = '''
# Patchwing updater 配置
# 由 `pw init` / `pw release` 自动生成

app_id: "$packageId"
base_url: "$baseUrl"
release_id: "$releaseId"
''';
    File(p.join(projectDir, 'shorebird.yaml')).writeAsStringSync(content);
  }

  /// 构建 release APK（支持指定架构）
  Future<String> buildReleaseApk({
    String? localEngine,
    String? localEngineSrc,
    String? localEngineHost,
    AndroidAbi? abi,
  }) async {
    final targetAbi = abi ?? AndroidAbis.arm64;
    final args = <String>[
      'build',
      'apk',
      '--release',
      '--target-platform=${targetAbi.flutterPlatform}',
      '--split-per-abi',
      '--no-tree-shake-icons',
    ];

    if (localEngine != null) {
      args.addAll(['--local-engine', localEngine]);
    }
    if (localEngineSrc != null) {
      args.addAll(['--local-engine-src-path', localEngineSrc]);
    }
    if (localEngineHost != null) {
      args.addAll(['--local-engine-host', localEngineHost]);
    }

    final result = await Process.run(
      'flutter',
      args,
      workingDirectory: projectDir,
    );

    if (result.exitCode != 0) {
      throw Exception('APK 构建失败:\n${result.stderr}');
    }

    final apkPath = p.join(
      projectDir,
      'build/app/outputs/flutter-apk/${targetAbi.apkSuffix}',
    );

    if (!File(apkPath).existsSync()) {
      throw Exception('APK 文件不存在: $apkPath');
    }

    return apkPath;
  }

  /// 从 APK 中提取 libapp.so（支持指定架构）
  Future<String> extractLibapp(String apkPath, String outputDir,
      {AndroidAbi? abi}) async {
    final targetAbi = abi ?? AndroidAbis.arm64;
    final outputPath = p.join(outputDir, 'libapp.so');
    final dir = Directory(outputDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final result = await Process.run(
      'unzip',
      ['-p', apkPath, '${targetAbi.libDir}/libapp.so'],
      workingDirectory: projectDir,
      stdoutEncoding: null,
    );

    if (result.exitCode != 0) {
      throw Exception('提取 libapp.so 失败 (${targetAbi.name})');
    }

    File(outputPath).writeAsBytesSync(result.stdout as List<int>);
    return outputPath;
  }

  /// 确保 pubspec.yaml 中包含 shorebird.yaml 作为 flutter asset
  /// 返回 true 表示已修改，false 表示已存在无需修改
  bool ensurePubspecAsset() {
    final pubspecFile = File(p.join(projectDir, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return false;

    var content = pubspecFile.readAsStringSync();

    // 检查是否已包含 shorebird.yaml
    if (content.contains('shorebird.yaml')) return false;

    // 查找 flutter: 下的 assets: 部分
    final assetsRegex = RegExp(r'(\n\s*assets:\s*\n)');
    final match = assetsRegex.firstMatch(content);

    if (match != null) {
      // assets: 已存在，在其后添加 shorebird.yaml
      final insertPos = match.end;
      content =
          '${content.substring(0, insertPos)}    - shorebird.yaml\n${content.substring(insertPos)}';
    } else {
      // assets: 不存在，在 flutter: 部分添加
      final flutterRegex = RegExp(r'(\nflutter:\s*\n)');
      final flutterMatch = flutterRegex.firstMatch(content);
      if (flutterMatch != null) {
        final insertPos = flutterMatch.end;
        content =
            '${content.substring(0, insertPos)}\n  assets:\n    - shorebird.yaml\n${content.substring(insertPos)}';
      } else {
        // 没有 flutter: 部分，追加到末尾
        content += '\nflutter:\n  assets:\n    - shorebird.yaml\n';
      }
    }

    pubspecFile.writeAsStringSync(content);
    return true;
  }

  /// 确保 AndroidManifest.xml 中包含 INTERNET 权限
  /// 返回 true 表示已修改，false 表示已存在无需修改
  bool ensureInternetPermission() {
    final manifestFile = File(
      p.join(projectDir, 'android/app/src/main/AndroidManifest.xml'),
    );
    if (!manifestFile.existsSync()) return false;

    var content = manifestFile.readAsStringSync();

    // 检查是否已包含 INTERNET 权限
    if (content.contains('android.permission.INTERNET')) return false;

    // 在 <manifest> 标签后插入权限声明
    final manifestTagRegex = RegExp(r'(<manifest[^>]*>)');
    final match = manifestTagRegex.firstMatch(content);
    if (match == null) return false;

    final insertPos = match.end;
    const permissions = '''

    <!-- Patchwing OTA 更新需要网络权限 -->
    <uses-permission android:name="android.permission.INTERNET" />''';

    content =
        '${content.substring(0, insertPos)}$permissions${content.substring(insertPos)}';
    manifestFile.writeAsStringSync(content);
    return true;
  }

  /// 计算文件 SHA256
  static String fileSha256(String path) {
    final bytes = File(path).readAsBytesSync();
    return sha256.convert(bytes).toString();
  }

  /// 获取文件大小
  static int fileSize(String path) => File(path).lengthSync();
}
