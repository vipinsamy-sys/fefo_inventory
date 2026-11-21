// FEFO Inventory — scan product name + expiry, add to inventory,
// and suggest the earlier-expiry stock whenever a later-expiry item is added.
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'label_parser.dart';
import 'stock_repo.dart';

final repo = StockRepo();
final _fmt = DateFormat('dd MMM yyyy');
String fd(DateTime? d) => d == null ? '—' : _fmt.format(d);

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FEFO Inventory',
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      home: const InventoryScreen(),
    ));

// =====================================================================
// Inventory list: grouped by product, earliest expiry on top ("SELL FIRST")
// =====================================================================
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  List<StockItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await repo.inventory();
    if (mounted) setState(() => _items = items);
  }

  Color _expColor(int? days) {
    if (days == null) return Colors.grey;
    if (days < 0) return Colors.red.shade900;
    if (days <= 30) return Colors.red;
    if (days <= 90) return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final groups = <int, List<StockItem>>{};
    for (final i in _items) {
      groups.putIfAbsent(i.productId, () => []).add(i);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.document_scanner),
        label: const Text('Scan & Add'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const ScanAddScreen()));
          _load();
        },
      ),
      body: groups.isEmpty
          ? const Center(child: Text('No stock yet. Tap "Scan & Add".'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                for (final g in groups.values)
                  Card(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      ListTile(
                        title: Text(g.first.productName, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text('Total: ${g.fold<int>(0, (s, i) => s + i.qty)} units · ${g.length} batch(es)'),
                      ),
                      for (var k = 0; k < g.length; k++)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.circle, size: 14, color: _expColor(g[k].daysLeft)),
                          title: Text('Exp ${fd(g[k].exp)}  ·  Batch ${g[k].batch ?? '—'}'),
                          subtitle: Text('Qty ${g[k].qty} · added ${fd(g[k].addedAt)}'
                              '${g[k].daysLeft == null ? '' : ' · ${g[k].daysLeft! < 0 ? 'EXPIRED' : '${g[k].daysLeft} days left'}'}'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (k == 0 && g.length > 1)
                              const Chip(label: Text('SELL FIRST'), visualDensity: VisualDensity.compact),
                            IconButton(
                              tooltip: 'Sold 1',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () async {
                                await repo.deduct(g[k].id, 1);
                                _load();
                              },
                            ),
                          ]),
                        ),
                    ]),
                  ),
              ],
            ),
    );
  }
}

// =====================================================================
// Scan & Add: photo 1 = product name, photo 2 = batch / mfg / expiry
// =====================================================================
class ScanAddScreen extends StatefulWidget {
  const ScanAddScreen({super.key});
  @override
  State<ScanAddScreen> createState() => _ScanAddScreenState();
}

class _ScanAddScreenState extends State<ScanAddScreen> {
  final _picker = ImagePicker();
  final _ocr = TextRecognizer(script: TextRecognitionScript.latin);
  final _df = DateFormat('dd/MM/yyyy');

  final _nameCtl = TextEditingController();
  final _batchCtl = TextEditingController();
  final _mfgCtl = TextEditingController();
  final _expCtl = TextEditingController();
  final _qtyCtl = TextEditingController(text: '1');

  List<String> _candidates = [];
  bool _matched = false;
  bool _busy = false;

  @override
  void dispose() {
    _ocr.close();
    super.dispose();
  }

  Future<RecognizedText?> _capture() async {
    final x = await _picker.pickImage(source: ImageSource.camera, imageQuality: 95);
    if (x == null) return null;
    return _ocr.processImage(InputImage.fromFilePath(x.path));
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      _snack('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scanName() => _run(() async {
        final rt = await _capture();
        if (rt == null) return;
        _candidates = productNameCandidates(rt);
        final p = await repo.matchProduct(_candidates);
        _matched = p != null;
        _nameCtl.text = p?.name ?? (_candidates.isNotEmpty ? _candidates.first : '');
      });

