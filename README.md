# FEFO Inventory: test build

**Flow:** Scan product name → scan batch/expiry → **Add to inventory**.
If that product already has stock with an **earlier expiry**, the app shows a pop-up telling staff to sell that older stock before the new item.

## Screens
- **Inventory:** stock grouped by product, earliest expiry on top with a **SELL FIRST** tag. Colour by expiry: red ≤ 30 days, orange ≤ 90 days, green otherwise. Tap ⊖ to record one unit sold.
- **Scan & Add:**
  1. *Scan product name:* on-device OCR picks the largest text on the pack and matches it to products already added. The first time, staff confirm the name.
  2. *Scan batch / expiry:* reads the batch number, MFG and EXP dates (all fields can be edited).
  3. *Add to inventory:* if the same batch and expiry already exist, the quantity is added to it. If older stock of that product expires sooner, the **"Sell older stock first"** pop-up appears.

## Setup
```bash
flutter create fefo_inventory && cd fefo_inventory
# copy lib/main.dart, lib/label_parser.dart, lib/stock_repo.dart into lib/
flutter pub add google_mlkit_text_recognition image_picker sqflite path intl
```
- `android/app/build.gradle`: `minSdkVersion 21`
- `AndroidManifest.xml`: `<uses-permission android:name="android.permission.CAMERA"/>`

```bash
flutter run   # or: flutter build apk --release
```

## Test (with a biscuit pack)
1. Scan the pack and its expiry, then add it (for example Exp 10/01/2027).
2. Scan the same product again and change the expiry to a later date (for example 10/04/2027), then add it.
3. The pop-up says: *Sell older stock first: Exp 10 Jan 2027*. In Inventory, the Jan batch has the **SELL FIRST** tag.

Dates it can read: `12/05/2026`, `12.05.26`, `05/2026`, `MAY 2026`, `12MAY26`, and "Best before N months from mfg".
