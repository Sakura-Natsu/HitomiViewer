import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/services/tag_suggester.dart';
import 'package:hitomi_reader/services/tag_translations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _namespace(String name, Map<String, String> data) => {
  'namespace': name,
  'data': {
    for (final MapEntry(:key, :value) in data.entries)
      key: {'name': value, 'intro': '$value 的释义', 'links': ''},
  },
};

final _database = {
  'version': 7,
  'data': [
    _namespace('female', {
      'big breasts': '巨乳',
      'big ass': '大屁股',
      'glasses': '眼镜',
    }),
    _namespace('male', {'big breasts': '巨乳', 'yaoi': '耽美'}),
    _namespace('other', {'full color': '全彩'}),
    _namespace('mixed', {'group': '群交'}),
    _namespace('language', {'chinese': '汉语', 'rough translation': '粗翻'}),
    _namespace('parody', {'blue archive': '蔚蓝档案'}),
    _namespace('character', {'hina sorasaki': '空崎日奈'}),
    _namespace('cosplayer', {'someone': '某人'}),
  ],
};

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ehtag_test');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<TagTranslations> openWith(Map<String, dynamic> database) async {
    final bytes = gzip.encode(utf8.encode(jsonEncode(database)));
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/sha')) return http.Response('abc', 200);
      return http.Response.bytes(bytes, 200);
    });
    final translations = await TagTranslations.open(directory, client);
    expect(await translations.update(), isTrue);
    return translations;
  }

  test('downloads, maps namespaces and looks up tags', () async {
    final translations = await openWith(_database);
    expect(translations.isLoaded, isTrue);
    expect(
      translations.lookup(const Tag(TagType.female, 'big breasts'))?.name,
      '巨乳',
    );
    expect(
      translations.lookup(const Tag(TagType.series, 'blue archive'))?.name,
      '蔚蓝档案',
    );
    // hitomi 的普通标签对应 EH 的 other / mixed / 非语言的 language
    expect(
      translations.lookup(const Tag(TagType.tag, 'full color'))?.name,
      '全彩',
    );
    expect(translations.lookup(const Tag(TagType.tag, 'group'))?.name, '群交');
    expect(
      translations.lookup(const Tag(TagType.tag, 'rough translation'))?.name,
      '粗翻',
    );
    // 普通标签在 EH 中带性别时也能找到
    expect(translations.lookup(const Tag(TagType.tag, 'glasses'))?.name, '眼镜');
    expect(translations.lookup(const Tag(TagType.artist, 'nobody')), isNull);

    // 相同版本不重复下载；重新打开时从磁盘读取
    expect(await translations.update(), isFalse);
    final reopened = await TagTranslations.open(
      directory,
      MockClient((_) async => http.Response('', 500)),
    );
    expect(reopened.count, translations.count);
  });

  test('searches by Chinese and English with ranking', () async {
    final translations = await openWith(_database);
    final chinese = translations.search('巨乳');
    expect(chinese.map((m) => '${m.tag}'), [
      'female:big_breasts',
      'male:big_breasts',
    ]);
    final english = translations.search('big');
    expect(english.first.tag, const Tag(TagType.female, 'big ass'));
    expect(english.map((m) => m.tag.type).toSet(), {
      TagType.female,
      TagType.male,
    });
    expect(
      translations.search('archive').single.tag,
      const Tag(TagType.series, 'blue archive'),
    );
    expect(
      translations.search('big', type: TagType.male).single.tag,
      const Tag(TagType.male, 'big breasts'),
    );
    expect(translations.suffixMatches('学园巨乳').first.tag.name, 'big breasts');
    // 语言别名：EH 译作「汉语」，输入「中文」也能找到
    expect(
      translations.search('中文').first.tag,
      const Tag(TagType.language, 'chinese'),
    );
    expect(
      translations.search('汉语').first.tag,
      const Tag(TagType.language, 'chinese'),
    );
  });

  test('fragments take the last one to three words before the cursor', () {
    final fragments = TagSuggester.fragments('kei-chan zenbu big brea');
    expect(fragments.map((f) => f.text), [
      'zenbu big brea',
      'big brea',
      'brea',
    ]);
    expect(fragments.first.start, 'kei-chan '.length);
    // type: 前缀只能出现在片段开头（支持 female:big brea 这样带空格的标签名）
    expect(TagSuggester.fragments('big female:glas').map((f) => f.text), [
      'female:glas',
    ]);
    expect(TagSuggester.fragments('female:big brea').map((f) => f.text), [
      'female:big brea',
      'brea',
    ]);
    final negative = TagSuggester.fragments('-male:yao').single;
    expect(negative.isNegative, isTrue);
    expect(negative.typeAndTerm, (TagType.male, 'yao'));
  });

  test('merge prefers longer fragments and remote counts', () {
    TagCandidate candidate(String tag, int words, {int? count}) => TagCandidate(
      tag: Tag(TagType.female, tag),
      replaceFrom: 0,
      fragmentLength: words,
      count: count,
    );
    final merged = TagSuggester.merge(
      [candidate('breast feeding', 1), candidate('big breasts', 2)],
      [
        candidate('big breasts', 2, count: 100),
        candidate('breast expansion', 1, count: 5),
        candidate('breast feeding', 1, count: 50),
      ],
    );
    expect(merged.map((c) => c.tag.name), [
      'big breasts',
      'breast feeding',
      'breast expansion',
    ]);
    expect(merged.first.count, 100);
  });

  test(
    'searching the real database is fast enough for every keystroke',
    () async {
      // 需要一份真实的 EhTagTranslation 数据库（db.text.json.gz），用环境变量指定：
      //   EHTAG_DB=/path/to/db.text.json.gz flutter test test/tag_translation_test.dart
      final path = Platform.environment['EHTAG_DB'];
      final file = path == null ? null : File(path);
      if (file == null || !file.existsSync()) {
        markTestSkipped('没有设置 EHTAG_DB，跳过真实数据库的性能测试');
        return;
      }
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/sha')) {
          return http.Response('real', 200);
        }
        return http.Response.bytes(file.readAsBytesSync(), 200);
      });
      final translations = await TagTranslations.open(directory, client);
      await translations.update();
      expect(translations.count, greaterThan(40000));
      final watch = Stopwatch()..start();
      for (final query in ['巨', '巨乳', 'big', 'big brea', '蔚蓝', 'glasses']) {
        translations.search(query);
      }
      // ignore: avoid_print
      print('6 次本地搜索共 ${watch.elapsedMilliseconds}ms，条目 ${translations.count}');
      expect(watch.elapsedMilliseconds, lessThan(600));

      // 联想实际使用的批量搜索：3 个片段 + 中文后缀，一次遍历
      watch.reset();
      final (results, suffixes) = await translations.searchBatch([
        (null, 'kei-chan big brea'),
        (null, 'big brea'),
        (null, 'brea'),
      ], suffixText: '学园巨乳');
      // ignore: avoid_print
      print('批量搜索（3 个片段 + 中文后缀）${watch.elapsedMilliseconds}ms');
      expect(results[1].first.tag.name, 'big breasts');
      expect(suffixes.first.tag.name, 'big breasts');
      expect(
        translations.lookup(const Tag(TagType.female, 'big breasts'))?.name,
        '巨乳',
      );
    },
  );
}
