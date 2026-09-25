# מדריך ומשימות להעלאת "שלט לפרסומוטו" ל-Apple App Store

מדריך צעד-אחר-צעד (Actionable Checklist) מקיף להפצת האפליקציה `Pirsumoto_remote_control` ב-Apple App Store Connect.

---

## שלב 1: הגדרות חשבון מפתח ו-Certificates ב-Apple Developer

1. [ ] **חשבון Apple Developer פעיל:**
   ודאו שחשבון המפתח של החברה פעיל ב-[developer.apple.com](https://developer.apple.com).
2. [ ] **רישום App ID (Bundle Identifier):**
   * היכנסו ל-**Certificates, Identifiers & Profiles > Identifiers**.
   * צרו App ID חדש:
     * **Description:** `Pirsumoto Remote Control`
     * **Bundle ID:** `com.pirsumoto.remote.pirsumoto_remote_control` (explicit)
   * סמנו Capabilities נדרשים: `Push Notifications`, `Sign in with Apple` (אם רלוונטי).
3. [ ] **יצירת תעודות הפצה (Distribution Certificate & Provisioning Profile):**
   * צרו **Apple Distribution Certificate**.
   * צרו **App Store Distribution Provisioning Profile** המקושר ל-App ID הנ"ל.

---

## שלב 2: יצירת רשומת האפליקציה ב-App Store Connect

1. [ ] היכנסו ל-[App Store Connect](https://appstoreconnect.apple.com).
2. [ ] עברו ל-**My Apps** ולחצו על כפתור **+ (New App)**.
3. [ ] מלאו את הפרטים:
   * **Platforms:** `iOS`
   * **Name:** `שלט לפרסומוטו`
   * **Primary Language:** `Hebrew`
   * **Bundle ID:** בחרו ב-`com.pirsumoto.remote.pirsumoto_remote_control`
   * **SKU:** `pirsumoto-remote-ios-01`
   * **User Access:** `Full Access`
4. [ ] לחצו **Create**.

---

## שלב 3: מילוי פרטי האפליקציה ומידע עסקי (App Information & Pricing)

1. [ ] **General > App Information:**
   * **Subtitle:** `בקרת פרסום וקליטת רכב`
   * **Category:** Primary: `Business`, Secondary: `Utilities`
   * **Privacy Policy URL:** `https://pirsumoto.katsoft.com/privacy`
2. [ ] **Pricing and Availability:**
   * **Price:** `Free` (Tier 0).
   * **Availability:** כל המדינות או בחירה ב-`Israel`.
3. [ ] **App Privacy (שאלון פרטיות אפל):**
   * ענו על השאלון בהתאם לפירוט ב-[apple_app_store_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/apple_app_store_listing.md) (Data Linked to You: Contact Info, User Content, Identifiers).

---

## שלב 4: מילוי עמוד גרסת האפליקציה (Version Information)

בדף הגרסה (למשל `1.0.0 Prepare for Submission`):
1. [ ] **App Store Screenshots:**
   * **6.7" Display (iPhone 16 Pro Max / 15 Pro Max):**
     העלו את 8 צילומי המסך המעוצבים מ-`store_deployment_assets/ios/screenshots_6_7/` *(1290x2796 PNG)*.
   * **6.5" Display (iPhone 11 Pro Max / XS Max):**
     העלו את 8 צילומי המסך מ-`store_deployment_assets/ios/screenshots_6_5/` *(1242x2688 PNG)*.
   * **13" iPad Display (iPad Pro 13" M4 / 12.9" 6th Gen):**
     העלו את 8 צילומי המסך מ-`store_deployment_assets/ios/screenshots_ipad_13/` *(2048x2732 PNG)*.

2. [ ] **Promotional Text:**
   העתיקו את הטקסט מ-[apple_app_store_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/apple_app_store_listing.md).
3. [ ] **Description:**
   העתיקו את התיאור המלא מ-[apple_app_store_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/apple_app_store_listing.md).
4. [ ] **Keywords:**
   `פרסומוטו,שלט רחוק,קליטת רכב,מגרש רכב,סוחר רכב,יד2,לוח רכב,רישוי,רכבים,data.gov.il,HITL,רכב`
5. [ ] **Support URL & Marketing URL:**
   `https://pirsumoto.katsoft.com`
6. [ ] **Copyright:**
   `© 2026 Pirsumoto (Katsoft Ltd)`
7. [ ] **App Store Icon:**
   ודאו שהאייקון מוטמע או העלו את `store_deployment_assets/ios/icon/app_store_icon_1024.png` *(1024x1024 PNG ללא שקיפות)*.

---

## שלב 5: הכנת פרטי הבדיקה עבור צוות Apple Review (קריטי למניעת דחייה)

תחת **App Review Information**:
1. [ ] **Sign-in required:** סמנו ב-`V`.
2. [ ] **User Name / Password:** הזינו שם משתמש וסיסמה לבודק של אפל (למשל `demo_tester@katsoft.com` וסיסמת בדיקה או קוד אימות).
3. [ ] **Notes (הערות לבודק):**
   העתיקו את מכתב ההסבר לבודק המופיע בסעיף 6 ב-[apple_app_store_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/apple_app_store_listing.md).
4. [ ] **Contact Information:** הזינו שם, טלפון וכתובת דוא"ל של איש הקשר הטכני (`aric@katsoft.com`).

---

## שלב 6: בנייה והעלאת Build (Xcode / Flutter / Transporter)

1. [ ] **עדכון גרסה ומספר Build:**
   ודאו שב-`Pirsumoto_remote_control/pubspec.yaml` הגרסה מוגדרת: `version: 1.0.0+1`.
2. [ ] **בניית הארכיב ב-Flutter:**
   ```bash
   cd /Users/jotit/Desktop/Pirsumoto/Pirsumoto_remote_control
   flutter clean
   flutter pub get
   flutter build ipa --release
   ```
3. [ ] **העלאה ל-App Store Connect:**
   * ניתן להשתמש באפליקציית **Apple Transporter** ולהעלות את קובץ ה-`.ipa` שנוצר ב-`build/ios/ipa/`.
   * לחלופין, פתחו את פרויקט ה-iOS ב-Xcode (`open ios/Runner.xcworkspace`), בחרו ב-**Product > Archive** ולחצו על **Distribute App > App Store Connect > Upload**.

---

## שלב 7: בדיקות ב-TestFlight והגשה לבדיקה (App Review)

1. [ ] המתינו לסיום עיבוד ה-Build ב-App Store Connect (מופיע בסטטוס *Ready to Submit*).
2. [ ] ב-TestFlight, בדקו את הגרסה על מכשיר אייפון אמיתי של אחד מאנשי הצוות.
3. [ ] חזרו לדף הגרסה של האפליקציה ב-App Store Connect ובחרו את ה-Build שהועלה.
4. [ ] ב-**Export Compliance Information** (הצהרת הצפנה): סמנו *No* (האפליקציה משתמשת בהצפנת רשת סטנדרטית HTTPS/TLS ואינה דורשת אישור הצפנה מיוחד).
5. [ ] לחצו על **Add for Review** ולאחר מכן **Submit to App Review**.
6. [ ] המתינו לאישור אפל (בדרך כלל תוך 24-48 שעות).
