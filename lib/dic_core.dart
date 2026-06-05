import 'dart:math' as math;
import 'dart:typed_data';
import 'package:opencv_dart/opencv_dart.dart' as cv;

// ---------------------------------------------------------------------------
// 結果クラス
// ---------------------------------------------------------------------------

class DicResult {
  final List<int> xs;
  final List<int> ys;
  final int nx;
  final int ny;
  final Float32List U;
  final Float32List V;
  final Float32List zncc;
  final Float32List exx;
  final Float32List eyy;
  final Float32List exy;

  DicResult({
    required this.xs,
    required this.ys,
    required this.nx,
    required this.ny,
    required this.U,
    required this.V,
    required this.zncc,
    required this.exx,
    required this.eyy,
    required this.exy,
  });

  double get meanU => _nanMean(U);
  double get meanV => _nanMean(V);

  int get validCount {
    int n = 0;
    for (final v in U) {
      if (!v.isNaN) n++;
    }
    return n;
  }

  static double _nanMean(Float32List arr) {
    double sum = 0;
    int n = 0;
    for (final v in arr) {
      if (!v.isNaN && !v.isInfinite) {
        sum += v;
        n++;
      }
    }
    return n > 0 ? sum / n : double.nan;
  }
}

// ---------------------------------------------------------------------------
// グリッド生成
// ---------------------------------------------------------------------------

({List<int> xs, List<int> ys}) createGrid({
  required int height,
  required int width,
  required int subsetSize,
  required int searchRange,
  required int step,
  List<int>? roi, // [x1, y1, x2, y2]
}) {
  final margin = subsetSize ~/ 2 + searchRange + 2;
  int xMin = margin;
  int xMax = width - margin - 1;
  int yMin = margin;
  int yMax = height - margin - 1;
  if (roi != null) {
    xMin = math.max(xMin, roi[0]);
    xMax = math.min(xMax, roi[2]);
    yMin = math.max(yMin, roi[1]);
    yMax = math.min(yMax, roi[3]);
  }
  final xs = [for (int x = xMin; x <= xMax; x += step) x];
  final ys = [for (int y = yMin; y <= yMax; y += step) y];
  return (xs: xs, ys: ys);
}

// ---------------------------------------------------------------------------
// ZNCC探索（matchTemplate + 放物線サブピクセル）
// ---------------------------------------------------------------------------

({double u, double v, double zncc}) znccSearch({
  required cv.Mat ref,
  required cv.Mat deformed,
  required int cx,
  required int cy,
  required int subsetSize,
  required int searchX,
  required int searchY,
  int initU = 0,
  int initV = 0,
}) {
  final half = subsetSize ~/ 2;

  // テンプレート（参照サブセット）を切り出す
  final rx = cx - half;
  final ry = cy - half;
  if (rx < 0 || ry < 0 ||
      rx + subsetSize > ref.cols ||
      ry + subsetSize > ref.rows) {
    return (u: initU.toDouble(), v: initV.toDouble(), zncc: -1.0);
  }

  // 探索領域の座標（画像境界でクリップ）
  final sx0 = cx + initU - searchX - half;
  final sy0 = cy + initV - searchY - half;
  final sx0c = math.max(0, sx0);
  final sy0c = math.max(0, sy0);
  final sx1c = math.min(deformed.cols, cx + initU + searchX + half + 1);
  final sy1c = math.min(deformed.rows, cy + initV + searchY + half + 1);

  if (sx1c - sx0c < subsetSize || sy1c - sy0c < subsetSize) {
    return (u: initU.toDouble(), v: initV.toDouble(), zncc: -1.0);
  }

  // クリップによるオフセット（zncc_map インデックスのずれ）
  // result[j, i] → zncc_map の (iOff+i, jOff+j) に対応
  // 変位: u = initU + (iOff + i - searchX)
  final iOff = sx0c - sx0; // >= 0
  final jOff = sy0c - sy0; // >= 0

  cv.Mat? templ;
  cv.Mat? region;
  cv.Mat? result;

  try {
    templ = ref.region(cv.Rect(rx, ry, subsetSize, subsetSize));
    region = deformed.region(
      cv.Rect(sx0c, sy0c, sx1c - sx0c, sy1c - sy0c),
    );
    result = cv.matchTemplate(region, templ, cv.TM_CCOEFF_NORMED);

    // rawバイト列から float32 として読む（CV_32F 前提）
    final float32Data = result.data.buffer.asFloat32List();
    final cols = result.cols;

    // ピーク探索
    double maxVal = -2.0;
    int bestI = 0, bestJ = 0;
    for (int j = 0; j < result.rows; j++) {
      for (int i = 0; i < cols; i++) {
        final val = float32Data[j * cols + i];
        if (val > maxVal) {
          maxVal = val;
          bestI = i;
          bestJ = j;
        }
      }
    }

    // 整数画素変位
    final bestU = initU + (iOff + bestI - searchX);
    final bestV = initV + (jOff + bestJ - searchY);

    // 放物線フィットによるサブピクセル補間
    double du = 0, dv = 0;
    if (bestI > 0 &&
        bestI < result.cols - 1 &&
        bestJ > 0 &&
        bestJ < result.rows - 1) {
      double para(double cm, double c0, double cp) {
        final d = cm - 2 * c0 + cp;
        if (d.abs() < 1e-12) return 0.0;
        return ((cm - cp) / (2 * d)).clamp(-1.0, 1.0);
      }

      final c0  = float32Data[bestJ * cols + bestI];
      final cmU = float32Data[bestJ * cols + bestI - 1];
      final cpU = float32Data[bestJ * cols + bestI + 1];
      final cmV = float32Data[(bestJ - 1) * cols + bestI];
      final cpV = float32Data[(bestJ + 1) * cols + bestI];

      du = para(cmU, c0, cpU);
      dv = para(cmV, c0, cpV);
    }

    return (u: bestU + du, v: bestV + dv, zncc: maxVal);
  } finally {
    result?.dispose();
    region?.dispose();
    templ?.dispose();
  }
}

