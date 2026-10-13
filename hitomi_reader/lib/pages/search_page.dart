import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../services/app_services.dart';
import '../services/settings.dart';
import '../services/tag_suggester.dart';
import '../utils/labels.dart';
import '../widgets/tag_suggestions.dart';
import 'gallery_detail_page.dart';

/// 从粘贴的链接或纯数字中识别画廊 ID。
int? galleryIdFromText(String text) {
  text = text.trim();
  final url = RegExp(r'hitomi\.la/\S*?[-/](\d{3,9})\.html').firstMatch(text);
  if (url != null) return int.parse(url.group(1)!);
  final id = RegExp(r'^#?(\d{4,9})$').firstMatch(text);
  return id == null ? null : int.parse(id.group(1)!);
}

/// 搜索条件的简短描述，用于搜索框、历史与保存的搜索。
String describeQuery(BuildContext context, SearchQuery query) => [
  if (query.title != null) '「${query.title}」',
  for (final tag in query.tags)
    '${tag.isNegative ? '-' : ''}${tagName(context, tag)}',
].join(' ');

/// 搜索的范围：网站上的全部画廊，或本地的收藏。
enum SearchScope { online, favorites }

/// 搜索条件编辑页，返回 [SearchQuery]。
///
/// - 输入框里的文字就是标题条件，回车即可按标题搜索；
/// - 联想只针对光标前正在输入的片段，选中后这一段变成标签条件，其余文字保留；
/// - 本地中文标签库即时联想（支持中文），网站联想稍后补充作品数；
/// - 输入停顿时会提前查询标题索引，回车后几乎立即出结果；
/// - 仍兼容 `female:xxx -male:yyy` 这样的高级语法。
///
/// [scope] 为 [SearchScope.favorites] 时用于筛选收藏：交互完全相同，只是不查询网站的
/// 标题索引，也不写入搜索历史。
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.initial = const SearchQuery(),
    this.scope = SearchScope.online,
  });

  final SearchQuery initial;
  final SearchScope scope;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final List<Tag> _tags = [...widget.initial.tags];
  late final TextEditingController _input = TextEditingController(
    text: widget.initial.title == null ? '' : '${widget.initial.title} ',
  );
  final FocusNode _focus = FocusNode();

  /// 一次输入超过这么多字视为粘贴（粘贴的通常是标题，不弹出标签联想）。
  static const int _maxTypedChars = 12;

  Timer? _prefetchTimer;

  /// 是否处于“输入标签名”状态：只有在文字末尾打字时才进入。
  /// 粘贴、在中间编辑都会退出；删字不改变状态（便于修正打错的标签名）。
  bool _suggesting = false;
  String _lastText = '';

  final TagSuggestionController _suggestions = TagSuggestionController();

  bool get _online => widget.scope == SearchScope.online;

  @override
  void initState() {
    super.initState();
    _lastText = _input.text;
    _input.addListener(_onChanged);
    _suggestions.addListener(_onSuggestions);
    if (_online) services.hitomi.galleries.warmUpTitleIndex();
  }

  @override
  void dispose() {
    _prefetchTimer?.cancel();
    _suggestions.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSuggestions() {
    if (mounted) setState(() {});
  }

  String get _text => _input.text.trim();

  int get _cursor {
    final offset = _input.selection.baseOffset;
    return offset < 0 || offset > _input.text.length
        ? _input.text.length
        : offset;
  }

  /// 光标前的文字，联想只针对这部分末尾的片段。
  String get _textBeforeCursor => _input.text.substring(0, _cursor);

  /// 输入框变化（文字或光标）。这里的一切更新都必须是静默的：
  /// 不能改变输入框所在的组件结构，否则输入框会被重建、丢失焦点（手机上输入法会收起）。
  void _onChanged() {
    final text = _input.text;
    final cursorAtEnd = text.substring(_cursor).trim().isEmpty;

    if (text.trim().isEmpty || !cursorAtEnd) {
      _suggesting = false;
    } else if (text != _lastText) {
      // 与上次相比，从第一个不同的字符起删掉了多少、新增了多少
      var common = 0;
      final shortest = text.length < _lastText.length
          ? text.length
          : _lastText.length;
      while (common < shortest &&
          text.codeUnitAt(common) == _lastText.codeUnitAt(common)) {
        common++;
      }
      final added = text.length - common;
      if (added > _maxTypedChars) {
        _suggesting = false; // 粘贴
      } else if (added > 0) {
        _suggesting = true; // 在末尾打字（包括输入法上屏）
      }
    }
    _lastText = text;

    if (_suggesting) {
      _scheduleSuggestions();
    } else {
      _suggestions.clear();
    }

    // 输入停顿时提前查询标题，回车后直接命中缓存（后台进行）。
    _prefetchTimer?.cancel();
    if (_online) {
      _prefetchTimer = Timer(const Duration(milliseconds: 800), () {
        final title = services.hitomi.tags.parseQuery(_input.text).title;
        if (title != null && galleryIdFromText(_input.text) == null) {
          services.hitomi.galleries.prefetchTitle(title);
        }
      });
    }

    setState(() {}); // 刷新标题行、清除按钮、底部按钮
  }

  /// 在后台查询联想（防抖、可取消），结果出来前保留旧的列表。
  void _scheduleSuggestions() {
    // 输入法组字中（如拼音还没上屏）先不查询
    final composing = _input.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    _suggestions.update(_textBeforeCursor);
  }

  int _indexOfTag(Tag tag) =>
      _tags.indexWhere((t) => t.type == tag.type && t.name == tag.name);

  void _addTag(Tag tag) {
    final index = _indexOfTag(tag);
    setState(() {
      if (index == -1) {
        _tags.add(tag);
      } else {
        _tags[index] = tag;
      }
    });
  }

  /// 选中联想：光标前的片段变成标签条件，其余文字（标题）保留。
  void _applyCandidate(TagCandidate candidate, {bool? negative}) {
    _addTag(candidate.tag.negate(negative ?? candidate.tag.isNegative));
    final text = _input.text;
    final prefix = text.substring(0, candidate.replaceFrom).trimRight();
    final suffix = text.substring(_cursor).trimLeft();
    final head = prefix.isEmpty ? '' : '$prefix ';
    _input.value = TextEditingValue(
      text: '$head$suffix',
      selection: TextSelection.collapsed(offset: head.length),
    );
    // 这一段已经变成标签，剩下的是标题，等用户再打字时才重新联想
    setState(() => _suggesting = false);
    _suggestions.clear();
    _focus.requestFocus();
  }

  void _insertPrefix(String prefix) {
    final text = _input.text;
    final head = text.isEmpty || text.endsWith(' ') ? text : '$text ';
    _input.value = TextEditingValue(
      text: '$head$prefix',
      selection: TextSelection.collapsed(offset: head.length + prefix.length),
    );
    _focus.requestFocus();
  }

  /// 汇总已选标签与输入框内容（输入框中的 `type:name` 也会识别为标签）。
  SearchQuery _buildQuery() {
    final parsed = services.hitomi.tags.parseQuery(_input.text);
    final tags = [..._tags];
    for (final tag in parsed.tags) {
      tags.removeWhere((t) => t.type == tag.type && t.name == tag.name);
      tags.add(tag);
    }
    return SearchQuery(tags: tags, title: parsed.title);
  }

  void _submit([SearchQuery? query]) {
    query ??= _buildQuery();
    final settings = services.settings;
    if (_online) settings.addSearchHistory('$query');
    settings.addRecentTags(query.tags);
    Navigator.pop(context, query);
  }

  void _openGallery(int id) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => GalleryDetailPage(id: id)),
    );
  }

  void _loadIntoEditor(SearchQuery query) {
    setState(() {
      _tags
        ..clear()
        ..addAll(query.tags);
    });
    final text = query.title == null ? '' : '${query.title} ';
    _input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final query = _buildQuery();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _input,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: !_online
                ? '在收藏中搜索标题或标签'
                : _tags.isEmpty
                ? '输入标题，或输入标签名（支持中文）'
                : '继续添加标签，或输入标题',
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          if (_input.text.isNotEmpty)
            IconButton(
              tooltip: '清除输入',
              icon: const Icon(Icons.clear),
              onPressed: _input.clear,
            ),
        ],
        // bottom 必须始终存在：AppBar 有无 bottom 时内部结构不同，
        // 切换会让标题里的输入框被重建而丢失焦点。
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: SizedBox(
            height: 2,
            child: _suggestions.loading
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
        ),
      ),
      body: Column(
        children: [
          if (_tags.isNotEmpty) _conditions(),
          Expanded(child: _text.isEmpty ? _idleView() : _typingView()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.search),
            label: Text(
              query.isEmpty
                  ? (_online ? '浏览全部' : '显示全部收藏')
                  : '${_online ? '搜索' : '筛选收藏'}（${[if (query.tags.isNotEmpty) '${query.tags.length} 个标签', if (query.title != null) '标题'].join(' + ')}）',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
      ),
    );
  }

  /// 已选的标签条件：点按切换包含/排除，× 删除。
  Widget _conditions() {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _tags)
                    ConditionChip(
                      tag: tag,
                      onToggle: () => setState(
                        () => _tags[_indexOfTag(tag)] = tag.negate(),
                      ),
                      onDelete: () =>
                          setState(() => _tags.removeAt(_indexOfTag(tag))),
                    ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(_tags.clear),
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
  }

  /// 正在输入：按标题搜索 + 标签联想。
  Widget _typingView() {
    final theme = Theme.of(context);
    final galleryId = galleryIdFromText(_input.text);
    final parsed = services.hitomi.tags.parseQuery(_input.text);
    final candidates = _suggestions.candidates;
    final translationHint = tagTranslationHint();
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (galleryId != null)
          ListTile(
            leading: Icon(Icons.open_in_new, color: theme.colorScheme.primary),
            title: Text('打开画廊 #$galleryId'),
            subtitle: const Text('识别到画廊链接或 ID'),
            onTap: () => _openGallery(galleryId),
          ),
        if (parsed.title != null || parsed.tags.isNotEmpty)
          ListTile(
            leading: Icon(Icons.title, color: theme.colorScheme.primary),
            title: Text(
              parsed.title != null
                  ? '${_online ? '' : '在收藏中'}搜索标题「${parsed.title}」'
                  : '按输入的标签语法搜索',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _tags.isEmpty && parsed.tags.isEmpty
                  ? '回车或点此搜索；继续输入标签名可叠加标签筛选'
                  : '同时满足 ${_tags.length + parsed.tags.length} 个标签条件',
            ),
            onTap: _submit,
          ),
        const Divider(height: 1),
        if (!_suggesting)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '想按标签筛选？在末尾接着输入标签名（中英文均可），会出现联想。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          )
        else if (candidates.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '添加标签筛选（点按添加，右侧 − 为排除）',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          for (final candidate in candidates) _candidateTile(candidate),
        ] else if (!_suggestions.loading && _suggestions.query.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '没有匹配的标签',
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
        if (translationHint != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              translationHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }

  Widget _candidateTile(TagCandidate candidate) {
    final tag = candidate.tag;
    final index = _indexOfTag(tag);
    final selected = index == -1 ? null : _tags[index];
    return TagCandidateTile(
      key: ValueKey('candidate:${tag.negate(false)}'),
      candidate: candidate,
      status: selected == null ? null : (selected.isNegative ? '已排除' : '已添加'),
      onTap: () => _applyCandidate(candidate),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '包含',
            icon: Icon(
              selected != null && !selected.isNegative
                  ? Icons.add_circle
                  : Icons.add_circle_outline,
            ),
            onPressed: () => _applyCandidate(candidate, negative: false),
          ),
          IconButton(
            tooltip: '排除',
            icon: Icon(
              selected != null && selected.isNegative
                  ? Icons.remove_circle
                  : Icons.remove_circle_outline,
            ),
            onPressed: () => _applyCandidate(candidate, negative: true),
          ),
        ],
      ),
    );
  }

  Widget _idleView() {
    final theme = Theme.of(context);
    final settings = services.settings;
    // 快速搜索和搜索历史是网站搜索的，筛选收藏时不显示
    final saved = _online ? settings.savedSearches : const <SavedSearch>[];
    final recentTags = [
      for (final raw in settings.recentTags) ...services.hitomi.tags.parse(raw),
    ].where((tag) => _indexOfTag(tag) == -1).toList();
    final history = _online ? settings.searchHistory : const <String>[];
    const types = [
      TagType.female, TagType.male, TagType.tag, TagType.artist, //
      TagType.group, TagType.series, TagType.character, TagType.language,
      TagType.type,
    ];
    final titleStyle = theme.textTheme.titleSmall;
    final translationHint = tagTranslationHint();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _online
              ? '直接输入或粘贴标题即可搜索；输入标签名（中英文均可）后从联想中点选，'
                    '可叠加多个标签；粘贴画廊链接可直接打开。'
              : '输入标题中的文字即可在收藏中查找；输入标签名（中英文均可）后从联想中点选，'
                    '可叠加多个标签，点按已选的标签可切换包含 / 排除。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (translationHint != null) ...[
          const SizedBox(height: 8),
          Text(
            translationHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
        if (saved.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('快速搜索', style: titleStyle),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final search in saved)
                InputChip(
                  avatar: const Icon(Icons.bookmark, size: 18),
                  label: Text(search.name),
                  tooltip: search.query,
                  onPressed: () =>
                      _submit(services.hitomi.tags.parseQuery(search.query)),
                  onDeleted: () =>
                      setState(() => settings.removeSavedSearch(search.query)),
                ),
            ],
          ),
        ],
        if (recentTags.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('最近使用的标签', style: titleStyle)),
              TextButton(
                onPressed: () => setState(settings.clearRecentTags),
                child: const Text('清除'),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in recentTags.take(24))
                ActionChip(
                  avatar: Icon(
                    Icons.add,
                    size: 16,
                    color: tagTypeColor(tag.type),
                  ),
                  label: Text(tagFullName(context, tag)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _addTag(tag),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text('只在某一类标签中查找', style: titleStyle),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in types)
              ActionChip(
                label: Text(tagTypeLabel(type)),
                onPressed: () => _insertPrefix('${type.name}:'),
              ),
          ],
        ),
        if (history.isNotEmpty) ...[
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: Text('搜索历史', style: titleStyle)),
              TextButton(
                onPressed: () => setState(settings.clearSearchHistory),
                child: const Text('清除'),
              ),
            ],
          ),
          for (final raw in history) _historyTile(raw),
        ],
      ],
    );
  }

  Widget _historyTile(String raw) {
    final query = services.hitomi.tags.parseQuery(raw);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.history),
      title: Text(
        query.isEmpty ? '浏览全部' : describeQuery(context, query),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: '编辑',
            onPressed: () => _loadIntoEditor(query),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: '删除',
            onPressed: () =>
                setState(() => services.settings.removeSearchHistory(raw)),
          ),
        ],
      ),
      onTap: () => _submit(query),
    );
  }
}

