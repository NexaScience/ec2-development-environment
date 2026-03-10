#!/bin/bash

set -e

echo "### MCP Servers and Plugins Setup ###"

# Vercel MCP
echo "[1/5] Adding Vercel MCP server..."
claude mcp add --transport http vercel https://mcp.vercel.com || true

# Railway MCP
echo "[2/5] Checking Railway login status..."
if railway whoami &>/dev/null; then
  echo "  -> Already logged in to Railway"
else
  echo "  -> Not logged in. Run 'railway login' manually to use Railway MCP."
fi
echo "[2/5] Adding Railway MCP server..."
claude mcp add Railway npx @railway/mcp-server || true

# Subframe Plugin
echo "[3/5] Installing Subframe plugin..."
claude plugin marketplace add https://github.com/SubframeApp/subframe || true
claude plugin install subframe@subframe || true

# Supabase MCP
echo "[4/5] Adding Supabase MCP server..."
claude mcp add --transport http supabase "https://mcp.supabase.com/mcp" || true

# Stripe MCP
echo "[5/5] Adding Stripe MCP server..."
claude mcp add --transport http stripe https://mcp.stripe.com/ || true

echo ""
echo "### MCP Servers and Plugins setup complete ###"
