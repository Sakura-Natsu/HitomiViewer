import 'package:hitomi_api/hitomi_api.dart';

/// 翻页模式下的分屏：单页时每屏一页，双页时相邻两页并排。
///
/// 双页规则：封面可单独占一屏；横向的图片（本身就是跨页）单独占一屏；
/// 其余页面两两组合，落单的页面单独显示。
class ReaderSpreads {
  ReaderSpreads._(this.spreads, this._spreadOfPage);

  factory ReaderSpreads.build(
    List<GalleryImage> files, {
    required bool double,
    bool coverAlone = true,
  }) {
    final spreads = <List<int>>[];
    bool wide(int index) {
      final file = files[index];
      return file.height > 0 && file.width > file.height;
    }

    var index = 0;
    while (index < files.length) {
      final pairable =
          double &&
          !(coverAlone && index == 0) &&
          index + 1 < files.length &&
          !wide(index) &&
          !wide(index + 1);
      if (pairable) {
        spreads.add([index, index + 1]);
        index += 2;
      } else {
        spreads.add([index]);
        index++;
      }
    }
    final spreadOfPage = List.filled(files.length, 0);
    for (var i = 0; i < spreads.length; i++) {
      for (final page in spreads[i]) {
        spreadOfPage[page] = i;
      }
    }
    return ReaderSpreads._(spreads, spreadOfPage);
  }

  /// 每屏包含的页面下标（升序）。
  final List<List<int>> spreads;
  final List<int> _spreadOfPage;

  int get length => spreads.length;

  List<int> operator [](int index) => spreads[index];

  /// 包含 [page] 的那一屏。
  int spreadOf(int page) => _spreadOfPage.isEmpty
      ? 0
      : _spreadOfPage[page.clamp(0, _spreadOfPage.length - 1)];
}
