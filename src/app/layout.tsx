import type { Metadata, Viewport } from "next";
import "./globals.css";
export const metadata: Metadata = { title: "PDV Loja", description: "Ponto de venda e estoque", manifest: "/manifest.webmanifest" };
export const viewport: Viewport = { themeColor: "#0f172a", width: "device-width", initialScale: 1 };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) { return <html lang="pt-BR"><body>{children}<script dangerouslySetInnerHTML={{ __html: "if ('serviceWorker' in navigator) window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => undefined));" }} /></body></html>; }
