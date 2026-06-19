import { Heebo } from "next/font/google";
import "./globals.css";

const heebo = Heebo({
  subsets: ["hebrew", "latin"],
  weight: ["300", "400", "500", "700", "900"],
  variable: "--font-heebo",
});

export const metadata = {
  title: 'מחירוטו - פתרון קצה לקליטה ופרסום רכבים למגרשים',
  description: 'מערכת פנימית לניהול מלאי, טיב תמונות, ופרסום אוטומטי של רכבים ליד2, קארוויז ואתרי המגרש.',
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
