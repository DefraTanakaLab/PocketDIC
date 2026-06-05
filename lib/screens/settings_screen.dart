import 'package:flutter/material.dart';
import '../settings.dart';

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _interval;
  late final TextEditingController _maxFrames;
  late final TextEditingController _subset;
  late final TextEditingController _step;
  late final TextEditingController _search;
  late final TextEditingController _colorMin;
  late final TextEditingController _colorMax;
  late String _resolution;

  static const _resolutionOptions = ['1080p', '4K', '最大'];

  @override
  void initState() {
    super.initState();
    final s = widget.settings;
    _interval   = TextEditingController(text: s.intervalSec.toString());
    _maxFrames  = TextEditingController(text: s.maxFrames.toString());
    _subset     = TextEditingController(text: s.subsetSize.toString());
    _step       = TextEditingController(text: s.stepSize.toString());
    _search     = TextEditingController(text: s.searchRange.toString());
    _colorMin   = TextEditingController(text: s.colorMin?.toString() ?? '');
    _colorMax   = TextEditingController(text: s.colorMax?.toString() ?? '');
    _resolution = s.resolution;
  }

  @override
  void dispose() {
    _interval.dispose();
    _maxFrames.dispose();
    _subset.dispose();
    _step.dispose();
    _search.dispose();
    _colorMin.dispose();
    _colorMax.dispose();
    super.dispose();
  }

  void _save() {
    final s = widget.settings;
    s.intervalSec = int.tryParse(_interval.text)  ?? s.intervalSec;
    s.maxFrames   = int.tryParse(_maxFrames.text) ?? s.maxFrames;
    s.subsetSize  = int.tryParse(_subset.text)    ?? s.subsetSize;
    s.stepSize    = int.tryParse(_step.text)      ?? s.stepSize;
    s.searchRange = int.tryParse(_search.text)    ?? s.searchRange;
    if (s.subsetSize.isEven) s.subsetSize += 1;
    s.colorMin   = double.tryParse(_colorMin.text.trim());
    s.colorMax   = double.tryParse(_colorMax.text.trim());
    s.resolution = _resolution;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel('撮影'),
                _Field('撮影インターバル（秒）', _interval, hint: '例: 5'),
                _Field('最大枚数', _maxFrames, hint: '例: 5'),
                const SizedBox(height: 8),
                const Text('解像度', style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: _resolutionOptions
                      .map((r) => ButtonSegment(value: r, label: Text(r)))
                      .toList(),
                  selected: {_resolution},
                  onSelectionChanged: (v) => setState(() => _resolution = v.first),
                ),
                const SizedBox(height: 16),
                const _SectionLabel('DIC 解析'),
                _Field('サブセットサイズ（px、奇数）', _subset, hint: '例: 31'),
                _Field('ステップ（px）', _step, hint: '例: 15'),
                _Field('探索範囲（px）', _search, hint: '例: 20'),
                const SizedBox(height: 8),
                const Text(
                  '※ サブセット > ステップ × 2 になるように設定してください',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                const _SectionLabel('カラースケール（空欄 = 自動）'),
                _Field('最小値', _colorMin, hint: '例: -0.01', isDecimal: true),
                _Field('最大値', _colorMax, hint: '例:  0.01', isDecimal: true),
                const SizedBox(height: 8),
                const Text(
                  '※ 最小・最大を両方入力すると表示範囲が固定されます。\n'
                  '　 片方だけ入力しても効果はありません。',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              fontWeight: FontWeight.bold, color: Colors.grey, fontSize: 13)),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final String hint;
  final bool isDecimal;

  const _Field(this.label, this.ctrl, {this.hint = '', this.isDecimal = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: ctrl,
        keyboardType: isDecimal
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