  Future<void> _scanExpiry() => _run(() async {
        final rt = await _capture();
        if (rt == null) return;
        final l = parseLabel(rt.text);
        _batchCtl.text = l.batch ?? '';
        _mfgCtl.text = l.mfg == null ? '' : _df.format(l.mfg!);
        _expCtl.text = l.exp == null ? '' : _df.format(l.exp!);
        if (l.exp == null) _snack('Expiry not detected — retake closer or type it');
      });

  LabelData _label() => LabelData(
        batch: _batchCtl.text.trim().isEmpty ? null : _batchCtl.text.trim().toUpperCase(),
        mfg: parseDate(_mfgCtl.text),
        exp: parseDate(_expCtl.text, isExpiry: true),
        raw: '',
      );

  Future<void> _add() => _run(() async {
        final name = _nameCtl.text.trim();
        final l = _label();
        if (name.isEmpty) return _snack('Scan or type the product name');
        if (l.exp == null) return _snack('Scan or type the expiry date');

        final product = await repo.getOrCreateProduct(name, _candidates.take(1).toList());
        final id = await repo.addStock(product.id, l, int.tryParse(_qtyCtl.text) ?? 1);
        final earlier = await repo.earlierExpiry(product.id, l.exp, excludeId: id);

        if (!mounted) return;
        if (earlier.isNotEmpty) {
          await _showSuggestion(product.name, l.exp!, earlier);
        } else {
          _snack('Added ${product.name} · Exp ${fd(l.exp)}');
        }
        _reset();
      });

  Future<void> _showSuggestion(String name, DateTime newExp, List<StockItem> earlier) {
    return showDialog(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 40),
        title: const Text('Sell older stock first'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('New $name added (Exp ${fd(newExp)}).\n\nThese expire earlier — sell them before the new stock:'),
          const SizedBox(height: 8),
          for (final e in earlier)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.orange.shade50, borderRadius: BorderRadius.circular(6)),
              child: Text('Exp ${fd(e.exp)} · Batch ${e.batch ?? '—'} · ${e.qty} left\n'
                  'Added ${fd(e.addedAt)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
        ]),
        actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  void _reset() {
    for (final c in [_nameCtl, _batchCtl, _mfgCtl, _expCtl]) {
      c.clear();
    }
    _qtyCtl.text = '1';
    _candidates = [];
    _matched = false;
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan & Add')),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_busy) const LinearProgressIndicator(),
          FilledButton.icon(onPressed: _scanName, icon: const Icon(Icons.camera_alt), label: const Text('1. Scan product name')),
          TextField(
            controller: _nameCtl,
            decoration: InputDecoration(
              labelText: 'Product name',
              suffixIcon: _matched ? const Icon(Icons.verified, color: Colors.green) : null,
              helperText: _matched ? 'Matched existing product' : null,
            ),
            onChanged: (_) => setState(() => _matched = false),
          ),
          if (_candidates.length > 1)
            Wrap(spacing: 6, children: [
              for (final c in _candidates)
                ActionChip(label: Text(c), onPressed: () => setState(() { _nameCtl.text = c; _matched = false; })),
            ]),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: _scanExpiry, icon: const Icon(Icons.document_scanner), label: const Text('2. Scan batch / expiry')),
          TextField(controller: _batchCtl, decoration: const InputDecoration(labelText: 'Batch no')),
          Row(children: [
            Expanded(child: TextField(controller: _mfgCtl, decoration: const InputDecoration(labelText: 'Mfg (dd/mm/yyyy)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _expCtl, decoration: const InputDecoration(labelText: 'Expiry (dd/mm/yyyy)'))),
          ]),
          TextField(controller: _qtyCtl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity')),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: _add,
            child: const Text('Add to inventory', style: TextStyle(fontSize: 16)),
          ),
        ]),
      ),
    );
  }
}
