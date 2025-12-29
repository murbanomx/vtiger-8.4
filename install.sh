#!/bin/bash
set -e

# ==========================================
# 0. CARGAR VARIABLES
# ==========================================
if [ -f vtiger.env ]; then
    export $(grep -v '^#' vtiger.env | xargs)
else
    echo "❌ Error: No se encuentra el archivo vtiger.env"
    exit 1
fi

echo "🚀 Iniciando despliegue Inteligente para Vtiger CRM $VTIGER_VERSION..."
echo "🌐 Dominio: $DOMAIN_NAME"

# ==========================================
# 1. INSTALACIÓN DE DOCKER
# ==========================================
if ! command -v docker &> /dev/null; then
    echo "🔧 Docker no encontrado. Instalando..."
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    [ -f /etc/apt/keyrings/docker.gpg ] && sudo rm /etc/apt/keyrings/docker.gpg
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    CODENAME=$(lsb_release -cs)
    if [[ "$CODENAME" == "plucky" ]]; then CODENAME="noble"; fi 

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $CODENAME stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "✅ Docker ya está instalado."
fi

# ==========================================
# 2. ESTRUCTURA DE DIRECTORIOS
# ==========================================
BASE_DIR="$(pwd)/stack"
mkdir -p $BASE_DIR/html
mkdir -p $BASE_DIR/mysql
mkdir -p $BASE_DIR/nginx
mkdir -p $BASE_DIR/certbot/conf
mkdir -p $BASE_DIR/certbot/www
mkdir -p $BASE_DIR/logs

