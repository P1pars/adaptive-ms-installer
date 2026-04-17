#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ADMIN_SCRIPT="$INSTALL_DIR/create-admin.sh"
IMAGE_NAME="hubadaptive/adaptive-ms:latest"
APP_CONTAINER="adaptive-ms"
DB_CONTAINER="adaptive-db"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Lūdzu palaidiet šo skriptu ar sudo."
  exit 1
fi

COMPOSE_CMD=""

print_header() {
  echo "=== Adaptive MS instalators ==="
  echo
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    echo "Kļūda: Docker Compose nav pieejams."
    exit 1
  fi
}

check_requirements() {
  command -v docker >/dev/null 2>&1 || {
    echo "Kļūda: Docker nav instalēts."
    exit 1
  }

  docker info >/dev/null 2>&1 || {
    echo "Kļūda: Docker serviss nav palaists vai nav pieejams."
    echo "Pārliecinieties, ka Docker darbojas, un mēģiniet vēlreiz."
    exit 1
  }

  detect_compose
}

ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
  chmod 700 "$INSTALL_DIR"
}

prompt_password_twice() {
  local var_name="$1"
  local prompt_label="$2"
  local value confirm

  while true; do
    read -rsp "${prompt_label}: " value
    echo
    read -rsp "Confirm ${prompt_label}: " confirm
    echo

    if [[ -z "$value" ]]; then
      echo "Kļūda: ${prompt_label} nedrīkst būt tukša."
      continue
    fi

    if [[ "$value" == "$confirm" ]]; then
      printf -v "$var_name" '%s' "$value"
      break
    fi

    echo "Kļūda: paroles nesakrīt. Mēģiniet vēlreiz."
  done
}

collect_configuration() {
  echo "Tiks prasīti datubāzes un administratora piekļuves dati."
  echo "Paroles būs jāievada divreiz, lai pārliecinātos, ka tās sakrīt."
  echo

  read -rp "POSTGRES_USER [monitoringdb]: " POSTGRES_USER
  POSTGRES_USER="${POSTGRES_USER:-monitoringdb}"

  prompt_password_twice POSTGRES_PASSWORD "POSTGRES_PASSWORD"

  read -rp "POSTGRES_DB [adaptivems]: " POSTGRES_DB
  POSTGRES_DB="${POSTGRES_DB:-adaptivems}"

  read -rp "ADMIN_EMAIL [admin@local]: " ADMIN_EMAIL
  ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local}"

  read -rp "ADMIN_USERNAME [admin]: " ADMIN_USERNAME
  ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

  prompt_password_twice ADMIN_PASSWORD "ADMIN_PASSWORD"
}

load_existing_env() {
  set -a
  source "$ENV_FILE"
  set +a
}

validate_basic_inputs() {
  case "$ADMIN_EMAIL" in
    *"'"*|*'"'*)
      echo "Kļūda: ADMIN_EMAIL nedrīkst saturēt pēdiņas."
      exit 1
      ;;
  esac

  case "$ADMIN_USERNAME" in
    *"'"*|*'"'*)
      echo "Kļūda: ADMIN_USERNAME nedrīkst saturēt pēdiņas."
      exit 1
      ;;
  esac
}

write_env_file() {
  cat > "$ENV_FILE" <<ENV_EOF
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENV_EOF

  chmod 600 "$ENV_FILE"
}

write_compose_file() {
  cat > "$COMPOSE_FILE" <<'COMPOSE_EOF'
version: '3.8'

services:
  db:
    image: postgres:15
    container_name: adaptive-db
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - adaptive_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 20

  app:
    image: hubadaptive/adaptive-ms:latest
    container_name: adaptive-ms
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "3000:3000"
    environment:
      DATABASE_URL: postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}
    depends_on:
      db:
        condition: service_healthy

volumes:
  adaptive_data:
COMPOSE_EOF
}

write_admin_script() {
  cat > "$ADMIN_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"
ENV_FILE="$INSTALL_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Kļūda: .env fails nav atrasts."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

HASH=$(docker exec adaptive-ms node -e "const bcrypt = require('bcryptjs'); console.log(bcrypt.hashSync(process.argv[1], 10));" "$ADMIN_PASSWORD")

docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;' >/dev/null

docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
INSERT INTO \"User\" (id, email, username, \"passwordHash\", role, created_at)
VALUES (gen_random_uuid()::text, '$ADMIN_EMAIL', '$ADMIN_USERNAME', '$HASH', 'ADMIN', NOW())
ON CONFLICT (email) DO NOTHING;
" >/dev/null

echo "Admin lietotājs ir pārbaudīts/izveidots veiksmīgi."
SCRIPT_EOF

  chmod +x "$ADMIN_SCRIPT"
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -qE '(^|:)3000$'
    return
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:3000 -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  return 1
}

ensure_port_available_for_fresh_install() {
  if port_in_use; then
    echo "Kļūda: ports 3000 jau tiek izmantots."
    echo "Atbrīvojiet portu 3000 un mēģiniet vēlreiz."
    exit 1
  fi
}

