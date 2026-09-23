import Link from 'next/link';

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col justify-between">
      <header className="bg-slate-900 border-b border-slate-800 py-6 px-4">
        <div className="max-w-4xl mx-auto flex items-center justify-between">
          <Link href="/" className="text-blue-400 font-bold flex items-center gap-2 hover:underline">
            <span>→ חזרה לדף הבית</span>
          </Link>
          <span className="text-xl font-bold text-white">מדיניות פרטיות - Privacy Policy</span>
        </div>
      </header>

      <main className="max-w-4xl mx-auto bg-slate-900 my-12 p-8 sm:p-12 rounded-2xl border border-slate-800 shadow-xl leading-relaxed text-slate-300">
        <p className="text-xs text-slate-400 mb-6">עדכון אחרון: 22 בספטמבר 2026</p>

        <h1 className="text-3xl font-black mb-6 text-white">מדיניות פרטיות עבור אפליקציית ומערכת "פרסומוטו" (Pirsumoto)</h1>
        <p className="mb-4 leading-relaxed font-light">
          חברת פרסומוטו (להלן: "החברה" או "אנחנו") מחויבת להגנה על הפרטיות ואבטחת המידע של המשתמשים העסקיים שלנו. המערכת פועלת ככלי עבודה פנימי ומאובטח (B2B) המיועד לניהול מלאי, עיבוד מדיה, שליטה מרחוק ופרסום רכבים עבור מגרשי רכב מורשים בישראל בלבד.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">1. המידע שאנו אוספים ומעבדים</h2>
        <p className="mb-3 leading-relaxed font-light">המערכת מעבדת נתונים תפעוליים פנימיים בלבד שנמסרים על ידי עובדי ומנהלי המגרש המורשים דרך האפליקציה הייעודית:</p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li><strong>פרטי מלאי רכב:</strong> מספר רישוי, שנת עלייה לכביש, חודש טסט, קילומטראז', יד, סוג בעלות, מחיר ותיאור הרכב.</li>
          <li><strong>נתוני מאגרי ממשלה (data.gov.il):</strong> פרטי מפרט טכני והיסטוריית בעלויות הנשאבים באופן אוטומטי ממאגרי המידע הממשלתיים הפתוחים של משרד התחבורה.</li>
          <li><strong>קבצי מדיה ותמונות:</strong> תמונות רכב המצולמות או מועלות על ידי נציגי המגרש לצורך עיבוד, הסרת רקע, שיפור AI והחלת מיתוג המגרש.</li>
          <li><strong>הקלטות קוליות:</strong> קבצי שמע של סוכני המגרש הנמסרים באפליקציה לצורך תמלול אוטומטי, חילוץ הפרטים והזנתם לשדות המערכת.</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">2. כיצד אנו משתמשים במידע</h2>
        <p className="mb-3 leading-relaxed font-light">המידע מעובד אך ורק למטרות הבאות:</p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li>אימות תפעולי פנימי של שלמות נתוני הרכב טרם פרסומו.</li>
          <li>פרסום אוטומטי של הרכב לפלטפורמות הלוחות המשולמים בישראל (כגון Yad2, פייסבוק מרקטפלייס ו-CarWiz) לפי בחירת והגדרות המגרש.</li>
          <li>שיפור איכות המדיה והתמונות באופן אוטומטי באמצעות מנועי AI לטובת מראה מקצועי.</li>
          <li>מתן תמיכה טכנית ושליטה מרחוק מאובטחת על מכשירי השטח של המגרש (Pirsumoto Relay).</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">3. שיתוף מידע עם צדדים שלישיים</h2>
        <p className="mb-4 leading-relaxed font-light">המידע אינו נמכר, אינו מושכר ואינו משותף עם גורמי צד שלישי למטרות שיווקיות. המידע מועבר אך ורק לצינורות הפרסום שהוגדרו מראש על ידי הלקוח העסקי (כגון פלטפורמות הלוחות Yad2, Facebook ו-CarWiz) לצורך ביצוע פעולת הפרסום שהיא לב ליבו של השירות.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">4. שימוש באפליקציה ייעודית ומכשירי שטח</h2>
        <p className="mb-4 leading-relaxed font-light">
          האפליקציה הייעודית משמשת אך ורק ככלי לקליטת נתונים וניהול מלאי (Data-Entry Workflow) עבור נציגי המגרש שהורשו מראש במערכת. המערכת אינה פונה מיוזמתה לצרכנים קצה ואינה מבצעת דיוור שיווקי המוני.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">5. אבטחת מידע והצפנה</h2>
        <p className="mb-4 leading-relaxed font-light">אנו מיישמים אמצעי אבטחה טכנולוגיים וארגוניים מתקדמים, כולל הצפנת נתונים בתעבורה (SSL/TLS) ובמנוחה, כדי להבטיח שפרטי המלאי, קבצי השמע והתמונות של המגרשים השותפים מוגנים לחלוטין מפני גישה לא מורשית.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">6. יצירת קשר</h2>
        <p className="mb-4 leading-relaxed font-light">לשאלות בנושא מדיניות הפרטיות או לבקשת עדכון נתונים, ניתן לפנות למחלקת הציות והטכנולוגיה שלנו בכתובת המייל: <code className="bg-slate-800 text-blue-300 px-2 py-0.5 rounded">aric@katsoft.com</code>.</p>
      </main>

      <footer className="bg-slate-900 text-slate-400 text-xs py-6 text-center border-t border-slate-800">
        <p>© 2026 פרסומוטו (Pirsumoto). כל הזכויות שמורות. מערכת B2B למגרשי רכב מורשים.</p>
      </footer>
    </div>
  );
}
