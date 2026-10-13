import 'dart:io';

import 'package:hitomi_api/hitomi_api.dart';
import 'package:http/io_client.dart';

/// 运行：dart run example/example.dart
Future<void> main() async {
  // dart:io 默认不读取系统代理，这里使用 HTTP_PROXY 等环境变量。
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  final hitomi = Hitomi(client: IOClient(client));

  try {
    // 分页浏览：一个标签 + 语言，使用 Range 请求，可得到总数
    final tags = hitomi.tags.parse('female:sole_female language:chinese');
    final page = await hitomi.galleries.listPage(
      tags: tags,
      orderBy: SortType.popularityWeek,
      page: 0,
    );
    print('本周热门 ${page.ids.length} / 共 ${page.total}');

    // 画廊详情与图片地址
    final gallery = await hitomi.galleries.retrieve(page.ids.first);
    print('${gallery.title}（${gallery.files.length} 页）');
    final context = await hitomi.imageContext();
    print('封面缩略图：${gallery.files.first.thumbnailUrl(size: ThumbnailSize.big)}');
    print('第 1 页原图：${gallery.files.first.fullUrl(context)}');

    // 复杂查询：多标签 + 排除 + 标题关键词
    final ids = await hitomi.galleries.list(
      tags: hitomi.tags.parse('series:blue_archive -male:yaoi'),
      title: 'summer',
    );
    print('复杂查询结果：${ids.length} 个');

    // 标签联想
    for (final suggestion in (await hitomi.tags.search('female:big')).take(3)) {
      print('${suggestion.tag} (${suggestion.count})');
    }
  } finally {
    hitomi.close();
  }
}
