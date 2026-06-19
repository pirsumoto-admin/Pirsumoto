import Link from 'next/link';

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-slate-50 flex flex-col justify-between">
      <header className="bg-white border-b border-slate-200 py-6 px-4">
        <div className="max-w-4xl mx-auto flex items-center justify-between">
          <Link href="/" className="text-blue-600 font-bold flex items-center gap-2 hover:underline">
            <span>→ חזרה לדף הבית</span>
          </Link>
          <span className="text-xl font-bold text-slate-900">מדיניות פרטיות - Privacy Policy</span>
        </div>
      </header>

      <main className="max-w-4xl mx-auto bg-white my-12 p-8 sm:p-12 rounded-2xl border border-slate-200 shadow-sm leading-relaxed text-slate-700">
        <p className="text-xs text-slate-500 mb-6">עדכון אחרון: 19 ביוני 2026</p>

        <h1 className="text-3xl font-black mb-6 text-slate-900">מדיניות פרטיות עבור אפליקציית וממשק "מחירוטו"</h1>
        <p className="mb-4 leading-relaxed font-light">
          חברת מחירוטו (להלן: "החברה" או "אנחנו") מחויבת להגנה על הפרטיות ואבטחת המידע של המשתמשים העסקיים שלנו. המערכת פועלת ככלי עבודה פנימי ומאובטח (B2B) המיועד לניהול מלאי, עיבוד מדיה ופרסום רכבים עבור מגרשי רכב מורשים בישראל בלבד.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">1. המידע שאנו אוספים ומעבדים</h2>
        <p className="mb-3 leading-relaxed font-light">המערכת שלנו מעבדת נתונים תפעוליים פנימיים בלבד שנמסרים על ידי עובדי ומנהלי המגרש המורשים:</p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li><strong>פרטי מלאי רכב:</strong> מספר רישוי, שנת עלייה לכביש, חודש טסט, קילומטראז', יד, סוג בעלות, מחיר ותיאור הרכב.</li>
          <li><strong>קבצי מדיה:</strong> תמונות רכב המצולמות על ידי נציגי המגרש לצורך עיבוד, הסרת רקע והחלת תבניות מיתוג של המגרש.</li>
          <li><strong>הודעות קוליות (וואטסאפ):</strong> קבצי שמע של סוכני המגרש הנשלחים לערוץ ה-API הייעודי שלנו לצורך תמלול אוטומטי, חילוץ הפרטים והזנתם לשדות ה-CRM של המגרש בלבד.</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">2. כיצד אנו משתמשים במידע</h2>
        <p className="mb-3 leading-relaxed font-light">המידע מעובד אך ורק למטרות הבאות:</p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li>אימות תפעולי פנימי של שלמות נתוני הרכב טרם פרסומו.</li>
          <li>פרסום אוטומטי של הרכב לפלטפורמות הלוחות המשולמים בישראל (כגון יד2, קארוויז) ולפי בחירת והגדרות המגרש.</li>
          <li>שיפור איכות המדיה והתמונות באופן אוטומטי לטובת מראה מקצועי באתרי הלוחות.</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">3. שיתוף מידע עם צדדים שלישיים</h2>
        <p className="mb-4 leading-relaxed font-light">המידע אינו נמכר, אינו מושכר ואינו משותף עם גורמי צד שלישי למטרות שיווקיות. המידע מועבר אך ורק לצינורות הפרסום שהוגדרו מראש על ידי הלקוח העסקי (כגון פלטפורמות הלוחות Yad2 ו-CarWiz) לצורך ביצוע פעולת הפרסום שהיא לב ליבו של השירות.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">4. שימוש ב-WhatsApp Business API</h2>
        <p className="mb-4 leading-relaxed font-light">
          ממשק ה-WhatsApp שלנו פועל תחת כללי הציות הקשיחים של Meta. הממשק משמש אך ורק ככלי לקליטת נתונים (Data-Entry Workflow) עבור נציגי המגרש שהורשו מראש במערכת. המערכת אינה פונה מיוזמתה לצרכנים, אינה שולחת הודעות שיווקיות, ואינה מבצעת דיוור ישיר לקהל הרחב.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">5. אבטחת מידע</h2>
        <p className="mb-4 leading-relaxed font-light">אנו מיישמים אמצעי אבטחה טכנולוגיים וארגוניים מתקדמים, כולל הצפנת נתונים בתעבורה (SSL/TLS) ובמנוחה, כדי להבטיח שפרטי המלאי, קבצי השמע והתמונות של המגרשים השותפים מוגנים לחלוטין מפני גישה לא מורשית.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">6. יצירת קשר</h2>
        <p className="mb-4 leading-relaxed font-light">لשאלות בנושא מדיניות הפרטיות או לבקשת הסרת נתונים, ניתן לפנות למחלקת הציות והטכנולוגיה שלנו בכתובת המייל: <code className="bg-slate-100 text-slate-800 px-1.5 py-0.5 rounded">aric@katsoft.com</code>.</p>
      </main>

      <footer className="bg-slate-900 text-slate-400 text-xs py-6 text-center border-t border-slate-800">
        <p>© 2026 מחירוטו. כל הזכויות שמורות. נבנה בהתאמה מלאה למדיניות Meta Developer Policy.</p>
      </footer>
    </div>
  );
}
