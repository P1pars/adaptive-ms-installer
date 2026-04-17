set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"

echo "=== Adaptive MS instalators ==="

echo
echo "Tiks prasīti datubāzes un administratora piekļuves dati."
echo "Paroles būs jāievada divreiz, lai pārliecinātos, ka tās sakrīt."
echo

read -rp "POSTGRES_USER [monitoringdb]: " POSTGRES_USER
POSTGRES_USER="${POSTGRES_USER:-monitoringdb}"

while true; do
  read -rsp "POSTGRES_PASSWORD: " POSTGRES_PASSWORD
  echo
  read -rsp "Confirm POSTGRES_PASSWORD: " POSTGRES_PASSWORD_CONFIRM
  echo

  if [[ -z "$POSTGRES_PASSWORD" ]]; then
    echo "Kļūda: POSTGRES_PASSWORD nedrīkst būt tukša."
    continue
  fi

  if [[ "$POSTGRES_PASSWORD" == "$POSTGRES_PASSWORD_CONFIRM" ]]; then
    break
  else
    echo "Kļūda: paroles nesakrīt. Mēģiniet vēlreiz."
  fi
done

read -rp "POSTGRES_DB [adaptivems]: " POSTGRES_DB
POSTGRES_DB="${POSTGRES_DB:-adaptivems}"

read -rp "ADMIN_EMAIL [admin@local]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@local}"

read -rp "ADMIN_USERNAME [admin]: " ADMIN_USERNAME
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"

while true; do
  read -rsp "ADMIN_PASSWORD: " ADMIN_PASSWORD
  echo
  read -rsp "Confirm ADMIN_PASSWORD: " ADMIN_PASSWORD_CONFIRM
  echo

  if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "Kļūda: ADMIN_PASSWORD nedrīkst būt tukša."
    continue
  fi

  if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
    break
  else
    echo "Kļūda: paroles nesakrīt. Mēģiniet vēlreiz."
  fi
done

mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/.env" <<ENV_EOF
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_USERNAME=$ADMIN_USERNAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENV_EOF

chmod 600 "$INSTALL_DIR/.env"

cat > "$INSTALL_DIR/docker-compose.yml" <<'COMPOSE_EOF'
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

cat > "$INSTALL_DIR/create-admin.sh" <<'SCRIPT_EOF'
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/adaptive-ms"
set -a
source "$INSTALL_DIR/.env"
set +a

HASH=$(docker exec adaptive-ms node -e "const bcrypt = require('bcryptjs'); console.log(bcrypt.hashSync(process.argv[1], 10));" "$ADMIN_PASSWORD")

sudo docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'CREATE EXTENSION IF NOT EXISTS pgcrypto;'

sudo docker exec -i adaptive-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
INSERT INTO \"User\" (id, email, username, \"passwordHash\", role, created_at)
VALUES (gen_random_uuid()::text, '$ADMIN_EMAIL', '$ADMIN_USERNAME', '$HASH', 'ADMIN', NOW())
ON CONFLICT (email) DO NOTHING;
"
SCRIPT_EOF

chmod +x "$INSTALL_DIR/create-admin.sh"

cd "$INSTALL_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
else
  COMPOSE_CMD="docker-compose"
fi

$COMPOSE_CMD down -v || true
$COMPOSE_CMD up -d

echo
echo "Gaida, kamēr PostgreSQL būs gatavs darbam..."
until docker exec adaptive-db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  sleep 2
done

"$INSTALL_DIR/create-admin.sh"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo
echo "Adaptive MS ir veiksmīgi uzstādīts."
echo "URL: http://${SERVER_IP}:3000"
echo "Lietotājvārds: ${ADMIN_USERNAME}"
echo "Parole: tā, kuru ievadījāt ADMIN_PASSWORD laukā"
