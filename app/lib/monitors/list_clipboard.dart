import 'package:flutter/services.dart';

/// Somewhere to put a site list, and to read one back.
///
/// Behind an interface so the settings flow can be exercised without a platform
/// channel: `Clipboard` is a channel call, and under `flutter test` there is no
/// handler behind it, so awaiting it directly hangs the test rather than
/// failing it. Injecting it also keeps the card free of platform details, which
/// matters on the web build where the clipboard is permission-gated.
abstract class ListClipboard {
  /// Publishes [text] as the current clipboard contents.
  Future<void> write(String text);

  /// The current clipboard text, or null when there is none or it is not text.
  Future<String?> read();
}

/// The operating system clipboard, which is the only place a list ever goes.
class SystemListClipboard implements ListClipboard {
  const SystemListClipboard();

  @override
  Future<void> write(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<String?> read() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}
