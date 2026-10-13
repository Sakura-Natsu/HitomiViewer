import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/pages/reader/spreads.dart';

GalleryImage _page(int index, {bool wide = false}) => GalleryImage(
  hash: 'hash$index',
  name: '$index.webp',
  width: wide ? 2000 : 1000,
  height: 1400,
);

void main() {
  test('单页模式每屏一页', () {
    final spreads = ReaderSpreads.build([
      for (var i = 0; i < 3; i++) _page(i),
    ], double: false);
    expect(spreads.spreads, [
      [0],
      [1],
      [2],
    ]);
    expect(spreads.spreadOf(2), 2);
  });

  test('双页：封面单独，其余两两组合，落单的最后一页单独', () {
    final spreads = ReaderSpreads.build([
      for (var i = 0; i < 6; i++) _page(i),
    ], double: true);
    expect(spreads.spreads, [
      [0],
      [1, 2],
      [3, 4],
      [5],
    ]);
    expect(spreads.spreadOf(4), 2);
    expect(spreads.spreadOf(5), 3);
  });

  test('双页：封面不单独时从第一页开始组合', () {
    final spreads = ReaderSpreads.build(
      [for (var i = 0; i < 4; i++) _page(i)],
      double: true,
      coverAlone: false,
    );
    expect(spreads.spreads, [
      [0, 1],
      [2, 3],
    ]);
  });

  test('双页：横向的跨页图单独显示，后面重新配对', () {
    final spreads = ReaderSpreads.build([
      _page(0),
      _page(1),
      _page(2, wide: true),
      _page(3),
      _page(4),
      _page(5),
    ], double: true);
    expect(spreads.spreads, [
      [0],
      [1],
      [2],
      [3, 4],
      [5],
    ]);
  });

  test('越界页码按首尾处理', () {
    final spreads = ReaderSpreads.build([_page(0), _page(1)], double: false);
    expect(spreads.spreadOf(-1), 0);
    expect(spreads.spreadOf(99), 1);
    expect(ReaderSpreads.build([], double: true).spreadOf(0), 0);
  });
}
