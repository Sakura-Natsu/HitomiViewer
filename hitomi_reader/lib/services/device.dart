import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class BatteryState {
  const BatteryState(this.level, {this.charging = false});

  /// 电量百分比（0–100）。
  final int level;
  final bool charging;
}

/// 保存图片的结果。
class SavedImage {
  const SavedImage(this.location, {this.file});

  /// 给用户看的保存位置。
  final String location;

  /// 保存到的文件（Android 通过媒体库保存时为 null）。
  final File? file;
}

/// 屏幕常亮、电量读取与保存图片：Android 走 MainActivity 中的方法通道，
/// Windows 直接调用 Win32 API。其他平台或调用失败时尽量降级处理。
abstract final class Device {
  static const MethodChannel _channel = MethodChannel('hitomi_reader/device');

  /// 测试用：图片直接保存到这个目录，不经过系统相册。
  @visibleForTesting
  static Directory? saveDirectoryOverride;

  static const String _folderName = 'HitomiViewer';

  static Future<void> keepScreenOn(bool on) async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod<void>('keepScreenOn', on);
      } else if (Platform.isWindows) {
        _Win32.instance?.keepDisplayOn(on);
      }
    } catch (error) {
      debugPrint('设置屏幕常亮失败: $error');
    }
  }

  /// 当前电量，没有电池或无法获取时返回 null。
  static Future<BatteryState?> battery() async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMapMethod<String, Object?>(
          'battery',
        );
        final level = result?['level'];
        if (level is! int || level < 0 || level > 100) return null;
        return BatteryState(level, charging: result?['charging'] == true);
      } else if (Platform.isWindows) {
        return _Win32.instance?.battery();
      }
    } catch (error) {
      debugPrint('读取电量失败: $error');
    }
    return null;
  }

  /// 根据文件头判断图片格式，返回（扩展名，MIME 类型）。
  static (String, String) imageType(Uint8List bytes) {
    bool ascii(int offset, String text) {
      if (bytes.length < offset + text.length) return false;
      for (var i = 0; i < text.length; i++) {
        if (bytes[offset + i] != text.codeUnitAt(i)) return false;
      }
      return true;
    }

    if (ascii(0, 'RIFF') && ascii(8, 'WEBP')) return ('webp', 'image/webp');
    if (bytes.length > 3 && bytes[0] == 0x89 && ascii(1, 'PNG')) {
      return ('png', 'image/png');
    }
    if (bytes.length > 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return ('jpg', 'image/jpeg');
    }
    if (ascii(0, 'GIF8')) return ('gif', 'image/gif');
    if (ascii(4, 'ftypavi')) return ('avif', 'image/avif');
    return ('webp', 'image/webp');
  }

  /// 保存图片：Android 存到“图片/HitomiViewer”（相册可见），
  /// Windows 存到“图片\HitomiViewer”，重名时自动加序号。
  static Future<SavedImage> saveImage(Uint8List bytes, String baseName) async {
    final (extension, mime) = imageType(bytes);
    final override = saveDirectoryOverride;
    if (override == null && Platform.isAndroid) {
      final location = await _channel.invokeMethod<String>('saveImage', {
        'bytes': bytes,
        'name': '$baseName.$extension',
        'mime': mime,
      });
      return SavedImage(location ?? '图片/$_folderName');
    }
    final separator = Platform.pathSeparator;
    final folder =
        override ??
        Directory('${(await picturesDirectory()).path}$separator$_folderName');
    await folder.create(recursive: true);
    var file = File('${folder.path}$separator$baseName.$extension');
    for (var i = 2; await file.exists(); i++) {
      file = File('${folder.path}$separator$baseName ($i).$extension');
    }
    await file.writeAsBytes(bytes, flush: true);
    return SavedImage(file.path, file: file);
  }

  /// 系统的“图片”文件夹（Windows 会跟随 OneDrive 等重定向）。
  static Future<Directory> picturesDirectory() async {
    if (Platform.isWindows) {
      final path = _Win32.instance?.picturesPath();
      if (path != null) return Directory(path);
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null) return Directory('$profile\\Pictures');
    }
    return await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
  }

  /// 在资源管理器中显示文件（仅 Windows）。
  static Future<void> showInFolder(File file) async {
    if (!Platform.isWindows) return;
    try {
      await Process.run('explorer.exe', ['/select,', file.path]);
    } catch (error) {
      debugPrint('打开文件夹失败: $error');
    }
  }
}

