import 'dart:io';

void main() {
  final htmlFile = File('web_ui/dist/index.html');
  final dartFile = File('lib/services/web_ui.dart');

  String htmlContent = htmlFile.readAsStringSync();
  // Escape \$ just in case
  htmlContent = htmlContent.replaceAll('\$', '\\\$');

  final dartCode = "const String webUiHtml = r'''\n\$htmlContent\n''';\n";
  dartFile.writeAsStringSync(dartCode);
  print('Injected successfully!');
}
