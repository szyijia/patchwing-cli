import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../config/patchwing_yaml.dart';
import '../core/flutter_project.dart';

/// pw delete-release — 删除服务端的一个 release（及关联的 patch 和 baseline）
///
/// 使用场景：
/// - 自己 release 出错了，想重新发布同一版本 (--force)
/// - 想清理不再需要的旧版本
class DeleteReleaseCommand extends Command<int> {
  final Logger logger;

  DeleteReleaseCommand({required this.logger}) {
    argParser
      ..addOption('app-dir', help: 'Flutter 项目目录（默认当前目录）')
      ..addOption('app-id', help: '服务端 App ID（自动检测）')
      ..addOption('abi', help: 'ABI 过滤（如果不指定则删除所有架构）', defaultsTo: null)
      ..addFlag('yes', help: '跳过确认提示', negatable: false);
  }

  @override
  String get name => 'delete-release';

  @override
  String get description => '删除服务端的一个 release 及其所有关联数据';

  @override
  Future<int> run() async {
    final appDir = argResults!['app-dir'] as String? ?? Directory.current.path;
    final abi = argResults!['abi'] as String?;
    final yes = argResults!['yes'] as bool;
    var releaseIds =
        argResults!.rest.isNotEmpty ? argResults!.rest : <String>[];
    final config = PatchwingYaml.load(appDir);
    if (config == null) {
      logger.err('未找到 patchwing.yaml，请先运行 pw init');
      return 1;
    }

    final project = FlutterProject(appDir);
    final packageId = project.applicationId;
    if (packageId == null) {
      logger.err('无法从 build.gradle 提取 applicationId');
      return 1;
    }

    // 如果没有指定 release ID，从当前项目读取
    if (releaseIds.isEmpty) {
      releaseIds.add(project.releaseId);
    }

    final client = ApiClient();

    // 获取或查找 serverAppId
    int? serverAppId;
    if (argResults!['app-id'] != null) {
      serverAppId = int.tryParse(argResults!['app-id'] as String);
    } else {
      serverAppId = config.serverAppId;
    }

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

    if (serverAppId == null) {
      logger.err('找不到对应的应用，请先运行 pw init 或指定 --app-id');
      return 1;
    }

    // 获取并显示目标 releases
    final releases = await client.listReleases(serverAppId);
    final matchedReleases = releases.where((r) {
      final version = (r as Map)['version'] as String;
      if (!releaseIds.contains(version)) return false;
      if (abi != null && (r)['abi'] != abi) return false;
      return true;
    }).toList();

    if (matchedReleases.isEmpty) {
      logger.err('没有找到匹配的 release');
      return 1;
    }

    logger.info('');
    logger.info('⚠️  即将删除以下 release：');
    logger.info('');
    for (final r in matchedReleases) {
      final map = r as Map;
      final patches = map['patches'] as List? ?? [];
      logger.info(
          '  • ${map['version']} (${map['abi']}) - ${patches.length}个patch');
    }
    logger.info('');

    // 确认提示
    if (!yes) {
      logger.warn('此操作将永久删除 release 及其所有 patch、baseline，无法恢复');
      final confirm = logger.confirm('确认删除?', defaultValue: false);
      if (!confirm) {
        logger.info('已取消');
        return 0;
      }
    }

    // 执行删除
    for (final r in matchedReleases) {
      final map = r as Map;
      final id = map['id'] as int;
      final version = map['version'] as String;
      final releaseAbi = map['abi'] as String;

      final progress = logger.progress('删除 $version ($releaseAbi)');
      try {
        await client.deleteRelease(
          appId: serverAppId,
          releaseId: id,
        );
        progress.complete('删除成功');
      } on ApiException catch (e) {
        progress.fail('删除失败: ${e.message}');
      } catch (e) {
        progress.fail('删除失败: $e');
      }
    }

    logger.info('');
    logger.success('✅ 删除完成');
    return 0;
  }
}
