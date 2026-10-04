import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:gal/gal.dart';

/// 按平台保存 PNG：桌面端弹"另存为"对话框，移动端存入系统相册。
///
/// 返回给用户的结果文案（成功路径/取消路径）。
Future<String> savePng(Uint8List bytes) async {
  final name = 'taraxacum-${DateTime.now().millisecondsSinceEpoch}';
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    final location = await getSaveLocation(
      suggestedName: '$name.png',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG 图片', extensions: ['png']),
      ],
    );
    if (location == null) return '已取消导出';
    await XFile.fromData(bytes, mimeType: 'image/png').saveTo(location.path);
    return '已保存：${location.path}';
  }
  await Gal.putImageBytes(bytes, name: name);
  return '已保存到相册';
}
