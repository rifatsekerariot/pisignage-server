#!/bin/bash
#
# pisignage-server - Ubuntu kurulum ve çalıştırma betiği
# Kullanım: sudo ./install-and-run-ubuntu.sh [--install-service]
#   --install-service : systemd servisi kurar ve açılışta başlatır
#

set -e

# Renkli çıktı
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "${RED}[ERR]${NC} $1"; }

# Root kontrolü
if [ "$EUID" -ne 0 ]; then
  log_err "Bu betiği sudo ile çalıştırın: sudo $0 $*"
  exit 1
fi

INSTALL_SERVICE=false
for arg in "$@"; do
  [ "$arg" = "--install-service" ] && INSTALL_SERVICE=true
done

# Varsayılan kurulum dizini (betik pisignage-server/scripts içinden veya proje kökünden çalıştırılabilir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" == *"/pisignage-server/scripts" ]]; then
  INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
else
  INSTALL_DIR="${PISIGNAGE_INSTALL_DIR:-/opt/pisignage-server}"
fi

REPO_URL="${PISIGNAGE_REPO_URL:-https://github.com/rifatsekerariot/pisignage-server.git}"
NODE_VERSION="${NODE_VERSION:-18}"
PORT="${PORT:-3000}"

log_info "Kurulum dizini: $INSTALL_DIR"
log_info "Port: $PORT"

# --- Ubuntu sürüm kontrolü ---
if [ ! -f /etc/os-release ]; then
  log_err "Bu betik sadece Ubuntu için yazıldı."
  exit 1
fi
. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  log_warn "Tespit: $ID. Betik Ubuntu için test edildi."
fi

# --- 1. Sistem güncellemesi ve bağımlılıklar ---
log_info "Paket listesi güncelleniyor..."
apt-get -qq update
apt-get -y install -qq curl wget git ca-certificates gnupg lsb-release

# --- 2. MongoDB kurulumu ---
if ! command -v mongod &>/dev/null; then
  log_info "MongoDB kuruluyor..."
  # MongoDB 7.x için resmi key ve repo (Ubuntu 20.04, 22.04, 24.04)
  curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
  echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  apt-get -qq update
  apt-get -y install -qq mongodb-org
  systemctl enable mongod 2>/dev/null || true
  systemctl start mongod 2>/dev/null || true
  log_info "MongoDB kuruldu ve başlatıldı."
else
  log_info "MongoDB zaten yüklü."
  systemctl start mongod 2>/dev/null || true
fi

# Veri dizini (eski kurulumlarla uyumluluk)
DBDIR="/data/db"
if [ ! -d "$DBDIR" ]; then
  mkdir -p "$DBDIR"
  chown -R mongodb:mongodb "$DBDIR" 2>/dev/null || chmod -R 755 /data
  log_info "$DBDIR oluşturuldu."
fi

# --- 3. Node.js kurulumu ---
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 18 ]; then
  log_info "Node.js $NODE_VERSION.x kuruluyor..."
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
  apt-get -y install -qq nodejs
  log_info "Node.js $(node -v) kuruldu."
else
  log_info "Node.js zaten yüklü: $(node -v)"
fi

# --- 4. ffmpeg ve ImageMagick ---
if ! command -v ffmpeg &>/dev/null; then
  log_info "ffmpeg ve ImageMagick kuruluyor..."
  apt-get -y install -qq ffmpeg imagemagick
  log_info "ffmpeg ve ImageMagick kuruldu."
else
  log_info "ffmpeg zaten yüklü."
  dpkg -l imagemagick &>/dev/null || apt-get -y install -qq imagemagick
fi

# --- 5. pisignage-server dizini ---
if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/package.json" ]; then
  log_info "Proje klonlanıyor: $REPO_URL"
  if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
  fi
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
else
  log_info "Mevcut kurulum kullanılıyor: $INSTALL_DIR"
  (cd "$INSTALL_DIR" && git pull --rebase 2>/dev/null) || true
fi

# --- 6. media dizinleri (README: ../media ve ../media/_thumbnails) ---
MEDIA_DIR="$(dirname "$INSTALL_DIR")/media"
mkdir -p "$MEDIA_DIR/_thumbnails"
chmod -R 755 "$MEDIA_DIR"
log_info "Medya dizinleri: $MEDIA_DIR"

# --- 7. npm bağımlılıkları ---
log_info "npm install çalıştırılıyor..."
cd "$INSTALL_DIR"
npm install --production 2>/dev/null || npm install
cd - >/dev/null

# --- 8. Ortam ve çalıştırma ---
export NODE_ENV=development
export PORT="$PORT"

if [ "$INSTALL_SERVICE" = true ]; then
  # --- systemd servisi ---
  log_info "systemd servisi kuruluyor..."
  cat > /etc/systemd/system/pisignage.service << EOF
[Unit]
Description=piSignage Server
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/node $INSTALL_DIR/server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=development
Environment=PORT=$PORT

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable pisignage
  systemctl start pisignage
  log_info "Servis başlatıldı. Durum: systemctl status pisignage"
  log_info "Log: journalctl -u pisignage -f"
else
  log_info "Servis kurulmadı. Sunucuyu elle başlatmak için:"
  echo ""
  echo "  cd $INSTALL_DIR && NODE_ENV=development PORT=$PORT node server.js"
  echo ""
  echo "Arka planda çalıştırmak için:"
  echo "  cd $INSTALL_DIR && nohup node server.js >> /var/log/pisignage.log 2>&1 &"
  echo ""
fi

# Kısa bilgi
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
log_info "Kurulum tamamlandı."
echo ""
echo -e "${GREEN}  piSignage Server${NC}"
echo "  Adres: http://${IP:-localhost}:$PORT"
echo "  Varsayılan giriş: kullanıcı pi, şifre pi"
echo "  Ayarlar sayfasından pisignage.com kullanıcı adınızı ve lisansları yapılandırın."
echo ""
