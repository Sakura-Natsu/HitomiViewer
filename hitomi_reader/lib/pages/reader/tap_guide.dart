import 'package:flutter/material.dart';

import '../../services/settings.dart';
import 'zoom.dart';

/// 点击区域说明：左右三分之一翻页，中间打开菜单。点击任意处关闭。
class ReaderTapGuide extends StatelessWidget {
  const ReaderTapGuide({
    super.key,
    required this.mode,
    required this.tapToTurn,
    required this.onDismiss,
  });

  final ReaderMode mode;
  final bool tapToTurn;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (left, right) = switch (mode) {
      ReaderMode.leftToRight => ('上一页', '下一页'),
      ReaderMode.rightToLeft => ('下一页', '上一页'),
      ReaderMode.vertical => ('向上翻一屏', '向下翻一屏'),
    };
    Widget zone(String label, IconData icon, Color color) => Expanded(
      child: Container(
        color: color,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 32),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
          ],
        ),
      ),
    );
    return GestureDetector(
      key: const ValueKey('reader-tap-guide'),
      behavior: HitTestBehavior.opaque,
      onTap: onDismiss,
      child: Stack(
        children: [
          Positioned.fill(
            child: tapToTurn
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      zone(left, Icons.touch_app, const Color(0xB31565C0)),
                      zone('显示菜单', Icons.menu, const Color(0xB3424242)),
                      zone(right, Icons.touch_app, const Color(0xB32E7D32)),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      zone(
                        '点击任意位置显示菜单\n（点击翻页已关闭）',
                        Icons.menu,
                        const Color(0xB3424242),
                      ),
                    ],
                  ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24 + MediaQuery.paddingOf(context).bottom,
            child: Text(
              [
                switch ((mode == ReaderMode.vertical, isDesktop)) {
                  (false, false) => '双击或双指缩放',
                  (false, true) => '滚轮翻页，双击或 Ctrl + 滚轮缩放',
                  (true, false) => '双击或双指缩放，放大后仍可上下滑动',
                  (true, true) => 'Ctrl + 滚轮调整图片宽度',
                },
                '点击任意处关闭说明',
              ].join(' · '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}
