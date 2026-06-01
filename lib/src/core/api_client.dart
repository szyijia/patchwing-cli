import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'config.dart';

/// Patchwing API 客户端
class ApiClient {
  final String baseUrl;
  final String? apiKey;
  final String? token;

  ApiClient({String? baseUrl, String? apiKey, String? token})
      : baseUrl = baseUrl ?? PatchwingConfig.getApiUrl(),
        apiKey = apiKey ?? PatchwingConfig.getApiKey(),
        token = token ?? PatchwingConfig.getToken();

  Map<String, String> get _headers {
    final headers = <String, String>{'Accept': 'application/json'};
    if (apiKey != null) {
      headers['X-API-Key'] = apiKey!;
    } else if (token != null) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }

  /// 用户注册
  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    String? name,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/register'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email,
        'password': password,
        if (name != null) 'name': name,
      }),
    );
    return _handleResponse(resp);
  }

  /// 用户登录
  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/login'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    return _handleResponse(resp);
  }

  /// 创建 App
  Future<Map<String, dynamic>> createApp({
    required String name,
    required String packageId,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/api/v1/apps'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'package_id': packageId}),
    );
    return _handleResponse(resp);
  }

  /// 列出 Apps
  Future<List<dynamic>> listApps() async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/apps'),
      headers: _headers,
    );
    return _handleListResponse(resp);
  }

  /// 创建 Release（上传 baseline）
  /// [force] 如果为 true，则删除已存在的同名 release 后重建
  Future<Map<String, dynamic>> createRelease({
    required int appId,
    required String version,
    required String baselinePath,
    String? flutterVersion,
    String abi = 'arm64-v8a',
    bool force = false,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/v1/apps/$appId/releases'),
    );
    request.headers.addAll(_headers);
    request.fields['version'] = version;
    request.fields['abi'] = abi;
    if (flutterVersion != null) {
      request.fields['flutter_version'] = flutterVersion;
    }
    if (force) {
      request.fields['force'] = 'true';
    }
    request.files.add(
      await http.MultipartFile.fromPath('baseline', baselinePath),
    );

    final streamedResp = await request.send();
    final resp = await http.Response.fromStream(streamedResp);
    return _handleResponse(resp);
  }

  /// 列出 Releases
  Future<List<dynamic>> listReleases(int appId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/apps/$appId/releases'),
      headers: _headers,
    );
    return _handleListResponse(resp);
  }

  /// 删除 Release
  Future<Map<String, dynamic>> deleteRelease({
    required int appId,
    required int releaseId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$baseUrl/api/v1/apps/$appId/releases/$releaseId'),
      headers: _headers,
    );
    return _handleResponse(resp);
  }

  /// 创建 Patch（上传 patch.bin）
  Future<Map<String, dynamic>> createPatch({
    required int appId,
    required int releaseId,
    required String patchPath,
    String? targetHash,
    int? sourceReleaseId,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/v1/apps/$appId/releases/$releaseId/patches'),
    );
    request.headers.addAll(_headers);
    request.files.add(await http.MultipartFile.fromPath('patch', patchPath));
    if (targetHash != null) {
      request.fields['target_hash'] = targetHash;
    }
    if (sourceReleaseId != null) {
      request.fields['source_release_id'] = sourceReleaseId.toString();
    }

    final streamedResp = await request.send();
    final resp = await http.Response.fromStream(streamedResp);
    return _handleResponse(resp);
  }

  /// 列出 Patches
  Future<List<dynamic>> listPatches(int appId, int releaseId) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/apps/$appId/releases/$releaseId/patches'),
      headers: _headers,
    );
    return _handleListResponse(resp);
  }

  /// 下载文件
  Future<void> downloadFile(String url, String savePath) async {
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw ApiException('下载失败: HTTP ${resp.statusCode}');
    }
    final dir = Directory(p.dirname(savePath));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File(savePath).writeAsBytesSync(resp.bodyBytes);
  }

  /// 获取 Manifest
  Future<Map<String, dynamic>> getManifest(
    String packageId,
    String releaseId,
  ) async {
    final resp = await http.get(
      Uri.parse('$baseUrl/api/v1/manifest/$packageId/$releaseId/manifest.json'),
    );
    return _handleResponse(resp);
  }

  /// 健康检查
  Future<bool> healthCheck() async {
    try {
      final resp = await http.get(Uri.parse('$baseUrl/api/v1/health'));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 将服务端返回的 key 规范化（ID→id, camelCase→snake_case）
  dynamic _normalizeKeys(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data.map((key, value) {
        final normalizedKey = key == 'ID' ? 'id' : _camelToSnake(key);
        return MapEntry(normalizedKey, _normalizeKeys(value));
      });
    } else if (data is List) {
      return data.map(_normalizeKeys).toList();
    }
    return data;
  }

  String _camelToSnake(String input) {
    return input
        .replaceAllMapped(
          RegExp(r'[A-Z]'),
          (match) => '_${match.group(0)!.toLowerCase()}',
        )
        .replaceAll(RegExp(r'^_'), '');
  }

  Map<String, dynamic> _handleResponse(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      // go-admin 响应格式: {"code": 0, "data": {...}, "msg": "成功"}
      if (json.containsKey('code')) {
        final code = json['code'] as int;
        if (code != 0) {
          throw ApiException(
            json['msg'] as String? ?? '未知错误',
            statusCode: resp.statusCode,
          );
        }
        return _normalizeKeys(json['data']) as Map<String, dynamic>;
      }
      return _normalizeKeys(json) as Map<String, dynamic>;
    }
    final body = resp.body;
    String message;
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      message = json['msg'] as String? ?? json['error'] as String? ?? '未知错误';
    } catch (_) {
      message = 'HTTP ${resp.statusCode}: $body';
    }
    throw ApiException(message, statusCode: resp.statusCode);
  }

  List<dynamic> _handleListResponse(http.Response resp) {
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final json = jsonDecode(resp.body);
      // go-admin 响应格式: {"code": 0, "data": [...], "msg": "成功"}
      if (json is Map<String, dynamic> && json.containsKey('code')) {
        final code = json['code'] as int;
        if (code != 0) {
          throw ApiException(
            json['msg'] as String? ?? '未知错误',
            statusCode: resp.statusCode,
          );
        }
        return _normalizeKeys(json['data']) as List<dynamic>;
      }
      if (json is List) return _normalizeKeys(json) as List<dynamic>;
      return [];
    }
    String message;
    try {
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      message = json['msg'] as String? ?? 'HTTP ${resp.statusCode}';
    } catch (_) {
      message = 'HTTP ${resp.statusCode}: ${resp.body}';
    }
    throw ApiException(message, statusCode: resp.statusCode);
  }
}

/// API 异常
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  ApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ApiException: $message';
}
