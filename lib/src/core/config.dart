import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Patchwing CLI 全局配置
class PatchwingConfig {
  /// 配置文件目录 (~/.patchwing/)
  static String get configDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.patchwing');
  }

  /// 认证信息文件路径
  static String get credentialsPath => p.join(configDir, 'credentials.json');

  /// 默认 API 地址
  static String get defaultApiUrl {
    return Platform.environment['PATCHWING_API_URL'] ??
        'https://api.patchwing.cn';
  }

  /// 读取已保存的认证信息
  static Map<String, dynamic>? loadCredentials() {
    final file = File(credentialsPath);
    if (!file.existsSync()) return null;
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 保存认证信息
  static void saveCredentials({
    required String apiUrl,
    required String token,
    required String apiKey,
    required String email,
  }) {
    final dir = Directory(configDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final data = {
      'api_url': apiUrl,
      'token': token,
      'api_key': apiKey,
      'email': email,
      'saved_at': DateTime.now().toIso8601String(),
    };

    File(
      credentialsPath,
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// 获取 API URL（优先环境变量，其次配置文件）
  static String getApiUrl() {
    final envUrl = Platform.environment['PATCHWING_API_URL'];
    if (envUrl != null && envUrl.isNotEmpty) return envUrl;

    final creds = loadCredentials();
    return creds?['api_url'] as String? ?? defaultApiUrl;
  }

  /// 获取 API Key（优先环境变量，其次配置文件）
  static String? getApiKey() {
    final envKey = Platform.environment['PATCHWING_API_KEY'];
    if (envKey != null && envKey.isNotEmpty) return envKey;

    final creds = loadCredentials();
    return creds?['api_key'] as String?;
  }

  /// 获取 Token
  static String? getToken() {
    final envToken = Platform.environment['PATCHWING_TOKEN'];
    if (envToken != null && envToken.isNotEmpty) return envToken;

    final creds = loadCredentials();
    return creds?['token'] as String?;
  }

  /// 清除认证信息
  static void clearCredentials() {
    final file = File(credentialsPath);
    if (file.existsSync()) file.deleteSync();
  }
}
