import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hitomi_api/hitomi_api.dart';

import 'tag_translations.dart';

/// 一条标签联想。
class TagCandidate {
  TagCandidate({
    required this.tag,
    required this.replaceFrom,
    required this.fragmentLength,
    this.info,
    this.count,
  });

  final Tag tag;

  /// 选中后，输入框中从这个位置到光标的文字会被移除（变成标签条件）。
  final int replaceFrom;

  /// 匹配的片段长度（词数），越长越具体，排序越靠前。
  final int fragmentLength;
  TagInfo? info;

  /// 作品数，来自网站的标签联想接口；只有本地标签库匹配时为 null。
  int? count;

  String get key => '${tag.type.name}:${tag.name}';
}

/// 输入框末尾的一个候选片段。
class TagFragment {
  const TagFragment(this.start, this.text, this.words);

  final int start;
  final String text;
  final int words;

  bool get isNegative => text.startsWith('-');

  /// 解析 `[-]type:name` 前缀。
  (TagType?, String) get typeAndTerm {
    var value = isNegative ? text.substring(1) : text;
    final colon = value.indexOf(':');
    if (colon > 0) {
      final type = TagType.tryParse(value.substring(0, colon).toLowerCase());
      if (type != null) return (type, value.substring(colon + 1));
    }
    return (null, value);
  }
}

/// 标签联想：本地中文标签库（即时）+ 网站联想接口（带作品数，结果缓存 7 天）。
class TagSuggester {
  TagSuggester(this._hitomi, this._translations, this._cacheFile);

  static const Duration _remoteMaxAge = Duration(days: 7);
  static const int _maxRemoteEntries = 3000;
  static const int _maxFragmentLength = 40;

  final Hitomi _hitomi;
  final TagTranslations _translations;
  final File _cacheFile;

  final Map<String, (DateTime, List<TagSuggestion>)> _remote = {};
  final Map<String, Future<List<TagSuggestion>>> _pending = {};
  bool _loaded = false;
  Timer? _saveTimer;