ensure_image_available() {
  echo
  echo "Pārbauda Adaptive MS attēla pieejamību..."

  if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Adaptive MS attēls jau ir pieejams lokāli."
    return
  fi

  echo "Lokālais attēls nav atrasts. Mēģina lejupielādēt no Docker Hub..."

  if ! docker pull "$IMAGE_NAME"; then
    echo
    echo "Kļūda: neizdevās lejupielādēt $IMAGE_NAME"
    echo "Pārliecinieties, ka esat autorizējies Docker Hub:"
    echo "  docker login -u hubadaptive"
    echo
    echo "Ja skripts tiek palaists ar sudo, var būt nepieciešams arī:"
    echo "  sudo docker login -u hubadaptive"
    exit 1
  fi
}

compose_up() {
  cd "$INSTALL_DIR"
  $COMPOSE_CMD up -d
}

compose_down_keep_data() {
  cd "$INSTALL_DIR"
  $COMPOSE_CMD down || true
}

compose_down_delete_data() {
  cd "$INSTALL_DIR"
  $COMPOSE_CMD down -v || true
}

wait_for_postgres() {
  echo
  echo "Gaida, kamēr PostgreSQL būs gatavs darbam..."

  local retries=60
  local count=0

  until docker exec "$DB_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    count=$((count + 1))
    if [[ "$count" -ge "$retries" ]]; then
      echo "Kļūda: PostgreSQL nekļuva gatavs paredzētajā laikā."
      exit 1
    fi
    sleep 2
  done
}

ensure_containers_running() {
  docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || {
    echo "Kļūda: $DB_CONTAINER konteiners nedarbojas."
    exit 1
  }

  docker ps --format '{{.Names}}' | grep -qx "$APP_CONTAINER" || {
    echo "Kļūda: $APP_CONTAINER konteiners nedarbojas."
    exit 1
  }
}

get_server_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

print_existing_success() {
  local server_ip
  server_ip="$(get_server_ip)"

  echo
  echo "Adaptive MS ir palaists ar esošo konfigurāciju."
  if [[ -n "$server_ip" ]]; then
    echo "URL: http://${server_ip}:3000"
  else
    echo "URL: http://SERVER_IP:3000"
  fi
  echo "Lietotājvārds: ${ADMIN_USERNAME}"
  echo "Parole: iepriekš konfigurētā parole"
}

print_fresh_success() {
  local server_ip
  server_ip="$(get_server_ip)"

  echo
  echo "Adaptive MS ir veiksmīgi uzstādīts."
  if [[ -n "$server_ip" ]]; then
    echo "URL: http://${server_ip}:3000"
  else
    echo "URL: http://SERVER_IP:3000"
  fi
  echo "Lietotājvārds: ${ADMIN_USERNAME}"
  echo "Parole: tā, kuru ievadījāt ADMIN_PASSWORD laukā"
}

start_existing_install() {
  echo
  echo "Tiek izmantota esošā konfigurācija no $ENV_FILE"

  load_existing_env

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Docker Compose fails netika atrasts. Tiek izveidots no jauna."
    write_compose_file
  fi

  if [[ ! -f "$ADMIN_SCRIPT" ]]; then
    echo "Admin lietotāja izveides skripts netika atrasts. Tiek izveidots no jauna."
    write_admin_script
  fi

  compose_up
  ensure_containers_running
  print_existing_success
}

fresh_install() {
  echo "Esoša konfigurācija netika atrasta. Tiek veikta jauna uzstādīšana."
  echo

  collect_configuration
  validate_basic_inputs
  ensure_port_available_for_fresh_install
  write_env_file
  write_compose_file
  write_admin_script
  ensure_image_available

  compose_down_delete_data
  compose_up
  wait_for_postgres
  ensure_containers_running
  "$ADMIN_SCRIPT"
  print_fresh_success
}

clean_reinstall() {
  echo
  echo "Tiks veikta pilna pārinstalēšana."
  echo "Tas dzēsīs esošos konteinerus un datubāzes datus šajā serverī."
  read -rp "Turpināt? [y/N]: " CONFIRM_REINSTALL

  if [[ ! "$CONFIRM_REINSTALL" =~ ^[Yy]$ ]]; then
    echo "Darbība atcelta."
    exit 0
  fi

  echo
  collect_configuration
  validate_basic_inputs
  compose_down_delete_data
  ensure_port_available_for_fresh_install
  write_env_file
  write_compose_file
  write_admin_script
  ensure_image_available

  compose_up
  wait_for_postgres
  ensure_containers_running
  "$ADMIN_SCRIPT"
  print_fresh_success
}

main() {
  print_header
  check_requirements
  ensure_install_dir

  if [[ -f "$ENV_FILE" && -f "$COMPOSE_FILE" ]]; then
    echo "Atrasta esoša Adaptive MS konfigurācija."
    echo "1) Izmantot esošo konfigurāciju un palaist sistēmu"
    echo "2) Dzēst visu un veikt jaunu uzstādīšanu"
    echo
    read -rp "Izvēle [1/2]: " EXISTING_CHOICE

    case "$EXISTING_CHOICE" in
      1)
        start_existing_install
        ;;
      2)
        clean_reinstall
        ;;
      *)
        echo "Nederīga izvēle."
        exit 1
        ;;
    esac
  else
    fresh_install
  fi
}

main "$@"
