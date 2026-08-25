#!/bin/bash

# =====================================================
# Script: deploy.sh
# Descrição: Automatiza o deploy de sites a partir de um arquivo ZIP,
#            configurando Apache ou Nginx com SSL autoassinado.
# Uso: sudo ./deploy.sh --site arquivo.zip --dominio dominio.local --porta 8080 --engine nginx
# =====================================================

set -euo pipefail  # Interrompe em erro, trata variáveis não definidas e falhas em pipelines

# ---------- Funções auxiliares ----------

# Exibe mensagem de uso e sai
usage() {
    echo "Uso: $0 --site <arquivo.zip> --dominio <dominio> --porta <porta> --engine <nginx|apache2>"
    exit 1
}

# Verifica se um pacote está instalado; se não, instala
ensure_package() {
    local pkg="$1"
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo "Pacote $pkg não encontrado. Instalando..."
        apt update -y > /dev/null
        apt install -y "$pkg" > /dev/null
    else
        echo "Pacote $pkg já está instalado."
    fi
}

# Para e desabilita um serviço se estiver ativo
stop_and_disable_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        echo "Parando serviço $svc..."
        systemctl stop "$svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo "Desabilitando inicialização automática de $svc..."
        systemctl disable "$svc" > /dev/null
    fi
}

# Libera porta no firewall UFW (se ativo)
allow_port_ufw() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        echo "Liberando porta $port/$proto no UFW..."
        ufw allow "$port/$proto" > /dev/null
    fi
}

# ---------- Verificações iniciais ----------

# Executar como root
if [ "$EUID" -ne 0 ]; then
    echo "Erro: Este script deve ser executado com sudo ou como root."
    exit 1
fi

# ---------- Processamento dos argumentos ----------

SITE_ZIP=""
DOMAIN=""
PORT=""
ENGINE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)
            SITE_ZIP="$2"
            shift 2
            ;;
        --dominio)
            DOMAIN="$2"
            shift 2
            ;;
        --porta)
            PORT="$2"
            shift 2
            ;;
        --engine)
            ENGINE="$2"
            shift 2
            ;;
        *)
            echo "Parâmetro desconhecido: $1"
            usage
            ;;
    esac
done

# Validar presença de todos os parâmetros
if [ -z "$SITE_ZIP" ] || [ -z "$DOMAIN" ] || [ -z "$PORT" ] || [ -z "$ENGINE" ]; then
    echo "Erro: Todos os parâmetros (--site, --dominio, --porta, --engine) são obrigatórios."
    usage
fi

# Validar engine
if [ "$ENGINE" != "nginx" ] && [ "$ENGINE" != "apache2" ]; then
    echo "Erro: O parâmetro --engine deve ser 'nginx' ou 'apache2'."
    exit 1
fi

# Validar existência do arquivo ZIP
if [ ! -f "$SITE_ZIP" ]; then
    echo "Erro: Arquivo ZIP '$SITE_ZIP' não encontrado."
    exit 1
fi

# Validar porta (deve ser numérica entre 1 e 65535)
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Erro: Porta inválida. Use um número entre 1 e 65535."
    exit 1
fi

# ---------- Preparação do ambiente ----------

# Determinar diretório home do usuário que invocou sudo
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

# Diretório onde o site será extraído
TARGET_DIR="$USER_HOME/public_html/$DOMAIN"

# ---------- Gerenciamento dos servidores web ----------

if [ "$ENGINE" = "apache2" ]; then
    # Garantir Apache instalado
    ensure_package "apache2"

    # Parar/desabilitar Nginx (se existir)
    if dpkg -l | grep -q "^ii  nginx "; then
        stop_and_disable_service "nginx"
    fi

    # Habilitar Apache para iniciar com o sistema (caso tenha sido desabilitado antes)
    systemctl enable apache2 > /dev/null

elif [ "$ENGINE" = "nginx" ]; then
    # Garantir Nginx instalado
    ensure_package "nginx"

    # Parar/desabilitar Apache (se existir)
    if dpkg -l | grep -q "^ii  apache2 "; then
        stop_and_disable_service "apache2"
    fi

    # Habilitar Nginx para iniciar com o sistema
    systemctl enable nginx > /dev/null
