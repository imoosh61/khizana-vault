# خِزانة (Khizana)

تطبيق iOS/iPadOS (iOS 16+) لحفظ الملاحظات والصور والفيديوهات محلياً، مع قفل Face ID/Touch ID ورمز احتياطي، ونسخ احتياطي مشفّر AES-GCM-256 إلى Google Drive.

## البناء
1. ارفع المشروع إلى GitHub (المستودع العام يعطي دقائق Actions مجانية).
2. شغّل workflow **Build IPA** من تبويب Actions، ثم نزّل `SecureVault-ipa`.
3. الـ IPA غير موقّع: ثبّته عبر Sideloadly أو AltStore أو TrollStore.

## إعداد Google Drive
1. في Google Cloud Console أنشئ مشروعاً وفعّل **Google Drive API**.
2. أنشئ **OAuth client ID** من نوع iOS وأدخل Bundle ID: `com.securevault.app`.
3. في `project.yml` استبدل `YOUR_CLIENT_ID` بالـ Client ID، و`YOUR_REVERSED_CLIENT_ID` بالمعكوس (`com.googleusercontent.apps.XXXX`).
4. الصلاحية المستخدمة: `drive.appdata` فقط (مجلد التطبيق المخفي).

## ملاحظات
- كلمة مرور النسخة الاحتياطية لا يمكن استرجاعها.
- الاستعادة تستبدل كل البيانات الحالية.
- لتغيير اللغة: إعدادات iOS ← التطبيق ← اللغة (ar, en, fr, es, tr, ur).
