import type { ReactNode } from "react"
import "./globals.css"

export const metadata = {
  title: "SFLuv Migrator",
  description: "Berachain → Celo migration control panel",
  icons: "/icon.png",
}

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