fi

# ---------- Extração do arquivo ZIP ----------

echo "Criando diretório de destino: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

echo "Descompactando '$SITE_ZIP' em '$TARGET_DIR'..."
unzip -o "$SITE_ZIP" -d "$TARGET_DIR" > /dev/null

# ---------- Aplicação de permissões ----------

echo "Aplicando permissões (chown www-data:www-data, chmod 755)..."
chown -R www-data:www-data "$TARGET_DIR"
chmod -R 755 "$TARGET_DIR"

# Garantir que o diretório home do usuário seja atravessável pelo www-data
# (necessário se o site está dentro da home)
if [ "$USER_HOME" != "/var/www" ]; then
    echo "Ajustando permissão de acesso na pasta home ($USER_HOME) para www-data..."
    chmod o+x "$USER_HOME"
    chmod o+x "$USER_HOME/public_html"
fi

# ---------- Geração do certificado SSL autoassinado ----------

echo "Gerando certificado SSL autoassinado para $DOMAIN..."
mkdir -p /etc/ssl/private /etc/ssl/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$DOMAIN.key" \
    -out "/etc/ssl/certs/$DOMAIN.crt" \
    -subj "/CN=$DOMAIN" > /dev/null 2>&1

# ---------- Configuração do servidor web ----------

if [ "$ENGINE" = "apache2" ]; then
    echo "Configurando Apache2 para $DOMAIN na porta $PORT..."

    # Habilitar SSL e módulo de reescrita (se necessário)
    a2enmod ssl > /dev/null
    a2enmod rewrite > /dev/null

    # Adicionar Listen para a porta personalizada (se não existir)
    if ! grep -q "Listen $PORT" /etc/apache2/ports.conf; then
        echo "Listen $PORT" >> /etc/apache2/ports.conf
    fi

    # Criar arquivo de configuração do VirtualHost
    CONF_FILE="/etc/apache2/sites-available/$DOMAIN.conf"
    cat > "$CONF_FILE" <<EOF
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    Redirect permanent / https://$DOMAIN:$PORT/
</VirtualHost>

<VirtualHost *:$PORT>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot $TARGET_DIR

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/$DOMAIN.crt
    SSLCertificateKeyFile /etc/ssl/private/$DOMAIN.key

    <Directory $TARGET_DIR>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}_access.log combined
</VirtualHost>
EOF

    # Habilitar o site
    a2ensite "$DOMAIN.conf" > /dev/null

    # Testar configuração
    echo "Testando configuração do Apache..."
    apache2ctl configtest

    # Recarregar serviço
    systemctl reload apache2

elif [ "$ENGINE" = "nginx" ]; then
    echo "Configurando Nginx para $DOMAIN na porta $PORT..."

    # Criar arquivo de configuração do Server Block
    CONF_FILE="/etc/nginx/sites-available/$DOMAIN"
    cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;
    return 301 https://\$host:$PORT\$request_uri;
}

server {
    listen $PORT ssl;
    listen [::]:$PORT ssl;
    server_name $DOMAIN www.$DOMAIN;

    root $TARGET_DIR;
    index index.html index.htm;

    ssl_certificate /etc/ssl/certs/$DOMAIN.crt;
    ssl_certificate_key /etc/ssl/private/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Criar link simbólico em sites-enabled
    ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/$DOMAIN"

    # Testar configuração
    echo "Testando configuração do Nginx..."
    nginx -t

    # Recarregar serviço
    systemctl reload nginx
fi

# ---------- Liberação no firewall ----------

echo "Liberando porta $PORT no firewall (se ativo)..."
allow_port_ufw "$PORT"
# Também liberar porta 80 (para redirecionamento) se necessário
if [ "$ENGINE" = "apache2" ]; then
    allow_port_ufw 80
fi
# Para Nginx, a porta 80 já deve estar liberada, mas não custa garantir
allow_port_ufw 80

# ---------- Mensagem final ----------

echo ""
echo "=============================================="
echo "Sucesso! O seu site está no ar em: https://$DOMAIN:$PORT"
echo "=============================================="