  static final RegExp _cjk = RegExp(
    r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]',
    unicode: true,
  );

  /// 光标前最后 1～3 个词组成的片段，最长的在前。
  ///
  /// 除第一个词外，片段中不能包含 `type:` 形式的词（那是另一个标签）。
  static List<TagFragment> fragments(String textBeforeCursor) {
    final words = RegExp(r'\S+').allMatches(textBeforeCursor).toList();
    final result = <TagFragment>[];
    for (var count = 1; count <= 3 && count <= words.length; count++) {
      final first = words[words.length - count];
      if (count > 1 &&
          words[words.length - count + 1].group(0)!.contains(':')) {
        break;
      }
      final text = textBeforeCursor.substring(first.start).trim();
      if (text.length > _maxFragmentLength) break;
      result.add(TagFragment(first.start, text, count));
    }
    return result.reversed.toList();
  }

  /// 本地标签库的联想（一次遍历、分片执行，不阻塞界面）。
  Future<List<TagCandidate>> local(
    String textBeforeCursor, {
    bool Function()? isCancelled,
  }) async {
    final fragments = TagSuggester.fragments(textBeforeCursor)
        .where((fragment) => fragment.typeAndTerm.$2.isNotEmpty)
        .toList();

    // 不带空格的中文输入：末尾正好是某个标签的中文名
    final trimmed = textBeforeCursor.trimRight();
    final lastWord = RegExp(r'\S+$').firstMatch(trimmed)?.group(0);
    final suffix = lastWord != null && _cjk.hasMatch(lastWord)
        ? lastWord
        : null;
    if (fragments.isEmpty && suffix == null) return const [];

    final (results, suffixMatches) = await _translations.searchBatch(
      [for (final fragment in fragments) fragment.typeAndTerm],
      suffixText: suffix,
      isCancelled: isCancelled,
    );
    if (results.length != fragments.length) return const []; // 已取消

    return [
      for (var i = 0; i < fragments.length; i++)
        for (final match in results[i])
          TagCandidate(
            tag: match.tag.negate(fragments[i].isNegative),
            info: match.info,
            replaceFrom: fragments[i].start,
            fragmentLength: fragments[i].words,
          ),
      for (final match in suffixMatches)
        TagCandidate(
          tag: match.tag,
          info: match.info,
          replaceFrom: trimmed.length - match.info.name.length,
          fragmentLength: 1,
        ),
    ];
  }

  /// 网站联想接口的结果（只查询英文片段）。
  Future<List<TagCandidate>> remote(String textBeforeCursor) async {
    final fragments = TagSuggester.fragments(textBeforeCursor)
        .where((f) => f.words <= 2 && !_cjk.hasMatch(f.text))
        .toList();
    final results = await Future.wait([
      for (final fragment in fragments)
        _search(fragment).then<List<TagSuggestion>>(
          (value) => value,
          onError: (Object _) => const <TagSuggestion>[],
        ),
    ]);
    return [
      for (var i = 0; i < fragments.length; i++)
        for (final suggestion in results[i])
          TagCandidate(
            tag: suggestion.tag.negate(fragments[i].isNegative),
            info: _translations.lookup(suggestion.tag),
            count: suggestion.count,
            replaceFrom: fragments[i].start,
            fragmentLength: fragments[i].words,
          ),
    ];
  }

  Future<List<TagSuggestion>> _search(TagFragment fragment) async {
    final (type, term) = fragment.typeAndTerm;
    if (term.trim().isEmpty) return const [];
    final query = type == null ? term : '${type.name}:$term';
    final key = query.toLowerCase().trim();

    await _load();
    final cached = _remote[key];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < _remoteMaxAge) {
      return cached.$2;
    }
    return _pending[key] ??= _hitomi.tags
        .search(query)
        .then((results) {
          _remote.remove(key);
          if (_remote.length >= _maxRemoteEntries) {
            _remote.remove(_remote.keys.first);
          }
          _remote[key] = (DateTime.now(), results);
          _scheduleSave();
          return results;
        })
        .whenComplete(() {
          _pending.remove(key);
        });
  }

  /// 合并本地与网站的结果：长片段优先，同一片段内有作品数的在前（按作品数），其余按匹配程度。
  static List<TagCandidate> merge(
    List<TagCandidate> local,
    List<TagCandidate> remote, {
    int limit = 40,
  }) {
    final byKey = <String, TagCandidate>{};
    for (final candidate in [...remote, ...local]) {
      final existing = byKey[candidate.key];
      if (existing == null) {
        byKey[candidate.key] = candidate;
      } else if (candidate.fragmentLength > existing.fragmentLength) {
        candidate
          ..count ??= existing.count
          ..info ??= existing.info;
        byKey[candidate.key] = candidate;
      } else {
        existing
          ..count ??= candidate.count
          ..info ??= candidate.info;
      }
    }
    final order = {
      for (final (i, c) in [...remote, ...local].indexed) c.key: i,
    };
    final merged = byKey.values.toList()
      ..sort((a, b) {
        if (a.fragmentLength != b.fragmentLength) {
          return b.fragmentLength.compareTo(a.fragmentLength);
        }
        final aCounted = a.count != null, bCounted = b.count != null;
        if (aCounted != bCounted) return aCounted ? -1 : 1;
        if (aCounted && a.count != b.count) return b.count!.compareTo(a.count!);
        return order[a.key]!.compareTo(order[b.key]!);
      });
    return merged.take(limit).toList();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      if (!await _cacheFile.exists()) return;
      final json =
          jsonDecode(await _cacheFile.readAsString()) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in json.entries) {
        final entry = value as Map<String, dynamic>;
        final time = DateTime.tryParse(entry['t'] as String? ?? '');
        if (time == null || DateTime.now().difference(time) > _remoteMaxAge) {
          continue;
        }
        _remote[key] = (
          time,
          [
            for (final item in entry['r'] as List)
              if (TagType.tryParse((item as List)[0] as String)
                  case final type?)
                TagSuggestion(Tag(type, item[1] as String), item[2] as int),
          ],
        );
      }
    } catch (error) {
      debugPrint('读取标签联想缓存失败: $error');
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      try {
        await _cacheFile.parent.create(recursive: true);
        final temp = File('${_cacheFile.path}.tmp');
        await temp.writeAsString(
          jsonEncode({
            for (final MapEntry(:key, value: (time, results))
                in _remote.entries)
              key: {
                't': time.toIso8601String(),
                'r': [
                  for (final s in results)
                    [s.tag.type.name, s.tag.name, s.count],
                ],
              },
          }),
        );
        await temp.rename(_cacheFile.path);
      } catch (error) {
        debugPrint('保存标签联想缓存失败: $error');
      }
    });
  }
}