class _Win32 {
  _Win32._(DynamicLibrary kernel32)
    : _setExecutionState = kernel32
          .lookupFunction<Uint32 Function(Uint32), int Function(int)>(
            'SetThreadExecutionState',
          ),
      _getPowerStatus = kernel32
          .lookupFunction<
            Int32 Function(Pointer<Uint8>),
            int Function(Pointer<Uint8>)
          >('GetSystemPowerStatus'),
      _localAlloc = kernel32
          .lookupFunction<
            Pointer<Uint8> Function(Uint32, IntPtr),
            Pointer<Uint8> Function(int, int)
          >('LocalAlloc'),
      _localFree = kernel32
          .lookupFunction<
            Pointer<Void> Function(Pointer<Uint8>),
            Pointer<Void> Function(Pointer<Uint8>)
          >('LocalFree');

  static final _Win32? instance = () {
    try {
      return _Win32._(DynamicLibrary.open('kernel32.dll'));
    } catch (_) {
      return null;
    }
  }();

  static const int _esContinuous = 0x80000000;
  static const int _esDisplayRequired = 0x00000002;
  static const int _zeroInit = 0x40; // LMEM_ZEROINIT

  final int Function(int) _setExecutionState;
  final int Function(Pointer<Uint8>) _getPowerStatus;
  final Pointer<Uint8> Function(int, int) _localAlloc;
  final Pointer<Void> Function(Pointer<Uint8>) _localFree;

  /// SYSTEM_POWER_STATUS：ACLineStatus、BatteryFlag、BatteryLifePercent……共 12 字节。
  /// 只分配一次，随进程存在，不需要释放。
  late final Pointer<Uint8> _status = _localAlloc(_zeroInit, 12);

  /// 设置会一直保持到同一线程再次调用；Dart 主 isolate 始终运行在同一个线程上。
  void keepDisplayOn(bool on) => _setExecutionState(
    on ? _esContinuous | _esDisplayRequired : _esContinuous,
  );

  BatteryState? battery() {
    final status = _status;
    if (status == nullptr || _getPowerStatus(status) == 0) return null;
    final flag = status[1];
    final percent = status[2];
    // 128：没有电池（台式机）；255：未知
    if (flag == 255 || flag & 128 != 0 || percent > 100) return null;
    return BatteryState(percent, charging: status[0] == 1 || flag & 8 != 0);
  }

  /// SHGetKnownFolderPath(FOLDERID_Pictures)。
  String? picturesPath() {
    try {
      final getPath = DynamicLibrary.open('shell32.dll')
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32, IntPtr, Pointer<IntPtr>),
            int Function(Pointer<Uint8>, int, int, Pointer<IntPtr>)
          >('SHGetKnownFolderPath');
      final free = DynamicLibrary.open('ole32.dll')
          .lookupFunction<Void Function(IntPtr), void Function(int)>(
            'CoTaskMemFree',
          );
      // {33E28130-4E1E-4676-835A-98395C3BC3BB}，前三段按小端存放，后面跟 8 字节的输出指针
      const guid = [
        0x30, 0x81, 0xE2, 0x33, 0x1E, 0x4E, 0x76, 0x46, //
        0x83, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB,
      ];
      final buffer = _localAlloc(_zeroInit, 24);
      if (buffer == nullptr) return null;
      try {
        for (var i = 0; i < guid.length; i++) {
          buffer[i] = guid[i];
        }
        final out = Pointer<IntPtr>.fromAddress(buffer.address + 16);
        if (getPath(buffer, 0, 0, out) != 0 || out.value == 0) return null;
        final chars = Pointer<Uint16>.fromAddress(out.value);
        final units = <int>[];
        for (var i = 0; chars[i] != 0; i++) {
          units.add(chars[i]);
        }
        free(out.value);
        return String.fromCharCodes(units);
      } finally {
        _localFree(buffer);
      }
    } catch (error) {
      debugPrint('获取图片文件夹失败: $error');
      return null;
    }
  }
}
