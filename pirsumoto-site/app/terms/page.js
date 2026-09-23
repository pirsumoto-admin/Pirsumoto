import Link from 'next/link';

export default function TermsPage() {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col justify-between">
      <header className="bg-slate-900 border-b border-slate-800 py-6 px-4">
        <div className="max-w-4xl mx-auto flex items-center justify-between">
          <Link href="/" className="text-blue-400 font-bold flex items-center gap-2 hover:underline">
            <span>→ חזרה לדף הבית</span>
          </Link>
          <span className="text-xl font-bold text-white">תנאי שימוש - Terms of Service</span>
        </div>
      </header>

      <main className="max-w-4xl mx-auto bg-slate-900 my-12 p-8 sm:p-12 rounded-2xl border border-slate-800 shadow-xl leading-relaxed text-slate-300">
        <p className="text-xs text-slate-400 mb-6">עדכון אחרון: 22 בספטמבר 2026</p>

        <h1 className="text-3xl font-black mb-6 text-white">תנאי שימוש במערכת ובמכשירי "פרסומוטו" (Pirsumoto)</h1>
        <p className="mb-4 leading-relaxed font-light">
          ברוכים הבאים למערכת פרסומוטו (להלן: "המערכת"). השימוש במערכת, באפליקציה הייעודית, במכשירי האנדרואיד הייעודיים המסופקים על ידינו ובממשקי השליטה מרחוק (Pirsumoto Relay), מוסדר תחת תנאי שימוש אלו. אנא קרא אותם בעיון.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">1. מהות השירות העסקי (B2B Only)</h2>
        <p className="mb-4 leading-relaxed font-light">
          פרסומוטו היא פלטפורמה טכנולוגית המיועדת באופן בלעדי למגרשי רכב, סוכנויות רכב מורשות ועובדיהן בישראל. המערכת מספקת פתרון משולב של חומרה (מכשירי שטח ייעודיים ומאובטחים) ותוכנה המאפשרת לקלוט, לאמת מול מאגרי ממשלה, לטייב תמונות, לשלוט מרחוק ולפרסם באופן אוטומטי נתוני רכבים ללוחות צד שלישי מורשים (Yad2, פייסבוק מרקטפלייס, CarWiz) ולאתרי המגרש.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">2. הרשאה ושימוש באפליקציה ובמכשירי השטח</h2>
        <p className="mb-3 leading-relaxed font-light">
          השימוש באפליקציה הייעודית ובמכשירי השטח כפוף לתנאים הבאים:
        </p>
        <ul className="list-disc pr-6 space-y-2 mb-4 font-light">
          <li>הגישה לאפליקציה ולמכשירי המגרש מיועדת אך ורק לעובדים וסוכנים מורשים שאומתו והוגדרו במערכות המגרש.</li>
          <li>המכשיר הייעודי נועד לשימוש תפעולי עסקי בלבד לקליטת מלאי רכב, הזנת נתונים ופרסום.</li>
          <li>כל הודעה, הקלטה קולית או תמונה המועלות למערכת נועדו לצורך זיהוי הרכב, מיתוג ופרסום המודעה בערוצים המורשים.</li>
        </ul>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">3. קניין רוחני וזכויות במדיה</h2>
        <p className="mb-4 leading-relaxed font-light">
          מגרש הרכב המשתמש בשירות מצהיר כי הוא בעל הזכויות המלאות או בעל ההרשאה המתאימה בכל תמונה, קובץ שמע או מידע שהוא מזין למערכת. פרסומוטו אינה טוענת לבעלות על המידע הגולמי, אך המגרש מעניק לה רישיון מוגבל לעבד, לשפר (הסרת רקע, שיפור AI, החלת לוגו) ולשדר את המדיה לערוצי הפרסום הנבחרים.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">4. שימוש בנתוני מאגרי מידע ממשלתיים</h2>
        <p className="mb-4 leading-relaxed font-light">
          נתוני הרכב הרשמיים, לרבות מפרט, תוקף טסט והיסטוריית בעלויות, נשאבים ממאגרי המידע הפתוחים של משרד התחבורה וממשלת ישראל (data.gov.il). המערכת מספקת שיקוף נתונים אמין כפי שהם מופיעים במאגר הרשמי בעת השאילתה.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">5. הגבלת אחריות לגבי לוחות צד שלישי</h2>
        <p className="mb-4 leading-relaxed font-light">
          העלאת המודעות בפועל תלויה בזמינות, בתנאים ובמנויים המשולמים שיש למגרש הרכב מול לוחות Yad2, פייסבוק ו/או CarWiz. פרסומוטו מספקת את צינור האוטומציה והקישור ואינה אחראית למדיניות העריכה, החסימה או התמחור של לוחות צד שלישי אלו.
        </p>

        <h2 className="text-xl font-bold mt-8 mb-4 text-white">6. שינויים בתנאים וסמכות שיפוט</h2>
        <p className="mb-4 leading-relaxed font-light">
          אנו שומרים לעצמנו את הזכות לעדכן תנאים אלו מעת לעת. על תנאי שימוש אלו יחולו באופן בלעדי חוקי מדינת ישראל, ובתי המשפט המוסמכים במחוז חיפה והמרכז יהיו בעלי סמכות השיפוט הבלעדית.
        </p>
      </main>

      <footer className="bg-slate-900 text-slate-400 text-xs py-6 text-center border-t border-slate-800">
        <p>© 2026 פרסומוטו (Pirsumoto). כל הזכויות שמורות. שימוש במערכת מהווה הסכמה לתנאי השירות לעיל.</p>
      </footer>
    </div>
  );
}
