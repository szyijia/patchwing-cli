import 'package:patchwing_cli/src/cli_runner.dart';

Future<void> main(List<String> args) async {
  await PatchwingCliRunner().run(args);
}
