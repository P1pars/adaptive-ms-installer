#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ADMIN_SCRIPT="$INSTALL_DIR/create-admin.sh"
IMAGE_NAME="hubadaptive/adaptive-ms:latest"

if [[ "$EUID" -ne 0 ]]; then
  echo "Lūdzu palaidiet šo skriptu ar sudo."
  exit 1
fi

check_requirements() {
  command -v docker >/dev/null 2>&1 || {
    echo "Kļūda: Docker nav instalēts."
    exit 1
  }

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
  else
    echo "Kļūda: Docker Compose nav pieejams."
    exit 1
  fi
}

echo "=== Adaptive MS instalators ==="
echo

mkdir -p "$INSTALL_DIR"
check_requirements

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
      - db

volumes:
  adaptive_data:
COMPOSE_EOF
}

write_admin_script() {
  cat > "$ADMIN_SCRIPT" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"
set -a
source "$INSTALL_DIR/.env"
set +a

HASH=$(sudo docker exec adaptive-ms node -e "const bcrypt = require('bcryptjs'); console.log(bcrypt.hashSync(process.argv[1], 10));" "$ADMIN_PASSWORD")

sudo docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;'

sudo docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
INSERT INTO \"User\" (id, email, username, \"passwordHash\", role, created_at)
VALUES (gen_random_uuid()::text, '$ADMIN_EMAIL', '$ADMIN_USERNAME', '$HASH', 'ADMIN', NOW())
ON CONFLICT (email) DO NOTHING;
"
SCRIPT_EOF

  chmod +x "$ADMIN_SCRIPT"
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
    else
      echo "Kļūda: paroles nesakrīt. Mēģiniet vēlreiz."
    fi
  done
}

collect_configuration() {
  echo
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

check_docker_hub_access() {
  echo
  echo "Pārbauda Docker Hub piekļuvi Adaptive MS attēlam..."

  if ! docker pull "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "Kļūda: neizdevās lejupielādēt $IMAGE_NAME"
    echo "Pārliecinieties, ka esat izpildījis:"
    echo "  docker login -u hubadaptive"
    echo
    echo "Ja instalators tiek palaists ar sudo un piekļuve joprojām nedarbojas, izpildiet arī:"
    echo "  sudo docker login -u hubadaptive"
    exit 1
  fi

  echo "Docker Hub piekļuve ir veiksmīga."
}

wait_for_postgres() {
  echo
  echo "Gaida, kamēr PostgreSQL būs gatavs darbam..."
  until sudo docker exec adaptive-db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    sleep 2
  done
}

start_existing_install() {
  echo
  echo "Tiek izmantota esošā konfigurācija no $ENV_FILE"

  set -a
  source "$ENV_FILE"
  set +a

  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Docker Compose fails netika atrasts. Tiek izveidots no jauna."
    write_compose_file
  fi

  if [[ ! -f "$ADMIN_SCRIPT" ]]; then
    echo "Admin lietotāja izveides skripts netika atrasts. Tiek izveidots no jauna."
    write_admin_script
  fi

  cd "$INSTALL_DIR"
  $COMPOSE_CMD up -d

  SERVER_IP=$(hostname -I | awk '{print $1}')

  echo
  echo "Adaptive MS ir palaists ar esošo konfigurāciju."
  echo "URL: http://${SERVER_IP}:3000"
  echo "Lietotājvārds: ${ADMIN_USERNAME}"
  echo "Parole: iepriekš konfigurētā parole"
}

fresh_install() {
  collect_configuration
  write_env_file
  write_compose_file
  write_admin_script
  check_docker_hub_access

  cd "$INSTALL_DIR"
  $COMPOSE_CMD down -v || true
  $COMPOSE_CMD up -d

  wait_for_postgres
  "$ADMIN_SCRIPT"

  SERVER_IP=$(hostname -I | awk '{print $1}')

  echo
  echo "Adaptive MS ir veiksmīgi uzstādīts."
  echo "URL: http://${SERVER_IP}:3000"
  echo "Lietotājvārds: ${ADMIN_USERNAME}"
  echo "Parole: tā, kuru ievadījāt ADMIN_PASSWORD laukā"
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

  collect_configuration
  write_env_file
  write_compose_file
  write_admin_script
  check_docker_hub_access

  cd "$INSTALL_DIR"
  $COMPOSE_CMD down -v || true
  $COMPOSE_CMD up -d

  wait_for_postgres
  "$ADMIN_SCRIPT"

  SERVER_IP=$(hostname -I | awk '{print $1}')

  echo
  echo "Adaptive MS ir veiksmīgi pārinstalēts."
  echo "URL: http://${SERVER_IP}:3000"
  echo "Lietotājvārds: ${ADMIN_USERNAME}"
  echo "Parole: tā, kuru ievadījāt ADMIN_PASSWORD laukā"
}

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
  echo "Esoša konfigurācija netika atrasta. Tiek veikta jauna uzstādīšana."
  fresh_install
fi
