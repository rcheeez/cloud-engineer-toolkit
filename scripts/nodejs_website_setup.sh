#!/bin/bash

# Next.js Website Infrastructure Setup Tool
# Prepares server environment for Next.js application deployment

set -e

# Global variables
APP_NAME=""
DOMAIN_NAME=""
NODE_VERSION=""
INSTALL_SSL=""
INSTALL_REDIS=""
INSTALL_PM2=""
INSTALL_MYSQL=""
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

validate_node_version() {
    if [[ ! "$NODE_VERSION" =~ ^(18|20|22)$ ]]; then
        log_error "Unsupported Node.js version: $NODE_VERSION (Next.js requires 18, 20, or 22)"
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
# Input Collection
# ---------------------------------
collect_inputs() {
    echo "================================="
    echo " Next.js Infrastructure Setup"
    echo "================================="
    echo
    
    read -rp "Enter application name (e.g., myapp): " APP_NAME
    read -rp "Enter domain name (example.com www.example.com): " DOMAIN_NAME
    read -rp "Enter Node.js version (18 / 20 / 22): " NODE_VERSION
    
    validate_node_version
    
    read -rp "Install MySQL database server? (yes/no): " INSTALL_MYSQL
    read -rp "Install Redis for caching/sessions? (yes/no): " INSTALL_REDIS
    read -rp "Install PM2 for process management? (yes/no): " INSTALL_PM2
    read -rp "Install SSL certificate? (yes/no): " INSTALL_SSL
    
    WEB_ROOT="/var/www/$APP_NAME"
    NGINX_CONF="$NGINX_AVAIL/$APP_NAME.conf"
    
    echo
    echo "================= SUMMARY =================="
    echo "App Name     : $APP_NAME"
    echo "Domain       : $DOMAIN_NAME"
    echo "Web Root     : $WEB_ROOT"
    echo "Node.js      : v$NODE_VERSION"
    echo "MySQL        : $INSTALL_MYSQL"
    echo "Redis        : $INSTALL_REDIS"
    echo "PM2          : $INSTALL_PM2"
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

setup_swap() {
    log_info "Setting up 2GB swap file for Next.js..."
    
    if swapon --show | grep -q '/swapfile'; then
        log_skip "Swap file (already exists)"
        return 0
    fi
    
    if fallocate -l 2G /swapfile >/dev/null 2>&1 || dd if=/dev/zero of=/swapfile bs=1M count=2048 >/dev/null 2>&1; then
        chmod 600 /swapfile 2>/dev/null
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1
        
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        
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

install_nginx() {
    if check_installed "nginx"; then
        log_skip "Nginx"
        return 0
    fi
    
    log_info "Installing Nginx..."
    if apt install -y nginx >/dev/null 2>&1; then
        systemctl enable nginx >/dev/null 2>&1 || { log_error "Failed to enable Nginx"; return 1; }
        systemctl start nginx >/dev/null 2>&1 || { log_error "Failed to start Nginx"; return 1; }
        log_success "Nginx installed and started"
    else
        log_error "Failed to install Nginx"
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

install_pm2() {
    if [ "$INSTALL_PM2" != "yes" ]; then
        return 0
    fi
    
    if command -v pm2 >/dev/null 2>&1; then
        log_skip "PM2"
        return 0
    fi
    
    log_info "Installing PM2..."
    if npm install -g pm2 >/dev/null 2>&1; then
        # Setup PM2 startup script
        pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
        log_success "PM2 installed and configured"
    else
        log_error "Failed to install PM2"
        return 1
    fi
}

# ---------------------------------
# MySQL Management Functions
# ---------------------------------
remove_mysql() {
    log_info "Removing MySQL server completely..."
    
    systemctl stop mysql >/dev/null 2>&1 || true
    systemctl disable mysql >/dev/null 2>&1 || true
    
    if apt purge -y mysql-server mysql-client mysql-common mysql-server-core-* mysql-client-core-* >/dev/null 2>&1; then
        apt autoremove -y >/dev/null 2>&1
        apt autoclean >/dev/null 2>&1
        
        rm -rf /var/lib/mysql >/dev/null 2>&1
        rm -rf /var/log/mysql >/dev/null 2>&1
        rm -rf /etc/mysql >/dev/null 2>&1
        
        userdel mysql >/dev/null 2>&1 || true
        groupdel mysql >/dev/null 2>&1 || true
        
        log_success "MySQL server completely removed"
        return 0
    else
        log_error "Failed to remove MySQL server"
        return 1
    fi
}

create_credentials_file() {
    cat > "/root/${APP_NAME}_mysql_credentials.txt" << EOF
MySQL Root Password: ${MYSQL_ROOT_PASSWORD:-"N/A"}
Database Name: $DB_NAME
Database User: $DB_USER
Database Password: $DB_PASSWORD

Connection String for Next.js .env:
DATABASE_URL="mysql://$DB_USER:$DB_PASSWORD@localhost:3306/$DB_NAME"
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$DB_NAME
DB_USERNAME=$DB_USER
DB_PASSWORD=$DB_PASSWORD
EOF
    
    chmod 600 "/root/${APP_NAME}_mysql_credentials.txt"
    log_success "Credentials saved to /root/${APP_NAME}_mysql_credentials.txt"
}

create_database_with_auth() {
    local mysql_cmd="$1"
    
    if $mysql_cmd -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;" 2>/dev/null && \
       $mysql_cmd -e "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD';" 2>/dev/null && \
       $mysql_cmd -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';" 2>/dev/null && \
       $mysql_cmd -e "FLUSH PRIVILEGES;" 2>/dev/null; then
        
        create_credentials_file
        log_success "Database '$DB_NAME' and user '$DB_USER' created successfully"
        return 0
    else
        log_error "Failed to create database and user"
        return 1
    fi
}

install_fresh_mysql() {
    log_info "Installing fresh MySQL server..."
    
    debconf-set-selections <<< "mysql-server mysql-server/root_password password $MYSQL_ROOT_PASSWORD" 2>/dev/null
    debconf-set-selections <<< "mysql-server mysql-server/root_password_again password $MYSQL_ROOT_PASSWORD" 2>/dev/null
    
    if apt install -y mysql-server >/dev/null 2>&1; then
        systemctl enable mysql >/dev/null 2>&1 || { log_error "Failed to enable MySQL"; return 1; }
        systemctl start mysql >/dev/null 2>&1 || { log_error "Failed to start MySQL"; return 1; }
        
        log_info "Waiting for MySQL to initialize..."
        sleep 10
        
        local mysql_ready=false
        local attempts=0
        
        while [ $attempts -lt 3 ] && [ "$mysql_ready" = false ]; do
            attempts=$((attempts + 1))
            log_info "Testing MySQL connection (attempt $attempts)..."
            
            if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with configured password"
                if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                    mysql_ready=true
                fi
            elif sudo mysql -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with sudo authentication"
                if sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                    sleep 2
                    if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                        mysql_ready=true
                    fi
                else
                    if create_database_with_auth "sudo mysql"; then
                        MYSQL_ROOT_PASSWORD="Use 'sudo mysql' for root access"
                        mysql_ready=true
                    fi
                fi
            elif mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "MySQL ready with passwordless root"
                if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
                    sleep 2
                    if create_database_with_auth "mysql -u root -p$MYSQL_ROOT_PASSWORD"; then
                        mysql_ready=true
                    fi
                else
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
            return 1
        fi
    else
        log_error "Failed to install MySQL server"
        return 1
    fi
}

install_database() {
    if [ "$INSTALL_MYSQL" != "yes" ]; then
        log_info "MySQL installation skipped by user choice"
        return 0
    fi
    
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
                MYSQL_ROOT_PASSWORD="root"
                install_fresh_mysql
            else
                log_error "Failed to remove existing MySQL installation"
                return 1
            fi
        else
            log_info "Using existing MySQL installation..."
            
            if sudo mysql -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "Using sudo authentication for MySQL"
                create_database_with_auth "sudo mysql"
            elif mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
                log_info "Using passwordless root authentication"
                create_database_with_auth "mysql -u root"
            else
                echo
                read -rsp "Enter existing MySQL root password: " EXISTING_ROOT_PASSWORD
                echo
                
                if mysql -u root -p"$EXISTING_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
                    log_info "Using provided root password"
                    MYSQL_ROOT_PASSWORD="$EXISTING_ROOT_PASSWORD"
                    create_database_with_auth "mysql -u root -p$EXISTING_ROOT_PASSWORD"
                else
                    log_error "Invalid MySQL root password or authentication failed"
                    return 1
                fi
            fi
        fi
    else
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
    if apt install -y redis-server >/dev/null 2>&1; then
        systemctl enable redis-server >/dev/null 2>&1 || { log_error "Failed to enable Redis"; return 1; }
        systemctl start redis-server >/dev/null 2>&1 || { log_error "Failed to start Redis"; return 1; }
        
        sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf 2>/dev/null
        sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null
        systemctl restart redis-server >/dev/null 2>&1 || { log_error "Failed to restart Redis"; return 1; }
        log_success "Redis installed and configured for Next.js"
    else
        log_error "Failed to install Redis"
        return 1
    fi
}

# ---------------------------------
# Web Root Setup
# ---------------------------------
setup_webroot() {
    log_info "Creating web root structure..."
    
    mkdir -p "$WEB_ROOT" 2>/dev/null
    
    # Create only fallback HTML file
    cat > "$WEB_ROOT/index.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Next.js Setup Ready</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; background: #f5f5f5; }
        .container { max-width: 600px; margin: 0 auto; background: white; padding: 40px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        .status { color: #28a745; font-size: 24px; margin: 20px 0; }
        .instructions { background: #f8f9fa; padding: 20px; border-radius: 5px; text-align: left; margin: 20px 0; }
        code { background: #e9ecef; padding: 2px 4px; border-radius: 3px; font-family: monospace; }
        .logo { font-size: 48px; color: #0070f3; margin-bottom: 20px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="logo">⚡</div>
        <h1>Next.js Infrastructure Ready</h1>
        <div class="status">✓ Server environment configured successfully</div>
        
        <div class="instructions">
            <h3>Next Steps:</h3>
            <ol>
                <li>Deploy your Next.js application to: <code>$WEB_ROOT</code></li>
                <li>Run: <code>npm install</code></li>
                <li>Configure: <code>.env.local</code> file</li>
                <li>Run: <code>npm run build</code></li>
                <li>Start: <code>npm run start</code> or use PM2</li>
                <li>Set permissions: <code>chown -R www-data:www-data $WEB_ROOT</code></li>
            </ol>
            
            <h3>Database Configuration:</h3>
            <p>Database: <code>${DB_NAME:-'nextjs_db'}</code></p>
            <p>Username: <code>${DB_USER:-'nextjs_user'}</code></p>
            <p>Credentials: <code>/root/${APP_NAME}_mysql_credentials.txt</code></p>
            
            <h3>PM2 Commands:</h3>
            <p><code>pm2 start npm --name "$APP_NAME" -- start</code></p>
            <p><code>pm2 logs $APP_NAME</code></p>
        </div>
        
        <p><strong>Note:</strong> This placeholder will be replaced when your Next.js app starts on port 3000</p>
    </div>
</body>
</html>
EOF
    
    chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null
    chmod -R 755 "$WEB_ROOT" 2>/dev/null
}

# ---------------------------------
# Nginx Configuration
# ---------------------------------
generate_nginx_config() {
    log_info "Generating Next.js Nginx configuration..."
    
    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    listen [::]:80;
    
    server_name $DOMAIN_NAME;
    root $WEB_ROOT;
    
    access_log /var/log/nginx/${APP_NAME}_access.log;
    error_log /var/log/nginx/${APP_NAME}_error.log;
    
    location ~ /.well-known {
        auth_basic off;
        allow all;
    }
    
    index index.html;
    
    location / {
        proxy_pass http://127.0.0.1:3000/;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Server \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_pass_request_headers on;
        proxy_max_temp_file_size 0;
        proxy_connect_timeout 900;
        proxy_send_timeout 900;
        proxy_read_timeout 900;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_temp_file_write_size 256k;
    }
}
EOF
}

# ---------------------------------
# Site Activation
# ---------------------------------
activate_site() {
    log_info "Activating Next.js site..."
    
    ln -sf "$NGINX_CONF" "$NGINX_ENABLED/$APP_NAME.conf" 2>/dev/null
    rm -f "$NGINX_ENABLED/default" 2>/dev/null
    
    if ! nginx -t >/dev/null 2>&1; then
        log_error "Nginx configuration test failed"
        exit 1
    fi
    
    systemctl reload nginx >/dev/null 2>&1
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
        apt install -y certbot python3-certbot-nginx >/dev/null 2>&1
        
        if certbot --nginx -d $(echo $DOMAIN_NAME | tr ' ' ',') --non-interactive --agree-tos --email admin@$(echo $DOMAIN_NAME | awk '{print $1}') >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
            log_success "SSL certificate installed successfully"
        else
            log_error "SSL certificate installation failed"
        fi
    fi
}

# ---------------------------------
# Website Testing
# ---------------------------------
test_website() {
    log_info "Testing website accessibility..."
    
    local primary_domain=$(echo "$DOMAIN_NAME" | awk '{print $1}')
    
    echo
    echo "=== WEBSITE ACCESSIBILITY TEST ==="
    
    if [ "$DNS_RESOLVED" = true ]; then
        log_info "Testing via domain: $primary_domain"
        
        if [ "$INSTALL_SSL" = "yes" ]; then
            local https_status=$(curl -s -o /dev/null -w "%{http_code}" "https://$primary_domain" 2>/dev/null || echo "000")
            if [[ "$https_status" =~ ^(200|301|302)$ ]]; then
                echo "✓ HTTPS accessible: https://$primary_domain (Status: $https_status)"
                WEBSITE_TEST_RESULTS="HTTPS: ✓ Working"
            else
                echo "✗ HTTPS failed: https://$primary_domain (Status: $https_status)"
                WEBSITE_TEST_RESULTS="HTTPS: ✗ Failed ($https_status)"
            fi
        fi
        
        local http_status=$(curl -s -o /dev/null -w "%{http_code}" "http://$primary_domain" 2>/dev/null || echo "000")
        if [[ "$http_status" =~ ^(200|301|302)$ ]]; then
            echo "✓ HTTP accessible: http://$primary_domain (Status: $http_status)"
            WEBSITE_TEST_RESULTS="$WEBSITE_TEST_RESULTS | HTTP: ✓ Working"
        else
            echo "✗ HTTP failed: http://$primary_domain (Status: $http_status)"
            WEBSITE_TEST_RESULTS="$WEBSITE_TEST_RESULTS | HTTP: ✗ Failed ($http_status)"
        fi
    else
        log_info "DNS not resolved - testing local accessibility"
        
        local local_status=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $primary_domain" "http://localhost" 2>/dev/null || echo "000")
        if [[ "$local_status" =~ ^(200|301|302|502)$ ]]; then
            echo "✓ Local test successful: http://localhost (Status: $local_status)"
            echo "  Add to /etc/hosts: 127.0.0.1 $primary_domain"
            WEBSITE_TEST_RESULTS="Local: ✓ Working (Status: $local_status)"
        else
            echo "✗ Local test failed: http://localhost (Status: $local_status)"
            WEBSITE_TEST_RESULTS="Local: ✗ Failed ($local_status)"
        fi
    fi
    
    echo "=============================="
    echo
}

# ---------------------------------
# Final Instructions
# ---------------------------------
show_instructions() {
    echo
    echo "========================================="
    echo " Next.js Infrastructure Setup Complete!"
    echo "========================================="
    echo
    echo "Environment Details:"
    echo "  Web Root: $WEB_ROOT"
    echo "  Node.js Version: v$NODE_VERSION"
    if [ "$INSTALL_MYSQL" = "yes" ] && [ -n "$DB_NAME" ]; then
        echo "  Database: $DB_NAME"
        echo "  DB User: $DB_USER"
        echo "  Credentials: /root/${APP_NAME}_mysql_credentials.txt"
    fi
    echo
    echo "Website Test Results:"
    echo "  $WEBSITE_TEST_RESULTS"
    echo
    echo "Next Steps for Next.js Deployment:"
    echo "  1. Upload/clone your Next.js project to: $WEB_ROOT"
    echo "  2. cd $WEB_ROOT"
    echo "  3. npm install"
    echo "  4. Create .env.local with database credentials"
    echo "  5. npm run build"
    echo "  6. npm run start (or use PM2: pm2 start npm --name '$APP_NAME' -- start)"
    echo "  7. chown -R www-data:www-data $WEB_ROOT"
    echo
    if [ "$INSTALL_PM2" = "yes" ]; then
        echo "PM2 Commands:"
        echo "  - Start: pm2 start npm --name '$APP_NAME' -- start"
        echo "  - Stop: pm2 stop $APP_NAME"
        echo "  - Restart: pm2 restart $APP_NAME"
        echo "  - Logs: pm2 logs $APP_NAME"
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
    install_nodejs
    install_pm2
    install_database
    install_redis
    setup_webroot
    generate_nginx_config
    activate_site
    setup_ssl
    test_website
    show_instructions
}

# Run main function
main "$@"