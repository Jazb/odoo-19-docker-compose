#!/bin/bash
set -euo pipefail

# ==============================================================================
# Odoo 19 Docker Compose - Cross-platform deployment script (Linux & macOS)
# ==============================================================================

# --- Argument parsing ---------------------------------------------------------
DESTINATION=""
PORT=""
CHAT=""
PASSWORD=""
DB_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --destination) DESTINATION="$2"; shift 2 ;;
    --port)        PORT="$2";        shift 2 ;;
    --chat)        CHAT="$2";        shift 2 ;;
    --password)    PASSWORD="$2";    shift 2 ;;
    --db-password) DB_PASSWORD="$2"; shift 2 ;;
    *)
      echo "Error: Unknown option: $1" >&2
      echo "Usage: $0 --destination <path> --port <port> --chat <chat_port> [--password <master_password>] [--db-password <db_password>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DESTINATION" || -z "$PORT" || -z "$CHAT" ]]; then
  echo "Error: Missing required arguments" >&2
  echo "Usage: $0 --destination <path> --port <port> --chat <chat_port> [--password <master_password>] [--db-password <db_password>]" >&2
  exit 1
fi

# --- Platform detection -------------------------------------------------------
IS_MACOS=false
[[ "$OSTYPE" == "darwin"* ]] && IS_MACOS=true

# --- Cross-platform helpers ---------------------------------------------------

# Portable sed -i (macOS requires '' argument, GNU sed does not)
sedi() {
  if $IS_MACOS; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Escape special characters for sed replacement strings
escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&]/\\&/g'
}

# Determine the docker compose command (v2 plugin vs standalone v1)
docker_compose_cmd() {
  local prefix=""
  if ! docker ps >/dev/null 2>&1; then
    echo "Docker requires sudo privileges" >&2
    prefix="sudo"
  fi

  if docker compose version >/dev/null 2>&1; then
    echo "$prefix docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "$prefix docker-compose"
  else
    echo "Error: Neither 'docker compose' nor 'docker-compose' found" >&2
    exit 1
  fi
}

# --- Clone repository ---------------------------------------------------------
echo "Cloning Odoo 19 Docker Compose into '$DESTINATION'..."
git clone --depth=1 https://github.com/Jazb/odoo-19-docker-compose "$DESTINATION"
rm -rf "$DESTINATION/.git"

# --- Read defaults from config ------------------------------------------------
CONFIG_PATH="$DESTINATION/etc/odoo.conf"
COMPOSE_PATH="$DESTINATION/docker-compose.yml"

DEFAULT_ADMIN_PASSWD="$(grep -E '^[[:space:]]*admin_passwd[[:space:]]*=' "$CONFIG_PATH" \
  | head -n 1 \
  | sed -E 's/^[[:space:]]*admin_passwd[[:space:]]*=[[:space:]]*//')"

DEFAULT_DB_PASSWORD="$(grep -E '^[[:space:]]*-[[:space:]]*POSTGRES_PASSWORD=' "$COMPOSE_PATH" \
  | head -n 1 \
  | sed -E 's/^[[:space:]]*-[[:space:]]*POSTGRES_PASSWORD=//')"

if [[ -z "$PASSWORD" ]]; then
  # Temporarily disable pipefail to prevent SIGPIPE from tr when head closes the pipe
  set +o pipefail
  MASTER_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  set -o pipefail
else
  MASTER_PASSWORD="$PASSWORD"
fi
EFFECTIVE_DB_PASSWORD="${DB_PASSWORD:-$DEFAULT_DB_PASSWORD}"

# --- Prepare filesystem -------------------------------------------------------
mkdir -p "$DESTINATION/postgresql"

# Set ownership to current user:primary_group (works on both Linux and macOS)
USER_GROUP="$(id -gn)"
chown -R "$USER:$USER_GROUP" "$DESTINATION"

# Set standard permissions: 755 for dirs, 644 for files
find "$DESTINATION" -type d -exec chmod 755 {} \;
find "$DESTINATION" -type f -exec chmod 644 {} \;
chmod +x "$DESTINATION/entrypoint.sh"

# --- System tuning (Linux only) -----------------------------------------------
if ! $IS_MACOS; then
  SYSCTL_KEY="fs.inotify.max_user_watches"
  if grep -qF "$SYSCTL_KEY" /etc/sysctl.conf; then
    echo "inotify already configured: $(grep -F "$SYSCTL_KEY" /etc/sysctl.conf)"
  else
    echo "$SYSCTL_KEY = 524288" | sudo tee -a /etc/sysctl.conf
  fi
  sudo sysctl -p
fi

# --- Apply configuration -----------------------------------------------------

# Ports
sedi "s/10019/$PORT/g" "$COMPOSE_PATH"
sedi "s/20019/$CHAT/g" "$COMPOSE_PATH"

# Master password (always apply, whether generated or provided)
ESCAPED="$(escape_sed_replacement "$MASTER_PASSWORD")"
sedi -E "s/^[[:space:]]*admin_passwd[[:space:]]*=.*/admin_passwd = $ESCAPED/" "$CONFIG_PATH"

# Database password (only if explicitly provided)
if [[ -n "$DB_PASSWORD" ]]; then
  ESCAPED="$(escape_sed_replacement "$DB_PASSWORD")"
  sedi -E "s/^([[:space:]]*-[[:space:]]*POSTGRES_PASSWORD=).*/\\1$ESCAPED/" "$COMPOSE_PATH"
  sedi -E "s/^([[:space:]]*-[[:space:]]*PASSWORD=).*/\\1$ESCAPED/" "$COMPOSE_PATH"
fi

# --- Start Odoo ---------------------------------------------------------------
COMPOSE="$(docker_compose_cmd)"
$COMPOSE -f "$COMPOSE_PATH" up -d

echo ""
echo "============================================================"
echo " Odoo started successfully!"
echo "------------------------------------------------------------"
echo " URL:             http://localhost:$PORT"
echo " Live chat:       http://localhost:$CHAT"
echo " Master password: $MASTER_PASSWORD"
echo " DB password:     $EFFECTIVE_DB_PASSWORD"
echo "============================================================"
