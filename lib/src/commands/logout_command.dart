import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/config.dart';

/// pw logout — 退出登录
class LogoutCommand extends Command<int> {
  final Logger logger;

  LogoutCommand({required this.logger});

  @override
  String get name => 'logout';

  @override
  String get description => '退出登录，清除本地凭证';

  @override
  Future<int> run() async {
    PatchwingConfig.clearCredentials();
    logger.success('已退出登录');
    logger.info('  凭证已从 ${PatchwingConfig.credentialsPath} 清除');
    return 0;
  }
}
