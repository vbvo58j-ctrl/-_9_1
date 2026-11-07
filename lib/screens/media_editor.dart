import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';

import '../widgets/blousab_visuals.dart';

// ---------------------------------------------------------------------------
// محرر الصور والفيديو قبل النشر (القصص والمنشورات).
// - الصور: قص بنسب جاهزة مع تكبير وتحريك، تدوير، قلب، فلاتر، سطوع/تباين/تشبع،
//   رسم بالقلم، نصوص، وملصقات إيموجي. التصدير JPEG بجودة عالية.
// - الفيديو: قص البداية والنهاية، كتم الصوت، اختيار الجودة، ومعاينة المقطع.
// لا يمسّ أي منطق للاتصال أو المزامنة؛ يُرجع ملفاً فقط.
// ---------------------------------------------------------------------------

/// يفتح محرر الصور. يُرجع مسار ملف JPEG المعدَّل، أو null عند الإلغاء.
Future<String?> openImageEditor(BuildContext context, String path) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(fullscreenDialog: true, builder: (_) => ImageEditorScreen(path: path)),
  );
}

/// نتيجة محرر الفيديو.
class VideoEditResult {
  const VideoEditResult({required this.startSeconds, required this.durationSeconds, required this.trimmed, required this.mute, required this.quality});
  final int startSeconds;
  final int durationSeconds;
  final bool trimmed;
  final bool mute;
  final VideoQuality quality;
}

/// يفتح محرر الفيديو. يُرجع null عند الإلغاء.
Future<VideoEditResult?> openVideoEditor(BuildContext context, String path, {int maxSeconds = 60, VideoQuality initialQuality = VideoQuality.MediumQuality}) {
  return Navigator.of(context).push<VideoEditResult>(
    MaterialPageRoute<VideoEditResult>(fullscreenDialog: true, builder: (_) => VideoEditorScreen(path: path, maxSeconds: maxSeconds, initialQuality: initialQuality)),
  );
}

/// يطبّق نتيجة المحرر على الفيديو (قص/كتم/ضغط) ويُرجع الملف الناتج.
Future<File> applyVideoEdit(String sourcePath, VideoEditResult r) async {
  final info = await VideoCompress.compressVideo(
    sourcePath,
    quality: r.quality,
    deleteOrigin: false,
    startTime: r.trimmed ? r.startSeconds : null,
    duration: r.trimmed ? r.durationSeconds : null,
    includeAudio: !r.mute,
  );
  final file = info?.file;
  if (file == null) {
    if (r.trimmed || r.mute) throw Exception('تعذر تطبيق تعديلات الفيديو');
    return File(sourcePath);
  }
  return file;
}

// ===========================================================================
// محرر الصور
// ===========================================================================

Uint8List _encodeJpg(Map<String, Object> args) {
  final w = args['w'] as int;
  final h = args['h'] as int;
  final bytes = args['bytes'] as Uint8List;
  final image = img.Image.fromBytes(width: w, height: h, bytes: bytes.buffer, numChannels: 4);
  return Uint8List.fromList(img.encodeJpg(image, quality: 86));
}

class _Stroke {
  _Stroke(this.color, this.width);
  final Color color;
  final double width; // نسبة من عرض الإطار
  final List<Offset> points = <Offset>[]; // إحداثيات مُطبَّعة 0..1
}

class _Item {
  _Item({required this.text, required this.color, required this.size, this.bold = true});
  String text;
  Color color;
  double size;
  bool bold;
  Offset pos = const Offset(.5, .5); // مركز العنصر (مُطبَّع)
  double scale = 1;
  double rotation = 0;
}

class _Preset {
  const _Preset(this.name, this.matrix);
  final String name;
  final List<double> matrix; // 4x5
}

const List<double> _identity = <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];

List<double> _satMatrix(double s) => <double>[
  .213 + .787 * s, .715 - .715 * s, .072 - .072 * s, 0, 0,
  .213 - .213 * s, .715 + .285 * s, .072 - .072 * s, 0, 0,
  .213 - .213 * s, .715 - .715 * s, .072 + .928 * s, 0, 0,
  0, 0, 0, 1, 0,
];

