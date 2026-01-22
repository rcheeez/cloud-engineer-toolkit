#!/bin/bash

# Laravel Website Infrastructure Setup Tool
# Prepares server environment for Laravel application deployment

set -e

# Global variables
APP_NAME=""
DOMAIN_NAME=""
PHP_VERSION=""
PHP_PKG=""
NODE_VERSION=""
INSTALL_SSL=""
INSTALL_REDIS=""
INSTALL_SUPERVISOR=""
INSTALL_MYSQL=""
USE_EXTERNAL_DB=""
EXTERNAL_DB_HOST=""
EXTERNAL_DB_PORT=""
EXTERNAL_DB_NAME=""
EXTERNAL_DB_USER=""
EXTERNAL_DB_PASSWORD=""
WEB_ROOT=""
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF=""
DNS_RESOLVED=false
WEBSITE_TEST_RESULTS=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
MYSQL_ROOT_PASSWORD=""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ---------------------------------
# Utility Functions
# ---------------------------------
log_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

log_info() {
    echo -e "${YELLOW}INFO: $1${NC}"
}

log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_skip() {
    echo -e "${YELLOW}⚠ $1 (already installed)${NC}"
}

handle_error() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        log_error "Command failed at line $line_number with exit code $exit_code"
        exit $exit_code
    fi
}

trap 'handle_error $LINENO' ERR

check_installed() {
    local package=$1
    dpkg -l | grep -q "^ii  $package " 2>/dev/null
}

check_service_running() {
    local service=$1
    systemctl is-active --quiet "$service" 2>/dev/null
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

validate_php_version() {
    if [[ ! "$PHP_VERSION" =~ ^8\.[1-4]$ ]]; then
        log_error "Unsupported PHP version: $PHP_VERSION (Laravel requires 8.1+)"
        exit 1
    fi
}

validate_node_version() {
    if [[ ! "$NODE_VERSION" =~ ^(18|20|22)$ ]]; then
        log_error "Unsupported Node.js version: $NODE_VERSION (Laravel requires 18, 20, or 22)"
        exit 1
    fi
}

check_dns_resolution() {
    local domain="$1"
    local primary_domain=$(echo "$domain" | awk '{print $1}')
    
    if nslookup "$primary_domain" >/dev/null 2>&1; then
        DNS_RESOLVED=true
        log_info "DNS resolution confirmed for $primary_domain"
    else
        DNS_RESOLVED=false
        log_info "DNS not resolved for $primary_domain - SSL will be skipped"
    fi
}

generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-16
}

# ---------------------------------
# External Database Functions
# ---------------------------------
collect_external_db_details() {
    echo
    echo "=== External Database Configuration ==="
    read -rp "Enter database host (e.g., mydb.cluster-xyz.us-east-1.rds.amazonaws.com): " EXTERNAL_DB_HOST
    read -rp "Enter database port (default 3306): " EXTERNAL_DB_PORT
    EXTERNAL_DB_PORT=${EXTERNAL_DB_PORT:-3306}
    read -rp "Enter database name: " EXTERNAL_DB_NAME
    read -rp "Enter database username: " EXTERNAL_DB_USER
    read -rsp "Enter database password: " EXTERNAL_DB_PASSWORD
    echo
    echo
    
    if test_external_db_connection; then
        log_success "External database connection verified"
        DB_NAME="$EXTERNAL_DB_NAME"
        DB_USER="$EXTERNAL_DB_USER"
        DB_PASSWORD="$EXTERNAL_DB_PASSWORD"
    else
        log_error "Couldn't connect to DB from this server."
        read -rp "Continue without DB? (yes/no): " CONTINUE_WITHOUT_DB
        if [ "$CONTINUE_WITHOUT_DB" != "yes" ]; then
            echo "Setup aborted by user."
            exit 1
        else
            log_info "Continuing setup without database configuration"
            USE_EXTERNAL_DB="no"
        fi
    fi
}

