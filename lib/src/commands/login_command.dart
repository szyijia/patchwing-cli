import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';

import '../core/api_client.dart';
import '../core/config.dart';

/// pw login — 登录或注册
class LoginCommand extends Command<int> {
  final Logger logger;

  LoginCommand({required this.logger}) {
    argParser
      ..addOption('email', abbr: 'e', help: '邮箱地址')
      ..addOption('password', abbr: 'p', help: '密码')
      ..addOption('api-url', help: 'API 服务器地址')
      ..addFlag('register', abbr: 'r', help: '注册新账号', negatable: false);
  }

  @override
  String get name => 'login';

  @override
  String get description => '登录 Patchwing 平台（或注册新账号）';

  @override
  Future<int> run() async {
    final isRegister = argResults!['register'] as bool;
    final apiUrl =
        argResults!['api-url'] as String? ?? PatchwingConfig.getApiUrl();

    // 交互式获取邮箱和密码
    var email = argResults!['email'] as String?;
    var password = argResults!['password'] as String?;

    if (email == null || email.isEmpty) {
      email = logger.prompt('📧 邮箱:');
    }
    if (password == null || password.isEmpty) {
      password = logger.prompt('🔑 密码:', hidden: true);
    }

    final client = ApiClient(baseUrl: apiUrl);
    final progress = logger.progress(isRegister ? '正在注册...' : '正在登录...');

    try {
      Map<String, dynamic> result;
      if (isRegister) {
        result = await client.register(email: email, password: password);
      } else {
        result = await client.login(email: email, password: password);
      }

      final token = result['token'] as String;
      final apiKey = result['api_key'] as String;

      // 保存认证信息
      PatchwingConfig.saveCredentials(
        apiUrl: apiUrl,
        token: token,
        apiKey: apiKey,
        email: email,
      );

      progress.complete(isRegister ? '注册成功！' : '登录成功！');
      logger.info('  API Key: ${apiKey.substring(0, 20)}...');
      logger.info('  配置已保存到: ${PatchwingConfig.credentialsPath}');

      return 0;
    } on ApiException catch (e) {
      progress.fail(e.message);
      return 1;
    } catch (e) {
      progress.fail('连接失败: $e');
      logger.info('  请确认 API 服务器地址: $apiUrl');
      return 1;
    }
  }
}
