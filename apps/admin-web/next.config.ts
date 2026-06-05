import type { NextConfig } from "next"
import { withSentryConfig } from "@sentry/nextjs"

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  compress: true,
}

export default withSentryConfig(nextConfig, {
  org: "olimpo-um",
  project: "olimpo-admin",
  silent: !process.env.CI,
  disableLogger: true,
})
