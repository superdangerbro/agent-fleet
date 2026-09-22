import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { listCompanies } from "@/lib/companies";

export const metadata: Metadata = { title: "Fleet console" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  const companies = listCompanies();
  return (
    <html lang="en">
      <body>
        <header className="top">
          <Link href="/" className="brand">FLEET</Link>
          <nav>
            {companies.map((c) => (
              <Link key={c.slug} href={`/c/${c.slug}`}>{c.name}</Link>
            ))}
          </nav>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
