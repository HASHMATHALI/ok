#!/bin/bash
# =============================================================================
# Vellum RAG — Automated AWS EC2 Deployment Script
# Usage: EC2_HOST=<public-ip> EC2_KEY=~/.ssh/<key>.pem ./deploy.sh
# The SSH key must live OUTSIDE this repository. A .env file with the required
# secrets (see .env.example) must exist next to this script; it is synced to the server.
# =============================================================================

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
EC2_HOST="${EC2_HOST:?Set EC2_HOST to the server public IP or hostname}"
EC2_USER="${EC2_USER:-ubuntu}"
EC2_KEY="${EC2_KEY:?Set EC2_KEY to the path of your SSH private key (keep it outside the repo)}"
REMOTE_DIR="/home/ubuntu/rag"
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${CYAN}[$(date +%H:%M:%S)] $*${NC}"; }
ok()     { echo -e "${GREEN}[✓] $*${NC}"; }
warn()   { echo -e "${YELLOW}[⚠] $*${NC}"; }
error()  { echo -e "${RED}[✗] $*${NC}"; exit 1; }

# ── Validate SSH key ───────────────────────────────────────────────────────────
log "Step 1/8: Validating SSH key..."
if [ ! -f "$EC2_KEY" ]; then
    error "SSH key not found at $EC2_KEY."
fi
if [ ! -f "$LOCAL_DIR/.env" ]; then
    error "Missing $LOCAL_DIR/.env. Copy .env.example to .env and fill in the secrets first."
fi
chmod 400 "$EC2_KEY"
ok "SSH key validated."

# ── Test SSH connectivity ──────────────────────────────────────────────────────
log "Step 2/8: Testing SSH connectivity to $EC2_HOST..."
if ! ssh -i "$EC2_KEY" -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
    "$EC2_USER@$EC2_HOST" "echo 'SSH OK'" 2>/dev/null; then
    error "Cannot connect to EC2. Check security group (port 22) and key pair."
fi
ok "SSH connection successful."

# ── Bootstrap EC2: swap + docker ──────────────────────────────────────────────
log "Step 3/8: Bootstrapping EC2 (swap, Docker, Docker Compose)..."
ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_USER@$EC2_HOST" << 'REMOTE_BOOTSTRAP'
set -e

# ── Configure 4GB Swap (required for docker build on t3.micro) ──────────────
if ! swapon --show | grep -q swapfile; then
    echo "[SWAP] Creating 4GB swap file..."
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "[SWAP] Swap configured: $(free -h | grep Swap)"
else
    echo "[SWAP] Swap already configured."
fi

# ── Install Docker ───────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "[DOCKER] Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker ubuntu
    echo "[DOCKER] Docker installed: $(docker --version)"
else
    echo "[DOCKER] Docker already installed: $(docker --version)"
fi

# ── Verify Docker Compose v2 ─────────────────────────────────────────────────
if ! docker compose version &>/dev/null; then
    echo "[COMPOSE] Installing Docker Compose plugin..."
    sudo apt-get install -y -qq docker-compose-plugin
fi
echo "[COMPOSE] Docker Compose: $(docker compose version)"

REMOTE_BOOTSTRAP
ok "EC2 bootstrap complete."

# ── Sync project files ────────────────────────────────────────────────────────
log "Step 4/8: Syncing project files to EC2..."
ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_USER@$EC2_HOST" "mkdir -p $REMOTE_DIR"
rsync -avz --progress \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='.next' \
    --exclude='dist' \
    --exclude='*.pem' \
    -e "ssh -i $EC2_KEY -o StrictHostKeyChecking=accept-new" \
    "$LOCAL_DIR/" "$EC2_USER@$EC2_HOST:$REMOTE_DIR/"
ok "Files synced to $REMOTE_DIR."

# ── Copy SSH key permissions & build + start services ────────────────────────
log "Step 5/8: Building and starting Docker services..."
ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_USER@$EC2_HOST" << REMOTE_DEPLOY
set -e
cd "$REMOTE_DIR"

echo "[BUILD] Stopping any existing containers..."
docker compose down --remove-orphans 2>/dev/null || true