/// 已选标签条件：显示类型与（中文）名称，点按切换包含/排除，× 删除。
class ConditionChip extends StatelessWidget {
  const ConditionChip({
    super.key,
    required this.tag,
    required this.onToggle,
    required this.onDelete,
    this.dense = false,
  });

  final Tag tag;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = tag.isNegative
        ? theme.colorScheme.error
        : tagTypeColor(tag.type);
    return InputChip(
      tooltip: '${tag.isNegative ? '已排除，点按改为包含' : '点按改为排除'}（$tag）',
      avatar: Icon(
        tag.isNegative ? Icons.remove_circle : Icons.add_circle,
        size: 18,
        color: color,
      ),
      label: Text(
        tagFullName(context, tag),
        style: TextStyle(
          decoration: tag.isNegative ? TextDecoration.lineThrough : null,
        ),
      ),
      visualDensity: dense ? VisualDensity.compact : null,
      side: BorderSide(color: color.withValues(alpha: 0.6)),
      backgroundColor: color.withValues(alpha: 0.08),
      onPressed: onToggle,
      onDeleted: onDelete,
    );
  }
}

/// 根据搜索条件生成保存搜索时的默认名称。
SavedSearch savedSearchFor(BuildContext context, SearchQuery query) =>
    SavedSearch(describeQuery(context, query), '$query');
