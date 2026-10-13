import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hitomi_api/hitomi_api.dart';

import '../../services/image_loader.dart';
import '../../widgets/hitomi_image.dart';

/// 阅读器内的缩略图跳页，返回选中的页码（从 0 开始）。
Future<int?> showThumbnailSheet(
  BuildContext context, {
  required List<GalleryImage> files,
  required int current,
  required String? Function(int index) localFile,
}) {
  final height = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SizedBox(
      height: height * 0.6,
      child: _ThumbnailGrid(
        files: files,
        current: current,
        localFile: localFile,
      ),
    ),
  );
}

class _ThumbnailGrid extends StatefulWidget {
  const _ThumbnailGrid({
    required this.files,
    required this.current,
    required this.localFile,
  });

  final List<GalleryImage> files;
  final int current;
  final String? Function(int index) localFile;

  @override
  State<_ThumbnailGrid> createState() => _ThumbnailGridState();
}

class _ThumbnailGridState extends State<_ThumbnailGrid> {
  static const double _padding = 12;
  static const double _spacing = 8;
  static const double _labelHeight = 20;

  ScrollController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - _padding * 2;
        final columns = max(3, (width / 110).floor());
        final tileWidth = (width - _spacing * (columns - 1)) / columns;
        final tileHeight = tileWidth / 0.7 + _labelHeight;
        // 打开时让当前页所在的行出现在可见区域的上部
        _controller ??= ScrollController(
          initialScrollOffset: max(
            0,
            (widget.current ~/ columns) * (tileHeight + _spacing) -
                constraints.maxHeight / 3,
          ),
        );
        final ratio = MediaQuery.devicePixelRatioOf(context);
        return GridView.builder(
          controller: _controller,
          padding: const EdgeInsets.fromLTRB(_padding, 0, _padding, _padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisExtent: tileHeight,
            crossAxisSpacing: _spacing,
            mainAxisSpacing: _spacing,
          ),
          itemCount: widget.files.length,
          itemBuilder: (context, index) {
            final selected = index == widget.current;
            final local = widget.localFile(index);
            return InkWell(
              key: ValueKey('thumbnail:$index'),
              borderRadius: BorderRadius.circular(6),
              onTap: () => Navigator.pop(context, index),
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: selected ? colors.primary : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        // 已下载的画廊用本地原图缩小解码，离线也能显示
                        child: HitomiImage(
                          image: widget.files[index],
                          kind: local == null
                              ? ImageKind.thumbnailSmall
                              : ImageKind.full,
                          localFile: local,
                          decodeWidth: local == null
                              ? null
                              : (tileWidth * ratio).round(),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: _labelHeight,
                    child: Center(
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          color: selected ? colors.primary : null,
                          fontWeight: selected ? FontWeight.bold : null,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