echo "[BUILD] Pulling base images..."
docker compose pull postgres redis qdrant 2>/dev/null || true

echo "[BUILD] Building and starting all services (this may take 10-15 min for first build)..."
docker compose up --build -d

echo "[STATUS] Waiting 30s for services to initialize..."
sleep 30
REMOTE_DEPLOY
ok "Docker services started."

# ── Health check loop ─────────────────────────────────────────────────────────
log "Step 6/8: Verifying container health..."
ssh -i "$EC2_KEY" -o StrictHostKeyChecking=accept-new "$EC2_USER@$EC2_HOST" << 'REMOTE_HEALTH'
set -e
cd /home/ubuntu/rag

echo "[HEALTH] Container status:"
docker compose ps

echo ""
echo "[HEALTH] Checking individual containers..."

# Wait for backend to be ready (up to 3 minutes)
echo "[HEALTH] Waiting for backend API..."
for i in $(seq 1 36); do
    if docker compose exec -T backend curl -sf http://localhost:8000/ > /dev/null 2>&1; then
        echo "[✓] Backend is healthy."
        break
    fi
    if [ $i -eq 36 ]; then
        echo "[✗] Backend did not become healthy in time."
        echo "--- Backend logs (last 50 lines) ---"
        docker compose logs --tail=50 backend
    fi
    echo "  Attempt $i/36 — waiting 5s..."
    sleep 5
done

# Check postgres
if docker compose exec -T postgres pg_isready -U postgres -d rag_db > /dev/null 2>&1; then
    echo "[✓] PostgreSQL is healthy."
else
    echo "[✗] PostgreSQL not ready."
    docker compose logs --tail=30 postgres
fi

# Check redis
if docker compose exec -T redis redis-cli ping | grep -q PONG; then
    echo "[✓] Redis is healthy."
else
    echo "[✗] Redis not ready."
fi

# Check qdrant
if curl -sf http://localhost:6333/healthz > /dev/null 2>&1; then
    echo "[✓] Qdrant is healthy."
else
    echo "[!] Qdrant health check (may still be starting)."
fi

REMOTE_HEALTH

# ── Endpoint validation ───────────────────────────────────────────────────────
log "Step 7/8: Validating public endpoints..."
sleep 10

echo ""
echo "── API Root Test ──"
if curl -sf --max-time 15 "http://$EC2_HOST/api/" | python3 -m json.tool 2>/dev/null; then
    ok "Backend API /api/ is responding."
else
    warn "API root check failed — trying /api/health..."
    curl -v "http://$EC2_HOST/" 2>&1 | tail -20
fi

echo ""
echo "── Frontend Test ──"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://$EC2_HOST/")
if [ "$HTTP_CODE" = "200" ]; then
    ok "Frontend is accessible (HTTP $HTTP_CODE)."
else
    warn "Frontend returned HTTP $HTTP_CODE."
fi

echo ""
echo "── Docs Test ──"
HTTP_DOCS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "http://$EC2_HOST/docs")
if [ "$HTTP_DOCS" = "200" ]; then
    ok "Swagger docs accessible (HTTP $HTTP_DOCS)."
else
    warn "Docs returned HTTP $HTTP_DOCS."
fi

# ── Final summary ─────────────────────────────────────────────────────────────
log "Step 8/8: Deployment complete!"
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Vellum RAG — Successfully Deployed"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  🌐 Frontend:     http://$EC2_HOST"
echo "  🔌 API:          http://$EC2_HOST/api/"
echo "  📚 Swagger:      http://$EC2_HOST/docs"
echo "  🐘 PostgreSQL / Redis / Qdrant are bound to localhost on the server (use an SSH tunnel)"
echo ""
echo "  👤 Admin Login:  the ADMIN_EMAIL / ADMIN_PASSWORD from your .env"
echo ""
echo "  📋 SSH:          ssh -i $EC2_KEY $EC2_USER@$EC2_HOST"
echo "  📋 Logs:         ssh -i $EC2_KEY $EC2_USER@$EC2_HOST 'cd /home/ubuntu/rag && docker compose logs -f'"
echo ""
