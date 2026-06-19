import Link from 'next/link';

export default function TermsPage() {
  return (
    <div className="min-h-screen bg-slate-50 flex flex-col justify-between">
      <header className="bg-white border-b border-slate-200 py-6 px-4">
        <div className="max-w-4xl mx-auto flex items-center justify-between">
          <Link href="/" className="text-blue-600 font-bold flex items-center gap-2 hover:underline">
            <span>→ חזרה לדף הבית</span>
          </Link>
          <span className="text-xl font-bold text-slate-900">תנאי שימוש - Terms of Service</span>
        </div>
      </header>

      <main className="max-w-4xl mx-auto bg-white my-12 p-8 sm:p-12 rounded-2xl border border-slate-200 shadow-sm leading-relaxed text-slate-700">
        <p className="text-xs text-slate-500 mb-6">עדכון אחרון: 19 ביוני 2026</p>

        <h1 className="text-3xl font-black mb-6 text-slate-900">תנאי שימוש במערכת ובמכשיר "מחירוטו"</h1>
        <p className="mb-4 leading-relaxed font-light">
          ברוכים הבאים למערכת מחירוטו (להלן: "המערכת"). השימוש במערכת, באפליקציה, במכשיר הסלולרי הייעודי המסופק על ידינו ובממשק ה-WhatsApp של המערכת, מוסדר תחת תנאי שימוש אלו. אנא קרא אותם בעיון.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">1. מהות השירות העסקי (B2B Only)</h2>
        <p className="mb-4 leading-relaxed font-light">
          מחירוטו היא פלטפורמה טכנולוגית המיועדת באופן בלעדי למגרשי רכב, סוכנויות רכב מורשות ועובדיהן בישראל. המערכת מספקת פתרון משולב של חומרה (מכשיר ייעודי מאובטח בשטח) ותוכנה המאפשרת לקלוט, לטייב, לארגן ולפרסם באופן אוטומטי נתוני רכבים ללוחות צד שלישי מורשים (יד2, קארוויז) ולאתר המגרש.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">2. הרשאה ושימוש מותר בממשק WhatsApp</h2>
        <p className="mb-3 leading-relaxed font-light">
          השימוש באינטגרציית ה-WhatsApp של המערכת כפוף למגבלות הבאות:
        </p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li>הגישה למספר ה-WhatsApp של המערכת מיועדת אך ורק לעובדים וסוכנים של מגרשי הרכב הלקוחות אשר אומתו מראש במערכות החברה.</li>
          <li>חל איסור מוחלט לעשות שימוש בממשק על מנת לשלוח הודעות שיווקיות, הודעות ספאם, דיוור ישיר, או כל תוכן שאינו קשור במישרין להזנת נתוני רכבי המגרש למלאי.</li>
          <li>המשתמש מצהיר כי כל הודעה קולית או תמונה הנשלחת לערוץ נועדה אך ורק לצורך תמלול, מיתוג ופרסום המודעה בלוחות המורשים.</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">3. קניין רוחני וזכויות במדיה</h2>
        <p className="mb-4 leading-relaxed font-light">מגרש הרכב המשתמש בשירות מצהיר כי הוא בעל הזכויות המלאות או בעל ההרשאה המתאימה בכל תמונה, קובץ שמע, או מידע אחר שהוא מזין למערכת. מחירוטו אינה טוענת לבעלות על המידע הגולמי, אך המגרש מעניק לה רישיון מוגבל לעבד, לשנות (להסיר רקע, להחיל לוגו) ולשדר את המדיה הזו לערוצי הפרסום הנבחרים.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">4. הגבלת אחריות לגבי לוחות צד שלישי</h2>
        <p className="mb-4 leading-relaxed font-light">העלאת המודעות בפועל תלויה בזמינות, בתנאים ובמנויים המשולמים שיש למגרש הרכב מול לוחות יד2 ו/או קארוויז. מחירוטו מספקת את צינור האוטומציה בלבד ואינה אחראית למדיניות החסימה, העריכה או התמחור של לוחות צד שלישי אלו.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">5. שינויים בתנאים וסיום התקשרות</h2>
        <p className="mb-4 leading-relaxed font-light">אנו שומרים לעצמנו את הזכות לעדכן תנאים אלו מעת לעת על מנת לעמוד בדרישות הציות המשתנות של פלטפורמת WhatsApp והחוק בישראל. הפרה של תנאים אלו, לרבות ניסיון לעשות שימוש במערכת כבוט שיחה פתוח או להפצת תוכן שאינו מלאי רכב, תביא לחסימה מיידית וקבועה של המגרש מהשירות.</p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-slate-900">6. סמכות שיפוט</h2>
        <p className="mb-4 leading-relaxed font-light">על תנאי שימוש אלו יחולו באופן בלעדי חוקי מדינת ישראל, ובתי המשפט המוסמכים במחוז חיפה והצפון יהיו בעלי סמכות השיפוט הבלעדית בכל מחלוקת הנובעת מהם.</p>
      </main>

      <footer className="bg-slate-900 text-slate-400 text-xs py-6 text-center border-t border-slate-800">
        <p>© 2026 מחירוטו. כל הזכויות שמורות. שימוש במערכת מהווה הסכמה לתנאי השירות לעיל.</p>
      </footer>
    </div>
  );
}