List<double> _contrastBrightness(double c, double b) {
  final off = 128 * (1 - c) + b * 255;
  return <double>[c, 0, 0, 0, off, 0, c, 0, 0, off, 0, 0, c, 0, off, 0, 0, 0, 1, 0];
}

// a بعد b (كلاهما 4x5)
List<double> _mulM(List<double> a, List<double> b) {
  final o = List<double>.filled(20, 0);
  for (int i = 0; i < 4; i++) {
    for (int j = 0; j < 5; j++) {
      double v = 0;
      for (int k = 0; k < 4; k++) { v += a[i * 5 + k] * b[k * 5 + j]; }
      if (j == 4) v += a[i * 5 + 4];
      o[i * 5 + j] = v;
    }
  }
  return o;
}

const List<_Preset> _presets = <_Preset>[
  _Preset('الأصلي', _identity),
  _Preset('أبيض وأسود', <double>[.213, .715, .072, 0, 0, .213, .715, .072, 0, 0, .213, .715, .072, 0, 0, 0, 0, 0, 1, 0]),
  _Preset('بني قديم', <double>[.393, .769, .189, 0, 0, .349, .686, .168, 0, 0, .272, .534, .131, 0, 0, 0, 0, 0, 1, 0]),
  _Preset('نابض', <double>[1.25, -.1, -.05, 0, 0, -.05, 1.2, -.05, 0, 0, -.05, -.1, 1.3, 0, 0, 0, 0, 0, 1, 0]),
  _Preset('دافئ', <double>[1.1, 0, 0, 0, 12, 0, 1.0, 0, 0, 0, 0, 0, .88, 0, -12, 0, 0, 0, 1, 0]),
  _Preset('بارد', <double>[.9, 0, 0, 0, -10, 0, 1, 0, 0, 0, 0, 0, 1.12, 0, 14, 0, 0, 0, 1, 0]),
  _Preset('باهت', <double>[.85, 0, 0, 0, 34, 0, .85, 0, 0, 34, 0, 0, .85, 0, 34, 0, 0, 0, 1, 0]),
  _Preset('درامي', <double>[1.35, 0, 0, 0, -45, 0, 1.35, 0, 0, -45, 0, 0, 1.35, 0, -45, 0, 0, 0, 1, 0]),
];

const List<Color> _palette = <Color>[
  Colors.white, Colors.black, Color(0xFFFF3B4E), Color(0xFFFF9A1F), Color(0xFFFFD21F),
  Color(0xFF2BE36B), Color(0xFF28C7FF), Color(0xFF3577FF), Color(0xFFB238FF), Color(0xFFFF6FB5),
];

const List<String> _stickers = <String>[
  '😀', '😂', '😍', '😎', '🥳', '😭', '😡', '🤔', '👍', '🙏', '👏', '🔥', '❤️', '💙', '💯', '✨',
  '🎉', '🎂', '🎁', '🌹', '🌙', '⭐', '☀️', '🌈', '🕌', '☕', '🍕', '⚽', '🚗', '✈️', '📍', '💬',
];

enum _Tool { crop, filters, adjust, draw, text }

class ImageEditorScreen extends StatefulWidget {
  const ImageEditorScreen({super.key, required this.path});
  final String path;
  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  final TransformationController _viewer = TransformationController();
  Size? _imageSize;
  bool _loadFailed = false;
  bool _saving = false;
  _Tool _tool = _Tool.crop;

  int _turns = 0;
  bool _flip = false;
  double? _ratio; // null = حسب الصورة

  int _preset = 0;
  double _brightness = 0; // -0.5..0.5
  double _contrast = 1; // 0.6..1.6
  double _saturation = 1; // 0..2

  final List<_Stroke> _strokes = <_Stroke>[];
  Color _penColor = Colors.white;
  double _penWidth = .012;