// ---------------------------------------------------------------------------
// フルフィールドDIC
// ---------------------------------------------------------------------------

DicResult runDicFull({
  required cv.Mat ref,
  required cv.Mat deformed,
  required int subsetSize,
  required int step,
  required int searchX,
  required int searchY,
  double znccThreshold = 0.2,
  List<int>? roi,
  Float32List? prevU, // 前ステージの変位場（初期推定値）
  Float32List? prevV,
}) {
  final grid = createGrid(
    height: ref.rows,
    width: ref.cols,
    subsetSize: subsetSize,
    searchRange: math.max(searchX, searchY),
    step: step,
    roi: roi,
  );
  final xs = grid.xs;
  final ys = grid.ys;
  final nx = xs.length;
  final ny = ys.length;

  final U = Float32List(ny * nx);
  final V = Float32List(ny * nx);
  final Z = Float32List(ny * nx);

  for (int j = 0; j < ny; j++) {
    for (int i = 0; i < nx; i++) {
      final idx = j * nx + i;
      final iU = (prevU != null && idx < prevU.length && !prevU[idx].isNaN)
          ? prevU[idx].round() : 0;
      final iV = (prevV != null && idx < prevV.length && !prevV[idx].isNaN)
          ? prevV[idx].round() : 0;
      final r = znccSearch(
        ref: ref,
        deformed: deformed,
        cx: xs[i],
        cy: ys[j],
        subsetSize: subsetSize,
        searchX: searchX,
        searchY: searchY,
        initU: iU,
        initV: iV,
      );
      if (r.zncc >= znccThreshold) {
        U[idx] = r.u;
        V[idx] = r.v;
      } else {
        U[idx] = double.nan;
        V[idx] = double.nan;
      }
      Z[idx] = r.zncc;
    }
  }

  final strain = calcStrainField(
    xs: xs,
    ys: ys,
    U: U,
    V: V,
    nx: nx,
    ny: ny,
    step: step,
  );

  return DicResult(
    xs: xs,
    ys: ys,
    nx: nx,
    ny: ny,
    U: U,
    V: V,
    zncc: Z,
    exx: strain.exx,
    eyy: strain.eyy,
    exy: strain.exy,
  );
}

// ---------------------------------------------------------------------------
// ひずみ計算（中心差分）
// ---------------------------------------------------------------------------

({Float32List exx, Float32List eyy, Float32List exy}) calcStrainField({
  required List<int> xs,
  required List<int> ys,
  required Float32List U,
  required Float32List V,
  required int nx,
  required int ny,
  required int step,
}) {
  final size = ny * nx;
  final exx = Float32List(size);
  final eyy = Float32List(size);
  final exy = Float32List(size);
  for (int i = 0; i < size; i++) {
    exx[i] = double.nan;
    eyy[i] = double.nan;
    exy[i] = double.nan;
  }

  if (nx < 3 || ny < 3) return (exx: exx, eyy: eyy, exy: exy);

  final dx = xs.length > 1 ? (xs[1] - xs[0]).toDouble() : step.toDouble();
  final dy = ys.length > 1 ? (ys[1] - ys[0]).toDouble() : step.toDouble();

  for (int j = 1; j < ny - 1; j++) {
    for (int i = 1; i < nx - 1; i++) {
      final idx = j * nx + i;
      exx[idx] = (U[j * nx + i + 1] - U[j * nx + i - 1]) / (2 * dx);
      eyy[idx] = (V[(j + 1) * nx + i] - V[(j - 1) * nx + i]) / (2 * dy);
      exy[idx] = 0.5 *
          ((U[(j + 1) * nx + i] - U[(j - 1) * nx + i]) / (2 * dy) +
              (V[j * nx + i + 1] - V[j * nx + i - 1]) / (2 * dx));
    }
  }

  return (exx: exx, eyy: eyy, exy: exy);
}
