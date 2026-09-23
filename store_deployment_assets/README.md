# חבילת נכסי הפצה ומסמכי חנות לאפליקציית "שלט לפרסומוטו" (Pirsumoto Remote Control)

ערכת נכסים גרפיים מלאה, נתוני מטא-דאטה בעברית ובאנגלית, ורשימת משימות צעד-אחר-צעד להפצת האפליקציה ב-**Google Play Store** וב-**Apple App Store**.

---

## 📁 מבנה התיקיות והקבצים שנוצרו

```text
store_deployment_assets/
├── android/
│   ├── icon/
│   │   └── ic_launcher_512.png         # אייקון Google Play ברוחב 512x512
│   ├── feature_graphic/
│   │   └── feature_graphic_1024x500.png# באנר ראשי (Feature Graphic) 1024x500
│   └── screenshots/                   # 8 צילומי מסך מעוצבים בגודל 1080x2400
│       ├── 01_chat_intake.png
│       ├── 02_missing_fields.png
│       ├── 03_gov_data.png
│       ├── 04_remote_hitl.png
│       ├── 05_connected_devices.png
│       ├── 06_inventory.png
│       ├── 07_publish_queue.png
│       └── 08_secure_login.png
├── ios/
│   ├── icon/
│   │   └── app_store_icon_1024.png     # אייקון App Store ברוחב 1024x1024 (ללא שקיפות)
│   ├── screenshots_6_7/               # 8 צילומי מסך 1290x2796 (מסכי 6.7" Pro Max)
│   └── screenshots_6_5/               # 8 צילומי מסך 1242x2688 (מסכי 6.5")
├── metadata/
│   ├── google_play_listing.md         # שמות, תיאור קצר/מלא, סיווג והצהרת Data Safety
│   └── apple_app_store_listing.md     # שמות, כותרת משנה, מילות מפתח, הסבר לבודק אפל
└── checklists/
    ├── google_play_upload_tasks.md    # צ'קליסט משימות מלא ל-Google Play Console
    └── apple_app_store_upload_tasks.md# צ'קליסט משימות מלא ל-App Store Connect
```

---

## 🔗 קישורים ישירים למסמכים
* [Google Play Store Metadata](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/google_play_listing.md)
* [Apple App Store Metadata](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/metadata/apple_app_store_listing.md)
* [Google Play Deployment Checklist](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/checklists/google_play_upload_tasks.md)
* [Apple App Store Deployment Checklist](file:///Users/jotit/Desktop/Pirsumoto/store_deployment_assets/checklists/apple_app_store_upload_tasks.md)
