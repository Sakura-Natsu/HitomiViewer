// 访问真实服务器的测试，默认跳过。运行方式：
//   dart test --run-skipped -t live test/live_test.dart
@Tags(['live'])
@Skip('需要网络，使用 --run-skipped 运行')
library;

import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_api/io.dart';
import 'package:http/io_client.dart';
import 'package:test/test.dart';

void main() {
  late Hitomi hitomi;

  setUpAll(() {
    hitomi = Hitomi(client: IOClient(createEnvironmentHttpClient()));
  });

  tearDownAll(() => hitomi.close());

  test('lists newest galleries with paging and total', () async {
    final page = await hitomi.galleries.listPage(page: 0, pageSize: 10);
    expect(page.ids, hasLength(10));
    expect(page.total, greaterThan(100000));
  });

  test('retrieves a gallery and downloads its images', () async {
    final page = await hitomi.galleries.listPage(page: 0, pageSize: 5);
    final gallery = await hitomi.galleries.retrieve(page.ids.first);
    expect(gallery.id, page.ids.first);
    expect(gallery.files, isNotEmpty);

    final image = gallery.files.first;
    final full = await hitomi.fetchImage(image);
    expect(full.length, greaterThan(1000));
    final thumbnail = await hitomi.fetchImage(
      image,
      thumbnailSize: ThumbnailSize.big,
    );
    expect(thumbnail.length, greaterThan(500));
    final small = await hitomi.fetchImage(
      gallery.files.last,
      thumbnailSize: ThumbnailSize.small,
    );
    expect(small.length, greaterThan(500));
  });

  test('searches by tag + language with paging', () async {
    final tags = hitomi.tags.parse('female:big_breasts language:chinese');
    final page = await hitomi.galleries.listPage(
      tags: tags,
      orderBy: SortType.popularityWeek,
      page: 0,
    );
    expect(page.ids, isNotEmpty);
    final gallery = await hitomi.galleries.retrieve(page.ids.first);
    expect(gallery.language?.name, 'chinese');
  });

  test('searches by title through the B-tree index', () async {
    final ids = await hitomi.galleries.list(
      title: 'blue archive',
      tags: const [Tag(TagType.language, 'english')],
    );
    expect(ids, isNotEmpty);
    // galleriesindex 不只收录标题，也收录系列、角色等标签中的词。
    final gallery = await hitomi.galleries.retrieve(ids.first);
    final words = [
      gallery.title,
      ...gallery.allTags.map((tag) => tag.name),
    ].join(' ').toLowerCase();
    expect(words, allOf(contains('blue'), contains('archive')));
  });

  test('pasting a full title finds the gallery (lenient matching)', () async {
    for (final language in ['chinese', 'english', 'japanese']) {
      // 刚上传的画廊可能还没进入标题索引，这里取本月热门。
      final page = await hitomi.galleries.listPage(
        tags: [Tag(TagType.language, language)],
        orderBy: SortType.popularityMonth,
        page: 0,
        pageSize: 4,
      );
      for (final id in page.ids) {
        final gallery = await hitomi.galleries.retrieve(id);
        final watch = Stopwatch()..start();
        final result = await hitomi.galleries.search(
          title: gallery.title,
          lenientTitle: true,
        );
        print(
          '[$language] ${watch.elapsedMilliseconds}ms '
          '${result.ids.length} 个结果  ${gallery.title}',
        );
        expect(
          result.ids,
          contains(id),
          reason:
              '[$language] ${gallery.title} '
              '(ignored: ${result.ignoredWords})',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('title search is fast after warm-up', () async {
    var watch = Stopwatch()..start();
    await hitomi.galleries.warmUpTitleIndex();
    print('warm-up ${watch.elapsedMilliseconds}ms');
    for (final title in [
      'Shoujo shika Ninshin Dekinai Sekai',
      'Minna ga Dare kato Tsukiaeru Made no Hanashi',
      'デリヘル呼んだら元同級生が来た 1-2',
    ]) {
      watch = Stopwatch()..start();
      final cold = await hitomi.galleries.search(
        title: title,
        lenientTitle: true,
      );
      final coldMs = watch.elapsedMilliseconds;
      watch = Stopwatch()..start();
      await hitomi.galleries.search(title: title, lenientTitle: true);
      print(
        '$title: ${cold.ids.length} 个结果，首次 ${coldMs}ms，再次 ${watch.elapsedMilliseconds}ms',
      );
      expect(cold.ids, isNotEmpty);
    }
  });

  test('complex search with negative tag', () async {
    final search = GallerySearch(
      hitomi,
      tags: hitomi.tags.parse(
        'series:blue_archive language:korean -female:netorare',
      ),
    );
    final first = await search.loadPage(0);
    expect(first, isNotEmpty);
    expect(search.total, greaterThan(0));
  });

  test('tag suggestions', () async {
    final results = await hitomi.tags.search('female:big b');
    expect(results.first.tag.name, startsWith('big b'));
    expect(results.first.count, greaterThan(0));
    expect(await hitomi.tags.search('naru'), isNotEmpty);
  });

  test('lists tags by initial', () async {
    final series = await hitomi.tags.list(TagType.series, 'b');
    expect(series, contains(const Tag(TagType.series, 'blue archive')));
    final female = await hitomi.tags.list(TagType.female, 'b');
    expect(female, contains(const Tag(TagType.female, 'big breasts')));
    final plain = await hitomi.tags.list(TagType.tag, 'f');
    expect(plain.every((tag) => tag.type == TagType.tag), isTrue);
  });

  test('lists languages of a tag', () async {
    final languages = await hitomi.tags.listLanguages(
      const Tag(TagType.series, 'blue archive'),
    );
    expect(languages.map((l) => l.name), containsAll(['english', 'chinese']));
  });
}
