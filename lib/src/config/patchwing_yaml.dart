import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Patchwing 项目配置文件 (patchwing.yaml) 管理类
/// 参考 Shorebird 的 PatchwingYaml 实现
///
/// 文件位置：Flutter 项目根目录 /patchwing.yaml
/// 职责：
///   1. 定义 app_id / base_url 等用于 CLI 命令的配置
///   2. 记录与当前项目绑定的 Flutter 版本（用于 engine 按需下载）
///   3. 记录项目的 flavor 配置（如有）
class PatchwingYaml {
  /// 应用唯一标识（包名）
  final String appId;

  /// API 服务地址
  final String baseUrl;

  /// 当前绑定使用的 Flutter 版本（用于 engine artifact 匹配）
  /// 在 `pw init` 时自动检测并写入
  final String? flutterVersion;

  /// 服务端 App ID
  final int? serverAppId;

  /// Release ID（版本号格式 x.y.z_build）
  final String? releaseId;

  /// Flavor 配置（多 flavor 时使用）
  final Map<String, String>? flavors;

  PatchwingYaml({
    required this.appId,
    required this.baseUrl,
    this.flutterVersion,
    this.serverAppId,
    this.releaseId,
    this.flavors,
  });

  /// 从 Flutter 项目目录加载
  static PatchwingYaml? load(String projectDir) {
    final file = File(p.join(projectDir, 'patchwing.yaml'));
    if (!file.existsSync()) return null;

    try {
      final content = file.readAsStringSync();
      final yaml = loadYaml(content) as YamlMap;
      return PatchwingYaml.fromMap(
        Map<String, dynamic>.from(yaml),
        baseUrl: yaml['base_url'] as String? ?? 'http://localhost:8080',
      );
    } catch (e) {
      return null;
    }
  }

  /// 从 Map 解析
  factory PatchwingYaml.fromMap(
    Map<String, dynamic> map, {
    String? baseUrl,
  }) {
    return PatchwingYaml(
      appId: map['app_id'] as String? ?? '',
      baseUrl: baseUrl ?? map['base_url'] as String? ?? 'http://localhost:8080',
      flutterVersion: map['flutter_version'] as String?,
      serverAppId: map['server_app_id'] as int?,
      releaseId: map['release_id'] as String?,
      flavors: map['flavors'] != null
          ? Map<String, String>.from(map['flavors'] as Map)
          : null,
    );
  }

  /// 保存到项目目录
  Future<void> save(String projectDir) async {
    final file = File(p.join(projectDir, 'patchwing.yaml'));
    await file.writeAsString(toYaml());
  }

  /// 转换为 YAML 字符串
  String toYaml() {
    final buffer = StringBuffer();
    buffer.writeln('# Patchwing 项目配置');
    buffer.writeln('# 由 `pw init` 自动生成');
    buffer.writeln();
    buffer.writeln('app_id: "$appId"');
    buffer.writeln('base_url: "$baseUrl"');
    if (flutterVersion != null && flutterVersion!.isNotEmpty) {
      buffer.writeln('flutter_version: "$flutterVersion"');
    }
    if (releaseId != null && releaseId!.isNotEmpty) {
      buffer.writeln('release_id: "$releaseId"');
    }
    if (serverAppId != null) {
      buffer.writeln('server_app_id: $serverAppId');
    } else {
      buffer.writeln('# server_app_id: <创建后自动填入>');
    }
    if (flavors != null && flavors!.isNotEmpty) {
      buffer.writeln();
      buffer.writeln('flavors:');
      for (final entry in flavors!.entries) {
        buffer.writeln('  ${entry.key}: "${entry.value}"');
      }
    }
    return buffer.toString();
  }

  /// 更新字段并返回新的实例
  PatchwingYaml copyWith({
    String? appId,
    String? baseUrl,
    String? flutterVersion,
    int? serverAppId,
    String? releaseId,
    Map<String, String>? flavors,
  }) {
    return PatchwingYaml(
      appId: appId ?? this.appId,
      baseUrl: baseUrl ?? this.baseUrl,
      flutterVersion: flutterVersion ?? this.flutterVersion,
      serverAppId: serverAppId ?? this.serverAppId,
      releaseId: releaseId ?? this.releaseId,
      flavors: flavors ?? this.flavors,
    );
  }
}
