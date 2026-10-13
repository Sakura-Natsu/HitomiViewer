import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_reader/services/device.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('按文件头判断图片格式', () {
    Uint8List bytes(List<int> head) =>
        Uint8List.fromList([...head, 0, 0, 0, 0]);
    expect(Device.imageType(bytes('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits)), (
      'webp',
      'image/webp',
    ));
    expect(Device.imageType(bytes([0x89, ...'PNG\r\n'.codeUnits])), (
      'png',
      'image/png',
    ));
    expect(Device.imageType(bytes([0xFF, 0xD8, 0xFF, 0xE0])), (
      'jpg',
      'image/jpeg',
    ));
    expect(Device.imageType(bytes('\x00\x00\x00\x1cftypavif'.codeUnits)), (
      'avif',
      'image/avif',
    ));
    expect(Device.imageType(bytes('GIF89a'.codeUnits)), ('gif', 'image/gif'));
  });

  test('保存图片：按格式加扩展名，重名时加序号', () async {
    final directory = await Directory.systemTemp.createTemp('device_test');
    addTearDown(() => directory.delete(recursive: true));
    Device.saveDirectoryOverride = directory;
    addTearDown(() => Device.saveDirectoryOverride = null);

    final png = Uint8List.fromList([0x89, ...'PNG\r\n'.codeUnits, 1, 2, 3]);
    final first = await Device.saveImage(png, 'hitomi_42_001');
    expect(first.file!.path, endsWith('hitomi_42_001.png'));
    expect(await first.file!.readAsBytes(), png);

    final second = await Device.saveImage(png, 'hitomi_42_001');
    expect(second.file!.path, endsWith('hitomi_42_001 (2).png'));
    expect(second.location, second.file!.path);
  });

  test('Windows 上能找到“图片”文件夹', () async {
    final pictures = await Device.picturesDirectory();
    expect(await pictures.exists(), isTrue, reason: pictures.path);
  }, skip: Platform.isWindows ? false : '仅 Windows');
}