  final List<_Item> _items = <_Item>[];
  _Item? _selected;
  Size _frame = const Size(300, 400);
  double _baseScale = 1;
  double _baseRotation = 0;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  @override
  void dispose() {
    _viewer.dispose();
    super.dispose();
  }

  Future<void> _loadSize() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      if (mounted) setState(() => _imageSize = size);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Size get _rotatedSize {
    final s = _imageSize ?? const Size(1, 1);
    return _turns.isOdd ? Size(s.height, s.width) : s;
  }

  double get _frameAspect => _ratio ?? (_rotatedSize.width / _rotatedSize.height);

  List<double> get _matrix {
    var m = _presets[_preset].matrix;
    m = _mulM(_contrastBrightness(_contrast, _brightness), m);
    m = _mulM(_satMatrix(_saturation), m);
    return m;
  }

  void _resetViewer() => _viewer.value = Matrix4.identity();

  Future<void> _save() async {
    if (_saving) return;
    setState(() { _saving = true; _selected = null; });
    try {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final boundary = _boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final pr = (1440 / math.max(_frame.width, _frame.height)).clamp(1.0, 4.0).toDouble();
      final image = await boundary.toImage(pixelRatio: pr);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (data == null) throw Exception('تعذر قراءة الصورة');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final jpg = await compute(_encodeJpg, <String, Object>{'w': w, 'h': h, 'bytes': bytes});
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/edit_${DateTime.now().microsecondsSinceEpoch}.jpg');
      await file.writeAsBytes(jpg, flush: true);
      if (mounted) Navigator.of(context).pop(file.path);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        BlousabToast.show(context, 'تعذر حفظ التعديلات.');
      }
    }
  }

  // ----------------------------------------------------------------- النصوص
  Future<void> _addOrEditText([_Item? existing]) async {
    final controller = TextEditingController(text: existing?.text ?? '');
    Color color = existing?.color ?? Colors.white;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(existing == null ? 'إضافة نص' : 'تعديل النص'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: controller, autofocus: true, maxLines: 3, minLines: 1, maxLength: 120, decoration: const InputDecoration(hintText: 'اكتب هنا')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setD(() => color = c),
                  child: BlousabKeepColors(child: Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: color == c ? Colors.cyanAccent : Colors.white54, width: color == c ? 3 : 1)),
                  )),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تم')),
          ],
        ),
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (result != true || text.isEmpty) return;
    setState(() {
      if (existing != null) {
        existing.text = text;
        existing.color = color;
      } else {
        final item = _Item(text: text, color: color, size: 30);
        _items.add(item);
        _selected = item;
      }
    });
  }

  void _addSticker(String emoji) {
    setState(() {
      final item = _Item(text: emoji, color: Colors.white, size: 64, bold: false);
      _items.add(item);
      _selected = item;
    });
  }

  Future<void> _openStickers() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: GridView.count(
            shrinkWrap: true,
            crossAxisCount: 8,
            children: [
              for (final e in _stickers)
                InkWell(onTap: () => Navigator.pop(ctx, e), child: Center(child: Text(e, style: const TextStyle(fontSize: 28)))),
            ],
          ),
        ),
      ),
    );
    if (picked != null) _addSticker(picked);
  }

  // ----------------------------------------------------------------- الواجهة
  Widget _imageLayer() {
    final size = _imageSize!;
    final rot = _rotatedSize;
    Widget image = RotatedBox(
      quarterTurns: _turns % 4,
      child: SizedBox(width: size.width, height: size.height, child: Image.file(File(widget.path), fit: BoxFit.fill, gaplessPlayback: true)),
    );
    if (_flip) image = Transform(alignment: Alignment.center, transform: Matrix4.diagonal3Values(-1, 1, 1), child: image);
    final fitted = SizedBox.expand(
      child: FittedBox(fit: BoxFit.cover, clipBehavior: Clip.hardEdge, child: SizedBox(width: rot.width, height: rot.height, child: image)),
    );
    final interactive = _tool == _Tool.draw
        ? fitted
        : InteractiveViewer(transformationController: _viewer, minScale: 1, maxScale: 6, child: fitted);
    return ColorFiltered(colorFilter: ColorFilter.matrix(_matrix), child: interactive);
  }

  Widget _frameWidget() {
    return LayoutBuilder(builder: (context, box) {
      double w = box.maxWidth, h = box.maxHeight;
      final aspect = _frameAspect;
      if (w / h > aspect) { w = h * aspect; } else { h = w / aspect; }
      _frame = Size(w, h);
      return Center(
        child: SizedBox(
          width: w, height: h,
          child: BlousabKeepColors(
            child: RepaintBoundary(
              key: _boundaryKey,
              child: ClipRect(
                child: Container(
                  color: Colors.black,
                  child: Stack(fit: StackFit.expand, children: [
                    _imageLayer(),
                    Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _StrokePainter(_strokes)))),
                    if (_tool == _Tool.draw)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) {
                            final s = _Stroke(_penColor, _penWidth);
                            s.points.add(Offset(d.localPosition.dx / w, d.localPosition.dy / h));
                            setState(() => _strokes.add(s));
                          },
                          onPanUpdate: (d) {
                            if (_strokes.isEmpty) return;
                            setState(() => _strokes.last.points.add(Offset(d.localPosition.dx / w, d.localPosition.dy / h)));
                          },
                        ),
                      ),
                    for (final it in _items) _itemWidget(it, w, h),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _itemWidget(_Item it, double w, double h) {
    final selected = identical(_selected, it) && !_saving;
    return Positioned.fill(
      child: Align(
        alignment: Alignment(it.pos.dx * 2 - 1, it.pos.dy * 2 - 1),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selected = it),
          onDoubleTap: () { if (it.bold) _addOrEditText(it); },
          onScaleStart: (_) { _selected = it; _baseScale = it.scale; _baseRotation = it.rotation; },
          onScaleUpdate: (d) {
            setState(() {
              it.pos = Offset(
                (it.pos.dx + d.focalPointDelta.dx / w).clamp(0.0, 1.0).toDouble(),
                (it.pos.dy + d.focalPointDelta.dy / h).clamp(0.0, 1.0).toDouble(),
              );
              it.scale = (_baseScale * d.scale).clamp(.4, 6.0).toDouble();
              it.rotation = _baseRotation + d.rotation;
            });
          },
          child: Transform.rotate(
            angle: it.rotation,
            child: Transform.scale(
              scale: it.scale,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: selected ? BoxDecoration(border: Border.all(color: Colors.white70), borderRadius: BorderRadius.circular(6)) : null,
                child: Text(
                  it.text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: it.color, fontSize: it.size, fontWeight: it.bold ? FontWeight.w800 : FontWeight.w400, shadows: const [Shadow(color: Colors.black87, blurRadius: 6)]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 8),
    child: ChoiceChip(label: Text(label), selected: on, onSelected: (_) => onTap()),
  );

  Widget _slider(String label, double value, double min, double max, ValueChanged<double> onChanged) => Row(children: [
    SizedBox(width: 62, child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13))),
    Expanded(child: Slider(value: value.clamp(min, max).toDouble(), min: min, max: max, onChanged: onChanged)),
  ]);

  Widget _panel() {
    switch (_tool) {
      case _Tool.crop:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
            _chip('الأصلية', _ratio == null, () => setState(() { _ratio = null; _resetViewer(); })),
            _chip('1:1', _ratio == 1, () => setState(() { _ratio = 1; _resetViewer(); })),
            _chip('4:5', _ratio == 4 / 5, () => setState(() { _ratio = 4 / 5; _resetViewer(); })),
            _chip('3:4', _ratio == 3 / 4, () => setState(() { _ratio = 3 / 4; _resetViewer(); })),
            _chip('9:16', _ratio == 9 / 16, () => setState(() { _ratio = 9 / 16; _resetViewer(); })),
            _chip('4:3', _ratio == 4 / 3, () => setState(() { _ratio = 4 / 3; _resetViewer(); })),
            _chip('16:9', _ratio == 16 / 9, () => setState(() { _ratio = 16 / 9; _resetViewer(); })),
          ])),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(tooltip: 'تدوير لليسار', onPressed: () => setState(() { _turns = (_turns + 3) % 4; _resetViewer(); }), icon: const Icon(Icons.rotate_left_rounded, color: Colors.white)),
            IconButton(tooltip: 'تدوير لليمين', onPressed: () => setState(() { _turns = (_turns + 1) % 4; _resetViewer(); }), icon: const Icon(Icons.rotate_right_rounded, color: Colors.white)),
            IconButton(tooltip: 'قلب', onPressed: () => setState(() => _flip = !_flip), icon: const Icon(Icons.flip_rounded, color: Colors.white)),
            IconButton(tooltip: 'إعادة الضبط', onPressed: () => setState(() { _turns = 0; _flip = false; _ratio = null; _resetViewer(); }), icon: const Icon(Icons.restart_alt_rounded, color: Colors.white)),
          ]),
          const Text('حرّك الصورة بإصبع وكبّرها بإصبعين لاختيار منطقة القص.', style: TextStyle(color: Colors.white60, fontSize: 11.5)),
        ]);
      case _Tool.filters:
        return SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _presets.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) => GestureDetector(
              onTap: () => setState(() => _preset = i),
              child: Column(children: [
                Container(
                  width: 62, height: 62,
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: _preset == i ? Colors.cyanAccent : Colors.white24, width: _preset == i ? 2.5 : 1)),
                  clipBehavior: Clip.antiAlias,
                  child: BlousabKeepColors(child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(_presets[i].matrix),
                    child: Image.file(File(widget.path), fit: BoxFit.cover, cacheWidth: 160),
                  )),
                ),
                const SizedBox(height: 4),
                Text(_presets[i].name, style: TextStyle(color: _preset == i ? Colors.cyanAccent : Colors.white70, fontSize: 11.5)),
              ]),
            ),
          ),
        );
      case _Tool.adjust:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _slider('السطوع', _brightness, -.5, .5, (v) => setState(() => _brightness = v)),
          _slider('التباين', _contrast, .6, 1.6, (v) => setState(() => _contrast = v)),
          _slider('التشبع', _saturation, 0, 2, (v) => setState(() => _saturation = v)),
          TextButton(onPressed: () => setState(() { _brightness = 0; _contrast = 1; _saturation = 1; }), child: const Text('إعادة الضبط')),
        ]);
      case _Tool.draw:
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
              for (final c in _palette)
                GestureDetector(
                  onTap: () => setState(() => _penColor = c),
                  child: BlousabKeepColors(child: Container(
                    width: 30, height: 30, margin: const EdgeInsetsDirectional.only(end: 8),
                    decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: _penColor == c ? Colors.cyanAccent : Colors.white54, width: _penColor == c ? 3 : 1)),
                  )),
                ),
            ]))),
            IconButton(tooltip: 'تراجع', onPressed: _strokes.isEmpty ? null : () => setState(() => _strokes.removeLast()), icon: const Icon(Icons.undo_rounded, color: Colors.white)),
            IconButton(tooltip: 'مسح الرسم', onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear), icon: const Icon(Icons.delete_sweep_rounded, color: Colors.white)),
          ]),
          _slider('السماكة', _penWidth, .004, .04, (v) => setState(() => _penWidth = v)),
        ]);
      case _Tool.text:
        final sel = _selected;
        return Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 10, runSpacing: 6, alignment: WrapAlignment.center, children: [
            FilledButton.icon(onPressed: () => _addOrEditText(), icon: const Icon(Icons.title_rounded), label: const Text('إضافة نص')),
            FilledButton.icon(onPressed: _openStickers, icon: const Icon(Icons.emoji_emotions_outlined), label: const Text('ملصق')),
            if (sel != null && sel.bold) OutlinedButton.icon(onPressed: () => _addOrEditText(sel), icon: const Icon(Icons.edit_rounded), label: const Text('تعديل')),
            if (sel != null) OutlinedButton.icon(onPressed: () => setState(() { _items.remove(sel); _selected = null; }), icon: const Icon(Icons.delete_outline_rounded), label: const Text('حذف')),
          ]),
          const SizedBox(height: 4),
          const Text('اسحب العنصر لتحريكه، وبإصبعين للتكبير والتدوير.', style: TextStyle(color: Colors.white60, fontSize: 11.5)),
        ]);
    }
  }

  Widget _toolButton(_Tool t, IconData icon, String label) {
    final on = _tool == t;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() { _tool = t; if (t != _Tool.text) _selected = null; }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: on ? Colors.cyanAccent : Colors.white70, size: 25),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: on ? Colors.cyanAccent : Colors.white70, fontSize: 11, fontWeight: on ? FontWeight.w800 : FontWeight.w500)),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF05070D),
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: _saving ? null : () => Navigator.of(context).pop()),
        title: const Text('تعديل الصورة', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 10),
            child: _saving
                ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)))
                : FilledButton(onPressed: _imageSize == null ? null : _save, child: const Text('تم')),
          ),
        ],
      ),
      body: _loadFailed
          ? const Center(child: Text('تعذر فتح الصورة', style: TextStyle(color: Colors.white)))
          : _imageSize == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: Column(children: [
                    Expanded(child: Padding(padding: const EdgeInsets.all(8), child: _frameWidget())),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      color: const Color(0xFF0B1020),
                      child: _panel(),
                    ),
                    Container(
                      color: const Color(0xFF0B1020),
                      child: Row(children: [
                        _toolButton(_Tool.crop, Icons.crop_rounded, 'قص وتدوير'),
                        _toolButton(_Tool.filters, Icons.auto_awesome_rounded, 'فلاتر'),
                        _toolButton(_Tool.adjust, Icons.tune_rounded, 'ضبط'),
                        _toolButton(_Tool.draw, Icons.brush_rounded, 'رسم'),
                        _toolButton(_Tool.text, Icons.text_fields_rounded, 'نص وملصقات'),
                      ]),
                    ),
                  ]),
                ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);
  final List<_Stroke> strokes;
  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      if (s.points.isEmpty) continue;
      final paint = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = s.width * size.width;
      if (s.points.length == 1) {
        canvas.drawCircle(Offset(s.points.first.dx * size.width, s.points.first.dy * size.height), paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final path = Path()..moveTo(s.points.first.dx * size.width, s.points.first.dy * size.height);
      for (final p in s.points.skip(1)) { path.lineTo(p.dx * size.width, p.dy * size.height); }
      canvas.drawPath(path, paint);
    }
  }
  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}