# ==========================================
# 3. DESCARGA DE VTIGER
# ==========================================
if [ -z "$(ls -A $BASE_DIR/html)" ]; then
    echo "📥 Descargando Vtiger $VTIGER_VERSION..."
    wget -O vtiger.tar.gz "$VTIGER_DOWNLOAD_URL"
    echo "📦 Descomprimiendo..."
    tar -xzf vtiger.tar.gz -C $BASE_DIR
    mv $BASE_DIR/vtigercrm/* $BASE_DIR/html/ 2>/dev/null || true
    mv $BASE_DIR/vtigercrm/.* $BASE_DIR/html/ 2>/dev/null || true
    rmdir $BASE_DIR/vtigercrm
    rm vtiger.tar.gz
    sudo chown -R 33:33 $BASE_DIR/html
    echo "✅ Vtiger descargado."
else
    echo "ℹ️  Archivos de Vtiger detectados. Omitiendo descarga."
fi

# ==========================================
# 4. GENERAR DOCKERFILE (Bookworm Fix)
# ==========================================
cat <<EOF > Dockerfile
FROM php:${PHP_VERSION}-fpm-bookworm

RUN apt-get update && apt-get install -y \\
    libfreetype6-dev libjpeg62-turbo-dev libpng-dev libzip-dev \\
    libonig-dev libxml2-dev libcurl4-openssl-dev libc-client-dev \\
    libkrb5-dev zip unzip curl \\
    && docker-php-ext-configure gd --with-freetype --with-jpeg \\
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \\
    && docker-php-ext-install -j$(nproc) gd imap zip mysqli pdo_mysql soap intl bcmath opcache mbstring curl xml simplexml exif


RUN { \\
    echo 'memory_limit = ${PHP_MEMORY_LIMIT}'; \\
    echo 'max_execution_time = ${PHP_MAX_EXECUTION_TIME}'; \\
    echo 'upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE}'; \\
    echo 'post_max_size = ${PHP_POST_MAX_SIZE}'; \\
    echo 'max_input_vars = ${PHP_MAX_INPUT_VARS}'; \\
    echo 'date.timezone = ${TIMEZONE}'; \\
    echo 'short_open_tag = Off'; \\
    echo 'display_errors = Off'; \\
    echo 'log_errors = On'; \\
    echo 'error_log = /var/log/php_errors.log'; \\
} > /usr/local/etc/php/conf.d/vtiger-custom.ini

WORKDIR /var/www/html
EOF

# ==========================================
# 5. GENERAR NGINX.CONF
# ==========================================
cat <<EOF > $BASE_DIR/nginx/default.conf
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    server_tokens off;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN_NAME};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN_NAME}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN_NAME}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.php index.html;
    client_max_body_size ${PHP_UPLOAD_MAX_FILESIZE};
    
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;

    location ~* ^/(config\.inc\.php|logs/|storage/|cron/|vtlib/) { return 403; }
    location ~ /\.(?!well-known).* { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout ${PHP_MAX_EXECUTION_TIME};
    }
}
EOF

# ==========================================
# 6. CERTIFICADO DUMMY (Arranque)
# ==========================================
SSL_PATH="$BASE_DIR/certbot/conf/live/$DOMAIN_NAME"
if [ ! -d "$SSL_PATH" ]; then
    echo "⚠️ Generando certificado temporal..."
    mkdir -p "$SSL_PATH"
    openssl req -x509 -nodes -newkey rsa:4096 -days 1 \
        -keyout "$SSL_PATH/privkey.pem" \
        -out "$SSL_PATH/fullchain.pem" \
        -subj "/CN=localhost"
fi

# ==========================================
# 7. GENERAR DOCKER-COMPOSE.YML
# ==========================================
cat <<EOF > docker-compose.yml
services:
  app:
    build: .
    container_name: vtiger_app
    volumes:
      - ./stack/html:/var/www/html
    environment:
      - DB_HOST=${DB_HOST}
      - DB_USER=${DB_USER}
      - DB_PASSWORD=${DB_PASSWORD}
      - DB_NAME=${DB_DATABASE}
    networks:
      - vtiger-net
    depends_on:
      - db
    restart: always

  db:
    image: mariadb:${MARIADB_VERSION}
    container_name: vtiger_db
    environment:
      - MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
      - MYSQL_DATABASE=${DB_DATABASE}
      - MYSQL_USER=${DB_USER}
      - MYSQL_PASSWORD=${DB_PASSWORD}
    volumes:
      - ./stack/mysql:/var/lib/mysql
    command: --sql_mode="" --transaction-isolation=READ-COMMITTED
    networks:
      - vtiger-net
    restart: always

  web:
    image: nginx:${NGINX_VERSION}
    container_name: vtiger_nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./stack/html:/var/www/html
      - ./stack/nginx/default.conf:/etc/nginx/conf.d/default.conf
      - ./stack/certbot/conf:/etc/letsencrypt
      - ./stack/certbot/www:/var/www/certbot
      - ./stack/logs:/var/log/nginx
    networks:
      - vtiger-net
    depends_on:
      - app
    restart: always

  certbot:
    image: certbot/certbot
    container_name: vtiger_certbot
    volumes:
      - ./stack/certbot/conf:/etc/letsencrypt
      - ./stack/certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait \$\${!}; done;'"
    networks:
      - vtiger-net

networks:
  vtiger-net:
    driver: bridge
EOF

# ==========================================
# 8. EJECUCIÓN
# ==========================================
echo "🚀 Levantando contenedores..."
sudo docker compose up -d --build

# ==========================================
# 9. SSL REAL (VERIFICACIÓN INTELIGENTE)
# ==========================================
echo "🔍 Verificando estado del certificado SSL..."
sleep 5 # Dar tiempo a que Nginx arranque

CURRENT_CERT="$BASE_DIR/certbot/conf/live/$DOMAIN_NAME/fullchain.pem"
NEEDS_RENEWAL=false

if [ -f "$CURRENT_CERT" ]; then
    # Leemos el emisor del certificado
    ISSUER=$(openssl x509 -in "$CURRENT_CERT" -noout -issuer 2>/dev/null)
    
    if [[ "$ISSUER" == *"localhost"* ]] || [[ "$ISSUER" == *"CN = localhost"* ]]; then
        echo "⚠️ DETECTADO: El certificado actual es 'Dummy' (localhost)."
        NEEDS_RENEWAL=true
    else
        echo "✅ Certificado válido detectado (Emisor: Let's Encrypt o válido)."
    fi
else
    echo "⚠️ No se encuentra el certificado. Se intentará generar."
    NEEDS_RENEWAL=true
fi

if [ "$NEEDS_RENEWAL" = true ]; then
    echo "🔄 Iniciando proceso de reemplazo por Let's Encrypt REAL..."
    
    # Limpieza de archivos dummy antiguos
    sudo rm -rf "$BASE_DIR/certbot/conf/live/$DOMAIN_NAME"
    sudo rm -rf "$BASE_DIR/certbot/conf/archive/$DOMAIN_NAME"
    sudo rm -rf "$BASE_DIR/certbot/conf/renewal/$DOMAIN_NAME.conf"

    # Solicitar nuevo
    sudo docker compose run --rm --entrypoint "" certbot certbot certonly \
        --webroot \
        --webroot-path /var/www/certbot \
        --email $SSL_EMAIL \
        --agree-tos \
        --no-eff-email \
        -d $DOMAIN_NAME \
        --force-renewal
    
    if [ $? -eq 0 ]; then
        echo "✅ Certificado obtenido con éxito."
        echo "🔄 Recargando Nginx..."
        sudo docker compose exec web nginx -s reload
        echo "✅ ¡TODO LISTO! Accede a https://$DOMAIN_NAME"
    else
        echo "❌ Error CRÍTICO obteniendo SSL. Revisa logs y DNS."
    fi
else
    echo "✅ El sistema ya es seguro. No se requieren cambios."
    echo "👉 https://$DOMAIN_NAME"
fi

sudo chown -R 33:33 $BASE_DIR/html




# --- BLOQUE DE CORRECCION DE PERMISOS PERMANENTE ---

echo "⏳ Esperando 10 segundos para asegurar que el contenedor inicie..."
sleep 10

echo "🔧 Aplicando corrección automática de permisos para Vtiger 8.4..."

# 1. Creamos la carpeta del bug del logo si no existe
sudo docker exec -u 0 vtiger_app bash -c "mkdir -p /var/www/html/test/logo"

# 2. Aplicamos permisos 777 a las carpetas críticas (Logs, Storage, Test, Cache)
sudo docker exec -u 0 vtiger_app bash -c "chmod -R 777 /var/www/html/test /var/www/html/storage /var/www/html/logs /var/www/html/cache"

# 3. Aseguramos que el usuario www-data sea el dueño
sudo docker exec -u 0 vtiger_app bash -c "chown -R www-data:www-data /var/www/html/test /var/www/html/storage /var/www/html/logs"

echo "✅ Parche de permisos aplicado correctamente."
# ---------------------------------------------------
