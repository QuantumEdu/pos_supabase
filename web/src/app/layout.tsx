import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Farmacia Salud — POS",
  description: "Sistema de punto de venta",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="es">
      <body className="antialiased">{children}</body>
    </html>
  );
}
