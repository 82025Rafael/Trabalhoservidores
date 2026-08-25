#!/bin/bash
# ============================================================
# deploy.sh - Deploy em 1-clique (Apache ou Nginx) - RASCUNHO
# Uso:
#   ./deploy.sh --site meu_site.zip --dominio empresa.local --porta 8080 --engine nginx
# ============================================================

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

# ---------- 3. PROCESSAMENTO DO ARQUIVO ----------
# Nome do site derivado do domínio (ex: empresa.local -> empresa.local)
SITE_NOME="$DOMINIO"
DESTINO="/home/$USER/public_html/$SITE_NOME"

echo "Criando diretório do site em $DESTINO ..."
sudo mkdir -p "$DESTINO"

echo "Descompactando $SITE em $DESTINO ..."
sudo unzip -o "$SITE" -d "$DESTINO"

echo "Ajustando permissões para www-data ..."
sudo chown -R www-data:www-data "$DESTINO"
sudo chmod -R 755 "$DESTINO"

# ---------- 4. CERTIFICADO SSL AUTOASSINADO ----------
CERT_DIR="/etc/ssl/certs"
KEY_DIR="/etc/ssl/private"
CERT_FILE="$CERT_DIR/${DOMINIO}.crt"
KEY_FILE="$KEY_DIR/${DOMINIO}.key"

echo "Gerando certificado SSL autoassinado para $DOMINIO (sem interação) ..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=$DOMINIO"

# ---------- 5. CONFIGURAÇÃO DO SERVIDOR WEB ----------
if [ "$ENGINE" = "nginx" ]; then

    CONF_PATH="/etc/nginx/sites-available/$DOMINIO"

    echo "Gerando configuração do Nginx em $CONF_PATH ..."
    sudo bash -c "cat > $CONF_PATH" <<EOF
server {
    listen $PORTA;
    server_name $DOMINIO www.$DOMINIO;
    root $DESTINO;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 443 ssl;
    server_name $DOMINIO www.$DOMINIO;
    root $DESTINO;
    index index.html index.htm;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen $PORTA;
    server_name $DOMINIO www.$DOMINIO;
    return 301 https://\$host:$PORTA\$request_uri;
}
EOF

    echo "Ativando site (link simbólico) ..."
    sudo ln -s "$CONF_PATH" "/etc/nginx/sites-enabled/" 2>/dev/null

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
    sudo a2enmod ssl
    sudo a2enmod rewrite

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
    sudo a2ensite "${DOMINIO}-ssl.conf"
    sudo a2ensite "${DOMINIO}.conf"

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

# ---------- 6. MENSAGEM FINAL ----------
echo ""
echo "Sucesso! O seu site está no ar em: https://$DOMINIO:$PORTA"

