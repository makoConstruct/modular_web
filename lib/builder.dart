import 'dart:async';

import 'package:build/build.dart';
import 'wapc_parser.dart';

Builder fromFilesBuilder(BuilderOptions options) => ApcGeneratorFromFile();

class ApcGeneratorFromFile extends Builder {
  @override
  Future build(BuildStep buildStep) async {
    print("anything");
    // final apcId = inputId.changeExtension('.apc');
    final outPath = buildStep.inputId.addExtension(".g.dart");
    final contents = await buildStep.readAsString(buildStep.inputId);
    buildStep.writeAsString(outPath, dartFileForApc(parseWapc(contents)));
  }

  @override
  Map<String, List<String>> get buildExtensions => {
        '.apc': ['.apc.g.dart'],
      };
}
