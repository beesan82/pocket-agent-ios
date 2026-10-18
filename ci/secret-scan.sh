#!/usr/bin/env bash
# Fail if anything that looks like a real credential is committed (AT-11, minimal).
# Prints only file:line, never the matched value.
set -euo pipefail

PATTERNS='sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|CLAUDE_CODE_OAUTH_TOKEN *[:=] *[^ $]|-----BEGIN (RSA |EC )?PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}'

if git grep -nIE "${PATTERNS}" -- . ':!ci/secret-scan.sh' | cut -d: -f1,2; then
  echo "::error::Possible secret committed (values hidden). Remove it and rotate the key."
  exit 1
fi
echo "secret-scan: clean"
