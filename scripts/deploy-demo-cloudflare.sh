#!/usr/bin/env bash
# Publishes the Keldan DEMO (sample data) to Cloudflare Pages: https://keldan-demo.pages.dev
# First time only: `npx wrangler@3 login` (opens Cloudflare in the browser).
set -e
cd "$(dirname "$0")/.."
VITE_APP=demo OUT_DIR=build/cf-demo npx vite build
npx -y wrangler@3 pages project create keldan-demo --production-branch main 2>/dev/null || true
npx -y wrangler@3 pages deploy build/cf-demo --project-name keldan-demo --branch main --commit-dirty=true
