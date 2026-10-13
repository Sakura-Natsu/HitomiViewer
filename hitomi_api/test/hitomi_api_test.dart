import 'dart:convert';
import 'dart:typed_data';

import 'package:hitomi_api/hitomi_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const _ggJs = '''
'use strict';
gg = { m: function(g) {
var o = 0;
switch (g) {
case 3445:
case 2818:
case 1301:
o = 1; break;
}
return o;
},
s: function(h) { var m = /(..)(.)\$/.exec(h); return parseInt(m[2]+m[1], 16).toString(10); },
b: '1791885602/'
};
''';

const _hash =
    '368ad2e7c0a7167f5989e1f5161ac1861a5d85ae6d7b7f2000aa16ad1f1b9a80';

Uint8List _ids(List<int> ids) {
  final data = ByteData(ids.length * 4);
  for (var i = 0; i < ids.length; i++) {
    data.setInt32(i * 4, ids[i]);
  }
  return data.buffer.asUint8List();
}

/// 根据路径返回预设响应，并记录请求。
Hitomi _mockHitomi(Map<String, Object> routes, {List<http.BaseRequest>? log}) {
  final client = MockClient((request) async {
    log?.add(request);
    final key = '${request.url.host}${request.url.path}';
    final body = routes[key];
    if (body == null) return http.Response('', 404);
    var bytes = body is String ? utf8.encode(body) : body as Uint8List;
    final range = request.headers['range'];
    if (range != null && range.contains(',')) {
      // 多个范围：返回 multipart/byteranges
      const boundary = 'BOUNDARY';
      final body = BytesBuilder();
      for (final match in RegExp(r'(\d+)-(\d+)').allMatches(range)) {
        final start = int.parse(match[1]!);
        if (start >= bytes.length) continue;
        final end = int.parse(match[2]!).clamp(0, bytes.length - 1);
        body
          ..add(
            utf8.encode(
              '\r\n--$boundary\r\n'
              'Content-Type: application/octet-stream\r\n'
              'Content-Range: bytes $start-$end/${bytes.length}\r\n\r\n',
            ),
          )
          ..add(bytes.sublist(start, end + 1));
      }
      body.add(utf8.encode('\r\n--$boundary--\r\n'));
      return http.Response.bytes(
        body.toBytes(),
        206,
        headers: {'content-type': 'multipart/byteranges; boundary=$boundary'},
      );
    }
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      final start = int.parse(match[1]!);
      final end = int.parse(match[2]!);
      if (start >= bytes.length) {
        return http.Response.bytes(
          [],
          416,
          headers: {'content-range': 'bytes */${bytes.length}'},
        );
      }
      final last = end >= bytes.length ? bytes.length - 1 : end;
      return http.Response.bytes(
        bytes.sublist(start, last + 1),
        206,
        headers: {'content-range': 'bytes $start-$last/${bytes.length}'},
      );
    }
    return http.Response.bytes(bytes, 200);
  });
  return Hitomi(client: client);
}

void main() {
  group('ImageContext', () {
    test('parses gg.js', () {
      final context = ImageContext.parse(_ggJs);
      expect(context.codes, {3445, 2818, 1301});
      expect(context.defaultValue, 0);
      expect(context.matchedValue, 1);
      expect(context.pathPrefix, '1791885602/');
      expect(context.m(3445), 1);
      expect(context.m(168), 0);
    });

    test('throws on unparsable gg.js', () {
      expect(
        () => ImageContext.parse('nothing here'),
        throwsA(isA<HitomiException>()),
      );
    });

    test('builds full image urls like common.js', () {
      final context = ImageContext.parse(_ggJs);
      const image = GalleryImage(
        hash: _hash,
        name: '01.png',
        width: 1,
        height: 1,
        hasAvif: true,
      );
      expect(hashCodeOf(_hash), 168);
      expect(
        image.fullUrl(context),
        'https://w1.gold-usergeneratedcontent.net/1791885602/168/$_hash.webp',
      );
      expect(
        image.fullUrl(context, extension: ImageExtension.avif),
        'https://a1.gold-usergeneratedcontent.net/1791885602/168/$_hash.avif',
      );

      // 末三位 "514" → "4" + "51" → 0x451，命中 case 列表时使用 w2。
      const matched = GalleryImage(
        hash:
            '0000000000000000000000000000000000000000000000000000000000000514',
        name: 'a',
        width: 1,
        height: 1,
      );
      expect(hashCodeOf(matched.hash), 0x451);
      final ctx = ImageContext(
        codes: {0x451},
        defaultValue: 0,
        matchedValue: 1,
        pathPrefix: 'p/',
      );
      expect(matched.fullUrl(ctx), startsWith('https://w2.'));
    });

    test('builds thumbnail urls and validates combinations', () {
      const image = GalleryImage(
        hash: _hash,
        name: '01.png',
        width: 1,
        height: 1,
        hasAvif: true,
      );
      expect(
        image.thumbnailUrl(),
        'https://tn.gold-usergeneratedcontent.net/webpsmalltn/0/a8/$_hash.webp',
      );
      expect(
        () => image.thumbnailUrl(size: ThumbnailSize.big),
        throwsA(isA<HitomiException>()),
      );
      const withThumbnail = GalleryImage(
        hash: _hash,
        name: '01.png',
        width: 1,
        height: 1,
        hasThumbnail: true,
      );
      expect(
        withThumbnail.thumbnailUrl(size: ThumbnailSize.big),
        contains('/webpbigtn/0/a8/'),
      );
      expect(
        () => withThumbnail.thumbnailUrl(
          extension: ImageExtension.webp,
          size: ThumbnailSize.medium,
        ),
        throwsA(isA<HitomiException>()),
      );
      expect(
        () => withThumbnail.thumbnailUrl(extension: ImageExtension.avif),
        throwsA(isA<HitomiException>()),
      );
    });
  });

  group('Gallery', () {
    final raw = <String, dynamic>{
      'id': '123456',
      'type': 'manga',
      'galleryurl': '/galleries/123456.html',
      'language': 'english',
      'language_localname': 'English',
      'title': 'A mocked gallery',
      'japanese_title': null,
      'artists': null,
      'groups': [
        {'group': 'some group'},
      ],
      'parodys': [
        {'parody': 'series tag'},
      ],
      'characters': [
        {'character': 'char tag'},
      ],
      'tags': [
        {'tag': 'general tag'},
        {'tag': 'male tag', 'male': '1', 'female': ''},
        {'tag': 'female tag', 'female': 1},
      ],
      'files': [
        {
          'hash': _hash,
          'name': '1.jpg',
          'width': 1000,
          'height': 1500,
          'hasavif': 1,
        },
        {'hash': _hash, 'name': '2.jpg', 'width': 1280, 'height': 720},
        {'hash': _hash, 'name': '3.jpg', 'width': 1280, 'height': 720},
      ],
      'languages': [
        {
          'galleryid': '234567',
          'name': 'japanese',
          'language_localname': '日本語',
          'url': '/galleries/234567.html',
        },
      ],
      'related': [1, 2],
      'blocked': 0,
      'date': '2026-10-13 04:23:00-05',
      'datepublished': '2016-03-27 13:37:33.612-05',
      'videofilename': 'video.mp4',
    };

    test('parses raw json', () {
      final gallery = Gallery.fromJson(raw);
      expect(gallery.id, 123456);
      expect(gallery.type, 'manga');
      expect(gallery.language?.name, 'english');
      expect(gallery.artists, isEmpty);
      expect(gallery.groups, [const Tag(TagType.group, 'some group')]);
      expect(gallery.series, [const Tag(TagType.series, 'series tag')]);
      expect(gallery.characters, [const Tag(TagType.character, 'char tag')]);
      expect(gallery.tags, const [
        Tag(TagType.tag, 'general tag'),
        Tag(TagType.male, 'male tag'),
        Tag(TagType.female, 'female tag'),
      ]);
      expect(gallery.files.map((f) => f.hasThumbnail), [true, true, false]);
      expect(gallery.files.first.hasAvif, isTrue);
      expect(gallery.files[1].hasAvif, isFalse);
      expect(gallery.translations.single.id, 234567);
      expect(gallery.relatedIds, [1, 2]);
      expect(gallery.isBlocked, isFalse);
      expect(gallery.addedDate.toUtc(), DateTime.utc(2026, 10, 13, 9, 23));
      expect(
        gallery.publishedDate!.toUtc(),
        DateTime.utc(2016, 3, 27, 18, 37, 33, 612),
      );
      expect(
        gallery.video!.url,
        'https://streaming.gold-usergeneratedcontent.net/videos/video.mp4',
      );
      expect(
        gallery.video!.posterUrl,
        endsWith('/videos/posters/0/a8/$_hash.webp'),
      );
      expect(gallery.thumbnails.length, 2);
      expect(gallery.allTags.first, const Tag(TagType.type, 'manga'));
      expect(Gallery.fromJson(gallery.toJson()).title, gallery.title);
    });
  });

  group('Tag', () {
    test('toString and url', () {
      const tag = Tag(TagType.female, 'big breasts', isNegative: true);
      expect('$tag', '-female:big_breasts');
      expect(tag.url, '/tag/female%3Abig%20breasts-all.html');
      expect(const Tag(TagType.language, 'korean').url, '/index-korean.html');
      expect(
        const Tag(TagType.series, 'blue archive').url,
        '/series/blue%20archive-all.html',
      );
    });

    test('parseQuery splits tags and title words', () {
      final hitomi = Hitomi(
        client: MockClient((_) async => http.Response('', 404)),
      );
      final query = hitomi.tags.parseQuery(
        '  female:Big_Breasts -male:yaoi  Hello  unknown:x language:chinese female:big_breasts world ',
      );
      expect(query.tags, const [
        Tag(TagType.female, 'big breasts'),
        Tag(TagType.male, 'yaoi', isNegative: true),
        Tag(TagType.language, 'chinese'),
      ]);
      // 类型无法识别的词（如标题中的 Re:Zero）保留为标题词，大小写保持原样
      expect(query.titleWords, ['Hello', 'unknown:x', 'world']);
      expect(query.title, 'Hello unknown:x world');
      expect(
        hitomi.tags.parseQuery('Re:Zero kara female:loli').toString(),
        'female:loli Re:Zero kara',
      );
      expect(hitomi.tags.parseQuery('  ').title, isNull);
      expect(hitomi.tags.parse('female:a female:a -tag:b_c'), const [
        Tag(TagType.female, 'a'),
        Tag(TagType.tag, 'b c', isNegative: true),
      ]);
    });
  });

  group('GalleryManager.nozomiPath', () {
    test('matches search.js', () {
      expect(GalleryManager.nozomiPath(), '/n/index-all.nozomi');
      expect(
        GalleryManager.nozomiPath(language: 'chinese'),
        '/n/index-chinese.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(orderBy: SortType.popularityWeek),
        '/n/popular/week-all.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(orderBy: SortType.datePublished),
        '/n/date/published-all.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(
          tag: const Tag(TagType.language, 'korean'),
          orderBy: SortType.popularityDay,
        ),
        '/n/popular/today-korean.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(
          tag: const Tag(TagType.female, 'sole female'),
          language: 'czech',
          orderBy: SortType.popularityWeek,
        ),
        '/n/tag/popular/week/female:sole%20female-czech.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(
          tag: const Tag(TagType.female, 'big breasts'),
        ),
        '/n/tag/female:big%20breasts-all.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(
          tag: const Tag(TagType.series, 'blue archive'),
          orderBy: SortType.datePublished,
        ),
        '/n/series/date/published/blue%20archive-all.nozomi',
      );
      expect(
        GalleryManager.nozomiPath(tag: const Tag(TagType.type, 'manga')),
        '/n/type/manga-all.nozomi',
      );
    });

    test('isPageable', () {
      expect(GalleryManager.isPageable(), isTrue);
      expect(
        GalleryManager.isPageable(
          tags: const [
            Tag(TagType.female, 'a'),
            Tag(TagType.language, 'chinese'),
          ],
        ),
        isTrue,
      );
      expect(
        GalleryManager.isPageable(
          tags: const [Tag(TagType.female, 'a'), Tag(TagType.male, 'b')],
        ),
        isFalse,
      );
      expect(
        GalleryManager.isPageable(
          tags: const [Tag(TagType.female, 'a', isNegative: true)],
        ),
        isFalse,
      );
      expect(GalleryManager.isPageable(title: 'abc'), isFalse);
      expect(GalleryManager.isPageable(orderBy: SortType.random), isFalse);
    });
  });

  group('GalleryManager.list', () {
    const ltn = 'ltn.gold-usergeneratedcontent.net';

    test(
      'intersects positive tags and removes negative tags in base order',
      () async {
        final log = <http.BaseRequest>[];
        final hitomi = _mockHitomi({
          '$ltn/n/tag/female:a-chinese.nozomi': _ids([9, 8, 7, 6, 5, 4]),
          '$ltn/n/series/b-chinese.nozomi': _ids([4, 5, 6, 8, 100]),
          '$ltn/n/tag/male:c-chinese.nozomi': _ids([6]),
        }, log: log);
        final ids = await hitomi.galleries.list(
          tags: const [
            Tag(TagType.male, 'c', isNegative: true),
            Tag(TagType.language, 'chinese'),
            Tag(TagType.female, 'a'),
            Tag(TagType.series, 'b'),
            Tag(TagType.language, 'english', isNegative: true),
          ],
        );
        expect(ids, [8, 5, 4]);
        // 已有正向语言标签时，排除语言标签无需请求。
        expect(
          log.map((r) => r.url.path),
          isNot(contains('/n/index-english.nozomi')),
        );
      },
    );

    test(
      'negative language tag without positive language uses its own index',
      () async {
        final hitomi = _mockHitomi({
          '$ltn/n/popular/week-all.nozomi': _ids([3, 2, 1]),
          '$ltn/n/index-english.nozomi': _ids([2]),
        });
        final ids = await hitomi.galleries.list(
          tags: const [Tag(TagType.language, 'english', isNegative: true)],
          orderBy: SortType.popularityWeek,
        );
        expect(ids, [3, 1]);
      },
    );

    test('fails cleanly when every request fails', () async {
      final hitomi = Hitomi(
        client: MockClient((_) async => http.Response('', 500)),
      );
      await expectLater(
        hitomi.galleries.list(
          tags: const [
            Tag(TagType.female, 'a'),
            Tag(TagType.male, 'b'),
            Tag(TagType.tag, 'c', isNegative: true),
          ],
          title: 'x y',
        ),
        throwsA(isA<HitomiException>()),
      );
      // 留出时间让其余失败的请求完成；若有未处理的异步错误，测试会失败。
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('unknown nozomi file yields empty result', () async {
      final hitomi = _mockHitomi({});
      expect(
        await hitomi.galleries.list(
          tags: const [Tag(TagType.artist, 'nobody')],
        ),
        isEmpty,
      );
    });

    test('listPage uses range and content-range total', () async {
      final log = <http.BaseRequest>[];
      final all = List.generate(60, (i) => 1000 - i);
      final hitomi = _mockHitomi({
        '$ltn/n/tag/female:a-all.nozomi': _ids(all),
      }, log: log);
      final page = await hitomi.galleries.listPage(
        tags: const [Tag(TagType.female, 'a')],
        page: 1,
        pageSize: 25,
      );
      expect(page.ids, all.sublist(25, 50));
      expect(page.total, 60);
      expect(log.single.headers['range'], 'bytes=100-199');

      final last = await hitomi.galleries.listPage(
        tags: const [Tag(TagType.female, 'a')],
        page: 2,
        pageSize: 25,
      );
      expect(last.ids, all.sublist(50));

      final beyond = await hitomi.galleries.listPage(
        tags: const [Tag(TagType.female, 'a')],
        page: 5,
        pageSize: 25,
      );
      expect(beyond.ids, isEmpty);
      expect(beyond.total, 60);
    });

    test('GallerySearch pages complex queries locally', () async {
      final hitomi = _mockHitomi({
        '$ltn/n/tag/female:a-all.nozomi': _ids(
          List.generate(30, (i) => 100 - i),
        ),
        '$ltn/n/tag/male:b-all.nozomi': _ids([99, 98, 80, 75, 71]),
      });
      final search = GallerySearch(
        hitomi,
        tags: const [Tag(TagType.female, 'a'), Tag(TagType.male, 'b')],
        pageSize: 2,
      );
      expect(search.isPaged, isFalse);
      expect(await search.loadPage(0), [99, 98]);
      expect(search.total, 5);
      expect(await search.loadPage(2), [71]);
      expect(await search.loadPage(3), isEmpty);
    });
  });

  group('title search', () {
    const ltn = 'ltn.gold-usergeneratedcontent.net';

    /// 用给定的词构造只有一个叶子节点的 galleriesindex，以及对应的数据文件。
    Hitomi titleIndex(
      Map<String, List<int>> words, {
      List<http.BaseRequest>? log,
    }) {
      final hasher = Hitomi(
        client: MockClient((_) async => http.Response('', 404)),
      );
      final entries = [
        for (final MapEntry(key: word, value: ids) in words.entries)
          (hasher.hashTerm(word), ids),
      ]..sort((a, b) => compareKeys(a.$1, b.$1));

      final data = BytesBuilder();
      final node = BytesBuilder()
        ..add((ByteData(4)..setInt32(0, entries.length)).buffer.asUint8List());
      for (final (key, _) in entries) {
        node
          ..add((ByteData(4)..setInt32(0, key.length)).buffer.asUint8List())
          ..add(key);
      }
      node.add((ByteData(4)..setInt32(0, entries.length)).buffer.asUint8List());
      for (final (_, ids) in entries) {
        final offset = data.length;
        data
          ..add((ByteData(4)..setInt32(0, ids.length)).buffer.asUint8List())
          ..add(_ids(ids));
        node.add(
          (ByteData(12)
                ..setUint64(0, offset)
                ..setInt32(8, 4 + ids.length * 4))
              .buffer
              .asUint8List(),
        );
      }
      node.add(Uint8List(17 * 8));
      final index = Uint8List(464)..setRange(0, node.length, node.toBytes());
      return _mockHitomi({
        '$ltn/galleriesindex/version': '7',
        '$ltn/galleriesindex/galleries.7.index': index,
        '$ltn/galleriesindex/galleries.7.data': data.toBytes(),
      }, log: log);
    }

    test('lenient matching handles punctuation and unknown words', () async {
      final hitomi = titleIndex({
        'kei-chan': [1, 2, 3],
        'zenbu': [2, 3, 9],
        '转生': [3, 4],
        '女骑士': [3, 5],
      });
      const title = 'Kei-chan!! ZENBU 转生～女骑士 nothinghere';

      final strict = await hitomi.galleries.search(title: title);
      expect(strict.ids, isEmpty);

      final lenient = await hitomi.galleries.search(
        title: title,
        lenientTitle: true,
      );
      expect(lenient.ids, [3]);
      expect(lenient.ignoredWords, ['nothinghere']);

      final onlyUnknown = await hitomi.galleries.search(
        title: 'nothinghere',
        lenientTitle: true,
      );
      expect(onlyUnknown.ids, isEmpty);
      expect(onlyUnknown.ignoredWords, ['nothinghere']);

      final search = GallerySearch(hitomi, title: 'zenbu  kei-chan, ???');
      expect(await search.loadPage(0), [3, 2]);
      expect(search.ignoredWords, ['???']);
    });

    test(
      'lenient search skips common words once the result is narrow',
      () async {
        final log = <http.BaseRequest>[];
        final hitomi = titleIndex({
          'kei-chan': [1, 2, 3],
          // 约 1.1 MB，超过常见词阈值
          'the': [for (var i = 1; i <= 270000; i++) i],
        }, log: log);

        final lenient = await hitomi.galleries.search(
          title: 'the kei-chan',
          lenientTitle: true,
        );
        expect(lenient.ids, [3, 2, 1]);
        final dataRequests = log.where((r) => r.url.path.endsWith('.data'));
        expect(dataRequests, hasLength(1));
        expect(dataRequests.single.headers['range']!.split(','), hasLength(1));

        // 严格模式（与网站一致）仍然下载全部词
        log.clear();
        final strict = await hitomi.galleries.list(title: 'the kei-chan');
        expect(strict, [3, 2, 1]);
        expect(log.where((r) => r.url.path.endsWith('.data')), hasLength(1));
      },
    );

    test('title words are cached and can be prefetched', () async {
      final log = <http.BaseRequest>[];
      final hitomi = titleIndex({
        'zenbu': [2, 3, 9],
        'suki': [3, 9],
      }, log: log);
      await hitomi.galleries.prefetchTitle('Zenbu suki');
      final requests = log.length;
      expect(requests, greaterThan(0));
      final result = await hitomi.galleries.search(
        title: 'zenbu SUKI',
        lenientTitle: true,
      );
      expect(result.ids, [9, 3]);
      expect(log.length, requests, reason: '预取后搜索不应再发请求');
    });
  });

  group('IndexProvider', () {
    // 构造一个两层的 B 树：根节点 key=[5]，左子树 key=[1,3]，右子树 key=[7]
    Uint8List node(List<int> keys, List<(int, int)> datas, List<int> children) {
      final builder = BytesBuilder();
      final header = ByteData(4)..setInt32(0, keys.length);
      builder.add(header.buffer.asUint8List());
      for (final key in keys) {
        final size = ByteData(4)..setInt32(0, 4);
        builder.add(size.buffer.asUint8List());
        builder.add([0, 0, 0, key]);
      }
      builder.add(
        (ByteData(4)..setInt32(0, datas.length)).buffer.asUint8List(),
      );
      for (final (offset, length) in datas) {
        final data = ByteData(12)
          ..setUint64(0, offset)
          ..setInt32(8, length);
        builder.add(data.buffer.asUint8List());
      }
      for (var i = 0; i < 17; i++) {
        final address = ByteData(8)
          ..setUint64(0, i < children.length ? children[i] : 0);
        builder.add(address.buffer.asUint8List());
      }
      final bytes = builder.toBytes();
      return Uint8List(464)..setRange(0, bytes.length, bytes);
    }

    test('binary search walks subnodes', () async {
      final index = BytesBuilder()
        ..add(node([5], [(500, 50)], [464, 928]))
        ..add(node([1, 3], [(100, 10), (300, 30)], []))
        ..add(node([7], [(700, 70)], []));
      const ltn = 'ltn.gold-usergeneratedcontent.net';
      final hitomi = _mockHitomi({
        '$ltn/galleriesindex/version': '42\n',
        '$ltn/galleriesindex/galleries.42.index': index.toBytes(),
      });
      final provider = hitomi.galleries.index;
      Future<int?> find(int key) async =>
          (await provider.search(Uint8List.fromList([0, 0, 0, key])))
              ?.$1
              .offset;
      expect(await find(5), 500);
      expect(await find(3), 300);
      expect(await find(1), 100);
      expect(await find(7), 700);
      expect(await find(2), isNull);
      expect(await find(9), isNull);
    });

    test('prefetch loads upper levels with multi-range requests', () async {
      final index = BytesBuilder()
        ..add(node([5], [(500, 50)], [464, 928]))
        ..add(node([1, 3], [(100, 10), (300, 30)], []))
        ..add(node([7], [(700, 70)], []));
      const ltn = 'ltn.gold-usergeneratedcontent.net';
      final log = <http.BaseRequest>[];
      final hitomi = _mockHitomi({
        '$ltn/galleriesindex/version': '42',
        '$ltn/galleriesindex/galleries.42.index': index.toBytes(),
      }, log: log);
      final provider = hitomi.galleries.index;
      await provider.prefetch('42', levels: 1);
      // 根节点一次，两个子节点合并为一次 multi-range 请求
      expect(log.where((r) => r.url.path.endsWith('.index')), hasLength(2));
      expect(log.last.headers['range'], 'bytes=464-927,928-1391');

      log.clear();
      final found = await provider.search(Uint8List.fromList([0, 0, 0, 3]));
      expect(found?.$1.offset, 300);
      expect(log.where((r) => r.url.path.endsWith('.index')), isEmpty);
    });

    test('searchMany batches each level into one request', () async {
      final index = BytesBuilder()
        ..add(node([5], [(500, 50)], [464, 928]))
        ..add(node([1, 3], [(100, 10), (300, 30)], []))
        ..add(node([7], [(700, 70)], []));
      const ltn = 'ltn.gold-usergeneratedcontent.net';
      final log = <http.BaseRequest>[];
      final hitomi = _mockHitomi({
        '$ltn/galleriesindex/version': '42',
        '$ltn/galleriesindex/galleries.42.index': index.toBytes(),
      }, log: log);
      final results = await hitomi.galleries.index.searchMany([
        for (final key in [1, 3, 7, 5, 9]) Uint8List.fromList([0, 0, 0, key]),
      ], '42');
      expect(results.map((data) => data?.offset), [100, 300, 700, 500, null]);
      // 根节点 1 次 + 第二层两个节点合并为 1 次
      expect(log, hasLength(2));
    });

    test('hashTerm returns first 4 bytes of sha256', () {
      final hitomi = Hitomi(
        client: MockClient((_) async => http.Response('', 404)),
      );
      // sha256("abc") = ba7816bf...
      expect(hitomi.hashTerm('abc'), [0xba, 0x78, 0x16, 0xbf]);
    });
  });

  group('multi-range', () {
    test('parses multipart/byteranges even if data contains the boundary', () {
      final data = utf8.encode('--B\r\nfake');
      final body = BytesBuilder()
        ..add(utf8.encode('\r\n--B\r\nContent-Range: bytes 10-18/100\r\n\r\n'))
        ..add(data)
        ..add(utf8.encode('\r\n--B\r\ncontent-range: bytes 40-42/100\r\n\r\n'))
        ..add([1, 2, 3])
        ..add(utf8.encode('\r\n--B--\r\n'));
      final parts = Hitomi.parseMultipartByteRanges(body.toBytes(), 'B');
      expect(parts.keys, [10, 40]);
      expect(parts[10], data);
      expect(parts[40], [1, 2, 3]);
    });

    test('requestRanges works for single and multiple ranges', () async {
      final file = Uint8List.fromList(List.generate(100, (i) => i));
      final hitomi = _mockHitomi({'example.com/file': file});
      final multi = await hitomi.requestRanges('example.com', '/file', [
        (0, 2),
        (50, 51),
        (98, 99),
      ]);
      expect(multi[0], [0, 1, 2]);
      expect(multi[50], [50, 51]);
      expect(multi[98], [98, 99]);
      final single = await hitomi.requestRanges('example.com', '/file', [
        (10, 12),
      ]);
      expect(single[10], [10, 11, 12]);
    });

    test('refuses to read a full response when Range is ignored', () async {
      final hitomi = Hitomi(
        client: MockClient(
          (_) async => http.Response.bytes(Uint8List(16), 200),
        ),
      );
      // 小文件可以接受
      final small = await hitomi.request('example.com', '/f', range: '0-3');
      expect(small.statusCode, 200);
    });
  });

  group('TagManager.search', () {
    test('encodes term into per-character path', () async {
      final log = <http.BaseRequest>[];
      final hitomi = _mockHitomi({
        'tagindex.hitomi.la/female/b/i/g/_/b.json':
            '[["big breasts",465670,"female"],["big body",1,"unknown"]]',
      }, log: log);
      final results = await hitomi.tags.search('female:big b');
      expect(results.single.tag, const Tag(TagType.female, 'big breasts'));
      expect(results.single.count, 465670);
      await hitomi.tags.search('a.b/c');
      expect(log.last.url.path, '/global/a/dot/b/slash/c.json');
      expect(
        () => hitomi.tags.search('nope:x'),
        throwsA(isA<HitomiException>()),
      );
    });
  });

  group('language_support.js', () {
    test('maps bit numbers to languages', () {
      final bits = Hitomi.parseLanguageSupport(
        'var bitnumber_language = {"2":"catalan","0":"indonesian","43":"chinese"}, '
        'language_localname = {"chinese":"中文","all":"(all)"};',
      );
      expect(bits.length, 44);
      expect(bits[0]?.name, 'indonesian');
      expect(bits[0]?.localName, 'Bahasa Indonesia');
      expect(bits[1], isNull);
      expect(bits[43]?.localName, '中文');
    });

    test('static table matches current bit order', () {
      expect(Language.ordered[15].name, 'khmer');
      expect(Language.ordered[29].name, 'textless narrative');
      expect(Language.ordered[43].name, 'chinese');
      expect(Language.ordered[44].name, 'japanese');
    });
  });

  group('CachedValue', () {
    test('deduplicates concurrent fetches and expires', () async {
      var calls = 0;
      final value = CachedValue(() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return calls;
      }, const Duration(hours: 1));
      final results = await Future.wait([
        value.get(),
        value.get(),
        value.get(),
      ]);
      expect(results, [1, 1, 1]);
      expect(await value.get(), 1);
      value.invalidate();
      expect(await value.get(), 2);
      expect(await value.get(forceRefresh: true), 3);
    });
  });
}
