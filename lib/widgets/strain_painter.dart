import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../dic_core.dart';

enum DisplayMode { exx, eyy, exy, u, v }

extension DisplayModeLabel on DisplayMode {
  String get label => switch (this) {
        DisplayMode.exx => 'εxx',
        DisplayMode.eyy => 'εyy',
        DisplayMode.exy => 'εxy',
        DisplayMode.u   => 'U',
        DisplayMode.v   => 'V',
      };
}

/// データと表示モードから描画範囲を計算する。
/// vminOverride/vmaxOverride が両方 non-null のときはそちらを優先する。
(double vmin, double vmax) computeRange(
  Float32List data,
  DisplayMode mode, {
  double? vminOverride,
  double? vmaxOverride,
}) {
  if (vminOverride != null && vmaxOverride != null) {
    return (vminOverride, vmaxOverride);
  }

  double vmin = double.infinity, vmax = double.negativeInfinity;
  for (final v in data) {
    if (!v.isNaN && !v.isInfinite) {
      if (v < vmin) vmin = v;
      if (v > vmax) vmax = v;
    }
  }
  if (vmin.isInfinite) { vmin = -1.0; vmax = 1.0; }
  else if ((vmax - vmin).abs() < 1e-10) { vmin -= 0.001; vmax += 0.001; }
  else if (mode == DisplayMode.exx ||
           mode == DisplayMode.eyy ||
           mode == DisplayMode.exy) {
    final absMax = math.max(vmin.abs(), vmax.abs());
    vmin = -absMax; vmax = absMax;
  }

  return (vminOverride ?? vmin, vmaxOverride ?? vmax);
}

// jet カラーマップ（t: 0→1 = 青→赤）
Color jetColor(double t, {int alpha = 255}) {
  double r, g, b;
  if (t < 0.125) {
    r = 0; g = 0; b = 0.5 + 4 * t;
  } else if (t < 0.375) {
    r = 0; g = 4 * (t - 0.125); b = 1;
  } else if (t < 0.625) {
    r = 4 * (t - 0.375); g = 1; b = 1 - 4 * (t - 0.375);
  } else if (t < 0.875) {
    r = 1; g = 1 - 4 * (t - 0.625); b = 0;
  } else {
    r = 1 - 4 * (t - 0.875); g = 0; b = 0;
  }
  return Color.fromARGB(
    alpha,
    (r.clamp(0.0, 1.0) * 255).round(),
    (g.clamp(0.0, 1.0) * 255).round(),
    (b.clamp(0.0, 1.0) * 255).round(),
  );
}

class StrainPainter extends CustomPainter {
  final DicResult result;
  final DisplayMode mode;
  final double imageWidth;
  final double imageHeight;
  final double? vminOverride;
  final double? vmaxOverride;

  const StrainPainter({
    required this.result,
    required this.mode,
    required this.imageWidth,
    required this.imageHeight,
    this.vminOverride,
    this.vmaxOverride,
  });

  Float32List get _data => switch (mode) {
        DisplayMode.exx => result.exx,
        DisplayMode.eyy => result.eyy,
        DisplayMode.exy => result.exy,
        DisplayMode.u   => result.U,
        DisplayMode.v   => result.V,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final data = _data;
    final (vmin, vmax) = computeRange(data, mode,
        vminOverride: vminOverride, vmaxOverride: vmaxOverride);
    final dv = vmax - vmin;

    final scale = math.min(size.width / imageWidth, size.height / imageHeight);
    final offsetX = (size.width - imageWidth * scale) / 2;
    final offsetY = (size.height - imageHeight * scale) / 2;

    final cellW = (result.nx > 1 ? result.xs[1] - result.xs[0] : 15) * scale;
    final cellH = (result.ny > 1 ? result.ys[1] - result.ys[0] : 15) * scale;

    final paint = Paint();
    for (int j = 0; j < result.ny; j++) {
      for (int i = 0; i < result.nx; i++) {
        final idx = j * result.nx + i;
        final val = data[idx];
        if (val.isNaN) continue;
        final t = dv > 0 ? ((val - vmin) / dv).clamp(0.0, 1.0) : 0.5;
        paint.color = jetColor(t, alpha: 178);
        // 変形後の実際の位置に描画（変位場で補正）
        final u = result.U[idx].isNaN ? 0.0 : result.U[idx];
        final v = result.V[idx].isNaN ? 0.0 : result.V[idx];
        final x = offsetX + (result.xs[i] + u) * scale - cellW / 2;
        final y = offsetY + (result.ys[j] + v) * scale - cellH / 2;
        canvas.drawRect(Rect.fromLTWH(x, y, cellW, cellH), paint);
      }
    }
  }

  @override
  bool shouldRepaint(StrainPainter old) =>
      old.mode != mode ||
      old.result != result ||
      old.vminOverride != vminOverride ||
      old.vmaxOverride != vmaxOverride;
}
