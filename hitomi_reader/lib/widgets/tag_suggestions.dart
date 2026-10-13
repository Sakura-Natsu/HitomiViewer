import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/app_services.dart';
import '../services/tag_suggester.dart';
import '../utils/labels.dart';

/// 标签联想：防抖后在后台查询本地中文标签库与网站联想接口，丢弃过期结果。
///
/// 搜索页、收藏筛选、屏蔽标签都用它，联想结果保持一致。
class TagSuggestionController extends ChangeNotifier {
  Timer? _timer;

  /// 每次开始或取消联想时递增，用于丢弃过期结果。
  int _generation = 0;
  bool _disposed = false;

  String _query = '';
  List<TagCandidate> _local = const [];
  List<TagCandidate> _remote = const [];
  bool _loading = false;

  /// 当前结果对应的光标前文字，没有联想时为空。
  String get query => _query;

  /// 网站联想接口还在查询中。
  bool get loading => _loading;

  List<TagCandidate> get candidates => TagSuggester.merge(_local, _remote);

  /// 为光标前的文字查询联想。相同文字不重复查询；新结果出来前保留旧列表，避免闪烁。
  void update(String textBeforeCursor) {
    if (textBeforeCursor == _query) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 150), () async {
      final generation = ++_generation;
      bool cancelled() => _disposed || generation != _generation;

      final suggester = services.tagSuggester;
      _query = textBeforeCursor;
      _loading = true;
      notifyListeners();
      final remote = suggester.remote(textBeforeCursor);
      final local = await suggester.local(
        textBeforeCursor,
        isCancelled: cancelled,
      );
      if (cancelled()) return;
      _local = local;
      _remote = const [];
      notifyListeners();
      final remoteResults = await remote;
      if (cancelled()) return;
      _remote = remoteResults;
      _loading = false;
      notifyListeners();
    });
  }

  /// 取消进行中的联想并清空结果。
  void clear() {
    _timer?.cancel();
    _generation++;
    final changed =
        _query.isNotEmpty ||
        _local.isNotEmpty ||
        _remote.isNotEmpty ||
        _loading;
    _query = '';
    _local = const [];
    _remote = const [];
    _loading = false;
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// 中文标签库还不可用时的提示，可用时返回 null。
String? tagTranslationHint() {
  final translations = services.translations;
  if (!services.settings.tagTranslation || translations.isLoaded) return null;
  if (translations.isUpdating) return '中文标签库下载中，完成后可以用中文搜索标签…';
  return '中文标签库尚未下载，可在 设置 → 标签翻译 中更新，之后可以用中文搜索标签。';
}

/// 联想结果中的一项：类型、中文名（附英文名）、作品数和状态。
class TagCandidateTile extends StatelessWidget {
  const TagCandidateTile({
    super.key,
    required this.candidate,
    required this.onTap,
    this.status,
    this.trailing,
  });

  final TagCandidate candidate;
  final VoidCallback onTap;

  /// 附加在副标题后的状态，如“已添加”“已屏蔽”。
  final String? status;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tag = candidate.tag;
    final color = tagTypeColor(tag.type);
    final chinese = tag.type == TagType.language
        ? languageLabel(tag.name)
        : candidate.info?.name;
    return ListTile(
      dense: true,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: color.withValues(alpha: 0.15),
        child: Text(
          tagTypeLabel(tag.type).substring(0, 1),
          style: TextStyle(color: color, fontSize: 13),
        ),
      ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: chinese ?? tag.name),
            if (chinese != null && chinese != tag.name)
              TextSpan(
                text: '  ${tag.name}',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          tagTypeLabel(tag.type),
          if (candidate.count != null) '${formatCount(candidate.count!)} 个作品',
          ?status,
        ].join(' · '),
      ),
      onTap: onTap,
      trailing: trailing,
    );
  }
}
