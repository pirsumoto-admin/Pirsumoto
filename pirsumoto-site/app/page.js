'use client';

import { useState } from 'react';
import Image from 'next/image';
import Link from 'next/link';

export default function HomePage() {
  const [activeTab, setActiveTab] = useState('all');

  const screenshots = [
    {
      id: 'login',
      category: 'devices',
      title: 'כניסה מאובטחת',
      subtitle: 'אימות והזדהות משתמשי המגרש',
      desc: 'מסך כניסה מאובטח ייעודי לסוכני ומנהלי המגרש המאפשר גישה מהירה וחיבור תחת פרטי ההזדהות של המשתמש.',
      src: '/screenshots/app-login.jpeg',
      badge: 'אבטחת B2B',
    },
    {
      id: 'devices',
      category: 'devices',
      title: 'ניהול צי מכשירים (MDM)',
      subtitle: 'שליטה מלאה במכשירי השטח',
      desc: 'דשבורד מכשירים מחוברים המנוהלים תחת MDM Fleet Management. סטטוס מקוון בזמן אמת, גישה לצ\'אט, שליטה מרחוק ותור פרסומים.',
      src: '/screenshots/connected-devices.jpeg',
      badge: 'MDM Fleet Control',
    },
    {
      id: 'chat',
      category: 'chat',
      title: 'צ\'אט בוט קליטת רכב',
      subtitle: 'הזנה חכמה בהודעה או בקול',
      desc: 'ממשק שיחה ייעודי: שליחת מספר רישוי או הקלטה קולית, פענוח מיידי, הנחיות אינטראקטיביות ואישור פרסום.',
      src: '/screenshots/chat-bot-flow.jpeg',
      badge: 'אפליקציה ייעודית',
    },
    {
      id: 'gov',
      category: 'gov',
      title: 'נתוני ממשלה והיסטוריה',
      subtitle: 'שליפה אוטומטית מ-data.gov.il',
      desc: 'קליטה אוטומטית מלאה של מפרט הרכב, מנוע, סוג דלק, גיר, תוקף טסט, והיסטוריית בעלויות וידיים לאורך השנים.',
      src: '/screenshots/gov-data-sheet.jpeg',
      badge: 'data.gov.il',
    },
    {
      id: 'form',
      category: 'chat',
      title: 'טופס השלמת שדות חסרים',
      subtitle: 'השלמת נתונים אינטראקטיבית בצ\'אט',
      desc: 'טופס חכם מובנה בתוך הצ\'אט לעדכון מהיר של קילומטראז\', מחיר, יד, בעלות קודמת ומצב הרכב בלחיצת כפתור.',
      src: '/screenshots/missing-fields-form.jpeg',
      badge: 'חוויית משתמש מהירה',
    },
    {
      id: 'remote',
      category: 'remote',
      title: 'שידור חי ושליטת HITL',
      subtitle: 'Human-in-the-Loop Control',
      desc: 'שידור מסך חי בזמן אמת של מכשיר האוטומציה, שליטת אדם-בלולאה (HITL) מלאה, נראות מוחלטת ויכולת התערבות בכל שלב.',
      src: '/screenshots/remote-control-live.jpeg',
      badge: 'Human-in-the-Loop',
    },
    {
      id: 'history',
      category: 'inventory',
      title: 'היסטוריית מודעות ומלאי',
      subtitle: 'ניהול מלאי הרכבים במגרש',
      desc: 'רשימת כל הרכבים שנקלטו ונשמרו במערכת, חיפוש לפי רישוי ודגם, תגיות מחיר, קילומטראז\', בעלות וצפייה בפרטים מלאים.',
      src: '/screenshots/published-cars-history.jpeg',
      badge: 'ניהול מלאי',
    },
    {
      id: 'queue',
      category: 'inventory',
      title: 'תור ומעקב פרסומים',
      subtitle: 'סטטוס פרסום רב-ערוצי בזמן אמת',
      desc: 'מעקב אחר בקשות פרסום, אישור סנכרון אוטומטי ליד2 ולפייסבוק מרקטפלייס, וניהול תור משימות הפרסום.',
      src: '/screenshots/publications-queue.jpeg',
      badge: 'אוטומציה מלאה',
    },
  ];

  const filteredScreenshots = activeTab === 'all' 
    ? screenshots 
    : screenshots.filter(s => s.category === activeTab);

  return (
    <div className="min-h-screen flex flex-col justify-between bg-slate-950 text-slate-100 selection:bg-blue-600 selection:text-white">
      {/* Top Patent Pending Announcement Bar */}
      <div className="bg-gradient-to-r from-amber-600/90 via-orange-600/90 to-amber-600/90 text-white text-xs py-2 px-4 text-center font-bold tracking-wide flex items-center justify-center gap-2 shadow-sm border-b border-amber-500/30">
        <span className="bg-black/30 text-amber-200 text-[10px] px-2 py-0.5 rounded-full uppercase tracking-wider border border-amber-300/30">
          Patent Pending
        </span>
        <span>פתרון טכנולוגי מוגן בבקשת פטנט | אוטומציית מגרשים מנוהלת MDM עם שליטת Human-in-the-Loop מלאה</span>
      </div>

      {/* Upper Header Navigation */}
      <header className="bg-slate-900/85 backdrop-blur-md border-b border-slate-800 sticky top-0 z-50 transition-all duration-300">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-20 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Image
              src="/logo.png"
              alt="לוגו פרסומוטו"
              width={44}
              height={44}
              className="h-11 w-11 rounded-xl object-cover shadow-md ring-1 ring-blue-500/30"
              priority
            />
            <div className="flex flex-col">
              <div className="flex items-center gap-2">
                <span className="text-2xl font-black bg-gradient-to-l from-blue-400 via-indigo-300 to-white bg-clip-text text-transparent tracking-tight">
                  פרסומוטו
                </span>
                <span className="bg-amber-500/20 text-amber-400 text-[9px] font-bold px-1.5 py-0.5 rounded border border-amber-500/30">
                  Patent Pending
                </span>
              </div>
              <span className="text-[10px] text-blue-400 font-semibold tracking-wider -mt-0.5 uppercase">Pirsumoto Relay</span>
            </div>
          </div>

          <nav className="hidden lg:flex items-center gap-7 font-medium text-slate-300 text-sm">
            <a href="#solution" className="hover:text-blue-400 transition-colors">הפתרון המשולב</a>
            <a href="#mdm-architecture" className="hover:text-blue-400 transition-colors">מכשיר אוטומציה ו-MDM</a>
            <a href="#dedicated-app" className="hover:text-blue-400 transition-colors">אפליקציה ייעודית</a>
            <a href="#hitl-control" className="hover:text-blue-400 transition-colors">Human-in-the-Loop</a>
            <a href="#gov-data" className="hover:text-blue-400 transition-colors">מאגרי ממשלה</a>
            <a href="#features" className="hover:text-blue-400 transition-colors">גלריית מסכים</a>
          </nav>

          <div className="flex items-center gap-2 sm:gap-3">
            <span className="bg-blue-950 text-blue-300 text-xs font-bold px-3 py-1.5 rounded-full uppercase tracking-wider border border-blue-800/60 shadow-sm flex items-center gap-1.5">
              <span className="h-2 w-2 rounded-full bg-emerald-400 animate-pulse"></span>
              B2B בלבד
            </span>
          </div>
        </div>
      </header>

      {/* Hero Section */}
      <section className="relative bg-gradient-to-b from-slate-900 via-slate-950 to-slate-950 text-white py-16 lg:py-24 px-4 overflow-hidden border-b border-slate-800">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_top_right,rgba(59,130,246,0.18),transparent_60%)]"></div>
        <div className="absolute top-1/4 left-1/4 w-96 h-96 bg-indigo-600/10 rounded-full blur-3xl pointer-events-none"></div>

        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center relative z-10">
          <div className="lg:col-span-7 space-y-7 text-center lg:text-right">
            <div className="inline-flex flex-wrap items-center justify-center lg:justify-start gap-2">
              <div className="inline-flex items-center gap-1.5 bg-amber-500/10 border border-amber-500/30 rounded-full px-3.5 py-1 text-xs text-amber-300 font-bold">
                <span>🛡️</span> Patent Pending Solution
              </div>
              <div className="inline-flex items-center gap-2 bg-blue-900/40 border border-blue-700/50 rounded-full px-4 py-1 text-xs text-blue-300 font-medium">
                <span className="bg-blue-500 text-white text-[10px] font-bold px-2 py-0.5 rounded-full">חדש</span>
                מכשיר אוטומציה מנוהל MDM + שליטת Human-in-the-Loop
              </div>
            </div>

            <h1 className="text-4xl sm:text-5xl lg:text-6xl font-black leading-tight tracking-tight">
              הופכים את קליטת הרכב במגרש <br />
              <span className="bg-gradient-to-l from-blue-400 via-indigo-300 to-teal-300 bg-clip-text text-transparent">
                לאוטומציה מלאה תחת שליטתך
              </span>
            </h1>

            <p className="text-lg sm:text-xl text-slate-300 max-w-2xl mx-auto lg:mx-0 font-light leading-relaxed">
              מכשיר אוטומציה ייעודי ומאובטח המנוהל תחת <strong>MDM Fleet Management</strong>, הפועל תחת פרטי ההזדהות והחשבונות האישיים של הלקוח ישירות מביתו או ממשרדו. בשילוב עם אפליקציית <strong>Pirsumoto Relay</strong>, המערכת מספקת בקרת <strong>Human-in-the-Loop (HITL)</strong> מלאה עם נראות ושקיפות מוחלטת בכל רגע ומכל מקום.
            </p>

            <div className="pt-2 flex flex-wrap justify-center lg:justify-start gap-4">
              <a 
                href="#mdm-architecture" 
                className="bg-gradient-to-r from-blue-600 to-indigo-600 hover:from-blue-500 hover:to-indigo-500 text-white font-bold px-8 py-4 rounded-xl transition-all shadow-lg shadow-blue-600/30 hover:scale-[1.02] active:scale-[0.98] flex items-center gap-2"
              >
                <span>גלה את ארכיטקטורת המערכת</span>
                <span className="text-lg">←</span>
              </a>
              <a 
                href="#features" 
                className="bg-slate-800/80 hover:bg-slate-800 text-slate-200 font-medium px-8 py-4 rounded-xl backdrop-blur-sm transition-all border border-slate-700 hover:border-slate-600 hover:scale-[1.02] active:scale-[0.98]"
              >
                צפה במסכי המערכת (8 מסכים)
              </a>
            </div>

            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 pt-6 border-t border-slate-800/80 max-w-xl mx-auto lg:mx-0 text-right">
              <div className="bg-slate-900/50 p-3 rounded-xl border border-slate-800">
                <div className="text-xl font-black text-amber-400">Patent</div>
                <div className="text-[11px] text-slate-400">פתרון מוגן בפטנט</div>
              </div>
              <div className="bg-slate-900/50 p-3 rounded-xl border border-slate-800">
                <div className="text-xl font-black text-blue-400">MDM Fleet</div>
                <div className="text-[11px] text-slate-400">מכשיר ייעודי ומנוהל</div>
              </div>
              <div className="bg-slate-900/50 p-3 rounded-xl border border-slate-800">
                <div className="text-xl font-black text-emerald-400">HITL</div>
                <div className="text-[11px] text-slate-400">Human-in-the-Loop</div>
              </div>
              <div className="bg-slate-900/50 p-3 rounded-xl border border-slate-800">
                <div className="text-xl font-black text-indigo-400">data.gov.il</div>
                <div className="text-[11px] text-slate-400">היסטוריית בעלויות</div>
              </div>
            </div>
          </div>

          <div className="lg:col-span-5 flex justify-center relative">
            <div className="relative">
              {/* Glow backdrop */}
              <div className="absolute -inset-2 bg-gradient-to-r from-blue-600 via-indigo-600 to-amber-500 rounded-[48px] blur-xl opacity-35 animate-pulse"></div>
              
              {/* Phone Frame Mockup */}
              <div className="relative w-72 sm:w-80 h-[610px] bg-slate-900 rounded-[44px] p-3 shadow-2xl border-4 border-slate-700/80 overflow-hidden ring-1 ring-white/10 transition-transform duration-500 hover:scale-[1.02]">
                <div className="w-full h-full rounded-[34px] overflow-hidden bg-slate-950 relative">
                  <Image
                    src="/screenshots/chat-bot-flow.jpeg"
                    alt="צ'אט בוט קליטת רכב בפרסומוטו"
                    fill
                    className="object-cover object-top"
                    priority
                  />
                </div>
              </div>

              {/* Floating feature pills */}
              <div className="absolute -bottom-4 -right-6 bg-slate-900/90 backdrop-blur-md border border-slate-700 rounded-2xl p-3.5 shadow-xl hidden sm:flex items-center gap-3">
                <div className="h-10 w-10 rounded-xl bg-amber-500/20 text-amber-400 flex items-center justify-center font-bold text-lg">
                  🛡️
                </div>
                <div className="text-right">
                  <div className="text-xs font-bold text-white">MDM Managed Fleet</div>
                  <div className="text-[11px] text-slate-400">פועל תחת פרטי המשתמש מהמשרד</div>
                </div>
              </div>

              <div className="absolute top-12 -left-6 bg-slate-900/90 backdrop-blur-md border border-slate-700 rounded-2xl p-3.5 shadow-xl hidden sm:flex items-center gap-3">
                <div className="h-10 w-10 rounded-xl bg-emerald-500/20 text-emerald-400 flex items-center justify-center font-bold text-lg">
                  👁️
                </div>
                <div className="text-right">
                  <div className="text-xs font-bold text-white">Human-in-the-Loop</div>
                  <div className="text-[11px] text-slate-400">שליטה ונראות מלאה מכל מקום</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Breakthrough Architecture: MDM Fleet + User Credentials + HITL */}
      <section id="mdm-architecture" className="py-24 bg-slate-900 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto space-y-16">
          <div className="text-center max-w-3xl mx-auto space-y-4">
            <div className="inline-flex items-center gap-2 bg-amber-500/10 border border-amber-500/30 rounded-full px-4 py-1 text-xs text-amber-400 font-bold">
              <span>★</span> ארכיטקטורה מוגנת בפטנט (Patent Pending Architecture)
            </div>
            <h2 className="text-3xl sm:text-4xl font-black text-white">
              מכשיר אוטומציה מנוהל MDM תחת פרטי המשתמש שלך
            </h2>
            <p className="text-slate-300 text-lg font-light leading-relaxed">
              הפתרון של פרסומוטו משלב מכשיר פיזי ייעודי ומנוהל תחת מערכת MDM ארגונית, הפועל תחת חשבונות ההזדהות האישיים של בעל המגרש, עם בקרה אנושית בזמן אמת.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8">
            <div className="bg-slate-950 p-8 rounded-3xl border border-slate-800 shadow-xl space-y-5 hover:border-blue-500/50 transition-all duration-300 hover:translate-y-[-4px]">
              <div className="h-14 w-14 rounded-2xl bg-blue-500/10 border border-blue-500/30 text-blue-400 flex items-center justify-center text-2xl">
                📱
              </div>
              <h3 className="text-xl font-bold text-white">מכשיר אוטומציה ייעודי בניהול MDM</h3>
              <p className="text-slate-400 leading-relaxed font-light text-sm">
                המערכת פועלת על גבי מכשיר אנדרואיד ייעודי, נעול ומנוהל לחלוטין באמצעות <strong>MDM Fleet Management</strong>. המכשיר מוגן ברמה ארגונית ומיועד אך ורק לתהליכי אוטומציית המלאי של המגרש.
              </p>
              <div className="pt-2">
                <span className="text-xs text-blue-400 font-semibold bg-blue-950/80 px-2.5 py-1 rounded-md border border-blue-900">
                  ניהול צי מאובטח (Fleet Management)
                </span>
              </div>
            </div>

            <div className="bg-slate-950 p-8 rounded-3xl border border-slate-800 shadow-xl space-y-5 hover:border-emerald-500/50 transition-all duration-300 hover:translate-y-[-4px]">
              <div className="h-14 w-14 rounded-2xl bg-emerald-500/10 border border-emerald-500/30 text-emerald-400 flex items-center justify-center text-2xl">
                🔑
              </div>
              <h3 className="text-xl font-bold text-white">פועל תחת פרטי המשתמש מהמשרד/הבית</h3>
              <p className="text-slate-400 leading-relaxed font-light text-sm">
                המכשיר רץ תחת פרטי ההזדהות (Credentials) והחשבונות האישיים של הלקוח ישירות מביתו או ממשרדו. הדבר מבטיח שהפרסום מתבצע ישירות מחשבונות המגרש הרשמיים ללא חשיפת סיסמאות לצדדים שלישיים.
              </p>
              <div className="pt-2">
                <span className="text-xs text-emerald-400 font-semibold bg-emerald-950/80 px-2.5 py-1 rounded-md border border-emerald-900">
                  הזדהות ישירה ומאובטחת (User Credentials)
                </span>
              </div>
            </div>

            <div className="bg-slate-950 p-8 rounded-3xl border border-slate-800 shadow-xl space-y-5 hover:border-amber-500/50 transition-all duration-300 hover:translate-y-[-4px]">
              <div className="h-14 w-14 rounded-2xl bg-amber-500/10 border border-amber-500/30 text-amber-400 flex items-center justify-center text-2xl">
                👁️
              </div>
              <h3 className="text-xl font-bold text-white">Human-in-the-Loop & Pirsumoto Relay</h3>
              <p className="text-slate-400 leading-relaxed font-light text-sm">
                אפליקציית <strong>Pirsumoto Relay</strong> מעניקה למשתמש שליטת <strong>Human-in-the-Loop</strong> מלאה: שידור מסך חי בזמן אמת, נראות מוחלטת 24/7 מכל מקום, ויכולת התערבות, אישור או שינוי בלחיצת כפתור.
              </p>
              <div className="pt-2">
                <span className="text-xs text-amber-400 font-semibold bg-amber-950/80 px-2.5 py-1 rounded-md border border-amber-900">
                  שליטה ונראות מכל מקום (Full Visibility)
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Main Feature 1: Dedicated In-App Data Entry Interface */}
      <section id="dedicated-app" className="py-24 bg-slate-950 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center">
          {/* Dual Phone Showcase */}
          <div className="lg:col-span-6 order-last lg:order-first flex justify-center gap-4 sm:gap-6">
            <div className="w-56 sm:w-64 h-[480px] sm:h-[530px] bg-slate-900 rounded-[38px] p-2.5 shadow-2xl border-4 border-slate-800 overflow-hidden mt-6 transition-transform duration-500 hover:scale-[1.02]">
              <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                <Image
                  src="/screenshots/chat-bot-flow.jpeg"
                  alt="ממשק צ'אט בוט לקליטת רכב"
                  fill
                  className="object-cover object-top"
                />
              </div>
            </div>

            <div className="w-56 sm:w-64 h-[480px] sm:h-[530px] bg-slate-900 rounded-[38px] p-2.5 shadow-2xl border-4 border-slate-800 overflow-hidden transition-transform duration-500 hover:scale-[1.02]">
              <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                <Image
                  src="/screenshots/missing-fields-form.jpeg"
                  alt="טופס השלמת שדות חסרים"
                  fill
                  className="object-cover object-top"
                />
              </div>
            </div>
          </div>

          {/* Text Content */}
          <div className="lg:col-span-6 space-y-6">
            <span className="bg-emerald-950 text-emerald-300 text-xs font-bold px-3.5 py-1.5 rounded-full uppercase tracking-wider border border-emerald-800/80">
              ממשק אפליקציה ייעודי (Dedicated In-App Interface)
            </span>

            <h2 className="text-3xl sm:text-4xl font-black text-white leading-tight">
              ממשק הזנת נתונים מאובטח דרך אפליקציה ייעודית
            </h2>

            <p className="text-slate-300 text-lg font-light leading-relaxed">
              פיתחנו סביבת עבודה ייעודית, עצמאית ומאובטחת המותקנת ישירות על מכשירי הסוכנים. הממשק מבוסס צ\'אט אינטואיטיבי וטפסים מובנים (Inline Forms), המבטיחים קליטה מהירה ואפס טעויות אנוש.
            </p>

            <div className="space-y-4 text-slate-300 font-light">
              <div className="flex items-start gap-3 bg-slate-900/60 p-4 rounded-xl border border-slate-800">
                <div className="h-7 w-7 rounded-full bg-emerald-500/20 text-emerald-400 flex items-center justify-center text-sm font-bold shrink-0 mt-0.5 border border-emerald-500/30">
                  ✓
                </div>
                <div>
                  <h4 className="font-bold text-white text-base mb-1">קליטה מהירה לפי מספר רישוי או הקלטה קולית</h4>
                  <p className="text-sm text-slate-400">הסוכן מקליד מספר רישוי (7 או 8 ספרות) או מקליט הודעה קולית חופשית. המערכת מחלצת ומעבדת את המידע באופן מיידי.</p>
                </div>
              </div>

              <div className="flex items-start gap-3 bg-slate-900/60 p-4 rounded-xl border border-slate-800">
                <div className="h-7 w-7 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-bold shrink-0 mt-0.5 border border-blue-500/30">
                  ✓
                </div>
                <div>
                  <h4 className="font-bold text-white text-base mb-1">טופס השלמת שדות חסרים אינטראקטיבי</h4>
                  <p className="text-sm text-slate-400">אם חסרים פרטים כגון קילומטראז\', מחיר מבוקש, יד או מצב הרכב – נפתח טופס חכם ומובנה ישירות בתוך הצ\'אט לשמירה מהירה.</p>
                </div>
              </div>

              <div className="flex items-start gap-3 bg-slate-900/60 p-4 rounded-xl border border-slate-800">
                <div className="h-7 w-7 rounded-full bg-indigo-500/20 text-indigo-400 flex items-center justify-center text-sm font-bold shrink-0 mt-0.5 border border-indigo-500/30">
                  ✓
                </div>
                <div>
                  <h4 className="font-bold text-white text-base mb-1">צירוף תמונות והזנקת פרסום אוטומטית</h4>
                  <p className="text-sm text-slate-400">צירוף תמונות ישירות מהמצלמה, עיבוד AI ברקע, ונעילת המודעה לפרסום סימולטני ביד2 ובפייסבוק מרקטפלייס.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Main Feature 2: Human-in-the-Loop & Live Screen Remote Control */}
      <section id="hitl-control" className="py-24 bg-slate-900 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto space-y-16">
          <div className="text-center max-w-3xl mx-auto space-y-4">
            <span className="bg-rose-950 text-rose-300 text-xs font-bold px-3.5 py-1.5 rounded-full uppercase tracking-wider border border-rose-800/80">
              Pirsumoto Relay • Human-in-the-Loop
            </span>
            <h2 className="text-3xl sm:text-4xl font-black text-white">
              שליטת אדם-בלולאה (HITL) ונראות מלאה בכל זמן ומכל מקום
            </h2>
            <p className="text-slate-300 text-lg font-light leading-relaxed">
              אתה אף פעם לא בעיוורון. מערכת Pirsumoto Relay משדרת את מסך המכשיר האוטומטי בשידור חי (WebRTC) ומאפשרת לך לראות בדיוק מה קורה, להשתלט, לעצור או לאשר פעולות בכל שנייה.
            </p>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-8 items-start">
            {/* Login & Fleet */}
            <div className="space-y-4">
              <div className="w-full h-[480px] bg-slate-950 rounded-[36px] p-2.5 shadow-xl border-2 border-slate-800 overflow-hidden relative group">
                <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                  <Image
                    src="/screenshots/app-login.jpeg"
                    alt="מסך התחברות מאובטח"
                    fill
                    className="object-cover object-top transition-transform duration-500 group-hover:scale-105"
                  />
                </div>
              </div>
              <div className="text-right space-y-1">
                <h4 className="font-bold text-white text-lg">1. התחברות תחת פרטי הלקוח</h4>
                <p className="text-xs text-slate-400 font-light">אימות דו-שלבי וחיבור ישיר מחשבונות המגרש המורשים של המשתמש.</p>
              </div>
            </div>

            {/* Connected Devices */}
            <div className="space-y-4">
              <div className="w-full h-[480px] bg-slate-950 rounded-[36px] p-2.5 shadow-xl border-2 border-slate-800 overflow-hidden relative group">
                <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                  <Image
                    src="/screenshots/connected-devices.jpeg"
                    alt="מרכז ניהול מכשירים מחוברים"
                    fill
                    className="object-cover object-top transition-transform duration-500 group-hover:scale-105"
                  />
                </div>
              </div>
              <div className="text-right space-y-1">
                <h4 className="font-bold text-white text-lg">2. דשבורד מכשירי MDM מחוברים</h4>
                <p className="text-xs text-slate-400 font-light">ניטור מכשירי אנדרואיד פעילים בשטח (SM-G998B) עם גישה לצ\'אט, שליטה ותור פרסומים.</p>
              </div>
            </div>

            {/* Live Streaming & Remote Control */}
            <div className="space-y-4">
              <div className="w-full h-[480px] bg-slate-950 rounded-[36px] p-2.5 shadow-xl border-2 border-slate-800 overflow-hidden relative group">
                <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                  <Image
                    src="/screenshots/remote-control-live.jpeg"
                    alt="שידור מסך חי ושליטה מרחוק"
                    fill
                    className="object-cover object-top transition-transform duration-500 group-hover:scale-105"
                  />
                </div>
              </div>
              <div className="text-right space-y-1">
                <h4 className="font-bold text-white text-lg">3. שידור חי ובקרת HITL מלאה</h4>
                <p className="text-xs text-slate-400 font-light">שידור מסך חי WebRTC, אשף הוספת רכב, קבלת/שחרור שליטה ופיקוח מלא בזמן אמת.</p>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Main Feature 3: Official Government Vehicle Data Integration (data.gov.il) */}
      <section id="gov-data" className="py-24 bg-slate-950 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center">
          {/* Text Content */}
          <div className="lg:col-span-7 space-y-6">
            <span className="bg-blue-950 text-blue-300 text-xs font-bold px-3.5 py-1.5 rounded-full uppercase tracking-wider border border-blue-800/80">
              מאגר כלי רכב ממשלתי רשמי (data.gov.il)
            </span>

            <h2 className="text-3xl sm:text-4xl font-black text-white leading-tight">
              שליפת נתונים רשמית ממאגרי הממשלה והיסטוריית בעלויות מלאה
            </h2>

            <p className="text-slate-300 text-lg font-light leading-relaxed">
              אין צורך להקליד מפרטים ידנית. עם הזנת לוחית הרישוי, המערכת שולפת ומאמתת את נתוני הרכב ממאגרי משרד התחבורה הרשמיים, כולל פירוט היסטורי מלא.
            </p>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4 pt-2">
              <div className="bg-slate-900/80 p-4 rounded-xl border border-slate-800">
                <div className="text-blue-400 font-bold mb-1 flex items-center gap-2 text-sm">
                  <span>🚗</span> מפרט רכב כללי
                </div>
                <p className="text-xs text-slate-400">יצרן, דגם, שנת ייצור, צבע, סוג דלק, תיבת הילוכים ובעלות נוכחית.</p>
              </div>

              <div className="bg-slate-900/80 p-4 rounded-xl border border-slate-800">
                <div className="text-emerald-400 font-bold mb-1 flex items-center gap-2 text-sm">
                  <span>📅</span> רישוי וטסטים
                </div>
                <p className="text-xs text-slate-400">חודש עלייה לכביש, תוקף טסט נוכחי ותאריך מעבר טסט אחרון מדויק.</p>
              </div>

              <div className="bg-slate-900/80 p-4 rounded-xl border border-slate-800 sm:col-span-2">
                <div className="text-indigo-400 font-bold mb-1 flex items-center gap-2 text-sm">
                  <span>📑</span> היסטוריית בעלויות וידיים לאורך השנים
                </div>
                <p className="text-xs text-slate-400">
                  ספירת יד סה"כ, זיהוי סוג בעלות קודמת (פרטי, סוחר, השכרה / החכר), ופירוט תאריכי העברות בעלות היסטוריות מלאות.
                </p>
              </div>
            </div>
          </div>

          {/* Government Data Sheet Phone Showcase */}
          <div className="lg:col-span-5 flex justify-center">
            <div className="w-72 sm:w-80 h-[580px] bg-slate-900 rounded-[44px] p-3 shadow-2xl border-4 border-slate-800 overflow-hidden ring-1 ring-blue-500/20 transition-transform duration-500 hover:scale-[1.02]">
              <div className="w-full h-full rounded-[34px] overflow-hidden relative">
                <Image
                  src="/screenshots/gov-data-sheet.jpeg"
                  alt="שליפת נתוני רכב ממאגרי הממשלה"
                  fill
                  className="object-cover object-top"
                />
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Main Feature 4: Inventory Management & Multi-Channel Publishing Queue */}
      <section className="py-24 bg-slate-900 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center">
          {/* Dual Phone Showcase */}
          <div className="lg:col-span-6 flex justify-center gap-4 sm:gap-6">
            <div className="w-56 sm:w-64 h-[480px] sm:h-[530px] bg-slate-950 rounded-[38px] p-2.5 shadow-2xl border-4 border-slate-800 overflow-hidden transition-transform duration-500 hover:scale-[1.02]">
              <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                <Image
                  src="/screenshots/published-cars-history.jpeg"
                  alt="היסטוריית מודעות ורכבים"
                  fill
                  className="object-cover object-top"
                />
              </div>
            </div>

            <div className="w-56 sm:w-64 h-[480px] sm:h-[530px] bg-slate-950 rounded-[38px] p-2.5 shadow-2xl border-4 border-slate-800 overflow-hidden mt-6 transition-transform duration-500 hover:scale-[1.02]">
              <div className="w-full h-full rounded-[28px] overflow-hidden relative">
                <Image
                  src="/screenshots/publications-queue.jpeg"
                  alt="תור פרסומים ומעקב"
                  fill
                  className="object-cover object-top"
                />
              </div>
            </div>
          </div>

          {/* Text Content */}
          <div className="lg:col-span-6 space-y-6">
            <span className="bg-indigo-950 text-indigo-300 text-xs font-bold px-3.5 py-1.5 rounded-full uppercase tracking-wider border border-indigo-800/80">
              ניהול מלאי ותור פרסום רב-ערוצי
            </span>

            <h2 className="text-3xl sm:text-4xl font-black text-white leading-tight">
              שליטה מלאה במלאי הרכבים ותור פרסום אוטומטי
            </h2>

            <p className="text-slate-300 text-lg font-light leading-relaxed">
              כל רכב שנקלט נשמר במסד הנתונים של המגרש. ניתן לחפש, לעדכן, למחוק ולעקוב אחר סטטוס הפרסום בלוחות המובילים בזמן אמת.
            </p>

            <div className="space-y-4 text-slate-300 font-light">
              <div className="flex items-start gap-3 bg-slate-950 p-4 rounded-xl border border-slate-800">
                <div className="h-7 w-7 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-bold shrink-0 mt-0.5 border border-blue-500/30">
                  🔍
                </div>
                <div>
                  <h4 className="font-bold text-white text-base mb-1">חיפוש וסינון מתקדם</h4>
                  <p className="text-sm text-slate-400">חיפוש מיידי לפי מספר רישוי, יצרן או דגם, סינון מועדפים בלבד, וצפייה בפרטי כל רכב.</p>
                </div>
              </div>

              <div className="flex items-start gap-3 bg-slate-950 p-4 rounded-xl border border-slate-800">
                <div className="h-7 w-7 rounded-full bg-emerald-500/20 text-emerald-400 flex items-center justify-center text-sm font-bold shrink-0 mt-0.5 border border-emerald-500/30">
                  🎉
                </div>
                <div>
                  <h4 className="font-bold text-white text-base mb-1">אישור פרסום מושלם</h4>
                  <p className="text-sm text-slate-400">אינדיקציות מיידיות על הצלחת הפרסום ביד2 ובפייסבוק מרקטפלייס ללא צורך בכניסה ידנית לכל אתר.</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Interactive 8-Screen Gallery Section */}
      <section id="features" className="py-24 bg-slate-950 px-4 border-b border-slate-800">
        <div className="max-w-7xl mx-auto space-y-12">
          <div className="text-center max-w-2xl mx-auto space-y-4">
            <span className="text-blue-400 text-xs font-bold tracking-wider uppercase bg-blue-950 border border-blue-800/80 px-3 py-1 rounded-full">
              גלריית המערכת המלאה
            </span>
            <h2 className="text-3xl sm:text-4xl font-black text-white">כל מסכי המערכת בכף היד שלך</h2>
            <p className="text-slate-400 font-light">סייר במסכים ובממשקים שפותחו במיוחד עבור סוכני ומנהלי מגרשי רכב בישראל.</p>

            {/* Filter Tabs */}
            <div className="flex flex-wrap justify-center gap-2 pt-4">
              <button
                onClick={() => setActiveTab('all')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'all'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                כל המסכים ({screenshots.length})
              </button>
              <button
                onClick={() => setActiveTab('chat')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'chat'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                צ\'אט והזנת נתונים
              </button>
              <button
                onClick={() => setActiveTab('gov')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'gov'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                מאגרי ממשלה (data.gov.il)
              </button>
              <button
                onClick={() => setActiveTab('devices')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'devices'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                ניהול צי מכשירים (MDM)
              </button>
              <button
                onClick={() => setActiveTab('remote')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'remote'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                שליטת HITL ושידור חי
              </button>
              <button
                onClick={() => setActiveTab('inventory')}
                className={`px-4 py-2 rounded-xl text-xs font-bold transition-all ${
                  activeTab === 'inventory'
                    ? 'bg-blue-600 text-white shadow-lg shadow-blue-600/30'
                    : 'bg-slate-900 text-slate-400 hover:text-white border border-slate-800'
                }`}
              >
                מלאי ותור פרסומים
              </button>
            </div>
          </div>

          {/* Grid of Screenshots */}
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6 justify-items-center">
            {filteredScreenshots.map((item) => (
              <div 
                key={item.id} 
                className="w-full max-w-[280px] bg-slate-900/90 rounded-3xl p-3 border border-slate-800 shadow-xl hover:border-blue-500/40 transition-all duration-300 hover:translate-y-[-4px] flex flex-col justify-between"
              >
                <div className="space-y-3">
                  <div className="w-full h-[380px] bg-slate-950 rounded-2xl overflow-hidden relative border border-slate-800">
                    <Image
                      src={item.src}
                      alt={item.title}
                      fill
                      className="object-cover object-top"
                    />
                    <div className="absolute top-2 right-2 bg-slate-900/90 backdrop-blur-md text-[10px] font-bold text-blue-300 px-2.5 py-1 rounded-full border border-slate-700">
                      {item.badge}
                    </div>
                  </div>
                  <div className="text-right space-y-1 px-1">
                    <h4 className="font-bold text-white text-base">{item.title}</h4>
                    <p className="text-xs text-blue-400 font-medium">{item.subtitle}</p>
                    <p className="text-[11px] text-slate-400 leading-relaxed font-light">{item.desc}</p>
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Enterprise Security & Patent Protection */}
      <section className="py-20 bg-gradient-to-b from-slate-900 to-slate-950 px-4 border-b border-slate-800 text-center">
        <div className="max-w-4xl mx-auto space-y-6">
          <div className="inline-flex items-center justify-center h-16 w-16 rounded-2xl bg-amber-500/10 border border-amber-500/30 text-amber-400 text-3xl mb-2">
            🛡️
          </div>
          <div className="inline-block bg-amber-500/20 text-amber-300 text-xs font-bold px-3 py-1 rounded-full border border-amber-500/30">
            טכנולוגיה מוגנת בבקשת פטנט (Patent Pending)
          </div>
          <h2 className="text-3xl font-black text-white">אבטחת מידע, ניהול MDM וסודיות עסקית B2B</h2>
          <p className="text-slate-300 text-base font-light leading-relaxed max-w-2xl mx-auto">
            מערכת פרסומוטו פועלת תחת תקני אבטחה קפדניים, הצפנת נתונים בתעבורה ובמנוחה, הפרדה מלאה בין נתוני מגרשים, מכשירים מנוהלי MDM הרצים בסביבה מבוקרת תחת פרטי ההזדהות של הלקוח, ושליטת Human-in-the-Loop בזמן אמת.
          </p>
        </div>
      </section>

      {/* Footer Section */}
      <footer className="bg-slate-950 text-slate-400 py-12 px-4">
        <div className="max-w-7xl mx-auto flex flex-col md:flex-row items-center justify-between gap-6 border-b border-slate-800/80 pb-8 mb-8">
          <div className="flex items-center gap-3">
            <Image
              src="/logo.png"
              alt="לוגו פרסומוטו"
              width={38}
              height={38}
              className="h-9 w-9 rounded-xl object-cover brightness-90"
            />
            <div className="flex flex-col text-right">
              <div className="flex items-center gap-2">
                <span className="text-lg font-bold text-white">פרסומוטו (Pirsumoto)</span>
                <span className="bg-amber-500/20 text-amber-400 text-[9px] font-bold px-1.5 py-0.5 rounded border border-amber-500/30">
                  Patent Pending
                </span>
              </div>
              <span className="text-[10px] text-slate-400">אוטומציה לקליטה ופרסום רכבים • MDM & HITL Control</span>
            </div>
          </div>

          <div className="flex flex-wrap justify-center gap-6 text-sm font-medium">
            <a href="#solution" className="hover:text-white transition-colors">הפתרון</a>
            <a href="#mdm-architecture" className="hover:text-white transition-colors">ניהול MDM</a>
            <a href="#dedicated-app" className="hover:text-white transition-colors">אפליקציה ייעודית</a>
            <a href="#hitl-control" className="hover:text-white transition-colors">Human-in-the-Loop</a>
            <a href="#gov-data" className="hover:text-white transition-colors">מאגרי ממשלה</a>
            <Link href="/privacy" className="hover:text-white transition-colors">מדיניות פרטיות</Link>
            <Link href="/terms" className="hover:text-white transition-colors">תנאי שימוש</Link>
          </div>
        </div>

        <div className="max-w-7xl mx-auto text-xs text-center md:text-right space-y-2 font-light text-slate-400">
          <p>© 2026 פרסומוטו (Pirsumoto). כל הזכויות שמורות. פתרון טכנולוגי מוגן בבקשת פטנט (Patent Pending). המערכת מיועדת לשימוש עסקי (B2B) בלבד עבור מגרשי רכב מורשים בישראל.</p>
          <p className="text-slate-400">הנתונים הממשלתיים נשאבים ממאגרי המידע הפתוחים של משרד התחבורה (data.gov.il) בהתאם לתנאי השימוש החוקיים.</p>
        </div>
      </footer>
    </div>
  );
}
