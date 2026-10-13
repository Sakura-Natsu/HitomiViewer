import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hitomi_reader/pages/search_page.dart';
import 'package:hitomi_reader/services/app_services.dart';
import 'package:hitomi_reader/services/http_client.dart';
import 'package:hitomi_reader/services/settings.dart';
import 'package:hitomi_reader/services/tag_labels.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _pastedTitle = '[蜂巣 (Apoidea)] 煙霞繚乱 人を虜にする門主様 (ブルーアーカイブ)';

void main() {
  late Directory directory;
  final tagRequests = <Uri>[];

  Finder candidates() => find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('candidate:'),
  );

  EditableTextState editable(WidgetTester tester) =>
      tester.state<EditableTextState>(find.byType(EditableText));

  /// 模拟输入法提交新的文本与光标位置（打字、删字、粘贴都通过这里）。
  Future<void> edit(WidgetTester tester, String text, {int? cursor}) async {
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: cursor ?? text.length),
      ),
    );
    await tester.pump();
  }

  /// 等待防抖与联想请求完成。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpSearchPage(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tagRequests.clear();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('search_page_test');
      final database = gzip.encode(
        utf8.encode(
          jsonEncode({
            'data': [
              {
                'namespace': 'female',
                'data': {
                  'big breasts': {'name': '巨乳', 'intro': '', 'links': ''},
                  'huge breasts': {'name': '超乳', 'intro': '', 'links': ''},
                },
              },
            ],
          }),
        ),
      );
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/sha')) return http.Response('abc', 200);
        if (request.url.path.endsWith('db.text.json.gz')) {
          return http.Response.bytes(database, 200);
        }
        if (request.url.host == 'tagindex.hitomi.la') {
          tagRequests.add(request.url);
          return http.Response(
            jsonEncode([
              ['big breasts', 465000, 'female'],
              ['big ass', 62000, 'female'],
            ]),
            200,
          );
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
      // 预先读取（空的）联想缓存文件，避免在假时间里等待真实的文件读写
      await services.tagSuggester.remote('zz');
      await services.translations.update();
    });
    tagRequests.clear();

    await tester.pumpWidget(
      TagLabelScope(
        labels: services.tagLabels,
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pump();
  }

  Future<void> tearDownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5)); // 让缓存保存的定时器触发
    await tester.runAsync(() => directory.delete(recursive: true));
  }

  testWidgets('打字时输入框不会被重建，焦点保持', (tester) async {
    await pumpSearchPage(tester);
    final state = editable(tester);
    expect(state.widget.focusNode.hasFocus, isTrue);

    await edit(tester, 'b');
    await edit(tester, 'bi');
    await edit(tester, 'big');
    await settle(tester);

    expect(editable(tester), same(state), reason: '输入框被重建会导致手机输入法收起');
    expect(state.widget.focusNode.hasFocus, isTrue);
    expect(
      find.byKey(const ValueKey('candidate:female:big_breasts')),
      findsOneWidget,
    );
    await tearDownPage(tester);
  });

  testWidgets('粘贴标题、删减多余部分时不弹出标签联想', (tester) async {
    await pumpSearchPage(tester);
    final state = editable(tester);

    await edit(tester, _pastedTitle);
    await settle(tester);
    expect(candidates(), findsNothing);

    // 从开头逐字删掉 “[蜂巣 (Apoidea)] ”
    var text = _pastedTitle;
    while (!text.startsWith('煙霞')) {
      text = text.substring(1);
      await edit(tester, text, cursor: 0);
      await tester.pump(const Duration(milliseconds: 80));
    }
    // 从末尾逐字删掉 “ (ブルーアーカイブ)”
    while (!text.endsWith('門主様')) {
      text = text.substring(0, text.length - 1);
      await edit(tester, text);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await settle(tester);

    expect(text, '煙霞繚乱 人を虜にする門主様');
    expect(candidates(), findsNothing);
    expect(tagRequests, isEmpty, reason: '编辑标题时不应在后台查询标签');
    expect(editable(tester), same(state));
    expect(state.widget.focusNode.hasFocus, isTrue);
    expect(find.text('搜索标题「煙霞繚乱 人を虜にする門主様」'), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('标题后面接着输入标签名时才联想，选中后保留标题', (tester) async {
    await pumpSearchPage(tester);

    await edit(tester, '煙霞繚乱');
    await settle(tester);
    await edit(tester, '煙霞繚乱 b');
    await edit(tester, '煙霞繚乱 bi');
    await edit(tester, '煙霞繚乱 big');
    await settle(tester);

    final candidate = find.byKey(
      const ValueKey('candidate:female:big_breasts'),
    );
    expect(candidate, findsOneWidget);
    await tester.tap(candidate);
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '煙霞繚乱 ',
    );
    expect(find.text('女性：巨乳'), findsOneWidget);
    expect(candidates(), findsNothing);
    await tearDownPage(tester);
  });

  testWidgets('用中文输入标签名（输入法整词上屏）也能联想', (tester) async {
    await pumpSearchPage(tester);
    final state = editable(tester);
    await edit(tester, '巨乳');
    await settle(tester);
    final candidate = find.byKey(
      const ValueKey('candidate:female:big_breasts'),
    );
    expect(candidate, findsOneWidget);
    expect(
      find.descendant(of: candidate, matching: find.textContaining('巨乳')),
      findsOneWidget,
    );
    expect(tagRequests, isEmpty, reason: '中文片段不查询网站接口');
    expect(editable(tester), same(state));
    await tester.tap(candidate);
    await tester.pump();
    expect(find.text('女性：巨乳'), findsOneWidget);
    await tearDownPage(tester);
  });

  testWidgets('在文字中间编辑时不联想', (tester) async {
    await pumpSearchPage(tester);
    await edit(tester, 'big breasts');
    await settle(tester);
    // 把光标移到中间并删一个字
    await edit(tester, 'bg breasts', cursor: 1);
    await settle(tester);
    expect(candidates(), findsNothing);
    await tearDownPage(tester);
  });
}
