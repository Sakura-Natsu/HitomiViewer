import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/tag_labels.dart';

const Map<String, String> _typeLabels = {
  'doujinshi': '同人志',
  'manga': '漫画',
  'artistcg': '画师 CG',
  'gamecg': '游戏 CG',
  'imageset': '图集',
  'anime': '动画',
};

String galleryTypeLabel(String type) => _typeLabels[type] ?? type;

/// 与网站配色接近的类型颜色。
Color galleryTypeColor(String type) => switch (type) {
  'doujinshi' => const Color(0xFFE57373),
  'manga' => const Color(0xFFBA68C8),
  'artistcg' => const Color(0xFF4FC3F7),
  'gamecg' => const Color(0xFF81C784),
  'imageset' => const Color(0xFF4DB6AC),
  'anime' => const Color(0xFFFFB74D),
  _ => const Color(0xFF90A4AE),
};

String tagTypeLabel(TagType type) => switch (type) {
  TagType.artist => '作者',
  TagType.group => '社团',
  TagType.type => '类型',
  TagType.language => '语言',
  TagType.series => '原作',
  TagType.character => '角色',
  TagType.male => '男性',
  TagType.female => '女性',
  TagType.tag => '标签',
};

Color tagTypeColor(TagType type) => switch (type) {
  TagType.artist => const Color(0xFFEF6C00),
  TagType.group => const Color(0xFF6D4C41),
  TagType.type => const Color(0xFF546E7A),
  TagType.language => const Color(0xFF00897B),
  TagType.series => const Color(0xFF7B1FA2),
  TagType.character => const Color(0xFF3949AB),
  TagType.male => const Color(0xFF1E88E5),
  TagType.female => const Color(0xFFD81B60),
  TagType.tag => const Color(0xFF757575),
};

const Map<String, String> _languageLabels = {
  'chinese': '中文',
  'japanese': '日语',
  'english': '英语',
  'korean': '韩语',
  'spanish': '西班牙语',
  'french': '法语',
  'german': '德语',
  'russian': '俄语',
  'portuguese': '葡萄牙语',
  'italian': '意大利语',
  'thai': '泰语',
  'vietnamese': '越南语',
  'indonesian': '印尼语',
  'polish': '波兰语',
  'turkish': '土耳其语',
  'arabic': '阿拉伯语',
  'textless narrative': '无文字',
};

/// 标签的显示名：语言用中文名，其余开启翻译时用中文标签库，否则用英文原名。
///
/// 会让调用的组件依赖 [TagLabelScope]，标签库更新后自动重建。
String tagName(BuildContext context, Tag tag) {
  if (tag.type == TagType.language) return languageLabel(tag.name);
  return TagLabelScope.of(context).chinese(tag) ?? tag.name;
}

/// 带类型的完整显示名，如「女性：巨乳」。
String tagFullName(BuildContext context, Tag tag) =>
    '${tagTypeLabel(tag.type)}：${tagName(context, tag)}';

String languageLabel(String name) =>
    _languageLabels[name] ?? Language.byName(name)?.localName ?? name;

/// 设置页与筛选器中常用语言排在前面。
List<String> get languageOptions => [
  'all',
  'chinese',
  'japanese',
  'english',
  'korean',
  for (final language in Language.ordered)
    if (!const {
      'chinese',
      'japanese',
      'english',
      'korean',
    }.contains(language.name))
      language.name,
];

String languageOptionLabel(String name) =>
    name == 'all' ? '全部语言' : languageLabel(name);

String sortLabel(SortType sort) => switch (sort) {
  SortType.dateAdded => '最新上传',
  SortType.datePublished => '发布日期',
  SortType.popularityDay => '今日热门',
  SortType.popularityWeek => '本周热门',
  SortType.popularityMonth => '本月热门',
  SortType.popularityYear => '年度热门',
  SortType.random => '随机',
};

String formatDate(DateTime? date) {
  if (date == null) return '-';
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

String formatDateTime(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${formatDate(local)} ${two(local.hour)}:${two(local.minute)}';
}

String formatCount(int value) {
  final text = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) buffer.write(',');
    buffer.write(text[i]);
  }
  return buffer.toString();
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 将异常转为用户可读的中文说明。
String describeError(Object error) {
  final text = '$error';
  if (error is HitomiException && error.statusCode == 404) return '内容不存在（404）';
  if (text.contains('SocketException') ||
      text.contains('Connection') ||
      text.contains('HandshakeException')) {
    return '网络连接失败，请检查网络或在设置中配置代理\n$text';
  }
  if (text.contains('TimeoutException')) return '请求超时，请检查网络或代理设置';
  return text;
}
