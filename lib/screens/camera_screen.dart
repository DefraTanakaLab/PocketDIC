import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../dic_core.dart';
import '../settings.dart';
import '../widgets/strain_painter.dart';
import 'settings_screen.dart';

export '../widgets/strain_painter.dart' show DisplayMode;

enum _S { init, ready, refDone, capturing, captured, analyzing, done }

class CameraScreen extends StatefulWidget {
  final AppSettings settings;
  const CameraScreen({super.key, required this.settings});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  // カメラ
  CameraController? _ctrl;
  bool _camReady = false;

  // 画像データ
  cv.Mat? _refGray;
  Uint8List? _refBytes;
  List<cv.Mat> _defMats = [];
  List<Uint8List> _defBytes = [];
  int _imgW = 0, _imgH = 0;

  // DIC 結果
  List<DicResult> _results = [];
  List<double> _stageZncc = [];
  int _stage = 0;
  DisplayMode _mode = DisplayMode.exx;

  // ROI
  Rect? _roi;
  bool _roiMode = false;
  Offset? _roiStart;
  Rect? _roiDrag;
  Size _mainSize = Size.zero;

  // 状態管理
  _S _state = _S.init;
  Timer? _timer;
  int _count = 0;
  String _msg = '';

  AppSettings get _s => widget.settings;

  // --------------------------------------------------------- ライフサイクル

