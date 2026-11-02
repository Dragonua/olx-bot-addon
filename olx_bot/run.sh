#!/bin/sh
set -eu
OPT="${OPTIONS_FILE:-/data/options.json}"
DATA="${DATA_DIR:-/data}"
PY="${PYTHON_BIN:-python3}"
REPO="${REPO_URL:-https://github.com/Dragonua/Bot-OLX-Serth.git}"

# options.json -> змінні середовища (значення екрануються)
eval "$("$PY" - "$OPT" <<'PYEOF'
import json, shlex, sys
o = json.load(open(sys.argv[1]))
m = {"bot_token": "BOT_TOKEN", "admin_chat_id": "ADMIN_CHAT_ID", "gh_token": "GH_TOKEN",
     "gemini_api_key": "GEMINI_API_KEY", "freellm_api_key": "FREELLM_API_KEY",
     "freellm_base_url": "FREELLM_BASE_URL", "olx_proxy": "OLX_PROXY"}
for k, e in m.items():
    v = o.get(k)
    if v:
        print("export %s=%s" % (e, shlex.quote(str(v))))
PYEOF
)"
[ -n "${BOT_TOKEN:-}" ] || { echo "Задайте bot_token у налаштуваннях add-on"; exit 1; }
export DB_PATH="$DATA/olx_bot.db" PORT=8099 TZ_NAME="${TZ_NAME:-Europe/Kyiv}"
WEB_API_TOKEN="$(cat "$DATA/web_api_token" 2>/dev/null || "$PY" -c 'import secrets;print(secrets.token_urlsafe(32))' | tee "$DATA/web_api_token")"
export WEB_API_TOKEN

APP="$DATA/app"
AUTH=""
if [ -n "${GH_TOKEN:-}" ]; then
  AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
fi
gitc() { if [ -n "$AUTH" ]; then git -c "http.extraheader=$AUTH" "$@"; else git "$@"; fi; }
if [ -d "$APP/.git" ]; then
  gitc -C "$APP" pull --ff-only || echo "git pull не вдався — працюю зі збереженою версією"
else
  gitc clone --depth 1 "$REPO" "$APP"
fi

# залежності ставимо лише коли змінився requirements.txt
SUM="$(sha256sum "$APP/requirements.txt" | cut -d' ' -f1)"
if [ ! -x "$DATA/venv/bin/python" ] || [ "$(cat "$DATA/req.sha" 2>/dev/null)" != "$SUM" ]; then
  "$PY" -m venv "$DATA/venv"
  "$DATA/venv/bin/pip" install --no-cache-dir -r "$APP/requirements.txt"
  echo "$SUM" > "$DATA/req.sha"
fi
cd "$APP"

# socat relay: проксіює TLS-з'єднання з Railway до meta.ua через домашній NUC.
# Railway не може підключитись до imap.meta.ua / smtp.meta.ua напряму (IBM/SoftLayer блокується).
# Тут встановлюється прозорий TLS-тунель: Railway → socat (порт 19993/19465) → meta.ua.
# mail-mcp на Railway підключається до localhost:19993 / :19465 з security: plain,
# бо TLS вже завершується socat'ом (OPENSSL клієнт → meta.ua).
# IMAP relay: порт 19993 → imap.meta.ua:993 (IMAP over TLS)
socat TCP4-LISTEN:19993,fork,reuseaddr OPENSSL:imap.meta.ua:993,verify=0 &
# SMTP relay: порт 19465 → smtp.meta.ua:465 (SMTP over TLS)
socat TCP4-LISTEN:19465,fork,reuseaddr OPENSSL:smtp.meta.ua:465,verify=0 &
echo "socat relays started: :19993 → imap.meta.ua:993, :19465 → smtp.meta.ua:465"

exec "$DATA/venv/bin/python" bot.py
