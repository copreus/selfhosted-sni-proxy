#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: Please run as root."
  exit 1
fi

CURRENT_DIR=$(pwd)
if [ "$CURRENT_DIR" != "/root" ]; then
    echo "WARNING: You are running this script in $CURRENT_DIR"
    echo "It is highly recommended to run this in /root to ensure file paths match."
    read -p "Do you want to continue anyway? (y/n): " CONTINUE_ROOT
    if [[ ! "$CONTINUE_ROOT" =~ ^[Yy]$ ]]; then
        echo "Exiting. Please run cd /root and try again."
        exit 1
    fi
fi

INSTALL_DIR="/root/dns-teleport"
if [ -d "$INSTALL_DIR" ]; then
    echo "WARNING: Existing installation detected at $INSTALL_DIR"
    read -p "Do you want to delete it and reinstall? (y/n): " DELETE_EXISTING
    if [[ "$DELETE_EXISTING" =~ ^[Yy]$ ]]; then
        echo "Stopping existing containers..."
        cd "$INSTALL_DIR"
        docker compose down 2>/dev/null
        cd ..
        echo "Removing old files..."
        rm -rf "$INSTALL_DIR"
    else
        echo "Exiting to protect existing files."
        exit 1
    fi
fi

export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

echo "Welcome to the DNS Teleport Installer."

read -p "Enter your Domain (e.g., dns.example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then echo "Domain is required."; exit 1; fi

read -p "Do you want to provide an email for SSL expiry warnings? (y/n): " WANT_EMAIL
if [[ "$WANT_EMAIL" =~ ^[Yy]$ ]]; then
    read -p "Enter your Email Address: " CERT_EMAIL
else
    CERT_EMAIL=""
fi

read -p "Do you want to auto-detect your VPS IP? (y/n): " AUTO_IP
if [[ "$AUTO_IP" =~ ^[Yy]$ ]]; then
    VPS_IP=$(curl -4 -s https://ip.me)
    echo "Detected IPv4: $VPS_IP"
else
    read -p "Enter your VPS IP Address: " VPS_IP
fi

read -p "Enter desired AdGuard Username: " AGH_USER

read -s -p "Enter desired AdGuard Password (text field is blank, but password is being entered): " AGH_PASS
echo ""

echo "Client Setup: This limits access to ONLY your devices."
read -p "Enter a name for your device (e.g., MyiPhone): " CLIENT_NAME
read -p "Enter a Client ID (No spaces, e.g., myiphone): " CLIENT_ID

echo "Updating system and installing dependencies..."
apt-get update -q
apt-get upgrade $APT_OPTS

echo "Installing packages..."
apt-get install $APT_OPTS curl nano ufw certbot dnsmasq nginx libnginx-mod-stream python3-pip python3-bcrypt apache2-utils fail2ban

if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -sSL https://get.docker.com/ | CHANNEL=stable bash
else
    echo "Docker is already installed."
fi

CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ -f "$CERT_FILE" ]; then
    echo "Existing certificates found for $DOMAIN."
    echo "Skipping Certbot to prevent rate limits."
else
    echo "No certificates found. Stopping Nginx to generate new ones..."
    systemctl stop nginx

    echo "Requesting Let's Encrypt Certificate..."
    CERT_CMD="certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos"
    CERT_CMD="$CERT_CMD --pre-hook \"systemctl stop nginx\" --post-hook \"systemctl start nginx\""

    if [ -n "$CERT_EMAIL" ]; then
        CERT_CMD="$CERT_CMD --email $CERT_EMAIL --no-eff-email"
    else
        CERT_CMD="$CERT_CMD --register-unsafely-without-email"
    fi

    eval $CERT_CMD

    if [ ! -f "$CERT_FILE" ]; then
        echo "Error: Certificate generation failed."
        echo "Make sure an A Record for $DOMAIN points to $VPS_IP"
        exit 1
    fi
fi

echo "Hashing password..."
HASHED_PASS=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$AGH_PASS', bcrypt.gensalt()).decode())")

echo "Configuring Dnsmasq..."
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak 2>/dev/null

cat <<EOF > /etc/dnsmasq.conf
listen-address=127.0.0.1
port=5353
bind-interfaces
no-resolv
no-hosts
address=/#/$VPS_IP
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

echo "Configuring Nginx..."
rm /etc/nginx/nginx.conf 2>/dev/null

cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 768;
}

stream {
    resolver 1.1.1.1 ipv6=off;
    
    map \$ssl_preread_server_name \$target_backend {
        $DOMAIN      127.0.0.1:8443;
        default              \$ssl_preread_server_name:443;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$target_backend;
    }
}
EOF

systemctl restart nginx
systemctl enable nginx

echo "Setting up AdGuard Home..."
mkdir -p ~/dns-teleport/adguard/conf
mkdir -p ~/dns-teleport/adguard/work

cat <<EOF > ~/dns-teleport/adguard/conf/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: "0.0.0.0:3000"
  session_ttl: 720h
users:
  - name: "$AGH_USER"
    password: "$HASHED_PASS"
auth_attempts: 5
block_auth_min: 15
dns:
  bind_hosts:
    - "0.0.0.0"
  port: 53
  anonymize_client_ip: false
  upstream_dns:
    - '[/netflix.com/]1.1.1.1'
    - "127.0.0.1:5353"
  upstream_mode: load_balance
  allowed_clients:
    - "$CLIENT_ID"
  trusted_proxies:
    - "127.0.0.0/8"
    - "::1/128"
  cache_enabled: true
  cache_size: 4194304
  aaaa_disabled: true
  enable_dnssec: true
tls:
  enabled: true
  server_name: "$DOMAIN"
  force_https: false
  port_https: 8443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  certificate_path: "$CERT_FILE"
  private_key_path: "$KEY_FILE"
clients:
  persistent:
    - name: "$CLIENT_NAME"
      ids:
        - "$CLIENT_ID"
      tags: []
      upstreams: []
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
schema_version: 31
EOF

cat <<EOF > ~/dns-teleport/docker-compose.yml
version: '3.8'
services:
  adguardhome:
    container_name: adguardhome
    image: adguard/adguardhome:latest
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./adguard/conf:/opt/adguardhome/conf
      - ./adguard/work:/opt/adguardhome/work
      - /etc/letsencrypt:/etc/letsencrypt:ro
    environment:
      - TZ=UTC
EOF

echo "Starting AdGuard Home..."
cd ~/dns-teleport
docker compose up -d

echo "Configuring Security..."
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 853/tcp
ufw allow 8443/tcp
ufw allow 3000/tcp
ufw allow 53/tcp
ufw allow 53/udp
echo "y" | ufw enable

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF

systemctl restart fail2ban

echo ""
echo "INSTALLATION COMPLETE!"
echo "Admin Panel: http://$VPS_IP:3000"
echo "Username:    $AGH_USER"
echo "Password:    (Hidden)"
echo ""
echo "Your Client ID: $CLIENT_ID"
echo "Connection URL: https://$DOMAIN:8443/dns-query/$CLIENT_ID"
echo ""
echo "IMPORTANT: If Port 8443 doesn't work, use Port 443:"
echo "https://$DOMAIN:443/dns-query/$CLIENT_ID"
