import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

/// pw create — 创建新的 Flutter 项目并初始化 Patchwing
class CreateCommand extends Command<int> {
  final Logger logger;

  CreateCommand({required this.logger});

  @override
  String get name => 'create';

  @override
  String get description => '创建新的 Flutter 项目并自动初始化 Patchwing';

  @override
  String get invocation => 'pw create <project_name> [flutter create options]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      logger.err('请指定项目名称');
      logger.info('  用法: pw create my_app');
      return 64;
    }

    final projectName = rest.first;
    final flutterArgs = ['create', ...rest];

    // Step 1: 执行 flutter create
    logger.info('');
    final createProgress = logger.progress('创建 Flutter 项目: $projectName');

    final result = await Process.run(
      'flutter',
      flutterArgs,
      runInShell: true,
    );

    if (result.exitCode != 0) {
      createProgress.fail('flutter create 失败');
      logger.err(result.stderr.toString());
      return result.exitCode;
    }
    createProgress.complete('Flutter 项目创建成功');

    // Step 2: 进入项目目录，执行 pw init
    final projectDir = Directory(projectName);
    if (!projectDir.existsSync()) {
      logger.err('项目目录不存在: $projectName');
      return 1;
    }

    logger.info('');
    logger.info('  正在初始化 Patchwing...');
    logger.info('');

    // 切换到项目目录执行 init
    final initResult = await Process.run(
      Platform.resolvedExecutable, // 当前 dart/pw 可执行文件
      ['run', 'patchwing_cli:pw', 'init', '--package-id', projectName],
      workingDirectory: projectDir.absolute.path,
      runInShell: true,
    );

    // 如果是编译后的二进制，直接调用自身
    if (initResult.exitCode != 0) {
      // 尝试直接调用 pw init
      final pwInitResult = await Process.run(
        'pw',
        ['init'],
        workingDirectory: projectDir.absolute.path,
        runInShell: true,
      );
      if (pwInitResult.exitCode != 0) {
        logger.warn('自动初始化失败，请手动执行:');
        logger.info('  cd $projectName && pw init');
      } else {
        logger.info(pwInitResult.stdout.toString());
      }
    } else {
      logger.info(initResult.stdout.toString());
    }

    logger.info('');
    logger.success('🎉 项目创建完成！');
    logger.info('');
    logger.info('  下一步:');
    logger.info('    cd $projectName');
    logger.info('    pw release    — 发布 baseline 版本');
    logger.info('');

    return 0;
  }
}
