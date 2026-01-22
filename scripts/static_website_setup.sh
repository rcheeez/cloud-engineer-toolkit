#!/bin/bash

# Static Website Setup Tool - Enhanced Version
# Modular, DNS-aware, with inline config generation

# Error handling
set -e
trap 'log_error "Script failed at line $LINENO. Exit code: $?"' ERR

# Global variables
APP_NAME=""
DOMAIN_NAME=""
NEED_PHP=""
PHP_VERSION=""
PHP_PKG=""
INSTALL_SSL=""
WEB_ROOT=""
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF=""
DNS_RESOLVED=false

# ---------------------------------
# Utility Functions
# ---------------------------------
log_error() {
    echo "ERROR: $1" >&2
}

log_info() {
    echo "INFO: $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

validate_php_version() {
    if [[ ! "$PHP_VERSION" =~ ^8\.[0-4]$ ]]; then
        log_error "Unsupported PHP version: $PHP_VERSION"
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

# ---------------------------------
# Input Collection
# ---------------------------------
collect_inputs() {
    echo "================================="
    echo " Static Website Setup Tool "
    echo "================================="
    echo
    
    read -rp "Enter application / domain folder name (example.com): " APP_NAME
    read -rp "Enter server_name (example.com www.example.com): " DOMAIN_NAME
    read -rp "Do you need PHP support? (yes/no): " NEED_PHP
    
    if [ "$NEED_PHP" = "yes" ]; then
        read -rp "Enter PHP version (8.4 / 8.3 / 8.2 / 8.1 / 8.0): " PHP_VERSION
        validate_php_version
        PHP_PKG="php$PHP_VERSION"
    fi
    
    read -rp "Do you want to install free SSL (Let's Encrypt)? (yes/no): " INSTALL_SSL
    
    WEB_ROOT="/var/www/$APP_NAME"
    NGINX_CONF="$NGINX_AVAIL/$APP_NAME.conf"
    
    echo
    echo "================= SUMMARY ================="
    echo "App Name     : $APP_NAME"
    echo "Domains      : $DOMAIN_NAME"
    echo "Web Root     : $WEB_ROOT"
    echo "PHP Support  : $NEED_PHP"
    [ "$NEED_PHP" = "yes" ] && echo "PHP Version  : $PHP_PKG"
    echo "Install SSL  : $INSTALL_SSL"
    echo "=========================================="
    echo
    
    read -rp "Proceed with setup? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted by user."
        exit 0
    fi
}

# ---------------------------------
# System Setup
# ---------------------------------
update_system() {
    log_info "Checking for system package updates..."
    if ! apt update -y 2>/dev/null; then
        log_error "Failed to update package list"
        exit 1
    fi
    
    # Check if there are any upgradable packages
    local upgradable_count=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
    
    if [ "$upgradable_count" -gt 0 ]; then
        log_info "Found $upgradable_count upgradable packages. Upgrading..."
        if ! apt upgrade -y 2>/dev/null; then
            log_error "Failed to upgrade system packages"
            exit 1
        fi
        log_info "System packages upgraded successfully"
    else
        log_info "No package updates available. System is up to date."
    fi
}

install_nginx() {
    log_info "Installing Nginx..."
    if ! apt install -y nginx 2>/dev/null; then
        log_error "Failed to install Nginx"
        exit 1
    fi
    if ! systemctl enable nginx 2>/dev/null; then
        log_error "Failed to enable Nginx service"
        exit 1
    fi
    if ! systemctl start nginx 2>/dev/null; then
        log_error "Failed to start Nginx service"
        exit 1
    fi
}

install_php() {
    if [ "$NEED_PHP" = "yes" ]; then
        log_info "Adding PHP repository..."
        if ! apt install -y software-properties-common 2>/dev/null; then
            log_error "Failed to install software-properties-common"
            exit 1
        fi
        
        if ! add-apt-repository ppa:ondrej/php -y 2>/dev/null; then
            log_error "Failed to add PHP repository (ppa:ondrej/php)"
            exit 1
        fi
        
        if ! apt update 2>/dev/null; then
            log_error "Failed to update package list after adding PHP repository"
            exit 1
        fi
        
        log_info "Installing PHP $PHP_PKG (CLI + FPM)..."
        if ! apt install -y "$PHP_PKG" "$PHP_PKG-cli" "$PHP_PKG-fpm" 2>/dev/null; then
            log_error "Failed to install PHP $PHP_VERSION packages"
            exit 1
        fi
        
        if ! systemctl enable "$PHP_PKG-fpm" 2>/dev/null; then
            log_error "Failed to enable PHP-FPM service"
            exit 1
        fi
        
        if ! systemctl start "$PHP_PKG-fpm" 2>/dev/null; then
            log_error "Failed to start PHP-FPM service"
            exit 1
        fi
        
        log_info "PHP $PHP_VERSION installed successfully"
    fi
}

# ---------------------------------
# Nginx Configuration Generation
# ---------------------------------
generate_nginx_config() {
    log_info "Generating Nginx configuration..."
    
    cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;
    root $WEB_ROOT;
    index index.html index.htm$([ "$NEED_PHP" = "yes" ] && echo " index.php");
    
    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Static files
    location / {
        try_files \$uri \$uri/ =404;
    }
    
    # Assets caching
    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
EOF

    # Add PHP block if needed
    if [ "$NEED_PHP" = "yes" ]; then
        cat >> "$NGINX_CONF" << EOF
    
    # PHP processing
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/$PHP_PKG-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    
    # Deny access to .htaccess files
    location ~ /\.ht {
        deny all;
    }
EOF
    fi
    
    echo "}" >> "$NGINX_CONF"
}

# ---------------------------------
# Web Root Setup
# ---------------------------------
setup_webroot() {
    log_info "Creating web root: $WEB_ROOT"
    mkdir -p "$WEB_ROOT" 2>/dev/null
    chown -R www-data:www-data "$WEB_ROOT" 2>/dev/null
    chmod -R 755 "$WEB_ROOT" 2>/dev/null
    
    # Create a simple test page
    if [ "$NEED_PHP" = "yes" ]; then
        echo "<?php phpinfo(); ?>" > "$WEB_ROOT/info.php"
        echo "<h1>Welcome to $APP_NAME</h1><p>PHP is enabled. <a href='/info.php'>PHP Info</a></p>" > "$WEB_ROOT/index.html"
    else
        echo "<h1>Welcome to $APP_NAME</h1><p>Static website is live!</p>" > "$WEB_ROOT/index.html"
    fi
}

# ---------------------------------
# Site Activation
# ---------------------------------
activate_site() {
    log_info "Activating site..."
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
        
        log_info "Installing Certbot..."
        apt install -y certbot python3-certbot-nginx >/dev/null 2>&1
        
        log_info "Requesting SSL certificate..."
        if certbot --nginx -d $(echo $DOMAIN_NAME | tr ' ' ',') --non-interactive --agree-tos --email admin@$(echo $DOMAIN_NAME | awk '{print $1}') >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1
            log_info "SSL certificate installed successfully"
        else
            log_error "SSL certificate installation failed"
        fi
    fi
}

# ---------------------------------
# Website Testing
# ---------------------------------
test_website() {
    log_info "Testing website..."
    
    if [ "$DNS_RESOLVED" = true ] && [ "$INSTALL_SSL" = "yes" ]; then
        # Test HTTPS if SSL is installed
        local primary_domain=$(echo "$DOMAIN_NAME" | awk '{print $1}')
        if curl -s -o /dev/null -w "%{http_code}" "https://$primary_domain" | grep -q "200\|301\|302"; then
            log_info "Website is accessible via HTTPS: https://$primary_domain"
        else
            log_error "Website not accessible via HTTPS"
        fi
    else
        # Test local HTTP
        if curl -s -o /dev/null -w "%{http_code}" -H "Host: $(echo $DOMAIN_NAME | awk '{print $1}')" "http://localhost" | grep -q "200"; then
            log_info "Website is accessible locally (HTTP)"
            if [ "$DNS_RESOLVED" = false ]; then
                log_info "Configure DNS pointing to access via domain name"
            fi
        else
            log_error "Website not accessible locally"
        fi
    fi
}

# ---------------------------------
# Main Execution
# ---------------------------------
main() {
    check_root
    collect_inputs
    update_system
    install_nginx
    install_php
    setup_webroot
    generate_nginx_config
    activate_site
    setup_ssl
    test_website
    
    echo
    echo "========================================"
    echo " Website setup completed successfully!"
    echo " Web root : $WEB_ROOT"
    echo " Nginx conf : $NGINX_CONF"
    if [ "$DNS_RESOLVED" = true ]; then
        echo " URL : https://$(echo $DOMAIN_NAME | awk '{print $1}')"
    else
        echo " Local test: Add '127.0.0.1 $(echo $DOMAIN_NAME | awk '{print $1}')' to /etc/hosts"
    fi
    echo "========================================"
}

# Run main function
main "$@"