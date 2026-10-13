import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../navigation.dart';
import '../services/app_services.dart';
import '../services/tag_labels.dart';
import '../utils/labels.dart';
import '../widgets/common.dart';

/// 按类型与首字母浏览全部标签（对应网站的 alltags-a.html 等页面）。
class TagBrowserPage extends StatefulWidget {
  const TagBrowserPage({super.key});

  @override
  State<TagBrowserPage> createState() => _TagBrowserPageState();
}

class _TagBrowserPageState extends State<TagBrowserPage> {
  static const _types = [
    TagType.female,
    TagType.male,
    TagType.tag,
    TagType.artist,
    TagType.group,
    TagType.series,
    TagType.character,
  ];

  /// 页面之间共享的缓存，避免重复下载较大的标签列表页。
  static final Map<String, Future<List<Tag>>> _cache = {};

  TagType _type = TagType.female;
  String _initial = 'a';
  String _filter = '';

  Future<List<Tag>> _load({bool refresh = false}) {
    final key = '${_type.name}-$_initial';
    if (refresh) _cache.remove(key);
    return _cache[key] ??= services.hitomi.tags.list(_type, _initial)
      ..catchError((Object _) {
        _cache.remove(key);
        return <Tag>[];
      });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('标签目录'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(104),
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  children: [
                    for (final type in _types) ...[
                      ChoiceChip(
                        label: Text(tagTypeLabel(type)),
                        selected: type == _type,
                        onSelected: (_) => setState(() => _type = type),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  children: [
                    for (final initial in nameInitials) ...[
                      ChoiceChip(
                        label: Text(
                          initial == '123' ? '#' : initial.toUpperCase(),
                        ),
                        selected: initial == _initial,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _initial = initial),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.filter_list),
                hintText: '过滤（支持中文）',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _filter = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Tag>>(
              key: ValueKey('${_type.name}-$_initial'),
              future: _load(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return ErrorView(
                    error: snapshot.error!,
                    onRetry: () => setState(() => _load(refresh: true)),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final labels = TagLabelScope.of(context);
                final tags = snapshot.data!
                    .where(
                      (tag) =>
                          _filter.isEmpty ||
                          tag.name.contains(_filter) ||
                          (labels.info(tag)?.name.contains(_filter) ?? false),
                    )
                    .toList();
                if (tags.isEmpty) return const EmptyView(message: '没有标签');
                return ListView.builder(
                  itemCount: tags.length,
                  itemBuilder: (context, index) {
                    final tag = tags[index];
                    final chinese = labels.chinese(tag);
                    return ListTile(
                      dense: true,
                      title: Text(chinese ?? tag.name),
                      subtitle: chinese == null ? null : Text(tag.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openSearch(context, '$tag'),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
