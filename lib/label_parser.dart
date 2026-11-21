// Extracts product name candidates, batch no, mfg and expiry date from OCR text.
// Works on any product label (no barcode / SKU needed).
import 'dart:math';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class LabelData {
  final String? batch;
  final DateTime? mfg;
  final DateTime? exp;
  final String raw;
  LabelData({this.batch, this.mfg, this.exp, required this.raw});
  bool get isComplete => batch != null && exp != null;
}

/// Product name = the biggest text on the pack (brand/product name is printed largest).
/// Returns the top 3 candidates so the user can tap the right one the first time.
List<String> productNameCandidates(RecognizedText rt) {
  final lines = <TextLine>[];
  for (final b in rt.blocks) {
    for (final l in b.lines) {
      final letters = l.text.replaceAll(RegExp(r'[^A-Za-z]'), '');
      if (letters.length >= 3) lines.add(l);
    }
  }
  lines.sort((a, b) => b.boundingBox.height.compareTo(a.boundingBox.height));
  return lines.take(3).map((l) => l.text.trim()).toList();
}

// ---------------- Dates ----------------
const _mon = {
  'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
  'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
};

int _year(String y) => y.length == 2 ? 2000 + int.parse(y) : int.parse(y);
DateTime _lastDay(int y, int m) => DateTime(y, m + 1, 0);

/// Parses the first date in [s]. Month-only dates (05/26, MAY 2026) resolve to
/// the 1st for mfg and the last day of the month for expiry.
DateTime? parseDate(String s, {bool isExpiry = false}) {
  s = s.toUpperCase();

  // 12/05/2026  12.05.26  12-05-26
  var m = RegExp(r'(?<!\d)(\d{1,2})\s*[/.\-]\s*(\d{1,2})\s*[/.\-]\s*(\d{4}|\d{2})(?!\d)')
      .firstMatch(s);
  if (m != null) {
    final d = int.parse(m[1]!), mo = int.parse(m[2]!);
    if (d >= 1 && d <= 31 && mo >= 1 && mo <= 12) {
      return DateTime(_year(m[3]!), mo, d);
    }
  }

  // 12 MAY 2026 | MAY 2026 | MAY-26 | 12MAY26
  m = RegExp(r'(?:(\d{1,2})\s*[/.\-]?\s*)?(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)[A-Z]*\.?\s*[/.\-]?\s*(\d{4}|\d{2})(?!\d)')
      .firstMatch(s);
  if (m != null) {
    final mo = _mon[m[2]!]!, y = _year(m[3]!);
    if (m[1] != null) return DateTime(y, mo, int.parse(m[1]!));
    return isExpiry ? _lastDay(y, mo) : DateTime(y, mo, 1);
  }

  // 05/2026  05/26
  m = RegExp(r'(?<!\d)(\d{1,2})\s*[/.\-]\s*(\d{4}|\d{2})(?!\d)').firstMatch(s);
  if (m != null) {
    final mo = int.parse(m[1]!);
    if (mo >= 1 && mo <= 12) {
      final y = _year(m[2]!);
      return isExpiry ? _lastDay(y, mo) : DateTime(y, mo, 1);
    }
  }
  return null;
}

// Longest keys first so "EXPIRY DATE" wins over "EXP".
const _expKeys = ['EXPIRY DATE', 'EXP. DATE', 'EXP DATE', 'EXPIRY', 'USE BEFORE', 'USE BY', 'BEST BEFORE', 'EXP'];
const _mfgKeys = ['DATE OF MANUFACTURE', 'DATE OF MFG', 'MANUFACTURED ON', 'MFG. DATE', 'MFG DATE', 'PACKED ON', 'PKD ON', 'MFD', 'MFG', 'PKD', 'DOM'];
const _batchKeys = ['BATCH NO', 'BATCH NUMBER', 'BATCH', 'B. NO', 'B.NO', 'B NO', 'LOT NO', 'LOT'];

DateTime? _dateAfter(String t, List<String> keys, {required bool isExpiry}) {
  for (final k in keys) {
    var i = t.indexOf(k);
    while (i != -1) {
      final start = i + k.length;
      final end = min(t.length, start + 30);
      final d = parseDate(t.substring(start, end), isExpiry: isExpiry);
      if (d != null) return d;
      i = t.indexOf(k, i + 1);
    }
  }
  return null;
}

String? _batchAfter(String t) {
  final token = RegExp(r'^[\s:.\-#]*(?:NO\.?|NUMBER)?[\s:.\-#]*([A-Z0-9][A-Z0-9/\-]{2,15})');
  for (final k in _batchKeys) {
    var i = t.indexOf(k);
    while (i != -1) {
      final m = token.firstMatch(t.substring(i + k.length));
      // Batch must contain a digit, otherwise it's probably a word.
      if (m != null && RegExp(r'\d').hasMatch(m[1]!)) return m[1];
      i = t.indexOf(k, i + 1);
    }
  }
  return null;
}

LabelData parseLabel(String ocrText) {
  final t = ocrText.toUpperCase().replaceAll('\n', ' ');
  final mfg = _dateAfter(t, _mfgKeys, isExpiry: false);

  // Food packs often print "Best before 6 months from manufacture" instead of a date.
  DateTime? exp;
  final bb = RegExp(r'BEST\s*BEFORE\s*(\d{1,2})\s*MONTHS?').firstMatch(t);
  if (bb != null && mfg != null) {
    exp = DateTime(mfg.year, mfg.month + int.parse(bb[1]!), mfg.day);
  }
  exp ??= _dateAfter(t, _expKeys, isExpiry: true);

  return LabelData(batch: _batchAfter(t), mfg: mfg, exp: exp, raw: ocrText);
}
