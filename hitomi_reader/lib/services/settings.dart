import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'http_client.dart';

enum ReaderMode {
  leftToRight('从左到右', '左→右'),
  rightToLeft('从右到左（日漫）', '右→左'),
  vertical('竖向滚动', '竖向');

  const ReaderMode(this.label, this.shortLabel);

  final String label;
  final String shortLabel;
}

/// 翻页模式下一屏显示几页。
enum PageLayout {
  single('单页'),
  double('双页'),
  auto('自动');

  const PageLayout(this.label);

  final String label;
}

/// 阅读时的屏幕方向（仅移动端）。
enum ReaderOrientation {
  auto('跟随系统'),
  portrait('竖屏'),
  landscape('横屏');

  const ReaderOrientation(this.label);

  final String label;
}

enum ListStyle { list, grid }

/// 应用设置，持久化在 SharedPreferences 中。
class AppSettings extends ChangeNotifier {
  AppSettings(this._prefs);

  final SharedPreferences _prefs;

  T _enum<T extends Enum>(String key, List<T> values, T fallback) {
    final name = _prefs.getString(key);
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  Future<void> _set(String key, Object value) async {
    switch (value) {
      case String s:
        await _prefs.setString(key, s);
      case int i:
        await _prefs.setInt(key, i);
      case bool b:
        await _prefs.setBool(key, b);
      case List<String> list:
        await _prefs.setStringList(key, list);
      case Enum e:
        await _prefs.setString(key, e.name);
    }
    notifyListeners();
  }

  /// 是否已确认年满 18 岁。
  bool get ageConfirmed => _prefs.getBool('ageConfirmed') ?? false;
  set ageConfirmed(bool value) => _set('ageConfirmed', value);

  /// 默认语言，`all` 表示不限。
  String get language => _prefs.getString('language') ?? 'all';
  set language(String value) => _set('language', value);

  SortType get defaultSort =>
      _enum('defaultSort', SortType.values, SortType.dateAdded);
  set defaultSort(SortType value) => _set('defaultSort', value);

  ListStyle get listStyle =>
      _enum('listStyle', ListStyle.values, ListStyle.list);
  set listStyle(ListStyle value) => _set('listStyle', value);

  ThemeMode get themeMode =>
      _enum('themeMode', ThemeMode.values, ThemeMode.system);
  set themeMode(ThemeMode value) => _set('themeMode', value);

  ReaderMode get readerMode =>
      _enum('readerMode', ReaderMode.values, ReaderMode.leftToRight);
  set readerMode(ReaderMode value) => _set('readerMode', value);

  /// 阅读时向后预加载的页数。
  int get preloadPages => _prefs.getInt('preloadPages') ?? 3;
  set preloadPages(int value) => _set('preloadPages', value);

  /// 点击屏幕左右两侧翻页。
  bool get tapToTurn => _prefs.getBool('tapToTurn') ?? true;
  set tapToTurn(bool value) => _set('tapToTurn', value);

  /// 翻页模式下单页 / 双页显示，自动表示横屏时双页。
  PageLayout get pageLayout =>
      _enum('pageLayout', PageLayout.values, PageLayout.auto);
  set pageLayout(PageLayout value) => _set('pageLayout', value);

  /// 双页时封面单独显示，使后面的跨页对齐。
  bool get coverAlone => _prefs.getBool('coverAlone') ?? true;
  set coverAlone(bool value) => _set('coverAlone', value);

  /// 点击、按键翻页时是否有滑动动画。
  bool get pageAnimation => _prefs.getBool('pageAnimation') ?? true;
  set pageAnimation(bool value) => _set('pageAnimation', value);

  /// 音量键翻页（Android）。
  bool get volumeKeys => _prefs.getBool('volumeKeys') ?? false;
  set volumeKeys(bool value) => _set('volumeKeys', value);

  /// 反转音量键：音量加 = 下一页。
  bool get volumeKeysInverted => _prefs.getBool('volumeKeysInverted') ?? false;
  set volumeKeysInverted(bool value) => _set('volumeKeysInverted', value);

  /// 自动翻页间隔（秒）。
  int get autoTurnSeconds => _prefs.getInt('autoTurnSeconds') ?? 5;
  set autoTurnSeconds(int value) => _set('autoTurnSeconds', value);

  /// 阅读时屏幕常亮。
  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? true;
  set keepScreenOn(bool value) => _set('keepScreenOn', value);

  /// 阅读时叠加的黑色遮罩（0–80，百分比），用于比系统最低亮度更暗。
  int get readerDim => _prefs.getInt('readerDim') ?? 0;
  set readerDim(int value) => _set('readerDim', value);

  /// 阅读时角落显示页码、时间和电量。
  bool get readerInfo => _prefs.getBool('readerInfo') ?? true;
  set readerInfo(bool value) => _set('readerInfo', value);

  ReaderOrientation get readerOrientation => _enum(
    'readerOrientation',
    ReaderOrientation.values,
    ReaderOrientation.auto,
  );
  set readerOrientation(ReaderOrientation value) =>
      _set('readerOrientation', value);

  /// 竖向模式下图片的最大宽度（逻辑像素），桌面端可用 Ctrl + 滚轮调整。
  int get verticalWidth => _prefs.getInt('verticalWidth') ?? 960;
  set verticalWidth(int value) => _set('verticalWidth', value);

  /// 自动裁掉页面四周的白边（或黑边）。
  bool get cropBorders => _prefs.getBool('cropBorders') ?? false;
  set cropBorders(bool value) => _set('cropBorders', value);

  /// 是否已显示过点击区域说明。
  bool get readerGuideShown => _prefs.getBool('readerGuideShown') ?? false;
  set readerGuideShown(bool value) => _set('readerGuideShown', value);

  /// 屏蔽的标签，格式与搜索语法一致，如 `male:yaoi`。
  List<String> get blockedTags =>
      _prefs.getStringList('blockedTags') ?? const [];
  set blockedTags(List<String> value) => _set('blockedTags', value);

  ProxyConfig get proxy => ProxyConfig(
    mode: _enum('proxyMode', ProxyMode.values, ProxyMode.system),
    host: _prefs.getString('proxyHost') ?? '127.0.0.1',
    port: _prefs.getInt('proxyPort') ?? 7890,
  );

  Future<void> setProxy(ProxyConfig value) async {
    await _prefs.setString('proxyMode', value.mode.name);
    await _prefs.setString('proxyHost', value.host);
    await _prefs.setInt('proxyPort', value.port);
    notifyListeners();
  }

  /// 图片磁盘缓存上限（MB）。
  int get cacheLimitMb => _prefs.getInt('cacheLimitMb') ?? 1024;
  set cacheLimitMb(int value) => _set('cacheLimitMb', value);

  /// 最近的搜索记录，最新的在前。
  List<String> get searchHistory =>
      _prefs.getStringList('searchHistory') ?? const [];

  void addSearchHistory(String query) {
    query = query.trim();
    if (query.isEmpty) return;
    final history = [query, ...searchHistory.where((q) => q != query)];
    _set('searchHistory', history.take(30).toList());
  }

  void clearSearchHistory() => _set('searchHistory', <String>[]);

  void removeSearchHistory(String query) =>
      _set('searchHistory', searchHistory.where((q) => q != query).toList());

  /// 是否用中文显示标签（需要中文标签库）。
  bool get tagTranslation => _prefs.getBool('tagTranslation') ?? true;
  set tagTranslation(bool value) => _set('tagTranslation', value);

  /// 最近在搜索中使用过的标签（`type:name` 形式），最新的在前。
  List<String> get recentTags => _prefs.getStringList('recentTags') ?? const [];

  void addRecentTags(Iterable<Tag> tags) {
    final added = [for (final tag in tags) '${tag.negate(false)}'];
    if (added.isEmpty) return;
    final recent = [...added, ...recentTags.where((t) => !added.contains(t))];
    _set('recentTags', recent.take(40).toList());
  }

  void clearRecentTags() => _set('recentTags', <String>[]);

  /// 保存的搜索（快速搜索）。
  List<SavedSearch> get savedSearches => [
    for (final raw in _prefs.getStringList('savedSearches') ?? const <String>[])
      ?SavedSearch.tryParse(raw),
  ];

  set savedSearches(List<SavedSearch> value) =>
      _set('savedSearches', [for (final s in value) s.encode()]);

  bool isSavedSearch(String query) =>
      savedSearches.any((saved) => saved.query == query);

  void saveSearch(SavedSearch search) => savedSearches = [
    search,
    ...savedSearches.where((s) => s.query != search.query),
  ];

  void removeSavedSearch(String query) =>
      savedSearches = savedSearches.where((s) => s.query != query).toList();
}

/// 保存的搜索：名称 + 搜索语句（可被 TagManager.parseQuery 还原）。
class SavedSearch {
  const SavedSearch(this.name, this.query);

  static SavedSearch? tryParse(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return SavedSearch(json['name'] as String, json['query'] as String);
    } catch (_) {
      return null;
    }
  }

  final String name;
  final String query;

  String encode() => jsonEncode({'name': name, 'query': query});
}
