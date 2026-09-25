# מדריך ומשימות להעלאת "שלט לפרסומוטו" ל-Google Play Store

מדריך צעד-אחר-צעד (Actionable Checklist) מקיף להפצת האפליקציה `Pirsumoto_remote_control` ב-Google Play Console.

---

## שלב 1: הכנת חתימת האפליקציה (Keystore & Release Signing)

1. [x] **הגדרת Keystore ייעודי וחתימת Release:**
   * קובץ ה-Keystore (`upload-keystore.jks`) וקובץ ההגדרות (`key.properties`) הוגדרו בפרויקט `Pirsumoto_remote_control`.
2. [x] **חיבור החתימה ב-`android/app/build.gradle.kts`:**
   * הוגדר בלוק `signingConfigs.create("release")` והוגדר `signingConfig = signingConfigs.getByName("release")` עבור גרסת ה-Release.

---

## שלב 2: בניית קובץ ה-Release Android App Bundle (.aab)

1. [x] **עדכון גרסה ב-`pubspec.yaml`:**
   * גרסה נוכחית: `version: 1.0.0+1`.
2. [x] **בניית ה-AAB:**
   * ה-Build הושלם בהצלחה!
   * **נתיב הקובץ המוכן להעלאה:**
     [`Pirsumoto_remote_control/build/app/outputs/bundle/release/app-release.aab`](file:///Users/jotit/Desktop/Pirsumoto/Pirsumoto_remote_control/build/app/outputs/bundle/release/app-release.aab)


---

## שלב 3: יצירת האפליקציה ב-Google Play Console

1. [ ] היכנסו ל-[Google Play Console](https://play.google.com/console).
2. [ ] לחצו על **Create App** (יצירת אפליקציה).
3. [ ] הגדירו את הפרטים הראשוניים:
   * **App name:** `שלט לפרסומוטו`
   * **Default language:** `Hebrew (he-IL)`
   * **App or Game:** `App`
   * **Free or Paid:** `Free`
4. [ ] אשרו את הצהרות המדיניות ולחצו על **Create App**.

---

## שלב 4: מילוי הגדרות תוכן האפליקציה (App Content & Policies)

בסרגל הצד, היכנסו ל-**App Content** והשלימו את כל השאלונים:
1. [ ] **Privacy Policy (מדיניות פרטיות):**
   הזינו את הקישור: `https://pirsumoto.katsoft.com/privacy`
2. [ ] **App Access (גישה לאפליקציה עבור בודקי גוגל):**
   בחרו ב-*All or some functionality is restricted* והזינו פרטי משתמש לבדיקה (Username/Password) עם הנחיות כניסה.
3. [ ] **Ads (פרסומות):**
   בחרו ב-*No, my app does not contain ads*.
4. [ ] **Content Rating (דירוג תוכן - IARC):**
   מלאו את השאלון (קטגוריית Utility/Business) לקבלת דירוג 3+ / לכל הגילאים.
5. [ ] **Target Audience (קהל יעד):**
   בחרו `18 and over` (שימוש עסקי B2B בלבד).
6. [ ] **Government Apps (אפליקציות ממשלתיות):**
   בחרו ב-*No, this app is not a government app*.
   *(הנתונים מ-data.gov.il מוצהרים בהתאם כמקור מידע פתוח בתיאור האפליקציה).*
7. [ ] **Financial Features:**
   סמנו *My app doesn't provide any financial features*.
8. [ ] **Data Safety (בטיחות נתונים):**
   הצהירו לפי הטבלה ב-[google_play_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/google_play_listing.md):
   * אודיו: נאסף לתמלול קולי (App Functionality), מוצפן, ניתן למחיקה.
   * תמונות: מועברות לצורך העלאת מודעות הרכב.
   * מזהי מכשיר: לצורך סנכרון עמדות שליטה.

---

## שלב 5: העלאת טקסטים ומדיה לדף החנות (Store Listing)

בסרגל הצד, עברו ל-**Grow > Store presence > Main store listing**:
1. [ ] **App Details:**
   * העתיקו את `App Name`, `Short Description` ו-`Full Description` מ-[google_play_listing.md](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/google_play_listing.md).
2. [ ] **App Icon:**
   העלו את הקובץ:
   `store_deployment_assets/android/icon/ic_launcher_512.png` *(512x512 PNG)*
3. [ ] **Feature Graphic:**
   העלו את הקובץ:
   `store_deployment_assets/android/feature_graphic/feature_graphic_1024x500.png` *(1024x500 PNG)*
4. [ ] **Phone Screenshots:**
   העלו את 8 צילומי המסך המעוצבים מהתיקייה:
   `store_deployment_assets/android/screenshots/` *(1080x2400 PNG)*
5. [ ] שמרו את השינויים (**Save**).

---

## שלב 6: העלאת ה-AAB והפצה (Testing & Production)

1. [ ] **Internal Testing (בדיקה פנימית):**
   * עברו ל-**Testing > Internal testing**.
   * צרו Release חדש והעלו את קובץ ה-`.aab`.
   * הוסיפו את רשימת בודקי הצוות (Email list) ובדקו את ההתקנה בפועל על מכשיר אנדרואיד.
2. [ ] **Production Track (שחרור לפרודקשן):**
   * לאחר אימות הבדיקה הפנימית, עברו ל-**Release > Production**.
   * לחצו על **Create new release** ובחרו את ה-AAB המאומת.
   * הזינו Release Notes (הערות גרסה).
   * לחצו על **Review release** ולאחר מכן **Start rollout to Production**.
3. [ ] המתינו לסיום סקירת גוגל (בדרך כלל 1-3 ימי עסקים).
