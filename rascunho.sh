#!/bin/bash
# ============================================================
# deploy.sh - Deploy em 1-clique (Apache ou Nginx)
# Uso:
#   ./deploy.sh --site meu_site.zip --dominio empresa.local --porta 8080 --engine nginx
# ============================================================

set -e  # Interrompe o script se algum comando falhar (exceto onde tratamos manualmente)

# ---------- FUNÇÕES AUXILIARES ----------
# Função para verificar se um comando existe
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Função para instalar pacotes se necessário
install_if_missing() {
    local pkg="$1"
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "Pacote $pkg não encontrado. Instalando..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq "$pkg"
    fi
}

# ---------- 1. RECEBER PARÂMETROS ----------
SITE=""
DOMINIO=""
PORTA=""
ENGINE=""

while [ "$1" != "" ]; do
    case "$1" in
        --site)
            SITE="$2"
            shift 2
            ;;
        --dominio)
            DOMINIO="$2"
            shift 2
            ;;
        --porta)
            PORTA="$2"
            shift 2
            ;;
        --engine)
            ENGINE="$2"
            shift 2
            ;;
        *)
            echo "Parâmetro desconhecido: $1"
            exit 1
            ;;
    esac
done

# ---------- 2. VALIDAR PARÂMETROS OBRIGATÓRIOS ----------
if [ -z "$SITE" ] || [ -z "$DOMINIO" ] || [ -z "$PORTA" ] || [ -z "$ENGINE" ]; then
    echo "Erro: faltam parâmetros obrigatórios."
    echo "Uso: ./deploy.sh --site arquivo.zip --dominio dominio.local --porta 8080 --engine nginx|apache2"
    exit 1
fi

if [ "$ENGINE" != "nginx" ] && [ "$ENGINE" != "apache2" ]; then
    echo "Erro: --engine deve ser 'nginx' ou 'apache2'."
    exit 1
fi

# ---------- 3. VERIFICAR E INSTALAR DEPENDÊNCIAS ----------
echo "Verificando dependências..."

# unzip (necessário para descompactar)
install_if_missing unzip

# Nginx e Apache (ambos instalados, mas o script usará apenas um)
install_if_missing nginx
install_if_missing apache2

# openssl (já deve estar instalado, mas garantimos)
install_if_missing openssl

# ---------- 4. GARANTIR QUE OS SERVIÇOS ESTEJAM PARADOS E DESABILITADOS ----------
echo "Parando e desabilitando Nginx e Apache (para evitar conflitos)..."
sudo systemctl stop nginx apache2 2>/dev/null || true
sudo systemctl disable nginx apache2 2>/dev/null || true

# ---------- 5. LIBERAR PORTAS 80 E 443 (matar processos que estejam usando) ----------
echo "Verificando portas 80 e 443..."
# Mata processos ouvindo nessas portas (preventivo)
sudo fuser -k 80/tcp 443/tcp 2>/dev/null || true

# ---------- 6. ADICIONAR DOMÍNIO AO /ETC/HOSTS (SE NÃO EXISTIR) ----------
if ! grep -q "$DOMINIO" /etc/hosts; then
    echo "Adicionando $DOMINIO ao /etc/hosts..."
    echo "127.0.0.1 $DOMINIO www.$DOMINIO" | sudo tee -a /etc/hosts >/dev/null
fi

# ---------- 7. PROCESSAMENTO DO ARQUIVO .ZIP ----------
SITE_NOME="$DOMINIO"
DESTINO="/home/$USER/public_html/$SITE_NOME"

echo "Criando diretório do site em $DESTINO ..."
sudo mkdir -p "$DESTINO"

echo "Descompactando $SITE em $DESTINO ..."
sudo unzip -o "$SITE" -d "$DESTINO" >/dev/null

echo "Ajustando permissões para www-data ..."
sudo chown -R www-data:www-data "$DESTINO"
sudo chmod -R 755 "$DESTINO"

# ---------- 8. CERTIFICADO SSL AUTOASSINADO ----------
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
CERT_FILE="$CERT_DIR/${DOMINIO}.crt"
KEY_FILE="$KEY_DIR/${DOMINIO}.key"

