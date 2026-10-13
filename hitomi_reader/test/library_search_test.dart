import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:hitomi_reader/pages/library_pages.dart';
import 'package:hitomi_reader/pages/settings_page.dart';
import 'package:hitomi_reader/services/app_services.dart';
import 'package:hitomi_reader/services/http_client.dart';
import 'package:hitomi_reader/services/library_store.dart';
import 'package:hitomi_reader/services/settings.dart';
import 'package:hitomi_reader/services/tag_labels.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Gallery _gallery(
  int id,
  String title, {
  String? japaneseTitle,
  String language = 'chinese',
  String type = 'doujinshi',
  List<String> artists = const [],
  List<String> female = const [],
  List<String> male = const [],
}) => Gallery.fromJson({
  'id': '$id',
  'title': title,
  'japanese_title': ?japaneseTitle,
  'type': type,
  'language': language,
  'artists': [
    for (final artist in artists) {'artist': artist},
  ],
  'tags': [
    for (final tag in female) {'tag': tag, 'female': '1'},
    for (final tag in male) {'tag': tag, 'male': '1'},
  ],
  'files': [
    {'hash': 'hash$id', 'name': '1.webp', 'width': 10, 'height': 14},
  ],
});

final _ponytail = _gallery(
  1,
  'Ponytail Summer',
  japaneseTitle: 'ポニーテールの夏',
  artists: ['kei-chan'],
  female: ['big breasts', 'ponytail'],
);
final _glasses = _gallery(
  2,
  'Glasses Club',
  language: 'japanese',
  female: ['glasses'],
);
final _beach = _gallery(
  3,
  'Summer Beach',
  type: 'manga',
  female: ['big breasts', 'swimsuit'],
  male: ['muscle'],
);

