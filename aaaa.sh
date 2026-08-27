#!/bin/bash

# =====================================================
# Script: deploy.sh
# Descricao: automatiza o deploy de sites a partir de um arquivo ZIP,
#            configurando Apache ou Nginx com SSL auto-assinado.
# Uso: sudo ./deploy.sh --site arquivo.zip --dominio dominio.local --porta 8080 --engine nginx
#
# obs: testado num Ubuntu Server 22.04 e 24.04 recem instalado (sem nenhum
# pacote extra). se voce rodar num servidor que ja tem outras coisas
# configuradas, confere as portas antes.
# =====================================================

set -euo pipefail  # interrompe em erro, trata variaveis nao definidas e falhas em pipelines

# instalacao noninterativa. sem isso o apt as vezes fica esperando input
# (o needrestart adora abrir aquele menu perguntando quais servicos reiniciar)
# e o script trava no meio do nada parecendo que congelou
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------- Funcoes auxiliares ----------

# Exibe mensagem de uso e sai
usage() {
    echo "Uso: $0 --site <arquivo.zip> --dominio <dominio> --porta <porta> --engine <nginx|apache2>"
    exit 1
}

# checa se o pacote esta instalado sem depender do formato de saida do dpkg -l
# (dpkg -s e bem mais estavel pra isso)
pacote_instalado() {
    dpkg -s "$1" > /dev/null 2>&1
}

# Verifica se um pacote esta instalado; se nao, instala
ensure_package() {
    local pkg="$1"
    if ! pacote_instalado "$pkg"; then
        echo "Pacote $pkg nao encontrado. Instalando..."
        apt-get update -y > /dev/null
        apt-get install -y "$pkg" > /dev/null
    else
        echo "Pacote $pkg ja esta instalado."
    fi
}

# Para e desabilita um servico se estiver ativo
stop_and_disable_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        echo "Parando servico $svc..."
        systemctl stop "$svc"
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo "Desabilitando inicializacao automatica de $svc..."
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

# ---------- Verificacoes iniciais ----------

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
            echo "Parametro desconhecido: $1"
            usage
            ;;
    esac
done

# Validar presenca de todos os parametros
if [ -z "$SITE_ZIP" ] || [ -z "$DOMAIN" ] || [ -z "$PORT" ] || [ -z "$ENGINE" ]; then
    echo "Erro: Todos os parametros (--site, --dominio, --porta, --engine) sao obrigatorios."
    usage
fi

# Validar engine
if [ "$ENGINE" != "nginx" ] && [ "$ENGINE" != "apache2" ]; then
    echo "Erro: O parametro --engine deve ser 'nginx' ou 'apache2'."
    exit 1
fi

# Validar existencia do arquivo ZIP
if [ ! -f "$SITE_ZIP" ]; then
    echo "Erro: Arquivo ZIP '$SITE_ZIP' nao encontrado."
    exit 1
fi

# Validar porta (deve ser numerica entre 1 e 65535)
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "Erro: Porta invalida. Use um numero entre 1 e 65535."
    exit 1
fi

# ---------- Preparacao do ambiente ----------

