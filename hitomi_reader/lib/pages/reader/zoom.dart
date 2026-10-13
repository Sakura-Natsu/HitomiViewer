import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 桌面端：滚轮翻页、Ctrl + 滚轮缩放；移动端使用双指缩放。
final bool isDesktop = switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.linux ||
  TargetPlatform.macOS => true,
  _ => false,
};

/// 双击时在原始大小与 [scale] 倍之间切换的动画。
mixin _DoubleTapZoom<T extends StatefulWidget>
    on State<T>, SingleTickerProviderStateMixin<T> {
  TransformationController get transform;

  AnimationController? _animation;
  Animation<Matrix4>? _zoomAnimation;
  Offset _doubleTapPosition = Offset.zero;

  bool get zoomed => transform.value.getMaxScaleOnAxis() > 1.01;

  void onDoubleTapDown(TapDownDetails details) =>
      _doubleTapPosition = details.localPosition;

  void toggleZoom(double scale) {
    final Matrix4 target;
    if (zoomed) {
      target = Matrix4.identity();
    } else {
      final position = _doubleTapPosition;
      target = Matrix4.identity()
        ..translateByDouble(
          -position.dx * (scale - 1),
          -position.dy * (scale - 1),
          0,
          1,
        )
        ..scaleByDouble(scale, scale, 1, 1);
    }
    final animation = _animation ??= AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(() => transform.value = _zoomAnimation!.value);
    _zoomAnimation = Matrix4Tween(
      begin: transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut));
    animation.forward(from: 0);
  }

  @override
  void dispose() {
    _animation?.dispose();
    super.dispose();
  }
}

/// 翻页模式下的一屏（单页或双页）：支持双指缩放与双击放大。
class ZoomablePage extends StatefulWidget {
  const ZoomablePage({
    super.key,
    required this.child,
    required this.onTap,
    required this.onWheel,
    required this.onZoomChanged,
  });

  final Widget child;
  final ValueChanged<Offset> onTap;
  final ValueChanged<double> onWheel;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<ZoomablePage> createState() => _ZoomablePageState();
}

class _ZoomablePageState extends State<ZoomablePage>
    with SingleTickerProviderStateMixin, _DoubleTapZoom {
  @override
  final TransformationController transform = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void _onTransform() {
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
      widget.onZoomChanged(_zoomed);
    }
  }

  /// 桌面端：Ctrl + 滚轮缩放，放大后滚轮平移，否则滚轮翻页。
  void _onPointerSignal(PointerSignalEvent event) {
    final size = context.size;
    if (event is! PointerScrollEvent || size == null) return;
    if (HardwareKeyboard.instance.isControlPressed) {
      _zoomAt(event.localPosition, exp(-event.scrollDelta.dy / 200), size);
    } else if (_zoomed) {
      _setClamped(
        Matrix4.translationValues(
          -event.scrollDelta.dx,
          -event.scrollDelta.dy,
          0,
        ).multiplied(transform.value),
        size,
      );
    } else {
      widget.onWheel(event.scrollDelta.dy);
    }
  }

  void _zoomAt(Offset focal, double factor, Size size) {
    final current = transform.value.getMaxScaleOnAxis();
    final target = (current * factor).clamp(1.0, 5.0);
    if (target <= 1.0) {
      transform.value = Matrix4.identity();
      return;
    }
    final scale = target / current;
    final change = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _setClamped(change.multiplied(transform.value), size);
  }

  /// 限制平移范围，避免图片被移出视口。
  void _setClamped(Matrix4 matrix, Size size) {
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    final x = translation.x.clamp(size.width * (1 - scale), 0.0);
    final y = translation.y.clamp(size.height * (1 - scale), 0.0);
    transform.value = Matrix4.identity()
      ..translateByDouble(x, y, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => widget.onTap(details.globalPosition),
      onDoubleTapDown: onDoubleTapDown,
      onDoubleTap: () => toggleZoom(2.5),
      child: Listener(
        onPointerSignal: isDesktop ? _onPointerSignal : null,
        child: InteractiveViewer(
          transformationController: transform,
          minScale: 1,
          maxScale: 5,
          panEnabled: _zoomed,
          scaleEnabled: !isDesktop,
          child: SizedBox.expand(child: widget.child),
        ),
      ),
    );
  }
}

/// 竖向模式的缩放：双指缩放、双击在 1× 与 2× 之间切换，放大后单指上下滑动仍然滚动列表。
///
/// 两根手指按下时 [builder] 收到 `pinching = true`，列表应禁止滚动，
/// 这样手势会交给缩放，而不是被列表的拖动抢走。
class VerticalZoom extends StatefulWidget {
  const VerticalZoom({
    super.key,
    required this.controller,
    required this.onTap,
    required this.builder,
  });

  final TransformationController controller;
  final ValueChanged<Offset> onTap;
  final Widget Function(BuildContext context, bool pinching) builder;

  @override
  State<VerticalZoom> createState() => _VerticalZoomState();
}

class _VerticalZoomState extends State<VerticalZoom>
    with SingleTickerProviderStateMixin, _DoubleTapZoom {
  @override
  TransformationController get transform => widget.controller;

  final Set<int> _pointers = {};
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    transform.addListener(_onTransform);
  }

  @override
  void didUpdateWidget(VerticalZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTransform);
      widget.controller.addListener(_onTransform);
    }
  }

  @override
  void dispose() {
    transform.removeListener(_onTransform);
    super.dispose();
  }

  void _onTransform() {
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointers.add(event.pointer) && _pointers.length == 2) setState(() {});
  }

  void _onPointerUp(PointerEvent event) {
    if (_pointers.remove(event.pointer) && _pointers.length == 1) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _pointers.length >= 2);
    if (isDesktop) {
      // 桌面端用 Ctrl + 滚轮调整宽度，单击不必等待双击判定
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => widget.onTap(details.globalPosition),
        child: child,
      );
    }
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerUp,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => widget.onTap(details.globalPosition),
        onDoubleTapDown: onDoubleTapDown,
        onDoubleTap: () => toggleZoom(2),
        child: InteractiveViewer(
          transformationController: transform,
          minScale: 1,
          maxScale: 4,
          panEnabled: _zoomed,
          child: child,
        ),
      ),
    );
  }
}
