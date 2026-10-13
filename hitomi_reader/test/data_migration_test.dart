import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_reader/services/app_services.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('migration_test');
  });

  tearDown(() => root.delete(recursive: true));

  Directory dir(String path) => Directory('${root.path}/$path');

  Future<void> seed(String path) async {
    await dir(path).create(recursive: true);
    await File('${dir(path).path}/library.json').writeAsString(path);
  }

  test('新目录不存在时，把第一个存在的旧目录搬过去', () async {
    await seed('com.example/Hitomi Reader');
    final target = dir('Sakura-Natsu/HitomiViewer');
    await AppServices.migrateDataDirectory(target, [
      dir('com.example/HitomiViewer'),
      dir('com.example/Hitomi Reader'),
    ]);
    expect(
      await File('${target.path}/library.json').readAsString(),
      'com.example/Hitomi Reader',
    );
    expect(await dir('com.example/Hitomi Reader').exists(), isFalse);
  });

  test('新目录为空（已被创建）时优先搬较新的旧目录', () async {
    await seed('com.example/HitomiViewer');
    await seed('com.example/Hitomi Reader');
    final target = dir('Sakura-Natsu/HitomiViewer');
    await target.create(recursive: true);
    await AppServices.migrateDataDirectory(target, [
      dir('com.example/HitomiViewer'),
      dir('com.example/Hitomi Reader'),
    ]);
    expect(
      await File('${target.path}/library.json').readAsString(),
      'com.example/HitomiViewer',
    );
    expect(await dir('com.example/Hitomi Reader').exists(), isTrue);
  });

  test('新目录已有数据时不动', () async {
    await seed('Sakura-Natsu/HitomiViewer');
    await seed('com.example/HitomiViewer');
    final target = dir('Sakura-Natsu/HitomiViewer');
    await AppServices.migrateDataDirectory(target, [
      dir('com.example/HitomiViewer'),
    ]);
    expect(
      await File('${target.path}/library.json').readAsString(),
      'Sakura-Natsu/HitomiViewer',
    );
    expect(await dir('com.example/HitomiViewer').exists(), isTrue);
  });
}