// ===========================================================================
// محرر الفيديو
// ===========================================================================

class VideoEditorScreen extends StatefulWidget {
  const VideoEditorScreen({super.key, required this.path, required this.maxSeconds, required this.initialQuality});
  final String path;
  final int maxSeconds;
  final VideoQuality initialQuality;
  @override
  State<VideoEditorScreen> createState() => _VideoEditorScreenState();
}

class _VideoEditorScreenState extends State<VideoEditorScreen> {
  VideoPlayerController? _c;
  bool _ready = false;
  bool _failed = false;
  double _total = 1; // ثوانٍ
  RangeValues _range = const RangeValues(0, 1);
  bool _mute = false;
  late VideoQuality _quality;

  @override
  void initState() {
    super.initState();
    _quality = widget.initialQuality;
    final c = VideoPlayerController.file(File(widget.path));
    _c = c;
    c.initialize().then((_) {
      if (!mounted) return;
      final total = math.max(1.0, c.value.duration.inMilliseconds / 1000.0);
      setState(() {
        _total = total;
        _range = RangeValues(0, math.min(total, widget.maxSeconds.toDouble()));
        _ready = true;
      });
      c.setLooping(false);
      c.addListener(_onTick);
    }).catchError((_) { if (mounted) setState(() => _failed = true); });
  }

