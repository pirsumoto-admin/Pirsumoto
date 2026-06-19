import Image from 'next/image';
import Link from 'next/link';

export default function HomePage() {
  return (
    <div className="min-h-screen flex flex-col justify-between">
      {/* upper header navigation */}
      <header className="bg-white/80 backdrop-blur-md border-b border-slate-200 sticky top-0 z-50 transition-all duration-300">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Image
              src="/logo.png"
              alt="לוגו מחירוטו"
              width={48}
              height={48}
              className="h-12 w-12 rounded-xl object-cover shadow-sm ring-1 ring-slate-100"
              priority
            />
            <span className="text-2xl font-black bg-gradient-to-l from-blue-600 to-indigo-600 bg-clip-text text-transparent">מחירוטו</span>
          </div>
          <nav className="hidden md:flex items-center gap-8 font-medium text-slate-600">
            <a href="#solution" className="hover:text-blue-600 transition-colors">הפתרון שלנו</a>
            <a href="#whatsapp" className="hover:text-blue-600 transition-colors">ממשק WhatsApp</a>
            <a href="#features" className="hover:text-blue-600 transition-colors">יכולות מערכת</a>
          </nav>
          <div>
            <span className="bg-slate-100 text-slate-800 text-xs font-bold px-3 py-1.5 rounded-full uppercase tracking-wider border border-slate-200 shadow-sm">B2B בלבד</span>
          </div>
        </div>
      </header>

      {/* Hero Section */}
      <section className="relative bg-gradient-to-br from-slate-900 via-indigo-950 to-slate-900 text-white py-24 px-4 overflow-hidden">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_top_right,rgba(59,130,246,0.15),transparent_50%)]"></div>
        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center relative z-10">
          <div className="lg:col-span-7 space-y-6 text-center lg:text-right">
            <h1 className="text-4xl sm:text-5xl lg:text-6xl font-black leading-none tracking-tight">
              הופכים את קליטת הרכב במגרש <br />
              <span className="bg-gradient-to-l from-blue-400 to-indigo-400 bg-clip-text text-transparent">לאוטומציה מלאה</span>
            </h1>
            <p className="text-lg sm:text-xl text-slate-300 max-w-2xl mx-auto lg:mx-0 font-light leading-relaxed">
              מכשיר סמארטפון ייעודי ומאובטח המוענק למגרשי רכב בישראל, המאפשר לסוכנים בשטח לקלוט רכבים, לשפר תמונות באופן אוטומטי ולפרסם בלחיצת כפתור אחת ל-Yad2, CarWiz ואתרי החברה.
            </p>
            <div className="pt-4 flex flex-wrap justify-center lg:justify-start gap-4">
              <a href="#solution" className="bg-blue-600 hover:bg-blue-500 text-white font-bold px-8 py-4 rounded-xl transition-all shadow-lg shadow-blue-600/30 hover:scale-[1.02] active:scale-[0.98]">גלה את הפתרון</a>
              <a href="#whatsapp" className="bg-white/10 hover:bg-white/15 text-white font-medium px-8 py-4 rounded-xl backdrop-blur-sm transition-all border border-white/10 hover:scale-[1.02] active:scale-[0.98]">תהליך עבודה בוואטסאפ</a>
            </div>
          </div>
          <div className="lg:col-span-5 flex justify-center relative">
            <div className="w-72 h-[580px] bg-slate-800 rounded-[40px] p-3 shadow-2xl border-4 border-slate-700/50 relative overflow-hidden ring-1 ring-white/10 transition-transform duration-500 hover:scale-[1.03]">
              <Image
                src="/screenshot-list.png"
                alt="רשימת רכבים במחירוטו"
                width={288}
                height={580}
                className="w-full h-full object-cover rounded-[32px]"
                priority
              />
            </div>
          </div>
        </div>
      </section>

      {/* Solution Section */}
      <section id="solution" className="py-24 bg-white px-4">
        <div className="max-w-7xl mx-auto">
          <div className="text-center max-w-3xl mx-auto space-y-4 mb-16">
            <h2 className="text-3xl sm:text-4xl font-black text-slate-900">פתרון חומרה ותוכנה משולב למגרשים</h2>
            <p className="text-slate-600 text-lg">אנחנו מספקים למגרש מכשיר חכם ייעודי המיועד אך ורק למשימות תפעוליות וניהול המלאי.</p>
          </div>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div className="bg-slate-50 p-8 rounded-2xl border border-slate-200 shadow-sm space-y-4 hover:shadow-md transition-shadow duration-300">
              <div className="h-12 w-12 rounded-xl bg-blue-100 text-blue-600 flex items-center justify-center text-2xl font-bold">01</div>
              <h3 className="text-xl font-bold text-slate-900">מכשיר ייעודי בשטח</h3>
              <p className="text-slate-600 leading-relaxed font-light">הסוכנים במגרש מקבלים סמארטפון ארגוני מוגן, דרכו הם מצלמים ומזינים את הרכבים החדשים שהגיעו למלאי ישירות ל-CRM.</p>
            </div>
            <div className="bg-slate-50 p-8 rounded-2xl border border-slate-200 shadow-sm space-y-4 hover:shadow-md transition-shadow duration-300">
              <div className="h-12 w-12 rounded-xl bg-blue-100 text-blue-600 flex items-center justify-center text-2xl font-bold">02</div>
              <h3 className="text-xl font-bold text-slate-900">שיפור תמונות מבוסס AI</h3>
              <p className="text-slate-600 leading-relaxed font-light">המערכת מעבדת את תמונות הרכב באופן אוטומטי, מנקה רקעים לא מקצועיים ומחילה תבניות מיתוג מותאמות אישית של המגרש.</p>
            </div>
            <div className="bg-slate-50 p-8 rounded-2xl border border-slate-200 shadow-sm space-y-4 hover:shadow-md transition-shadow duration-300">
              <div className="h-12 w-12 rounded-xl bg-blue-100 text-blue-600 flex items-center justify-center text-2xl font-bold">03</div>
              <h3 className="text-xl font-bold text-slate-900">פרסום רב-ערוצי מיידי</h3>
              <p className="text-slate-600 leading-relaxed font-light">אינטגרציה מלאה לפלטפורמות המובילות בישראל כמו Yad2 ו-CarWiz. מזינים פעם אחת - והמודעה עולה בכל מקום במקביל.</p>
            </div>
          </div>
        </div>
      </section>

      {/* WhatsApp Integration Section */}
      <section id="whatsapp" className="py-24 bg-slate-100 px-4 border-y border-slate-200">
        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center">
          <div className="lg:col-span-5 order-last lg:order-first flex justify-center gap-4">
            <div className="w-64 h-[500px] bg-slate-800 rounded-[36px] p-2.5 shadow-xl border-4 border-slate-700/50 overflow-hidden mt-8 transition-transform duration-500 hover:scale-[1.03]">
              <Image
                src="/screenshot-voice.png"
                alt="הקלטה קולית חכמה"
                width={256}
                height={500}
                className="w-full h-full object-cover rounded-[28px]"
              />
            </div>
            <div className="w-64 h-[500px] bg-slate-800 rounded-[36px] p-2.5 shadow-xl border-4 border-slate-700/50 overflow-hidden transition-transform duration-500 hover:scale-[1.03]">
              <Image
                src="/screenshot-settings.png"
                alt="הגדרות ערוצי פרסום"
                width={256}
                height={500}
                className="w-full h-full object-cover rounded-[28px]"
              />
            </div>
          </div>
          <div className="lg:col-span-7 space-y-6">
            <span className="bg-emerald-100 text-emerald-800 text-xs font-bold px-3 py-1.5 rounded-full uppercase tracking-wider border border-emerald-200">אינטגרציה פנימית קשיחה (Internal Integration)</span>
            <h2 className="text-3xl sm:text-4xl font-black text-slate-900">ממשק הזנת נתונים מאובטח דרך WhatsApp API</h2>
            <p className="text-slate-600 text-lg font-light leading-relaxed">
              מכיוון ש-WhatsApp הוא כלי העבודה המרכזי והטבעי ביותר של סוכני הרכב בישראל, פיתחנו צינור נתונים ייעודי ומאובטח המיועד לעובדי המגרש בלבד.
            </p>
            <div className="space-y-4 text-slate-700 font-light">
              <div className="flex items-start gap-3">
                <div className="h-6 w-6 rounded-full bg-emerald-500 text-white flex items-center justify-center text-xs font-bold mt-1 shrink-0">✓</div>
                <p><strong>הקלטה ותמלול:</strong> סוכן המגרש מקליט הודעה קולית קצרה עם פרטי הרכב שהגיע (מספר רישוי, קילומטראז', יד ומחיר). המערכת מתמללת ומעבדת את המידע ישירות לתוך שדות ה-CRM.</p>
              </div>
              <div className="flex items-start gap-3">
                <div className="h-6 w-6 rounded-full bg-emerald-500 text-white flex items-center justify-center text-xs font-bold mt-1 shrink-0">✓</div>
                <p><strong>אימות שדות אוטומטי:</strong> במידה וחסרים נתונים קריטיים, המערכת משיבה לסוכן בבקשה להשלמת הפרטים החסרים עד לנעילת טופס הרכב בצורה תפעולית מאובטחת.</p>
              </div>
              <div className="flex items-start gap-3">
                <div className="h-6 w-6 rounded-full bg-emerald-500 text-white flex items-center justify-center text-xs font-bold mt-1 shrink-0">✓</div>
                <p><strong>סנכרון מדיה מהיר:</strong> הסוכן שולח את תמונות הרכב הגולמיות מהמגרש, המערכת משפרת אותן ברקע, ומזניקה את המודעה לפרסום באתרי הלוחות המשולמים.</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Screen Gallery Section */}
      <section id="features" className="py-24 bg-white px-4">
        <div className="max-w-7xl mx-auto space-y-16">
          <div className="text-center max-w-2xl mx-auto space-y-4">
            <h2 className="text-3xl font-black text-slate-900">ניהול ובקרה מלאה בכף היד</h2>
            <p className="text-slate-600 font-light">ממשק משתמש קל, נקי ומהיר המותאם לעבודה אינטנסיבית במגרש.</p>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-8 justify-items-center">
            <div className="space-y-3 text-center group">
              <div className="w-64 h-[500px] bg-slate-800 rounded-[36px] p-2.5 shadow-md border border-slate-200 overflow-hidden transition-all duration-300 group-hover:shadow-xl group-hover:scale-[1.02]">
                <Image
                  src="/screenshot-add.png"
                  alt="טופס הוספת רכב"
                  width={256}
                  height={500}
                  className="w-full h-full object-cover rounded-[28px]"
                />
              </div>
              <h4 className="font-bold text-slate-900 transition-colors group-hover:text-blue-600">הוספת פרטים ידנית מהירה</h4>
            </div>
            <div className="space-y-3 text-center group">
              <div className="w-64 h-[500px] bg-slate-800 rounded-[36px] p-2.5 shadow-md border border-slate-200 overflow-hidden transition-all duration-300 group-hover:shadow-xl group-hover:scale-[1.02]">
                <Image
                  src="/screenshot-details.png"
                  alt="פרטי מודעה מלאים"
                  width={256}
                  height={500}
                  className="w-full h-full object-cover rounded-[28px]"
                />
              </div>
              <h4 className="font-bold text-slate-900 transition-colors group-hover:text-blue-600">שליטה מלאה בפרטי הרכב</h4>
            </div>
            <div className="space-y-3 text-center group">
              <div className="w-64 h-[500px] bg-slate-800 rounded-[36px] p-2.5 shadow-md border border-slate-200 overflow-hidden transition-all duration-300 group-hover:shadow-xl group-hover:scale-[1.02]">
                <Image
                  src="/screenshot-settings.png"
                  alt="הגדרות רקעים וערוצים"
                  width={256}
                  height={500}
                  className="w-full h-full object-cover rounded-[28px]"
                />
              </div>
              <h4 className="font-bold text-slate-900 transition-colors group-hover:text-blue-600">תבניות רקע ואפשרויות הפצה</h4>
            </div>
          </div>
        </div>
      </section>

      {/* Footer Section */}
      <footer className="bg-slate-950 text-slate-400 py-12 px-4 border-t border-slate-900">
        <div className="max-w-7xl mx-auto flex flex-col md:flex-row items-center justify-between gap-6 border-b border-slate-900 pb-8 mb-8">
          <div className="flex items-center gap-3">
            <Image
              src="/logo.png"
              alt="לוגו מחירוטו"
              width={40}
              height={40}
              className="h-10 w-10 rounded-lg object-cover brightness-90"
            />
            <span className="text-xl font-bold text-white">מחירוטו</span>
          </div>
          <div className="flex flex-wrap justify-center gap-6 text-sm font-medium">
            <Link href="/privacy" className="hover:text-white transition-colors">מדיניות פרטיות (Privacy Policy)</Link>
            <Link href="/terms" className="hover:text-white transition-colors">תנאי שימוש (Terms of Service)</Link>
          </div>
        </div>
        <div className="max-w-7xl mx-auto text-xs text-center md:text-right space-y-2 font-light">
          <p>© 2026 מחירוטו (Pirsumoto). כל הזכויות שמורות. המערכת מיועדת לשימוש עסקי (B2B) בלבד עבור מגרשי רכב מורשים בישראל.</p>
          <p className="text-slate-600">WhatsApp הוא סימן מסחרי רשום של Meta Platforms Inc. השימוש ב-API נעשה בכפוף למדיניות פלטפורמת העסקים הרשמית.</p>
        </div>
      </footer>
    </div>
  );
}
