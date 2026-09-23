import { Heebo } from "next/font/google";
import "./globals.css";

const heebo = Heebo({
  subsets: ["hebrew", "latin"],
  weight: ["300", "400", "500", "700", "900"],
  variable: "--font-heebo",
});

export const metadata = {
  title: 'פרסומוטו (Pirsumoto) [Patent Pending] - פתרון קצה לקליטה ופרסום רכבים למגרשים',
  description: 'פתרון מוגן בבקשת פטנט (Patent Pending): מכשיר אוטומציה מנוהל MDM הפועל תחת פרטי המשתמש מהמשרד/הבית, בשילוב אפליקציית Pirsumoto Relay ושליטת Human-in-the-Loop מלאה.',
};

export default function RootLayout({ children }) {
  return (
    <html lang="he" dir="rtl" className={`${heebo.variable} scroll-smooth`}>
      <body className="font-sans antialiased bg-slate-50 text-slate-900 selection:bg-blue-600 selection:text-white">
        {children}
      </body>
    </html>
  );
}