  void _onTick() {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position.inMilliseconds / 1000.0;
    if (c.value.isPlaying && pos >= _range.end) {
      c.pause();
      c.seekTo(Duration(milliseconds: (_range.start * 1000).round()));
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c?.removeListener(_onTick);
    _c?.dispose();
    super.dispose();
  }

  String _fmt(double s) {
    final m = s ~/ 60;
    final r = (s - m * 60);
    return '${m.toString().padLeft(2, '0')}:${r.toStringAsFixed(1).padLeft(4, '0')}';
  }

  Future<void> _togglePlay() async {
    final c = _c;
    if (c == null || !_ready) return;
    if (c.value.isPlaying) { await c.pause(); return; }
    final pos = c.value.position.inMilliseconds / 1000.0;
    if (pos < _range.start || pos >= _range.end - .05) await c.seekTo(Duration(milliseconds: (_range.start * 1000).round()));
    await c.setVolume(_mute ? 0 : 1);
    await c.play();
  }

  void _done() {
    final start = _range.start.floor();
    final end = _range.end.ceil();
    final duration = math.max(1, end - start);
    final trimmed = start > 0 || (_range.end < _total - .5);
    Navigator.of(context).pop(VideoEditResult(
      startSeconds: start,
      durationSeconds: math.min(duration, widget.maxSeconds),
      trimmed: trimmed || _total > widget.maxSeconds,
      mute: _mute,
      quality: _quality,
    ));
  }

  Widget _qualityChip(String label, VideoQuality q) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 8),
    child: ChoiceChip(label: Text(label), selected: _quality == q, onSelected: (_) => setState(() => _quality = q)),
  );

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final selectedLen = _range.end - _range.start;
    return Scaffold(
      backgroundColor: const Color(0xFF05070D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF05070D),
        leading: IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).pop()),
        title: const Text('تعديل الفيديو', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [Padding(padding: const EdgeInsetsDirectional.only(end: 10), child: FilledButton(onPressed: _ready ? _done : null, child: const Text('تم')))],
      ),
      body: _failed
          ? const Center(child: Text('تعذر فتح الفيديو', style: TextStyle(color: Colors.white)))
          : !_ready || c == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  child: Column(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: _togglePlay,
                        child: Center(
                          child: Stack(alignment: Alignment.center, children: [
                            BlousabKeepColors(child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
                            if (!c.value.isPlaying) const Icon(Icons.play_circle_fill_rounded, color: Colors.white70, size: 72),
                          ]),
                        ),
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      color: const Color(0xFF0B1020),
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(_fmt(_range.start), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                          Text('المدة المحددة: ${selectedLen.toStringAsFixed(1)} ث', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                          Text(_fmt(_range.end), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
                        ]),
                        RangeSlider(
                          values: _range,
                          min: 0,
                          max: _total,
                          onChanged: (v) {
                            var r = v;
                            if (r.end - r.start > widget.maxSeconds) {
                              // الحد الأقصى للمدة: حرّك الطرف الآخر
                              if (r.start != _range.start) { r = RangeValues(r.start, r.start + widget.maxSeconds); }
                              else { r = RangeValues(r.end - widget.maxSeconds, r.end); }
                            }
                            if (r.end - r.start < 1) return;
                            setState(() => _range = r);
                            c.seekTo(Duration(milliseconds: (r.start * 1000).round()));
                          },
                        ),
                        Text('الحد الأقصى ${widget.maxSeconds} ثانية', style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
                        const SizedBox(height: 6),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('كتم الصوت', style: TextStyle(color: Colors.white)),
                          secondary: Icon(_mute ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white70),
                          value: _mute,
                          onChanged: (v) { setState(() => _mute = v); c.setVolume(v ? 0 : 1); },
                        ),
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Row(children: [
                            const Text('الجودة:  ', style: TextStyle(color: Colors.white)),
                            _qualityChip('منخفضة', VideoQuality.LowQuality),
                            _qualityChip('متوسطة', VideoQuality.MediumQuality),
                            _qualityChip('عالية', VideoQuality.HighestQuality),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
                ),
    );
  }
}