  @override
  void initState() {
    super.initState();
    _lockLandscape();
    _initCamera();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl?.dispose();
    _refGray?.dispose();
    for (final m in _defMats) { m.dispose(); }
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  void _lockLandscape() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // --------------------------------------------------------- カメラ初期化

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) { _setMsg('カメラが見つかりません'); return; }
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final preset = switch (_s.resolution) {
        '4K'  => ResolutionPreset.ultraHigh,
        '最大' => ResolutionPreset.max,
        _     => ResolutionPreset.veryHigh,
      };
      _ctrl = CameraController(cam, preset, enableAudio: false);
      await _ctrl!.initialize();
      if (mounted) setState(() { _camReady = true; _state = _S.ready; });
    } on CameraException catch (e) {
      _setMsg('カメラエラー: ${e.description}');
    }
  }

  // --------------------------------------------------------- 撮影

  Future<Uint8List?> _shoot() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized) return null;
    try {
      final xFile = await _ctrl!.takePicture();
      return await File(xFile.path).readAsBytes();
    } catch (e) {
      _setMsg('撮影エラー: $e');
      return null;
    }
  }

  Future<void> _captureRef() async {
    if (_state != _S.ready) return;
    _setMsg('参照画像を撮影中...');
    final bytes = await _shoot();
    if (bytes == null) return;

    _refGray?.dispose();
    _refGray = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
    _imgW = _refGray!.cols;
    _imgH = _refGray!.rows;

    try { await _ctrl!.setFocusMode(FocusMode.locked); } catch (_) {}

    _clearDeformed();
    setState(() {
      _refBytes = bytes;
      _roi = null;
      _roiMode = false;
      _state = _S.refDone;
      _msg = '参照画像 OK（${_imgW}×${_imgH}px）🔒フォーカスロック済み';
    });
  }

  void _startCapture() {
    if (_state != _S.refDone && _state != _S.captured) return;
    _clearDeformed();
    _count = 0;
    setState(() { _state = _S.capturing; _msg = '撮影中 0/${_s.maxFrames}'; });
    _timer = Timer.periodic(Duration(seconds: _s.intervalSec), (_) => _captureDeformed());
  }

  void _stopCapture() {
    _timer?.cancel();
    _timer = null;
    setState(() { _state = _S.captured; _msg = '停止（$_count 枚撮影済み）'; });
  }

  Future<void> _captureDeformed() async {
    final bytes = await _shoot();
    if (bytes == null) return;
    _defMats.add(cv.imdecode(bytes, cv.IMREAD_GRAYSCALE));
    _defBytes.add(bytes);
    _count++;
    setState(() => _msg = '撮影中 $_count/${_s.maxFrames}');
    if (_count >= _s.maxFrames) _stopCapture();
  }

  void _clearDeformed() {
    for (final m in _defMats) { m.dispose(); }
    _defMats = [];
    _defBytes = [];
    _results = [];
    _stageZncc = [];
    _stage = 0;
  }

  // --------------------------------------------------------- DIC 解析

  Future<void> _analyze() async {
    if (_refGray == null || _defMats.isEmpty) {
      _setMsg('参照画像と変形後画像が必要です');
      return;
    }
    // done 状態からの再解析時は結果をリセット
    final prevState = _state;
    setState(() { _state = _S.analyzing; _msg = '計算中 0/${_defMats.length}...'; });

    final results = <DicResult>[];
    final znccAvgs = <double>[];
    Float32List? prevU;
    Float32List? prevV;

    final roiList = _roi != null
        ? [_roi!.left.toInt(), _roi!.top.toInt(),
           _roi!.right.toInt(), _roi!.bottom.toInt()]
        : null;

    try {
      for (int s = 0; s < _defMats.length; s++) {
        setState(() => _msg = '計算中 ${s + 1}/${_defMats.length}...');
        await Future.delayed(const Duration(milliseconds: 50));

        final result = runDicFull(
          ref: _refGray!,
          deformed: _defMats[s],
          subsetSize: _s.subsetSize,
          step: _s.stepSize,
          searchX: _s.searchRange,
          searchY: _s.searchRange,
          znccThreshold: _s.znccThreshold,
          roi: roiList,
          prevU: prevU,
          prevV: prevV,
        );
        results.add(result);

        double znccSum = 0; int znccN = 0;
        for (final v in result.zncc) {
          if (!v.isNaN) { znccSum += v; znccN++; }
        }
        znccAvgs.add(znccN > 0 ? znccSum / znccN : 0.0);

        prevU = result.U;
        prevV = result.V;
      }

      setState(() {
        _results = results;
        _stageZncc = znccAvgs;
        _stage = 0;
        _state = _S.done;
        _msg = _stageMsg(0);
      });
    } catch (e) {
      setState(() {
        _state = prevState == _S.done ? _S.done : _S.captured;
        _msg = 'エラー: $e';
      });
    }
  }

  DicResult _zeroResult() {
    final r = _results[0];
    final n = r.nx * r.ny;
    return DicResult(
      xs: r.xs, ys: r.ys, nx: r.nx, ny: r.ny,
      U: Float32List(n), V: Float32List(n),
      zncc: Float32List(n)..fillRange(0, n, 1.0),
      exx: Float32List(n), eyy: Float32List(n), exy: Float32List(n),
    );
  }

  String _stageMsg(int s) {
    if (s == 0) return '参照段階 | ひずみ = 0';
    if (_results.isEmpty || s > _results.length) return '';
    final r = _results[s - 1];
    return 'Stage $s/${_results.length} | '
        '有効 ${r.validCount}/${r.nx * r.ny} | '
        'ZNCC avg ${_stageZncc[s - 1].toStringAsFixed(2)}';
  }

  // --------------------------------------------------------- ROI

  void _toggleRoi() {
    if (_roi != null && !_roiMode) {
      setState(() { _roi = null; });
    } else {
      setState(() { _roiMode = !_roiMode; });
    }
  }

  void _onRoiDragStart(DragStartDetails d) {
    _roiStart = d.localPosition;
    setState(() => _roiDrag = null);
  }

  void _onRoiDragUpdate(DragUpdateDetails d) {
    setState(() => _roiDrag = Rect.fromPoints(_roiStart!, d.localPosition));
  }

  void _onRoiDragEnd(DragEndDetails _) {
    if (_roiDrag == null || _mainSize == Size.zero || _imgW == 0) return;
    final scale = math.min(_mainSize.width / _imgW, _mainSize.height / _imgH);
    final ox = (_mainSize.width  - _imgW * scale) / 2;
    final oy = (_mainSize.height - _imgH * scale) / 2;
    final l = ((_roiDrag!.left   - ox) / scale).clamp(0.0, _imgW.toDouble());
    final t = ((_roiDrag!.top    - oy) / scale).clamp(0.0, _imgH.toDouble());
    final r = ((_roiDrag!.right  - ox) / scale).clamp(0.0, _imgW.toDouble());
    final b = ((_roiDrag!.bottom - oy) / scale).clamp(0.0, _imgH.toDouble());
    setState(() {
      if ((r - l).abs() > 10 && (b - t).abs() > 10) {
        _roi = Rect.fromLTRB(
          math.min(l, r), math.min(t, b),
          math.max(l, r), math.max(t, b),
        );
      }
      _roiDrag = null;
      _roiMode = false;
    });
  }

  // --------------------------------------------------------- カラースケール

  (double, double) _currentRange() {
    if (_results.isEmpty) return (-1.0, 1.0);
    final r = _results[(_stage == 0 ? 0 : _stage - 1).clamp(0, _results.length - 1)];
    final data = switch (_mode) {
      DisplayMode.exx => r.exx,
      DisplayMode.eyy => r.eyy,
      DisplayMode.exy => r.exy,
      DisplayMode.u   => r.U,
      DisplayMode.v   => r.V,
    };
    return computeRange(data, _mode,
        vminOverride: _s.colorMin, vmaxOverride: _s.colorMax);
  }

  String _fmtVal(double v) {
    if (_mode == DisplayMode.u || _mode == DisplayMode.v) {
      return '${v.toStringAsFixed(1)}px';
    }
    if (v.abs() >= 0.001 || v == 0) return v.toStringAsFixed(4);
    return v.toStringAsExponential(2);
  }

  Widget _buildColorBar() {
    final (vmin, vmax) = _currentRange();
    return Container(
      decoration: BoxDecoration(
        color: const Color.fromARGB(160, 0, 0, 0),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_fmtVal(vmax),
              style: const TextStyle(color: Colors.white, fontSize: 8)),
          const SizedBox(height: 4),
          Container(
            width: 14,
            height: 110,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.fromARGB(255, 128, 0,   0),   // t=1.0  赤暗
                  Color.fromARGB(255, 255, 0,   0),   // t=0.875 赤
                  Color.fromARGB(255, 255, 255, 0),   // t=0.625 黄
                  Color.fromARGB(255, 0,   255, 255), // t=0.375 シアン
                  Color.fromARGB(255, 0,   0,   255), // t=0.125 青
                  Color.fromARGB(255, 0,   0,   128), // t=0.0  青暗
                ],
                stops: [0.0, 0.125, 0.375, 0.625, 0.875, 1.0],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(_fmtVal(vmin),
              style: const TextStyle(color: Colors.white, fontSize: 8)),
        ],
      ),
    );
  }

  // --------------------------------------------------------- 保存

  Future<void> _saveImages() async {
    if (_results.isEmpty || _defBytes.isEmpty) return;
    final total = _results.length;
    setState(() => _msg = '保存準備中...');

    try {
      final hasAccess = await Gal.hasAccess(toAlbum: false);
      if (!hasAccess) {
        await Gal.requestAccess(toAlbum: false);
      }

      final (vmin, vmax) = _currentRange();
      final ts = DateTime.now().millisecondsSinceEpoch;

      for (int s = 0; s < total; s++) {
        setState(() => _msg = '保存中 ${s + 1}/$total...');
        await Future.delayed(const Duration(milliseconds: 30));

        final bytes = await _renderStage(s, vmin, vmax);
        final name = 'dic_${_mode.label}_s${s + 1}_$ts';
        await Gal.putImageBytes(bytes, name: name);
      }

      setState(() => _msg = '$total 枚をギャラリーに保存しました');
    } catch (e) {
      setState(() => _msg = '保存エラー: $e');
    }
  }

  Future<Uint8List> _renderStage(int stage, double vmin, double vmax) async {
    // 背景画像をデコード
    final codec = await ui.instantiateImageCodec(_defBytes[stage]);
    final frame = await codec.getNextFrame();
    final bgImage = frame.image;
    final w = bgImage.width.toDouble();
    final h = bgImage.height.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    // 背景写真を描画
    canvas.drawImage(bgImage, Offset.zero, Paint());

    // ひずみオーバーレイを描画（フル解像度：scale=1, offset=0）
    StrainPainter(
      result: _results[stage],
      mode: _mode,
      imageWidth: w,
      imageHeight: h,
      vminOverride: vmin,
      vmaxOverride: vmax,
    ).paint(canvas, Size(w, h));

    // カラーバーを描画
    _drawColorBar(canvas, Size(w, h), vmin, vmax);

    bgImage.dispose();

    final picture = recorder.endRecording();
    final image = await picture.toImage(bgImage.width, bgImage.height);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    return byteData!.buffer.asUint8List();
  }

  void _drawColorBar(Canvas canvas, Size size, double vmin, double vmax) {
    const barW = 18.0;
    const barH = 160.0;
    const marginL = 14.0;
    const marginB = 14.0;
    const labelH = 22.0;
    final left = marginL;
    final top = size.height - marginB - labelH - barH - labelH;

    // 背景
    final bgRect = Rect.fromLTWH(left - 4, top - 4, barW + 8 + 60, barH + labelH * 2 + 8);
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(4)),
      Paint()..color = const Color.fromARGB(160, 0, 0, 0),
    );

    // グラデーションバー（上=最大=赤、下=最小=青）
    final barRect = Rect.fromLTWH(left, top + labelH, barW, barH);
    canvas.drawRect(
      barRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.fromARGB(255, 128, 0,   0),
            Color.fromARGB(255, 255, 0,   0),
            Color.fromARGB(255, 255, 255, 0),
            Color.fromARGB(255, 0,   255, 255),
            Color.fromARGB(255, 0,   0,   255),
            Color.fromARGB(255, 0,   0,   128),
          ],
          stops: [0.0, 0.125, 0.375, 0.625, 0.875, 1.0],
        ).createShader(barRect),
    );

    // ラベル描画ヘルパー
    void drawLabel(String text, double x, double y) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, y));
    }

    drawLabel(_fmtVal(vmax), left + barW + 4, top + labelH - 4);
    drawLabel(_fmtVal(vmin), left + barW + 4, top + labelH + barH - 4);

    // モードラベル
    drawLabel(_mode.label, left, top + 2);
  }

  // --------------------------------------------------------- その他操作

  void _reset() {
    _timer?.cancel();
    _refGray?.dispose();
    _refGray = null;
    _clearDeformed();
    try { _ctrl?.setFocusMode(FocusMode.auto); } catch (_) {}
    setState(() {
      _refBytes = null;
      _roi = null;
      _roiMode = false;
      _state = _S.ready;
      _msg = '';
    });
  }

  Future<void> _openSettings() async {
    _timer?.cancel();
    final prevResolution = _s.resolution;
    await Navigator.push(context,
        MaterialPageRoute(builder: (_) => SettingsScreen(settings: _s)));
    _lockLandscape();
    if (_s.resolution != prevResolution) {
      setState(() { _camReady = false; _state = _S.init; });
      await _ctrl?.dispose();
      _ctrl = null;
      await _initCamera();
    }
    setState(() {});
  }

  void _setMsg(String m) => setState(() => _msg = m);

  // --------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Row(
          children: [
            Expanded(child: _buildMain()),
            _buildPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildMain() {
    return LayoutBuilder(builder: (_, c) {
      _mainSize = Size(c.maxWidth, c.maxHeight);
      final size = _mainSize;
      final canDrag = _roiMode && _imgW > 0;
      final showResult = _state == _S.done && _results.isNotEmpty && _imgW > 0;
      return GestureDetector(
        onPanStart:  canDrag ? _onRoiDragStart  : null,
        onPanUpdate: canDrag ? _onRoiDragUpdate : null,
        onPanEnd:    canDrag ? _onRoiDragEnd    : null,
        child: Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            _buildBg(),
            // ひずみオーバーレイ
            if (showResult)
              CustomPaint(
                size: size,
                painter: StrainPainter(
                  result: _stage == 0 ? _zeroResult() : _results[_stage - 1],
                  mode: _mode,
                  imageWidth: _imgW.toDouble(),
                  imageHeight: _imgH.toDouble(),
                  vminOverride: _s.colorMin,
                  vmaxOverride: _s.colorMax,
                ),
              ),
            // カラーバー
            if (showResult)
              Positioned(
                left: 6,
                top: 0,
                bottom: 0,
                child: Center(child: _buildColorBar()),
              ),
            // ROI オーバーレイ
            if (_imgW > 0 && (_roi != null || _roiDrag != null))
              CustomPaint(
                size: size,
                painter: _RoiPainter(
                  roi: _roi,
                  drag: _roiDrag,
                  imageWidth: _imgW.toDouble(),
                  imageHeight: _imgH.toDouble(),
                ),
              ),
            // 計算中スピナー
            if (_state == _S.analyzing)
              const Center(child: CircularProgressIndicator(color: Colors.white)),
            // ステージスライダー
            if (_state == _S.done && _results.length >= 1)
              Positioned(
                bottom: _msg.isNotEmpty ? 32 : 6,
                left: 6,
                right: 6,
                child: Row(
                  children: [
                    Text(
                      _stage == 0 ? '参照' : '$_stage/${_results.length}',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white38,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                        ),
                        child: Slider(
                          value: _stage.toDouble(),
                          min: 0,
                          max: _results.length.toDouble(),
                          divisions: _results.length,
                          onChanged: (v) {
                            final s = v.round();
                            setState(() {
                              _stage = s;
                              _msg = _stageMsg(s);
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // 情報テキスト
            if (_msg.isNotEmpty)
              Positioned(
                bottom: 6, left: 6, right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _msg,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        ),
      );
    });
  }

  Widget _buildBg() {
    if (_state == _S.done) {
      if (_stage == 0 && _refBytes != null) {
        return Image.memory(_refBytes!, fit: BoxFit.contain);
      }
      if (_stage > 0 && _defBytes.isNotEmpty && _stage - 1 < _defBytes.length) {
        return Image.memory(_defBytes[_stage - 1], fit: BoxFit.contain);
      }
    }
    if (_state == _S.capturing || _state == _S.captured) {
      final bytes = _defBytes.isNotEmpty ? _defBytes.last : _refBytes;
      if (bytes != null) return Image.memory(bytes, fit: BoxFit.contain);
    }
    if (_state == _S.refDone && _refBytes != null) {
      return Image.memory(_refBytes!, fit: BoxFit.contain);
    }
    if (_camReady && _ctrl != null) return CameraPreview(_ctrl!);
    return const Center(child: CircularProgressIndicator(color: Colors.white));
  }

  Widget _buildPanel() {
    final canRef      = _state == _S.ready;
    final canStart    = _state == _S.refDone || _state == _S.captured;
    final isCapturing = _state == _S.capturing;
    final canAnalyze  = (_state == _S.captured || _state == _S.done)
        && _refGray != null && _defMats.isNotEmpty;
    final canSave     = _state == _S.done && _results.isNotEmpty;
    final canReset    = _state != _S.init && _state != _S.ready;
    final canRoi      = _imgW > 0 &&
        (_state == _S.refDone || _state == _S.captured || _state == _S.done);

    return Container(
      width: 68,
      color: Colors.black87,
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            _Btn(Icons.settings,   '設定',   _openSettings),
            _Btn(Icons.camera_alt, '参照',   canRef ? _captureRef : null),
            _Btn(
              isCapturing ? Icons.stop : Icons.play_arrow,
              isCapturing ? '停止' : '開始',
              isCapturing ? _stopCapture : (canStart ? _startCapture : null),
              color: isCapturing ? Colors.redAccent : null,
            ),
            _Btn(Icons.auto_graph, '解析',   canAnalyze ? _analyze : null),
            _Btn(Icons.save_alt,   '保存',   canSave ? _saveImages : null),
            _Btn(
              Icons.crop,
              _roiMode ? 'ROI中' : (_roi != null ? 'ROI✓' : 'ROI'),
              canRoi ? _toggleRoi : null,
              color: _roiMode
                  ? Colors.yellowAccent
                  : (_roi != null ? Colors.greenAccent : null),
            ),
            _CompToggle(
              current: _mode,
              enabled: _state == _S.done,
              onChanged: (m) => setState(() => _mode = m),
            ),
            _Btn(Icons.refresh, 'ﾘｾｯﾄ', canReset ? _reset : null),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// --------------------------------------------------------- ROI オーバーレイ

class _RoiPainter extends CustomPainter {
  final Rect? roi;
  final Rect? drag;
  final double imageWidth;
  final double imageHeight;

  const _RoiPainter({
    required this.roi,
    required this.drag,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = const Color.fromARGB(220, 255, 220, 0)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final fill = Paint()
      ..color = const Color.fromARGB(20, 255, 220, 0)
      ..style = PaintingStyle.fill;

    if (drag != null) {
      canvas.drawRect(drag!, fill);
      canvas.drawRect(drag!, stroke);
    } else if (roi != null) {
      final scale = math.min(size.width / imageWidth, size.height / imageHeight);
      final ox = (size.width  - imageWidth  * scale) / 2;
      final oy = (size.height - imageHeight * scale) / 2;
      final sr = Rect.fromLTRB(
        roi!.left   * scale + ox, roi!.top    * scale + oy,
        roi!.right  * scale + ox, roi!.bottom * scale + oy,
      );
      canvas.drawRect(sr, fill);
      canvas.drawRect(sr, stroke);
    }
  }

  @override
  bool shouldRepaint(_RoiPainter old) => old.roi != roi || old.drag != drag;
}

// --------------------------------------------------------- 小ウィジェット

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  const _Btn(this.icon, this.label, this.onTap, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = onTap == null ? Colors.white24 : (color ?? Colors.white);
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c, size: 26),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: c, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _CompToggle extends StatelessWidget {
  final DisplayMode current;
  final bool enabled;
  final ValueChanged<DisplayMode> onChanged;

  const _CompToggle({
    required this.current,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: DisplayMode.values.map((m) {
        final selected = current == m && enabled;
        return GestureDetector(
          onTap: enabled ? () => onChanged(m) : null,
          child: Container(
            width: 52,
            margin: const EdgeInsets.symmetric(vertical: 1),
            padding: const EdgeInsets.symmetric(vertical: 3),
            decoration: BoxDecoration(
              color: selected ? Colors.blue : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: enabled ? Colors.white54 : Colors.white12),
            ),
            child: Text(
              m.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white24,
                fontSize: 10,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
