#!/bin/bash
#
# Sadece systemd pisignage servisini kurar (zaten kurulu sunucu için).
# Kullanım: sudo ./install-pisignage-service.sh
#

set -e

if [ "$EUID" -ne 0 ]; then
  echo "Bu betiği sudo ile çalıştırın: sudo $0"
  exit 1
fi

# Betik scripts/ içindeyse kurulum dizini bir üst dizin
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$SCRIPT_DIR" == *"/pisignage-server/scripts" ]]; then
  INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
else
  INSTALL_DIR="${PISIGNAGE_INSTALL_DIR:-/opt/pisignage-server}"
fi

if [ ! -f "$INSTALL_DIR/server.js" ]; then
  echo "Hata: server.js bulunamadı: $INSTALL_DIR"
  echo "PISIGNAGE_INSTALL_DIR ile dizin verebilirsiniz: sudo PISIGNAGE_INSTALL_DIR=/path/to/pisignage-server $0"
  exit 1
fi

PORT="${PORT:-3000}"

# Servisi çalıştıracak kullanıcı: dizin /home/altındaysa o kullanıcı, değilse root
INSTALL_OWNER=$(stat -c '%U' "$INSTALL_DIR" 2>/dev/null || echo "root")
if [ "$INSTALL_OWNER" = "root" ] && [ -d "/home" ]; then
  for u in ubuntu pi; do
    if [ -d "/home/$u" ] && [ -d "$INSTALL_DIR" ]; then
      INSTALL_OWNER="$u"
      break
    fi
  done
fi

echo "Kurulum dizini: $INSTALL_DIR"
echo "Port: $PORT"
echo "Çalıştıran kullanıcı: $INSTALL_OWNER"

cat > /etc/systemd/system/pisignage.service << EOF
[Unit]
Description=piSignage Server
After=network.target mongod.service

[Service]
Type=simple
User=$INSTALL_OWNER
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

echo ""
echo "Servis kuruldu ve başlatıldı."
echo "  Durum:  systemctl status pisignage"
echo "  Log:    journalctl -u pisignage -f"
echo "  Yenile: systemctl restart pisignage"
echo ""