void main() {
  group('GallerySummary.matches', () {
    final summary = GallerySummary.fromGallery(_ponytail);

    test('标签：包含的都有、排除的都没有；类型、语言、作者都算标签', () {
      bool match(String query) =>
          summary.matches(SearchQuery(tags: TagManagerForTest.parse(query)));
      expect(match('female:big_breasts'), isTrue);
      expect(match('female:big_breasts female:ponytail'), isTrue);
      expect(match('female:big_breasts female:glasses'), isFalse);
      expect(match('-female:ponytail'), isFalse);
      expect(match('-female:glasses'), isTrue);
      expect(match('language:chinese type:doujinshi'), isTrue);
      expect(match('-language:chinese'), isFalse);
      expect(match('artist:kei-chan'), isTrue);
    });

    test('标题词：都要出现在标题、日文标题或作者名中，不区分大小写', () {
      expect(summary.matches(const SearchQuery(title: 'ponytail')), isTrue);
      expect(summary.matches(const SearchQuery(title: 'SUMMER pony')), isTrue);
      expect(summary.matches(const SearchQuery(title: 'ポニーテール')), isTrue);
      expect(summary.matches(const SearchQuery(title: 'kei-chan')), isTrue);
      expect(
        summary.matches(const SearchQuery(title: 'ponytail winter')),
        isFalse,
      );
      expect(summary.matches(const SearchQuery(title: '1')), isTrue);
      expect(summary.matches(const SearchQuery(title: '#1')), isTrue);
    });

    test('JSON 往返保留标签；旧记录没有标签时为 null', () {
      final restored = GallerySummary.fromJson(
        jsonDecode(jsonEncode(summary.toJson())) as Map<String, dynamic>,
      );
      expect(restored.tags, summary.tags);
      expect(restored.japaneseTitle, 'ポニーテールの夏');
      final old = GallerySummary.fromJson({
        'id': 9,
        'title': 'old',
        'type': 'manga',
        'pageCount': 3,
        'language': 'chinese',
        'artists': ['someone'],
      });
      expect(old.tags, isNull);
      // 类型、语言、作者在旧记录里也有
      expect(
        old.matches(
          SearchQuery(
            tags: TagManagerForTest.parse('type:manga artist:someone'),
          ),
        ),
        isTrue,
      );
    });
  });

  test('补全旧收藏的标签信息，获取失败的不重复请求', () async {
    final directory = await Directory.systemTemp.createTemp('library_test');
    addTearDown(() => directory.delete(recursive: true));
    await File('${directory.path}/library.json').writeAsString(
      jsonEncode({
        'favorites': [
          for (final id in [1, 2, 404])
            {
              'gallery': {'id': id, 'title': 'old $id', 'type': 'manga'},
              'addedAt': DateTime(2026, 1, id % 28 + 1).toIso8601String(),
            },
        ],
      }),
    );
    final library = await LibraryStore.open(directory);
    expect(library.favoritesMissingTags, 3);

    final requested = <int>[];
    Future<Gallery> fetch(int id) async {
      requested.add(id);
      if (id == 404) throw const HttpException('404');
      return id == 1 ? _ponytail : _glasses;
    }

    await library.fillFavoriteDetails(fetch);
    expect(requested..sort(), [1, 2, 404]);
    expect(library.favoritesMissingTags, 0, reason: '失败的本次运行中不再计入');
    final byId = {for (final e in library.favorites) e.gallery.id: e.gallery};
    expect(byId[1]!.tags, contains('female:ponytail'));
    expect(byId[1]!.title, 'Ponytail Summer');
    expect(byId[404]!.tags, isNull);

    requested.clear();
    await library.fillFavoriteDetails(fetch);
    expect(requested, isEmpty);
    await library.save();
  });

  group('页面', () {
    late Directory directory;
    final tagRequests = <Uri>[];

    Future<void> setUpServices(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tagRequests.clear();
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('library_page_test');
        final database = gzip.encode(
          utf8.encode(
            jsonEncode({
              'data': [
                {
                  'namespace': 'female',
                  'data': {
                    'big breasts': {'name': '巨乳', 'intro': '', 'links': ''},
                    'ponytail': {'name': '马尾', 'intro': '', 'links': ''},
                    'glasses': {'name': '眼镜', 'intro': '', 'links': ''},
                  },
                },
              ],
            }),
          ),
        );
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/sha')) {
            return http.Response('abc', 200);
          }
          if (request.url.path.endsWith('db.text.json.gz')) {
            return http.Response.bytes(database, 200);
          }
          if (request.url.host == 'tagindex.hitomi.la') {
            tagRequests.add(request.url);
            return http.Response(jsonEncode([]), 200);
          }
          return http.Response('', 404);
        });
        await AppServices.create(
          settings: AppSettings(await SharedPreferences.getInstance()),
          http: ProxyHttpClient(const ProxyConfig(mode: ProxyMode.direct)),
          client: client,
          supportDirectory: Directory('${directory.path}/support'),
          cacheDirectory: Directory('${directory.path}/cache'),
          downloadDirectory: Directory('${directory.path}/downloads'),
        );
        await services.tagSuggester.remote('zz');
        await services.translations.update();
      });
      tagRequests.clear();
    }

    Future<void> tearDownPage(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(() async {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // 收藏记录可能还在写入
        }
      });
    }

    Future<void> type(WidgetTester tester, String text) async {
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Widget app(Widget home) => TagLabelScope(
      labels: services.tagLabels,
      child: MaterialApp(home: home),
    );

    Finder titleOf(Gallery gallery) => find.text(gallery.title);

    testWidgets('收藏：和普通搜索一样，标题 + 中文标签联想 + 排除', (tester) async {
      await setUpServices(tester);
      services.library
        ..setFavorite(_ponytail, true)
        ..setFavorite(_glasses, true)
        ..setFavorite(_beach, true);
      await tester.pumpWidget(app(const FavoritesPage()));
      await tester.pump();
      for (final gallery in [_ponytail, _glasses, _beach]) {
        expect(titleOf(gallery), findsOneWidget);
      }

      // 打开搜索编辑页，输入中文标签名，从联想中点选
      await tester.tap(find.byKey(const ValueKey('favorites-search-box')));
      await settle(tester);
      expect(find.text('在收藏中搜索标题或标签'), findsOneWidget);
      await type(tester, '巨乳');
      final candidate = find.byKey(
        const ValueKey('candidate:female:big_breasts'),
      );
      expect(candidate, findsOneWidget);
      expect(tagRequests, isEmpty, reason: '中文片段只查本地标签库');
      await tester.tap(candidate);
      await tester.pump();
      // 再输入标题词
      await type(tester, 'summer');
      await tester.tap(find.textContaining('筛选收藏'));
      await settle(tester);

      expect(titleOf(_ponytail), findsOneWidget);
      expect(titleOf(_beach), findsOneWidget);
      expect(titleOf(_glasses), findsNothing);
      expect(find.text('共 2 本（全部 3 本）'), findsOneWidget);

      // 点按标签条件切换为排除
      await tester.tap(find.text('女性：巨乳'));
      await tester.pump();
      expect(titleOf(_ponytail), findsNothing);
      expect(titleOf(_beach), findsNothing);
      expect(find.text('没有符合条件的收藏'), findsOneWidget);

      await tester.tap(find.widgetWithText(ActionChip, '清空'));
      await tester.pump();
      expect(titleOf(_glasses), findsOneWidget);
      // 筛选收藏不写入网站搜索的历史
      expect(services.settings.searchHistory, isEmpty);
      await tearDownPage(tester);
    });

    testWidgets('屏蔽标签：输入中文即可联想，点选后屏蔽；仍支持 类型:名称', (tester) async {
      await setUpServices(tester);
      await tester.pumpWidget(app(const BlockedTagsPage()));
      await tester.pump();
      expect(find.text('没有屏蔽的标签'), findsOneWidget);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await type(tester, '眼镜');
      final candidate = find.byKey(
        const ValueKey('block-candidate:female:glasses'),
      );
      expect(candidate, findsOneWidget);
      expect(
        find.descendant(of: candidate, matching: find.textContaining('眼镜')),
        findsOneWidget,
      );
      await tester.tap(candidate);
      await tester.pump();
      expect(services.settings.blockedTags, ['female:glasses']);
      expect(find.text('女性：眼镜'), findsWidgets);

      // 英文也能联想；已屏蔽的标注出来
      await type(tester, 'glass');
      expect(
        find.descendant(of: candidate, matching: find.textContaining('已屏蔽')),
        findsOneWidget,
      );

      await type(tester, 'male:yaoi');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(services.settings.blockedTags, ['female:glasses', 'male:yaoi']);
      await settle(tester);
      await tearDownPage(tester);
    });
  });
}

/// 测试里不依赖网络地解析标签写法。
abstract final class TagManagerForTest {
  static List<Tag> parse(String text) => [
    for (final token in text.split(' '))
      if (token.isNotEmpty)
        () {
          final negative = token.startsWith('-');
          final body = negative ? token.substring(1) : token;
          final colon = body.indexOf(':');
          return Tag(
            TagType.values.byName(body.substring(0, colon)),
            body.substring(colon + 1).replaceAll('_', ' '),
            isNegative: negative,
          );
        }(),
  ];
}
