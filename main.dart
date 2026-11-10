import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MercadoApp());

// ---------- Utilidades ----------
String brl(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

double? parseNum(String s) {
  var t = s.trim();
  if (t.contains(',')) t = t.replaceAll('.', '').replaceAll(',', '.');
  return double.tryParse(t);
}

String fmtNum(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

// ---------- Modelo ----------
class Item {
  String name;
  double price;
  double qty;
  bool kg;
  Item(this.name, this.price, this.qty, this.kg);
  double get subtotal => (price * qty * 100).round() / 100;
  Map<String, dynamic> toJson() =>
      {'n': name, 'p': price, 'q': qty, 'k': kg};
  factory Item.fromJson(Map<String, dynamic> j) =>
      Item(j['n'], (j['p'] as num).toDouble(), (j['q'] as num).toDouble(), j['k']);
}

// ---------- Leitura por foto (ML Kit, roda no celular) ----------
final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
final _priceRe = RegExp(r'(\d{1,4})\s*[.,]\s*(\d{2})\b');

Future<RecognizedText?> readPhoto() async {
  final x = await ImagePicker()
      .pickImage(source: ImageSource.camera, imageQuality: 90);
  if (x == null) return null;
  return _recognizer.processImage(InputImage.fromFilePath(x.path));
}

class TagResult {
  String name;
  double? price;
  bool kg;
  TagResult(this.name, this.price, this.kg);
}

TagResult parseTag(RecognizedText t) {
  final lines = [for (final b in t.blocks) ...b.lines];
  final full = t.text.toUpperCase();

  // Etiquetas com "preço por litro/kg" em destaque: o preço do produto
  // é o MAIOR valor (ex: R$19,90 e "1 litro sai por 3,98").
  final hasPerUnit =
      RegExp(r'SAI POR|POR LITRO|POR KG|1 LITRO|1 KG|LITRO SAI').hasMatch(full);

  final cands = <MapEntry<double, double>>[]; // valor, altura do texto
  for (final l in lines) {
    for (final m in _priceRe.allMatches(l.text)) {
      final v = double.parse('${m[1]}.${m[2]}');
      if (v > 0) cands.add(MapEntry(v, l.boundingBox.height));
    }
  }
  double? price;
  if (cands.isNotEmpty) {
    if (hasPerUnit && cands.length > 1) {
      price = cands.map((e) => e.key).reduce((a, b) => a > b ? a : b);
    } else {
      cands.sort((a, b) => b.value.compareTo(a.value)); // maior fonte
      price = cands.first.key;
    }
  }

  final kg = RegExp(r'\d[.,]\d{2}\s*(/|P/)?\s*KG\b').hasMatch(full) &&
      !hasPerUnit;

  const stop = [
    'OFERTA', 'IMBAT', 'PRECO', 'PREÇO', 'PROMO', 'LEVE', 'PAGUE', 'VALIDA',
    'VÁLIDA', 'NESTA', 'EMBALAGEM', 'R\$', 'SAI POR'
  ];
  var name = '';
  for (final l in lines) {
    final u = l.text.toUpperCase();
    final letters = RegExp(r'[A-ZÀ-Ú]').allMatches(u).length;
    if (letters >= 4 &&
        !_priceRe.hasMatch(u) &&
        !stop.any((s) => u.contains(s))) {
      name = l.text.trim();
      break;
    }
  }
  return TagResult(name, price, kg);
}

double? parseTotal(RecognizedText t) {
  final lines = [for (final b in t.blocks) ...b.lines];
  double? pick(String s) {
    final m = _priceRe.firstMatch(s);
    return m == null ? null : double.parse('${m[1]}.${m[2]}');
  }

  for (var i = 0; i < lines.length; i++) {
    if (lines[i].text.toUpperCase().contains('TOTAL')) {
      final v = pick(lines[i].text) ??
          (i + 1 < lines.length ? pick(lines[i + 1].text) : null);
      if (v != null) return v;
    }
  }
  double? best;
  for (final l in lines) {
    final v = pick(l.text);
    if (v != null && (best == null || v > best)) best = v;
  }
  return best;
}

// ---------- App ----------
class MercadoApp extends StatelessWidget {
  const MercadoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Contas do Mercado',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF1F8A4C), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF1F8A4C),
            brightness: Brightness.dark,
            useMaterial3: true),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  List<Item> items = [];
  double? caixa;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('items');
    if (raw != null) {
      items = (jsonDecode(raw) as List)
          .map((e) => Item.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    caixa = sp.getDouble('caixa');
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('items', jsonEncode(items.map((e) => e.toJson()).toList()));
    if (caixa == null) {
      await sp.remove('caixa');
    } else {
      await sp.setDouble('caixa', caixa!);
    }
  }

  double get total => items.fold(0.0, (a, i) => a + i.subtotal);

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<RecognizedText?> _shoot() async {
    setState(() => busy = true);
    try {
      return await readPhoto();
    } catch (e) {
      _snack('Não consegui abrir a câmera.');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _photoTag() async {
    final t = await _shoot();
    if (t == null || !mounted) return;
    final r = parseTag(t);
    if (r.price == null) _snack('Não achei o preço. Confira e digite.');
    await _addDialog(name: r.name, price: r.price, kg: r.kg);
  }

  Future<void> _addDialog(
      {String name = '', double? price, bool kg = false}) async {
    final n = TextEditingController(text: name);
    final p = TextEditingController(text: price == null ? '' : fmtNum(price));
    final q = TextEditingController(text: kg ? '' : '1');
    var isKg = kg;
    final it = await showDialog<Item>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Confira e informe a quantidade'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: n,
                  decoration: const InputDecoration(labelText: 'Nome')),
              TextField(
                  controller: p,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: isKg ? 'Preço do kg (R\$)' : 'Preço (R\$)')),
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vendido por peso (kg)'),
                  value: isKg,
                  onChanged: (v) => set(() => isKg = v)),
              TextField(
                  controller: q,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText:
                          isKg ? 'Peso da balança (kg)' : 'Quantidade')),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  final pr = parseNum(p.text), qt = parseNum(q.text);
                  if (pr == null || qt == null || qt <= 0) return;
                  Navigator.pop(
                      c,
                      Item(n.text.trim().isEmpty ? 'Item' : n.text.trim(), pr,
                          qt, isKg));
                },
                child: const Text('Adicionar')),
          ],
        ),
      ),
    );
    if (it != null) {
      setState(() => items.insert(0, it));
      _save();
    }
  }

  Future<void> _caixaDialog(double? initial) async {
    final c = TextEditingController(text: initial == null ? '' : fmtNum(initial));
    final v = await showDialog<double>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Total do caixa'),
        content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'R\$')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, parseNum(c.text)),
              child: const Text('Conferir')),
        ],
      ),
    );
    if (v != null) {
      setState(() => caixa = v);
      _save();
    }
  }

  Future<void> _photoCaixa() async {
    final t = await _shoot();
    if (t == null || !mounted) return;
    await _caixaDialog(parseTotal(t));
  }

  Widget _result() {
    if (caixa == null || items.isEmpty) return const SizedBox.shrink();
    final d = ((caixa! - total) * 100).round() / 100;
    final bad = d > 0;
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: bad ? cs.errorContainer : cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          d > 0
              ? '⚠️ Caixa está ${brl(d)} MAIOR que seu cálculo'
              : d < 0
                  ? 'Caixa está ${brl(-d)} menor que seu cálculo'
                  : '✅ Valores batem certinho',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🛒 Contas do Mercado'), actions: [
        IconButton(
            tooltip: 'Limpar lista',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              setState(() {
                items.clear();
                caixa = null;
              });
              _save();
            }),
      ]),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(children: [
            Expanded(
                child: Text(brl(total),
                    style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary))),
            Text('${items.length} item(ns)'),
          ]),
        ),
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Toque em "Foto da etiqueta" para começar'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final it = items[i];
                    return Dismissible(
                      key: ValueKey(it.hashCode ^ i),
                      background: Container(color: Colors.red),
                      onDismissed: (_) {
                        setState(() => items.removeAt(i));
                        _save();
                      },
                      child: ListTile(
                        title: Text(it.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(it.kg
                            ? '${fmtNum(it.qty)} kg × ${brl(it.price)}/kg'
                            : '${it.qty % 1 == 0 ? it.qty.toInt() : it.qty} × ${brl(it.price)}'),
                        trailing: Text(brl(it.subtotal),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                    );
                  }),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _result()),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                  child: FilledButton.icon(
                      onPressed: busy ? null : _photoTag,
                      icon: const Icon(Icons.photo_camera),
                      label: const Text('Foto da etiqueta'))),
              const SizedBox(width: 8),
              IconButton.outlined(
                  tooltip: 'Adicionar manualmente',
                  onPressed: () => _addDialog(),
                  icon: const Icon(Icons.edit)),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                  onPressed: busy ? null : _photoCaixa,
                  icon: const Icon(Icons.point_of_sale),
                  label: const Text('Caixa')),
            ]),
          ),
        ),
      ]),
    );
  }
}
