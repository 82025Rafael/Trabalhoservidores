#!/bin/bash

# deploy.sh - sobe um site a partir de um zip, configurando Apache ou Nginx
# com SSL auto-assinado.
# uso: sudo ./deploy.sh --site arquivo.zip --dominio dominio.local --porta 8080 --engine nginx

set -euo pipefail  # interrompe em erro, trata variaveis nao definidas e falhas em pipelines

# instalacao noninterativa. sem isso o apt as vezes fica esperando input
# (o needrestart adora abrir aquele menu perguntando quais servicos reiniciar)
# e o script trava no meio do nada parecendo que congelou
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---------- Funcoes auxiliares ----------

# Exibe mensagem de uso e sai
exibir_uso() {
    echo "Uso: $0 --site <arquivo.zip> --dominio <dominio> --porta <porta> --engine <nginx|apache2>"
    exit 1
}

# checa se o pacote esta instalado sem depender do formato de saida do dpkg -l
# (dpkg -s e bem mais estavel pra isso)
pacote_instalado() {
    dpkg -s "$1" > /dev/null 2>&1
}

# Verifica se um pacote esta instalado; se nao, instala
garantir_pacote() {
    local pacote="$1"
    if ! pacote_instalado "$pacote"; then
        echo "Pacote $pacote nao encontrado. Instalando..."
        apt-get update -y > /dev/null
        apt-get install -y "$pacote" > /dev/null
    else
        echo "Pacote $pacote ja esta instalado."
    fi
}

# Para e desabilita um servico se estiver ativo
parar_e_desabilitar_servico() {
    local servico="$1"
    if systemctl is-active --quiet "$servico"; then
        echo "Parando servico $servico..."
        systemctl stop "$servico"
    fi
    if systemctl is-enabled --quiet "$servico" 2>/dev/null; then
        echo "Desabilitando inicializacao automatica de $servico..."
        systemctl disable "$servico" > /dev/null
    fi
}

# Libera porta no firewall UFW (se ativo)
liberar_porta_ufw() {
    local porta="$1"
    local protocolo="${2:-tcp}"
    if command -v ufw >/dev/null && ufw status | grep -q "active"; then
        echo "Liberando porta $porta/$protocolo no UFW..."
        ufw allow "$porta/$protocolo" > /dev/null
    fi
}

# ---------- Verificacoes iniciais ----------

# Executar como root
if [ "$EUID" -ne 0 ]; then
    echo "Erro: Este script deve ser executado com sudo ou como root."
    exit 1
fi

# ---------- Processamento dos argumentos ----------

ARQUIVO_ZIP=""
DOMINIO=""
PORTA=""
ENGINE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)
            ARQUIVO_ZIP="$2"
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
            echo "Parametro desconhecido: $1"
            exibir_uso
            ;;
    esac
done

# Validar presenca de todos os parametros
if [ -z "$ARQUIVO_ZIP" ] || [ -z "$DOMINIO" ] || [ -z "$PORTA" ] || [ -z "$ENGINE" ]; then
    echo "Erro: Todos os parametros (--site, --dominio, --porta, --engine) sao obrigatorios."
    exibir_uso
fi

# Validar engine
if [ "$ENGINE" != "nginx" ] && [ "$ENGINE" != "apache2" ]; then
    echo "Erro: O parametro --engine deve ser 'nginx' ou 'apache2'."
    exit 1
fi

# Validar existencia do arquivo ZIP
if [ ! -f "$ARQUIVO_ZIP" ]; then
    echo "Erro: Arquivo ZIP '$ARQUIVO_ZIP' nao encontrado."
    exit 1
fi

# Validar porta (deve ser numerica entre 1 e 65535)
if ! [[ "$PORTA" =~ ^[0-9]+$ ]] || [ "$PORTA" -lt 1 ] || [ "$PORTA" -gt 65535 ]; then
    echo "Erro: Porta invalida. Use um numero entre 1 e 65535."
    exit 1
fi

# ---------- Preparacao do ambiente ----------

# Determinar diretorio home do usuario que invocou sudo
if [ -n "${SUDO_USER:-}" ]; then
    HOME_USUARIO=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    HOME_USUARIO="/var/www"
fi

# Diretorio onde o site sera extraido
DIRETORIO_DESTINO="$HOME_USUARIO/public_html/$DOMINIO"

# ---------- Gerenciamento dos servidores web ----------

if [ "$ENGINE" = "apache2" ]; then
    # Garantir Apache instalado
    garantir_pacote "apache2"

    # Parar/desabilitar Nginx (se existir)
    if pacote_instalado "nginx"; then
        parar_e_desabilitar_servico "nginx"
    fi

    # Habilitar Apache para iniciar com o sistema
    systemctl enable apache2 > /dev/null

    # Desabilitar site padrao para evitar conflitos (opcional, mas recomendado)
    if [ -f /etc/apache2/sites-enabled/000-default.conf ]; then
        echo "Desabilitando site padrao do Apache..."
        a2dissite 000-default.conf > /dev/null 2>&1 || true
    fi

elif [ "$ENGINE" = "nginx" ]; then
    # Garantir Nginx instalado
    garantir_pacote "nginx"

    # Parar/desabilitar Apache (se existir)
    if pacote_instalado "apache2"; then
        parar_e_desabilitar_servico "apache2"
    fi

    # Habilitar Nginx para iniciar com o sistema
    systemctl enable nginx > /dev/null

    # Remover site padrao do Nginx (se existir)
    if [ -L /etc/nginx/sites-enabled/default ]; then
        echo "Removendo site padrao do Nginx..."
        rm -f /etc/nginx/sites-enabled/default
    fi
