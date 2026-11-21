// Offline inventory: products (learned from OCR) + stock entries with expiry.
// FEFO: earliest expiry is always suggested first.
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'label_parser.dart';

class Product {
  final int id;
  final String name;
  Product(this.id, this.name);
}

class StockItem {
  final int id, productId, qty;
  final String productName;
  final String? batch;
  final DateTime? mfg, exp;
  final DateTime addedAt;
  StockItem.fromMap(Map<String, Object?> m)
      : id = m['id'] as int,
        productId = m['product_id'] as int,
        productName = (m['name'] as String?) ?? '',
        qty = m['qty'] as int,
        batch = m['batch'] as String?,
        mfg = _p(m['mfg']),
        exp = _p(m['exp']),
        addedAt = DateTime.parse(m['added_at'] as String);
  static DateTime? _p(Object? v) => v == null ? null : DateTime.parse(v as String);
  int? get daysLeft => exp?.difference(DateTime.now()).inDays;
}

String _d(DateTime d) => d.toIso8601String().substring(0, 10); // yyyy-mm-dd sorts correctly
String normalize(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

int _lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
    }
    prev = cur;
  }
  return prev[b.length];
}

double similarity(String a, String b) {
  a = normalize(a);
  b = normalize(b);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a.length >= 5 && b.length >= 5 && (a.contains(b) || b.contains(a))) return 0.9;
  return 1 - _lev(a, b) / max(a.length, b.length);
}

// Expiry NULL sorts last (unknown expiry should not be pushed first).
const _fefoOrder = 'CASE WHEN s.exp IS NULL THEN 1 ELSE 0 END, s.exp ASC, s.added_at ASC';

class StockRepo {
  Database? _db;

  Future<Database> get db async => _db ??= await openDatabase(
        p.join(await getDatabasesPath(), 'fefo_inventory.db'),
        version: 1,
        onCreate: (d, _) async {
          await d.execute('CREATE TABLE products(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL)');
          await d.execute('CREATE TABLE aliases(product_id INTEGER NOT NULL, alias TEXT NOT NULL)');
          await d.execute('''CREATE TABLE stock(
              id INTEGER PRIMARY KEY AUTOINCREMENT, product_id INTEGER NOT NULL,
              batch TEXT, mfg TEXT, exp TEXT, qty INTEGER NOT NULL, added_at TEXT NOT NULL)''');
          await d.execute('CREATE INDEX ix_stock_prod ON stock(product_id, exp)');
        },
      );

  // ---------- Products ----------
  /// Fuzzy-match OCR'd name candidates against known product names and past OCR spellings.
  Future<Product?> matchProduct(List<String> candidates, {double threshold = 0.8}) async {
    final rows = await (await db).rawQuery(
        'SELECT p.id, p.name, a.alias FROM products p LEFT JOIN aliases a ON a.product_id = p.id');
    Product? best;
    var bestScore = 0.0;
    for (final c in candidates) {
      for (final r in rows) {
        for (final ref in [r['name'] as String, (r['alias'] as String?) ?? '']) {
          final s = similarity(c, ref);
          if (s > bestScore) {
            bestScore = s;
            best = Product(r['id'] as int, r['name'] as String);
          }
        }
      }
    }
    return bestScore >= threshold ? best : null;
  }

  Future<Product> getOrCreateProduct(String name, List<String> ocrAliases) async {
    final existing = await matchProduct([name]);
    final d = await db;
    final prod = existing ?? Product(await d.insert('products', {'name': name.trim()}), name.trim());
    for (final a in ocrAliases) {
      final n = normalize(a);
      if (n.isEmpty) continue;
      final dup = await d.query('aliases', where: 'product_id = ? AND alias = ?', whereArgs: [prod.id, n]);
      if (dup.isEmpty) await d.insert('aliases', {'product_id': prod.id, 'alias': n});
    }
    return prod;
  }

  // ---------- Inventory ----------
  Future<int> addStock(int productId, LabelData l, int qty) async {
    final d = await db;
    // Same product + same batch + same expiry → just increase quantity.
    if (l.batch != null) {
      final same = await d.query('stock',
          where: "product_id = ? AND batch = ? AND IFNULL(exp, '') = ?",
          whereArgs: [productId, l.batch, l.exp == null ? '' : _d(l.exp!)]);
      if (same.isNotEmpty) {
        final id = same.first['id'] as int;
        await d.rawUpdate('UPDATE stock SET qty = qty + ? WHERE id = ?', [qty, id]);
        return id;
      }
    }
    return d.insert('stock', {
      'product_id': productId,
      'batch': l.batch,
      'mfg': l.mfg == null ? null : _d(l.mfg!),
      'exp': l.exp == null ? null : _d(l.exp!),
      'qty': qty,
      'added_at': DateTime.now().toIso8601String(),
    });
  }

  /// Stock of this product that expires BEFORE [exp] — this is what should be sold first.
  Future<List<StockItem>> earlierExpiry(int productId, DateTime? exp, {int? excludeId}) async {
    if (exp == null) return [];
    final r = await (await db).rawQuery('''
        SELECT s.*, p.name FROM stock s JOIN products p ON p.id = s.product_id
        WHERE s.product_id = ? AND s.qty > 0 AND s.exp IS NOT NULL AND s.exp < ?
          AND s.id <> ?
        ORDER BY $_fefoOrder''', [productId, _d(exp), excludeId ?? -1]);
    return r.map(StockItem.fromMap).toList();
  }

  /// All in-stock items, grouped by product, earliest expiry first.
  Future<List<StockItem>> inventory() async {
    final r = await (await db).rawQuery('''
        SELECT s.*, p.name FROM stock s JOIN products p ON p.id = s.product_id
        WHERE s.qty > 0 ORDER BY p.name COLLATE NOCASE, $_fefoOrder''');
    return r.map(StockItem.fromMap).toList();
  }

  Future<void> deduct(int stockId, int n) async {
    await (await db).rawUpdate('UPDATE stock SET qty = MAX(qty - ?, 0) WHERE id = ?', [n, stockId]);
  }
}