# Determinar diretorio home do usuario que invocou sudo
if [ -n "${SUDO_USER:-}" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    # se ninguem usou sudo (ta rodando direto como root) nao faz sentido
    # jogar o site dentro de /root e sair mexendo na permissao de la.
    # cai pro /var/www que ja e o lugar certo mesmo pra isso
    USER_HOME="/var/www"
fi

# Diretorio onde o site sera extraido
TARGET_DIR="$USER_HOME/public_html/$DOMAIN"

# ---------- Gerenciamento dos servidores web ----------

if [ "$ENGINE" = "apache2" ]; then
    # Garantir Apache instalado
    ensure_package "apache2"

    # Parar/desabilitar Nginx (se existir)
    if pacote_instalado "nginx"; then
        stop_and_disable_service "nginx"
    fi

    # Habilitar Apache para iniciar com o sistema (caso tenha sido desabilitado antes)
    systemctl enable apache2 > /dev/null

elif [ "$ENGINE" = "nginx" ]; then
    # Garantir Nginx instalado
    ensure_package "nginx"

    # Parar/desabilitar Apache (se existir)
    if pacote_instalado "apache2"; then
        stop_and_disable_service "apache2"
    fi

    # Habilitar Nginx para iniciar com o sistema
    systemctl enable nginx > /dev/null
fi

# ---------- Extracao do arquivo ZIP ----------

# isso aqui e o principal motivo do script quebrar num servidor recem instalado:
# unzip nao vem por padrao no Ubuntu Server, entao garante a instalacao antes de usar
ensure_package "unzip"

# confere se o zip nao esta corrompido antes de sair criando pasta e configurando servidor a toa
if ! unzip -tq "$SITE_ZIP" > /dev/null 2>&1; then
    echo "Erro: o arquivo '$SITE_ZIP' parece corrompido ou nao e um zip valido."
    exit 1
fi

echo "Criando diretorio de destino: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

echo "Descompactando '$SITE_ZIP' em '$TARGET_DIR'..."
unzip -o "$SITE_ZIP" -d "$TARGET_DIR" > /dev/null

# ---------- Aplicacao de permissoes ----------

echo "Aplicando permissoes (chown www-data:www-data, chmod 755)..."
chown -R www-data:www-data "$TARGET_DIR"
chmod -R 755 "$TARGET_DIR"

# Garantir que o diretorio home do usuario seja atravessavel pelo www-data
# (necessario se o site esta dentro da home)
if [ "$USER_HOME" != "/var/www" ]; then
    echo "Ajustando permissao de acesso na pasta home ($USER_HOME) para www-data..."
    chmod o+x "$USER_HOME"
    chmod o+x "$USER_HOME/public_html"
fi

# ---------- Geracao do certificado SSL autoassinado ----------

echo "Gerando certificado SSL autoassinado para $DOMAIN..."
mkdir -p /etc/ssl/private /etc/ssl/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$DOMAIN.key" \
    -out "/etc/ssl/certs/$DOMAIN.crt" \
    -subj "/CN=$DOMAIN" > /dev/null 2>&1

# ---------- Configuracao do servidor web ----------

if [ "$ENGINE" = "apache2" ]; then
    echo "Configurando Apache2 para $DOMAIN na porta $PORT..."

    # Habilitar SSL e modulo de reescrita (se necessario)
    a2enmod ssl > /dev/null
    a2enmod rewrite > /dev/null

    # Adicionar Listen para a porta personalizada (se nao existir)
    if ! grep -q "Listen $PORT" /etc/apache2/ports.conf; then
        echo "Listen $PORT" >> /etc/apache2/ports.conf
    fi

    # Criar arquivo de configuracao do VirtualHost
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

    # Testar configuracao
    echo "Testando configuracao do Apache..."
    apache2ctl configtest

    # reload nem sempre pega direito os modulos que acabamos de habilitar
    # (ssl/rewrite), entao da um restart completo pra garantir
    systemctl restart apache2

elif [ "$ENGINE" = "nginx" ]; then
    echo "Configurando Nginx para $DOMAIN na porta $PORT..."

    # Criar arquivo de configuracao do Server Block
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

    # Criar link simbolico em sites-enabled
    ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/$DOMAIN"

    # Testar configuracao
    echo "Testando configuracao do Nginx..."
    nginx -t

    # Recarregar servico
    systemctl reload nginx
fi

# ---------- Liberacao no firewall ----------

echo "Liberando porta $PORT no firewall (se ativo)..."
allow_port_ufw "$PORT"
# Tambem liberar porta 80 (para redirecionamento) se necessario
if [ "$ENGINE" = "apache2" ]; then
    allow_port_ufw 80
fi
# Para Nginx, a porta 80 ja deve estar liberada, mas nao custa garantir
allow_port_ufw 80

# ---------- Mensagem final ----------

echo ""
echo "=============================================="
echo "Sucesso! O seu site esta no ar em: https://$DOMAIN:$PORT"
echo "=============================================="