fi

# ---------- Extracao do arquivo ZIP ----------

garantir_pacote "unzip"

# confere se o zip nao esta corrompido antes de sair criando pasta e configurando servidor a toa
if ! unzip -tq "$ARQUIVO_ZIP" > /dev/null 2>&1; then
    echo "Erro: o arquivo '$ARQUIVO_ZIP' parece corrompido ou nao e um zip valido."
    exit 1
fi

echo "Criando diretorio de destino: $DIRETORIO_DESTINO"
mkdir -p "$DIRETORIO_DESTINO"

echo "Descompactando '$ARQUIVO_ZIP' em '$DIRETORIO_DESTINO'..."
unzip -o "$ARQUIVO_ZIP" -d "$DIRETORIO_DESTINO" > /dev/null

# ---------- Aplicacao de permissoes (diferenciadas para arquivos e pastas) ----------

echo "Aplicando permissoes (www-data como dono, 755 para pastas, 644 para arquivos)..."
chown -R www-data:www-data "$DIRETORIO_DESTINO"
find "$DIRETORIO_DESTINO" -type d -exec chmod 755 {} \;
find "$DIRETORIO_DESTINO" -type f -exec chmod 644 {} \;

# Garantir que o diretorio home do usuario seja atravessavel pelo www-data
if [ "$HOME_USUARIO" != "/var/www" ]; then
    echo "Ajustando permissao de acesso na pasta home ($HOME_USUARIO) para www-data..."
    chmod o+x "$HOME_USUARIO"
    # public_html pode nao existir ainda, mas se existir, ajusta
    [ -d "$HOME_USUARIO/public_html" ] && chmod o+x "$HOME_USUARIO/public_html"
fi

# ---------- Geracao do certificado SSL autoassinado ----------

# Garantir que o openssl esteja instalado (correcao critica)
garantir_pacote "openssl"

echo "Gerando certificado SSL autoassinado para $DOMINIO..."
mkdir -p /etc/ssl/private /etc/ssl/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "/etc/ssl/private/$DOMINIO.key" \
    -out "/etc/ssl/certs/$DOMINIO.crt" \
    -subj "/CN=$DOMINIO" > /dev/null 2>&1

# ---------- Configuracao do servidor web ----------

if [ "$ENGINE" = "apache2" ]; then
    echo "Configurando Apache2 para $DOMINIO na porta $PORTA..."

    # Habilitar SSL e modulo de reescrita
    a2enmod ssl > /dev/null
    a2enmod rewrite > /dev/null

    # Adicionar Listen para a porta personalizada (se nao existir)
    if ! grep -q "Listen $PORTA" /etc/apache2/ports.conf; then
        echo "Listen $PORTA" >> /etc/apache2/ports.conf
    fi

    # Criar arquivo de configuracao do VirtualHost
    ARQUIVO_CONF="/etc/apache2/sites-available/$DOMINIO.conf"
    cat > "$ARQUIVO_CONF" <<EOF
<VirtualHost *:80>
    ServerName $DOMINIO
    ServerAlias www.$DOMINIO
    Redirect permanent / https://$DOMINIO:$PORTA/
</VirtualHost>

<VirtualHost *:$PORTA>
    ServerName $DOMINIO
    ServerAlias www.$DOMINIO
    DocumentRoot $DIRETORIO_DESTINO

    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/$DOMINIO.crt
    SSLCertificateKeyFile /etc/ssl/private/$DOMINIO.key

    <Directory $DIRETORIO_DESTINO>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${DOMINIO}_error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMINIO}_access.log combined
</VirtualHost>
EOF

    # Habilitar o site
    a2ensite "$DOMINIO.conf" > /dev/null

    # Testar configuracao
    echo "Testando configuracao do Apache..."
    apache2ctl configtest

    # Reiniciar Apache para aplicar tudo (incluindo modulos)
    systemctl restart apache2

elif [ "$ENGINE" = "nginx" ]; then
    echo "Configurando Nginx para $DOMINIO na porta $PORTA..."

    # Criar arquivo de configuracao do Server Block
    ARQUIVO_CONF="/etc/nginx/sites-available/$DOMINIO"
    cat > "$ARQUIVO_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMINIO www.$DOMINIO;
    return 301 https://\$host:$PORTA\$request_uri;
}

server {
    listen $PORTA ssl;
    listen [::]:$PORTA ssl;
    server_name $DOMINIO www.$DOMINIO;

    root $DIRETORIO_DESTINO;
    index index.html index.htm;

    ssl_certificate /etc/ssl/certs/$DOMINIO.crt;
    ssl_certificate_key /etc/ssl/private/$DOMINIO.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

    # Criar link simbolico em sites-enabled
    ln -sf "$ARQUIVO_CONF" "/etc/nginx/sites-enabled/$DOMINIO"

    # Testar configuracao
    echo "Testando configuracao do Nginx..."
    nginx -t

    # Recarregar ou reiniciar? Melhor reiniciar para garantir que suba (correcao)
    systemctl restart nginx
fi

# ---------- Liberacao no firewall ----------

echo "Liberando porta $PORTA no firewall (se ativo)..."
liberar_porta_ufw "$PORTA"
# Tambem liberar porta 80 (para redirecionamento)
liberar_porta_ufw 80

# ---------- Mensagem final ----------

echo ""
echo "=============================================="
echo "Sucesso! O seu site esta no ar em: https://$DOMINIO:$PORTA"
echo "=============================================="