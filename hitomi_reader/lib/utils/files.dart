import 'dart:io';

import 'package:flutter/foundation.dart';

/// 将损坏或部分无法解析的数据文件复制一份，避免被下一次保存覆盖。
Future<void> backupFile(File file) async {
  try {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await file.copy('${file.path}.broken-$stamp');
  } catch (error) {
    debugPrint('备份 ${file.path} 失败: $error');
  }
}