test_external_db_connection() {
    log_info "Testing external database connection..."
    
    # Install mysql client if not present
    if ! command -v mysql >/dev/null 2>&1; then
        log_info "Installing MySQL client for connection testing..."
        apt update >/dev/null 2>&1
        apt install -y mysql-client-core-8.0 >/dev/null 2>&1
    fi
    
    # Test connection
    if mysql -h "$EXTERNAL_DB_HOST" -P "$EXTERNAL_DB_PORT" -u "$EXTERNAL_DB_USER" -p"$EXTERNAL_DB_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ---------------------------------
# Input Collection
# ---------------------------------
collect_inputs() {
    echo "================================="
    echo " Laravel Infrastructure Setup"
    echo "================================="
    echo
    
    read -rp "Enter application name (e.g., myapp): " APP_NAME
    read -rp "Enter domain name (example.com www.example.com): " DOMAIN_NAME
    read -rp "Enter PHP version (8.4 / 8.3 / 8.2 / 8.1): " PHP_VERSION
    
    validate_php_version
    PHP_PKG="php$PHP_VERSION"
    
    read -rp "Enter Node.js version (18 / 20 / 22): " NODE_VERSION
    validate_node_version
    
    read -rp "Install MySQL database server? (yes/no): " INSTALL_MYSQL
    
    if [ "$INSTALL_MYSQL" != "yes" ]; then
        read -rp "Are you using an external database like RDS or other? (yes/no): " USE_EXTERNAL_DB
        if [ "$USE_EXTERNAL_DB" = "yes" ]; then
            collect_external_db_details
        fi
    fi
    
    read -rp "Install Redis for caching/sessions? (yes/no): " INSTALL_REDIS
    read -rp "Install Supervisor for queue workers? (yes/no): " INSTALL_SUPERVISOR
    read -rp "Install SSL certificate? (yes/no): " INSTALL_SSL
    
    WEB_ROOT="/var/www/$APP_NAME"
    NGINX_CONF="$NGINX_AVAIL/$APP_NAME.conf"
    
    echo
    echo "================= SUMMARY =================="
    echo "App Name     : $APP_NAME"
    echo "Domain       : $DOMAIN_NAME"
    echo "Web Root     : $WEB_ROOT"
    echo "PHP Version  : $PHP_PKG"
    echo "Node.js      : v$NODE_VERSION"
    echo "MySQL        : $INSTALL_MYSQL"
    if [ "$USE_EXTERNAL_DB" = "yes" ]; then
        echo "External DB  : $EXTERNAL_DB_HOST:$EXTERNAL_DB_PORT/$EXTERNAL_DB_NAME"
    fi
    echo "Redis        : $INSTALL_REDIS"
    echo "Supervisor   : $INSTALL_SUPERVISOR"
    echo "SSL          : $INSTALL_SSL"
    echo "==========================================="
    echo
    
    read -rp "Proceed with infrastructure setup? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Setup cancelled by user."
        exit 0
    fi
}

# ---------------------------------
# System Setup
# ---------------------------------
update_system() {
    log_info "Checking for system package updates..."
    if ! apt update -y >/dev/null 2>&1; then
        log_error "Failed to update package list"
        return 1
    fi
    
    # Check if there are any upgradable packages
    local upgradable_count=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
    
    if [ "$upgradable_count" -gt 0 ]; then
        log_info "Found $upgradable_count upgradable packages. Upgrading..."
        if apt upgrade -y >/dev/null 2>&1; then
            log_success "System packages updated"
        else
            log_error "Failed to upgrade system packages"
            return 1
        fi
    else
        log_success "No package updates available. System is up to date."
    fi
}

install_nginx() {
    if check_installed "nginx"; then
        log_skip "Nginx"
        return 0
    fi
    
    log_info "Installing Nginx..."
    if apt install nginx -y >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || { log_error "Failed to enable Nginx"; return 1; }
        systemctl start nginx >/dev/null 2>&1 || { log_error "Failed to start Nginx"; return 1; }
        log_success "Nginx installed and started"
    else
        log_error "Failed to install Nginx"
        return 1
    fi
}

install_php() {
    if check_installed "$PHP_PKG"; then
        log_skip "PHP $PHP_VERSION"
        return 0
    fi
    
    log_info "Installing PHP $PHP_PKG with Laravel extensions..."
    
    # Add PHP repository
    if ! apt install software-properties-common -y >/dev/null 2>&1; then
        log_error "Failed to install software-properties-common"
        return 1
    fi
    
    if ! add-apt-repository ppa:ondrej/php -y >/dev/null 2>&1; then
        log_error "Failed to add PHP repository"
        return 1
    fi
    
    if ! apt update -y >/dev/null 2>&1; then
        log_error "Failed to update package list after adding PHP repository"
        return 1
    fi
    
    # Install PHP and required extensions for Laravel
    if apt install -y \
        "$PHP_PKG" \
        "$PHP_PKG-cli" \
        "$PHP_PKG-fpm" \
        "$PHP_PKG-mysql" \
        "$PHP_PKG-pgsql" \
        "$PHP_PKG-sqlite3" \
        "$PHP_PKG-redis" \
        "$PHP_PKG-memcached" \
        "$PHP_PKG-gd" \
        "$PHP_PKG-xml" \
        "$PHP_PKG-mbstring" \
        "$PHP_PKG-curl" \
        "$PHP_PKG-zip" \
        "$PHP_PKG-bcmath" \
        "$PHP_PKG-intl" \
        "$PHP_PKG-readline" \
        "$PHP_PKG-msgpack" \
        "$PHP_PKG-igbinary" >/dev/null 2>&1; then
        
        systemctl enable "$PHP_PKG-fpm" >/dev/null 2>&1 || { log_error "Failed to enable PHP-FPM"; return 1; }
        systemctl start "$PHP_PKG-fpm" >/dev/null 2>&1 || { log_error "Failed to start PHP-FPM"; return 1; }
        log_success "PHP $PHP_VERSION installed with all Laravel extensions"
    else
        log_error "Failed to install PHP $PHP_VERSION"
        return 1
    fi
}

install_composer() {
    if command -v composer >/dev/null 2>&1; then
        log_skip "Composer"
        return 0
    fi
    
    log_info "Installing Composer..."
    
    # First try installing from repository with timeout
    if timeout 30 apt install -y composer >/dev/null 2>&1; then
        log_success "Composer installed: $(composer --version 2>/dev/null | head -1)"
        return 0
    fi
    
    # If repository installation fails, install manually
    log_info "Repository installation failed, installing Composer manually..."
    
    # Download and install Composer manually
    if curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null 2>&1; then
        chmod +x /usr/local/bin/composer
        log_success "Composer installed manually: $(composer --version 2>/dev/null | head -1)"
    else
        log_error "Failed to install Composer"
        return 1
    fi
}

install_nodejs() {
    if command -v node >/dev/null 2>&1; then
        local current_version=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$current_version" = "$NODE_VERSION" ]; then
            log_skip "Node.js v$NODE_VERSION"
            return 0
        fi
    fi
    
    log_info "Installing Node.js v$NODE_VERSION..."
    
    # Install NodeSource repository
    if curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - >/dev/null 2>&1; then
        if apt install -y nodejs >/dev/null 2>&1; then
            log_success "Node.js installed: $(node --version 2>/dev/null)"
            log_success "npm installed: $(npm --version 2>/dev/null)"
        else
            log_error "Failed to install Node.js"
            return 1
        fi
    else
        log_error "Failed to add Node.js repository"
        return 1
    fi
}

# ---------------------------------
# MySQL Management Functions
# ---------------------------------
remove_mysql() {
    log_info "Removing MySQL server completely..."
    
    # Stop MySQL service
    systemctl stop mysql >/dev/null 2>&1 || true
    systemctl disable mysql >/dev/null 2>&1 || true
    
    # Remove MySQL packages and data
    if apt purge -y mysql-server mysql-client mysql-common mysql-server-core-* mysql-client-core-* >/dev/null 2>&1; then
        apt autoremove -y >/dev/null 2>&1
        apt autoclean >/dev/null 2>&1
        
        # Remove MySQL data directories
        rm -rf /var/lib/mysql >/dev/null 2>&1
        rm -rf /var/log/mysql >/dev/null 2>&1
        rm -rf /etc/mysql >/dev/null 2>&1
        
        # Remove MySQL user
        userdel mysql >/dev/null 2>&1 || true
        groupdel mysql >/dev/null 2>&1 || true
        
        log_success "MySQL server completely removed"
        return 0
    else
        log_error "Failed to remove MySQL server"
        return 1
    fi
}

create_database_with_auth() {
    local mysql_cmd="$1"
    
    if $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" 2>/dev/null && \
       $mysql_cmd -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null && \
       $mysql_cmd -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" 2>/dev/null && \
       $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null; then
        
        log_success "Database '$DB_NAME' and user '$DB_USER' created successfully"
        return 0
    else
        log_error "Failed to create database and user"
        return 1
    fi
}

install_fresh_mysql() {
    log_info "Installing fresh MySQL server..."
    
    # Set MySQL root password non-interactively
    debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD" 2>/dev/null
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD" 2>/dev/null
    
    if apt install mysql-server -y >/dev/null 2>&1; then
        systemctl enable mysql >/dev/null 2>&1 || { log_error "Failed to enable MySQL"; return 1; }
        systemctl start mysql >/dev/null 2>&1 || { log_error "Failed to start MySQL"; return 1; }
        
        # Wait for MySQL to be ready
        log_info "Waiting for MySQL to initialize..."
        sleep 10
        
        # Try multiple authentication methods for fresh installation
        local mysql_ready=false
        local attempts=0
        
        while [ $attempts -lt 3 ] && [ "$mysql_ready" = false ]; do
            attempts=$((attempts + 1))
            log_info "Testing MySQL connection (attempt $attempts)..."
            
            # Method 1: Try with configured password
            if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with configured password"
                if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                    mysql_ready=true
                fi
            # Method 2: Try sudo mysql (Ubuntu default)
            elif sudo mysql -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with sudo authentication"
                # Set root password first
                if sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                    sleep 2
                    if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                        mysql_ready=true
                    fi
                else
                    # Use sudo mysql directly
                    if create_database_with_auth "sudo mysql"; then
                        MYSQL_ROOT_PASSWORD="Use 'sudo mysql' for root access"
                        mysql_ready=true
                    fi
                fi
            # Method 3: Try passwordless root
            elif mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with passwordless root"
                # Set root password
                if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                    sleep 2
                    if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                        mysql_ready=true
                    fi
                else
                    # Use passwordless access
                    if create_database_with_auth "mysql -u root"; then
                        MYSQL_ROOT_PASSWORD="No password required"
                        mysql_ready=true
                    fi
                fi
            else
                log_info "MySQL not ready yet, waiting..."
                sleep 5
            fi
        done
        
        if [ "$mysql_ready" = true ]; then
            log_success "MySQL server installed and configured successfully"
            return 0
        else
            log_error "MySQL installed but database creation failed after multiple attempts"
            log_info "You may need to run: sudo mysql_secure_installation"
            return 1
        fi
    else
        log_error "Failed to install MySQL server"
        return 1
    fi
}

install_database() {
    if [ "$INSTALL_MYSQL" != "yes" ] && [ "$USE_EXTERNAL_DB" != "yes" ]; then
        log_info "Database installation skipped by user choice"
        return 0
    fi
    
    if [ "$USE_EXTERNAL_DB" = "yes" ]; then
        log_info "Using external database configuration"
        return 0
    fi
    
    # Local MySQL installation logic
    # Always generate database credentials with sanitized names
    local sanitized_name=$(echo "$APP_NAME" | tr '-' '_')
    DB_NAME="${sanitized_name}_db"
    DB_USER="${sanitized_name}_user"
    DB_PASSWORD=$(generate_password)
    
    if check_installed "mysql-server"; then
        echo
        echo -e "${YELLOW}MySQL server is already installed.${NC}"
        read -rp "Do you want to remove and reinstall MySQL? (yes/no): " REINSTALL_MYSQL
        
        if [ "$REINSTALL_MYSQL" = "yes" ]; then
            if remove_mysql; then
                MYSQL_ROOT_PASSWORD=$(generate_password)
                install_fresh_mysql
            else
                log_error "Failed to remove existing MySQL installation"
                return 1
            fi
        else
            # Try to use existing MySQL installation
            log_info "Using existing MySQL installation..."
            
            # Try different authentication methods
            if sudo mysql -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "Using sudo authentication for MySQL"
                create_database_with_auth "sudo mysql"
            elif mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "Using passwordless root authentication"
                create_database_with_auth "mysql -u root"
            else
                # Ask for existing root password
                echo
                read -rsp "Enter existing MySQL root password: " EXISTING_ROOT_PASSWORD
                echo
                
                if mysql -u root -p"$EXISTING_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
                    log_info "Using provided root password"
                    MYSQL_ROOT_PASSWORD="$EXISTING_ROOT_PASSWORD"
                    create_database_with_auth "mysql -u root -p$EXISTING_ROOT_PASSWORD"
                else
                    log_error "Invalid MySQL root password or authentication failed"
                    log_info "Please run 'mysql_secure_installation' or reinstall MySQL"
                    return 1
                fi
            fi
        fi
    else
        # Fresh installation
        MYSQL_ROOT_PASSWORD="root"
        install_fresh_mysql
    fi
}

install_redis() {
    if [ "$INSTALL_REDIS" != "yes" ]; then
        return 0
    fi
    
    if check_installed "redis-server"; then
        log_skip "Redis Server"
        return 0
    fi
    
    log_info "Installing Redis..."
    if apt install redis-server -y >/dev/null 2>&1; then
        systemctl enable redis-server >/dev/null 2>&1 || { log_error "Failed to enable Redis"; return 1; }
        systemctl start redis-server >/dev/null 2>&1 || { log_error "Failed to start Redis"; return 1; }
        
        # Configure Redis for Laravel
        sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf 2>/dev/null
        sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null
        systemctl restart redis-server >/dev/null 2>&1 || { log_error "Failed to restart Redis"; return 1; }
        log_success "Redis installed and configured for Laravel"
    else
        log_error "Failed to install Redis"
        return 1
    fi
}

install_supervisor() {
    if [ "$INSTALL_SUPERVISOR" != "yes" ]; then
        return 0
    fi
    
    if check_installed "supervisor"; then
        log_skip "Supervisor"
        return 0
    fi
    
    log_info "Installing Supervisor..."
    if apt install supervisor -y >/dev/null 2>&1; then
        systemctl enable supervisor >/dev/null 2>&1 || { log_error "Failed to enable Supervisor"; return 1; }
        systemctl start supervisor >/dev/null 2>&1 || { log_error "Failed to start Supervisor"; return 1; }
        
        # Create Laravel queue worker config template
        if cat > "/etc/supervisor/conf.d/${APP_NAME}-worker.conf" << EOF
[program:${APP_NAME}-worker]
process_name=%(program_name)s_%(process_num)02d
command=php ${WEB_ROOT}/artisan queue:work --sleep=3 --tries=3 --max-time=3600
directory=${WEB_ROOT}
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=www-data
numprocs=2
redirect_stderr=true
stdout_logfile=${WEB_ROOT}/storage/logs/worker.log
stopwaitsecs=3600
EOF
        then
            log_success "Supervisor installed with Laravel queue worker config"
        else
            log_error "Supervisor installed but failed to create worker config"
            return 1
        fi
    else
        log_error "Failed to install Supervisor"
        return 1
    fi
}

# ---------------------------------
# Web Root Setup
# ---------------------------------
setup_webroot() {
    log_info "Creating web root structure..."
    
    mkdir -p "$WEB_ROOT" 2>/dev/null
    mkdir -p "$WEB_ROOT/public" 2>/dev/null
    mkdir -p "$WEB_ROOT/storage/logs" 2>/dev/null
    
    # Create Coming Soon landing page
    cat > "$WEB_ROOT/public/index.php" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Coming Soon!</title>
    <style>
        body { 
            font-family: 'Arial', sans-serif; 
            text-align: center; 
            padding: 50px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            margin: 0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container { 
            max-width: 600px; 
            margin: 0 auto;
            background: rgba(255,255,255,0.1);
            padding: 40px;
            border-radius: 15px;
            backdrop-filter: blur(10px);
            box-shadow: 0 8px 32px rgba(0,0,0,0.1);
        }
        .title { 
            font-size: 48px; 
            margin: 20px 0;
            font-weight: bold;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        .subtitle {
            font-size: 18px;
            margin: 20px 0;
            opacity: 0.9;
        }
        .status { 
            color: #4CAF50; 
            font-size: 16px; 
            margin: 30px 0;
            background: rgba(255,255,255,0.2);
            padding: 15px;
            border-radius: 8px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="title">Coming Soon!</div>
        <div class="subtitle">We're working hard to bring you something amazing.</div>
        <div class="status">✓ Server infrastructure is ready and configured</div>
    </div>
</body>
</html>
EOF
    
    # Create .env file if database is configured
    if [ "$USE_EXTERNAL_DB" = "yes" ] || [ "$INSTALL_MYSQL" = "yes" ]; then
        create_env_file
    fi
    
    chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null
    chmod -R 755 "$WEB_ROOT" 2>/dev/null
    chmod -R 775 "$WEB_ROOT/storage" 2>/dev/null
}

create_env_file() {
    log_info "Creating .env file with database configuration..."
    
    if [ "$USE_EXTERNAL_DB" = "yes" ]; then
        # External database configuration
        cat > "$WEB_ROOT/.env" << EOF
APP_NAME=$APP_NAME
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://$(echo $DOMAIN_NAME | awk '{print $1}')

LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=$EXTERNAL_DB_HOST
DB_PORT=$EXTERNAL_DB_PORT
DB_DATABASE=$EXTERNAL_DB_NAME
DB_USERNAME=$EXTERNAL_DB_USER
DB_PASSWORD=$EXTERNAL_DB_PASSWORD

BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120

MEMCACHED_HOST=127.0.0.1

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="hello@example.com"
MAIL_FROM_NAME="\${APP_NAME}"

AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=ap-south-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false

PUSHER_APP_ID=
PUSHER_APP_KEY=
PUSHER_APP_SECRET=
PUSHER_HOST=
PUSHER_PORT=443
PUSHER_SCHEME=https
PUSHER_APP_CLUSTER=mt1

VITE_APP_NAME="\${APP_NAME}"
VITE_PUSHER_APP_KEY="\${PUSHER_APP_KEY}"
VITE_PUSHER_HOST="\${PUSHER_HOST}"
VITE_PUSHER_PORT="\${PUSHER_PORT}"
VITE_PUSHER_SCHEME="\${PUSHER_SCHEME}"
VITE_PUSHER_APP_CLUSTER="\${PUSHER_APP_CLUSTER}"
EOF
    else
        # Local MySQL configuration
        cat > "$WEB_ROOT/.env" << EOF
APP_NAME=$APP_NAME
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://$(echo $DOMAIN_NAME | awk '{print $1}')

LOG_CHANNEL=stack
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=debug

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASSWORD

BROADCAST_DRIVER=log
CACHE_DRIVER=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120

MEMCACHED_HOST=127.0.0.1

REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=smtp
MAIL_HOST=mailpit
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
MAIL_FROM_ADDRESS="hello@example.com"
MAIL_FROM_NAME="\${APP_NAME}"

AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false

PUSHER_APP_ID=
PUSHER_APP_KEY=
PUSHER_APP_SECRET=
PUSHER_HOST=
PUSHER_PORT=443
PUSHER_SCHEME=https
PUSHER_APP_CLUSTER=mt1

VITE_APP_NAME="\${APP_NAME}"
VITE_PUSHER_APP_KEY="\${PUSHER_APP_KEY}"
VITE_PUSHER_HOST="\${PUSHER_HOST}"
VITE_PUSHER_PORT="\${PUSHER_PORT}"
VITE_PUSHER_SCHEME="\${PUSHER_SCHEME}"
VITE_PUSHER_APP_CLUSTER="\${PUSHER_APP_CLUSTER}"
EOF
    fi
    
    chmod 644 "$WEB_ROOT/.env"
    chown www-data:www-data "$WEB_ROOT/.env"
    log_success ".env file created with database configuration"
}

# ---------------------------------
# Nginx Configuration
# ---------------------------------
generate_nginx_config() {
    log_info "Generating Laravel Nginx configuration..."
    
    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;
    root $WEB_ROOT/public;
    index index.php index.html;
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;
    
    # Laravel routing
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    # PHP processing
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/$PHP_PKG-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        
        # Laravel specific
        fastcgi_hide_header X-Powered-By;
        fastcgi_read_timeout 300;
        fastcgi_buffer_size 128k;
        fastcgi_buffers 4 256k;
        fastcgi_busy_buffers_size 256k;
    }
    
    # Assets caching
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
    
    # Deny access to sensitive files
    location ~ /\.(ht|env) {
        deny all;
    }
    
    location ~ /storage/.*\.php$ {
        deny all;
    }
    
    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;
}
EOF
}

# ---------------------------------
# Swap File Setup
# ---------------------------------
setup_swap() {
    log_info "Setting up 2GB swap file for Laravel..."
    
    # Check if swap already exists
    if swapon --show | grep -q '/swapfile'; then
        log_skip "Swap file (already exists)"
        return 0
    fi
    
    # Create 2GB swap file
    if fallocate -l 2G /swapfile >/dev/null 2>&1 || dd if=/dev/zero of=/swapfile bs=1M count=2048 >/dev/null 2>&1; then
        chmod 600 /swapfile 2>/dev/null
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        
        # Make swap permanent
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        
        # Optimize swap usage for Laravel
        echo 'vm.swappiness=10' >> /etc/sysctl.conf 2>/dev/null
        echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf 2>/dev/null
        sysctl vm.swappiness=10 >/dev/null 2>&1
        sysctl vm.vfs_cache_pressure=50 >/dev/null 2>&1
        
        log_success "2GB swap file configured with optimized settings"
    else
        log_error "Failed to create swap file"
        return 1
    fi
}

# ---------------------------------
# Site Activation
# ---------------------------------
activate_site() {
    log_info "Activating Laravel site..."
    
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED/$APP_NAME.conf" 2>/dev/null
    rm -f "$NGINX_ENABLED/default" 2>/dev/null
    
    if ! nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration test failed"
        exit 1
    fi
    
    systemctl reload nginx >/dev/null 2>&1
}

# ---------------------------------
# Website Testing
# ---------------------------------
test_website() {
    log_info "Testing website accessibility..."
    
    local primary_domain=$(echo "$DOMAIN_NAME" | awk '{print $1}')
    local test_results=""
    
    echo
    echo "=== WEBSITE ACCESSIBILITY TEST ==="
    
    if [ "$DNS_RESOLVED" = true ]; then
        # Test via domain (DNS resolved)
        log_info "Testing via domain: $primary_domain"
        
        if [ "$INSTALL_SSL" = "yes" ]; then
            # Test HTTPS
            local https_status=$(curl -s -o /dev/null -w "%{http_code}" "https://$primary_domain" 2>/dev/null || echo "000")
            if [[ "$https_status" =~ ^(200|301|302)$ ]]; then
                echo "✓ HTTPS accessible: https://$primary_domain (Status: $https_status)"
                test_results="HTTPS: ✓ Working"
            else
                echo "✗ HTTPS failed: https://$primary_domain (Status: $https_status)"
                test_results="HTTPS: ✗ Failed ($https_status)"
            fi
        fi
        
        # Test HTTP
        local http_status=$(curl -s -o /dev/null -w "%{http_code}" "http://$primary_domain" 2>/dev/null || echo "000")
        if [[ "$http_status" =~ ^(200|301|302)$ ]]; then
            echo "✓ HTTP accessible: http://$primary_domain (Status: $http_status)"
            test_results="$test_results | HTTP: ✓ Working"
        else
            echo "✗ HTTP failed: http://$primary_domain (Status: $http_status)"
            test_results="$test_results | HTTP: ✗ Failed ($http_status)"
        fi
        
    else
        # DNS not resolved - test locally
        log_info "DNS not resolved - testing local accessibility"
        
        # Test with Host header
        local local_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $primary_domain" "http://localhost" 2>/dev/null || echo "000")
        if [[ "$local_status" =~ ^(200|301|302)$ ]]; then
            echo "✓ Local test successful: http://localhost (Status: $local_status)"
            echo "  Add to /etc/hosts: 127.0.0.1 $primary_domain"
            test_results="Local: ✓ Working (Status: $local_status)"
        else
            echo "✗ Local test failed: http://localhost (Status: $local_status)"
            test_results="Local: ✗ Failed ($local_status)"
        fi
        
        # Test direct IP if available
        local server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null)
        if [ -n "$server_ip" ]; then
            local ip_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $primary_domain" "http://$server_ip" 2>/dev/null || echo "000")
            if [[ "$ip_status" =~ ^(200|301|302)$ ]]; then
                echo "✓ IP test successful: http://$server_ip (Status: $ip_status)"
                test_results="$test_results | IP: ✓ Working"
            else
                echo "✗ IP test failed: http://$server_ip (Status: $ip_status)"
                test_results="$test_results | IP: ✗ Failed ($ip_status)"
            fi
        fi
    fi
    
    echo "=============================="
    echo
    
    # Store test results for final summary
    WEBSITE_TEST_RESULTS="$test_results"
}

# ---------------------------------
# SSL Setup
# ---------------------------------
setup_ssl() {
    if [ "$INSTALL_SSL" = "yes" ]; then
        check_dns_resolution "$DOMAIN_NAME"
        
        if [ "$DNS_RESOLVED" = false ]; then
            log_info "Skipping SSL setup - DNS not resolved for domain"
            return
        fi
        
        log_info "Installing SSL certificate..."
        apt install certbot python3-certbot-nginx -y >/dev/null 2>&1
        
        if certbot --nginx -d $(echo $DOMAIN_NAME | tr ' ' ',') --non-interactive --agree-tos --email admin@$(echo $DOMAIN_NAME | awk '{print $1}') >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
            log_info "SSL certificate installed successfully"
        else
            log_error "SSL certificate installation failed"
        fi
    fi
}

# ---------------------------------
# Final Instructions
# ---------------------------------
show_instructions() {
    echo
    echo "========================================="
    echo " Laravel Infrastructure Setup Complete!"
    echo "========================================="
    echo
    echo "Environment Details:"
    echo "  Web Root: $WEB_ROOT"
    echo "  PHP Version: $PHP_VERSION"
    if [ "$INSTALL_MYSQL" = "yes" ] && [ -n "$DB_NAME" ]; then
        echo "  Database: $DB_NAME (Local MySQL)"
        echo "  DB User: $DB_USER"
        echo "  .env file: $WEB_ROOT/.env (configured with local MySQL)"
    elif [ "$USE_EXTERNAL_DB" = "yes" ]; then
        echo "  Database: $EXTERNAL_DB_NAME (External: $EXTERNAL_DB_HOST:$EXTERNAL_DB_PORT)"
        echo "  DB User: $EXTERNAL_DB_USER"
        echo "  .env file: $WEB_ROOT/.env (configured with external DB)"
    else
        echo "  Database: Not configured"
    fi
    echo
    echo "Website Test Results:"
    echo "  $WEBSITE_TEST_RESULTS"
    echo
    echo "Next Steps for Laravel Deployment:"
    echo "  1. Upload/clone your Laravel project to: $WEB_ROOT"
    echo "  2. cd $WEB_ROOT"
    echo "  3. composer install --optimize-autoloader --no-dev"
    if [ "$USE_EXTERNAL_DB" = "yes" ] || [ "$INSTALL_MYSQL" = "yes" ]; then
        echo "  4. .env file already configured with database settings"
        echo "  5. php artisan key:generate"
        echo "  6. php artisan migrate"
        echo "  7. php artisan config:cache"
        echo "  8. php artisan route:cache"
        echo "  9. php artisan view:cache"
        echo "  10. chown -R www-data:www-data storage bootstrap/cache"
    else
        echo "  4. cp .env.example .env (configure database manually)"
        echo "  5. php artisan key:generate"
        echo "  6. Configure database in .env file"
        echo "  7. php artisan migrate"
        echo "  8. php artisan config:cache"
        echo "  9. php artisan route:cache"
        echo "  10. php artisan view:cache"
        echo "  11. chown -R www-data:www-data storage bootstrap/cache"
    fi
    echo
    if [ "$INSTALL_SUPERVISOR" = "yes" ]; then
        echo "Queue Worker Setup:"
        echo "  - After Laravel deployment, enable: supervisorctl reread && supervisorctl update"
        echo
    fi
    echo "Test URL: http://$(echo $DOMAIN_NAME | awk '{print $1}')"
    echo "========================================="
}

# ---------------------------------
# Main Execution
# ---------------------------------
main() {
    check_root
    collect_inputs
    setup_swap
    update_system
    install_nginx
    install_php
    install_composer
    install_nodejs
    install_database
    install_redis
    install_supervisor
    setup_webroot
    generate_nginx_config
    activate_site
    setup_ssl
    test_website
    show_instructions
}

# Run main function
main "$@"