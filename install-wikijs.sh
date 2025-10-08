#!/bin/bash
# Instalador automático do Wiki.js no Debian 13 (sem Docker)
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Veja o link: https://wiki.projetoroot.com.br/index.php?title=WikiJS
# Versão: 1.0
# 2025

set -e

echo "=== Instalador Wiki.js para Debian 13 ==="
echo ""
echo "Aviso: Este script vai remover qualquer instalação existente do Wiki.js,"
echo "incluindo o banco de dados 'wikijs', o usuário 'wikijsuser' e a pasta /opt/wikijs."
echo "Tenha certeza do que está fazendo antes de continuar."
read -p "Deseja continuar? (S/N): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[Ss]$ ]]; then
    echo "Abortando..."
    exit 0
fi

read -p "Digite o domínio ou IP do servidor (ex: wiki.seudominio.com.br): " DOMAIN
read -p "Digite a senha do banco de dados Wiki.js: " DB_PASS
read -p "Deseja configurar HTTPS com Certbot automaticamente? (S/N): " USE_HTTPS

echo "Removendo instalações antigas..."
# Remove banco de dados e usuário antigo com cuidado
if sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='wikijs'" | grep -q 1; then
    # Finaliza conexões ativas antes de apagar o banco
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='wikijs';"
    sudo -u postgres psql -c "DROP DATABASE wikijs;"
fi

if sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='wikijsuser'" | grep -q 1; then
    sudo -u postgres psql -c "REASSIGN OWNED BY wikijsuser TO postgres;"
    sudo -u postgres psql -c "DROP OWNED BY wikijsuser;"
    sudo -u postgres psql -c "DROP ROLE wikijsuser;"
fi

sudo rm -rf /opt/wikijs

echo "Atualizando sistema e instalando dependências..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget gnupg2 unzip nano nginx postgresql postgresql-contrib

# Instala Node.js 22
if ! command -v node &> /dev/null; then
    echo "Instalando Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt install -y nodejs
fi

echo "Node.js: $(node -v), npm: $(npm -v)"

echo "Criando banco de dados e usuário..."
sudo -u postgres psql <<EOF
CREATE DATABASE wikijs;
CREATE USER wikijsuser WITH PASSWORD '${DB_PASS}';
ALTER ROLE wikijsuser SET client_encoding TO 'utf8';
ALTER ROLE wikijsuser SET default_transaction_isolation TO 'read committed';
ALTER ROLE wikijsuser SET timezone TO 'UTC';
GRANT ALL PRIVILEGES ON DATABASE wikijs TO wikijsuser;
\c wikijs;
GRANT ALL PRIVILEGES ON SCHEMA public TO wikijsuser;
ALTER SCHEMA public OWNER TO wikijsuser;
EOF

echo "Baixando e instalando Wiki.js..."
sudo mkdir -p /opt/wikijs
sudo chown $USER:$USER /opt/wikijs
cd /opt/wikijs
LATEST=$(curl -s https://api.github.com/repos/Requarks/wiki/releases/latest | grep "tag_name" | cut -d '"' -f4)
wget "https://github.com/Requarks/wiki/releases/download/${LATEST}/wiki-js.tar.gz"
tar xzf wiki-js.tar.gz
rm wiki-js.tar.gz

# Configuração do config.yml
cp config.sample.yml config.yml
cat > config.yml <<EOL
port: 3000
bindIP: 0.0.0.0
logLevel: info

db:
  type: postgres
  host: localhost
  port: 5432
  user: wikijsuser
  pass: ${DB_PASS}
  db: wikijs
  ssl: false

pool:
  min: 2
  max: 10

path:
  data: ./data

uploads:
  maxFileSize: 50mb

sessionSecret: 'wikijs-secret-key'

analytics:
  enabled: false

auth:
  local:
    enabled: true
EOL

chmod 640 config.yml
sudo chown -R www-data:www-data /opt/wikijs

# Serviço systemd
sudo tee /etc/systemd/system/wikijs.service > /dev/null <<EOF
[Unit]
Description=Wiki.js
After=network.target postgresql.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/wikijs
ExecStart=/usr/bin/node server
Restart=always
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable wikijs
sudo systemctl start wikijs

# Nginx proxy reverso opcional
if [[ "$USE_HTTPS" =~ ^[SsNn]$ ]]; then
    sudo tee /etc/nginx/sites-available/wikijs.conf > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://localhost:3000/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        client_max_body_size 100M;
    }
}
EOF
    sudo ln -sf /etc/nginx/sites-available/wikijs.conf /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl restart nginx

    if [[ "$USE_HTTPS" =~ ^[Ss]$ ]]; then
        sudo apt install -y certbot python3-certbot-nginx
        sudo certbot --nginx -d "$DOMAIN"
    fi
fi

echo ""
echo "=== Instalação concluída ==="
echo "Wiki.js está rodando em: http://localhost:3000"
echo "Banco de dados: wikijs (usuário wikijsuser)"
echo "Configuração: /opt/wikijs/config.yml"
echo "Serviço systemd: systemctl status wikijs"
echo "Acesse http://$DOMAIN ou http://IP_DO_SERVIDOR:3000 para finalizar a configuração via web."
