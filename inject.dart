import 'dart:io';

void main() {
  final htmlFile = File('web_ui/dist/index.html');
  final dartFile = File('lib/services/web_ui.dart');

  String htmlContent = htmlFile.readAsStringSync();
  // Escape \$ for raw string interpolation is not needed, but we don't use raw string if we want to be safe, 
  // actually in a raw string r''' ... ''' we don't need to escape \$ at all.
  
  // We can just concatenate strings.
  final dartCode = "const String webUiHtml = r'''\n$htmlContent\n''';\n";
  dartFile.writeAsStringSync(dartCode);
  stdout.writeln('Injected successfully!');
}
