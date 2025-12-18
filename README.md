# BRIX (Truffle + Frontend)

هيكلة المشروع (مثل مثال counter):

- `contracts/` عقود Solidity
- `migrations/` ملفات نشر العقود (Truffle)
- `test/` اختبارات Truffle
- `truffle-config.js` إعدادات Truffle
- `frontend/` مشروع Next.js (الواجهة)

## تشغيل سريع (محلي)

### 1) تشغيل الشبكة المحلية (Ganache)
داخل مجلد `brix`:
```bash
npm install
npm run chain
```

### 2) نشر العقود (Truffle)
بترمينال ثاني داخل مجلد `brix`:
```bash
npm run migrate
```

### 3) تشغيل الواجهة (Next.js)
داخل مجلد `brix/frontend`:
```bash
cd frontend
npm install
npm run dev
```

بعد خطوة (2) ستجد العناوين مكتوبة تلقائياً هنا:
`frontend/src/config/deployments/local.json`
