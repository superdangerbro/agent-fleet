import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // The company registry is read from disk at request time (see lib/companies.ts);
  // make sure a local companies.json ships with the serverless bundle when present.
  outputFileTracingIncludes: { "/**/*": ["./companies.json", "./companies.example.json"] },
};

export default nextConfig;