echo "Gerando certificado SSL autoassinado para $DOMINIO (sem interação) ..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$DOMINIO" 2>/dev/null

# ---------- 9. CONFIGURAR O ENGINE ESCOLHIDO ----------
if [ "$ENGINE" = "nginx" ]; then

    CONF_PATH="/etc/nginx/sites-available/$DOMINIO"

    echo "Gerando configuração do Nginx em $CONF_PATH ..."
    sudo bash -c "cat > $CONF_PATH" <<EOF
# HTTPS – escuta na porta informada (--porta)
server {
    listen $PORTA ssl;
    server_name $DOMINIO www.$DOMINIO;
    root $DESTINO;
    index index.html index.htm;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

# HTTP – redireciona para HTTPS na mesma porta informada
server {
    listen 80;
    server_name $DOMINIO www.$DOMINIO;
    return 301 https://$DOMINIO:$PORTA\$request_uri;
}
EOF

    echo "Ativando site (link simbólico) ..."
    sudo ln -sf "$CONF_PATH" "/etc/nginx/sites-enabled/"

    echo "Garantindo que o Nginx esteja em execução..."
    sudo systemctl start nginx

    echo "Validando sintaxe do Nginx ..."
    sudo nginx -t

    if [ $? -eq 0 ]; then
        echo "Recarregando Nginx ..."
        sudo systemctl reload nginx
    else
        echo "Erro na configuração do Nginx. Abortando."
        exit 1
    fi

else
    # ENGINE = apache2

    CONF_PATH="/etc/apache2/sites-available/${DOMINIO}-ssl.conf"
    CONF_HTTP_PATH="/etc/apache2/sites-available/${DOMINIO}.conf"

    echo "Habilitando módulos necessários ..."
    sudo a2enmod ssl 2>/dev/null
    sudo a2enmod rewrite 2>/dev/null

    echo "Gerando configuração HTTPS do Apache em $CONF_PATH ..."
    sudo bash -c "cat > $CONF_PATH" <<EOF
<IfModule mod_ssl.c>
    <VirtualHost *:$PORTA>
        ServerAdmin admin@$DOMINIO
        ServerName $DOMINIO
        DocumentRoot $DESTINO

        SSLEngine on
        SSLCertificateFile $CERT_FILE
        SSLCertificateKeyFile $KEY_FILE

        <Directory $DESTINO>
            Options -Indexes +FollowSymLinks
            AllowOverride All
            Require all granted
        </Directory>

        ErrorLog \${APACHE_LOG_DIR}/${DOMINIO}_ssl_error.log
        CustomLog \${APACHE_LOG_DIR}/${DOMINIO}_ssl_access.log combined
    </VirtualHost>
</IfModule>
EOF

    echo "Gerando configuração HTTP (redirecionamento) em $CONF_HTTP_PATH ..."
    sudo bash -c "cat > $CONF_HTTP_PATH" <<EOF
<VirtualHost *:80>
    ServerName $DOMINIO
    ServerAlias www.$DOMINIO
    Redirect permanent / https://$DOMINIO:$PORTA/
</VirtualHost>
EOF

    echo "Ativando os sites ..."
    sudo a2ensite "${DOMINIO}-ssl.conf" 2>/dev/null
    sudo a2ensite "${DOMINIO}.conf" 2>/dev/null

    echo "Garantindo que o Apache esteja em execução..."
    sudo systemctl start apache2

    echo "Validando sintaxe do Apache ..."
    sudo apache2ctl configtest

    if [ $? -eq 0 ]; then
        echo "Recarregando Apache ..."
        sudo systemctl reload apache2
    else
        echo "Erro na configuração do Apache. Abortando."
        exit 1
    fi
fi

# ---------- 10. MENSAGEM FINAL ----------
echo ""
echo "✅ Sucesso! O seu site está no ar em: https://$DOMINIO:$PORTA"
echo "   (O redirecionamento HTTP → HTTPS está ativo na porta 80)"
