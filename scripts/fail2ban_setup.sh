#!/bin/bash

# Fail2ban Setup Tool
# Installs and configures fail2ban for server security

set -e
trap 'log_error "Script failed at line $LINENO. Exit code: $?"' ERR

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

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_installed() {
    local package=$1
    dpkg -l | grep -q "^ii  $package " 2>/dev/null
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

# ---------------------------------
# Fail2ban Installation
# ---------------------------------
install_fail2ban() {
    if check_installed "fail2ban"; then
        log_skip "Fail2ban"
        return 0
    fi
    
    log_info "Installing Fail2ban..."
    if apt install -y fail2ban >/dev/null 2>&1; then
        systemctl enable fail2ban >/dev/null 2>&1 || { log_error "Failed to enable Fail2ban"; return 1; }
        systemctl start fail2ban >/dev/null 2>&1 || { log_error "Failed to start Fail2ban"; return 1; }
        log_success "Fail2ban installed and started"
    else
        log_error "Failed to install Fail2ban"
        return 1
    fi
}

# ---------------------------------
# Basic Configuration
# ---------------------------------
create_basic_config() {
    log_info "Creating basic Fail2ban configuration..."
    
    # Create jail.local file with basic SSH protection
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# Ban hosts for 1 hour (3600 seconds)
bantime = 3600

# A host is banned if it has generated "maxretry" during the last "findtime" seconds
findtime = 600

# Number of failures before a host get banned
maxretry = 5

# Destination email for notifications
destemail = root@localhost

# Sender email
sender = fail2ban@localhost

# Email action
action = %(action_mw)s

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
    
    # Restart fail2ban to apply configuration
    systemctl restart fail2ban >/dev/null 2>&1
    log_success "Basic configuration created and applied"
}

# ---------------------------------
# Status Check
# ---------------------------------
check_status() {
    log_info "Checking Fail2ban status..."
    
    if systemctl is-active --quiet fail2ban; then
        log_success "Fail2ban service is running"
        
        # Show active jails
        local active_jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | cut -d: -f2 | tr -d ' \t')
        if [ -n "$active_jails" ]; then
            log_success "Active jails: $active_jails"
        else
            log_info "No active jails found"
        fi
    else
        log_error "Fail2ban service is not running"
        return 1
    fi
}

# ---------------------------------
# Setup Guide
# ---------------------------------
show_setup_guide() {
    echo
    echo "========================================="
    echo " Fail2ban Setup Complete!"
    echo "========================================="
    echo
    echo "✓ Fail2ban installed and configured"
    echo "✓ SSH protection enabled (3 failed attempts = 1 hour ban)"
    echo "✓ Service is running and enabled"
    echo
    echo "=== CONFIGURATION FILES ==="
    echo "Main config: /etc/fail2ban/jail.conf (DO NOT EDIT)"
    echo "Local config: /etc/fail2ban/jail.local (YOUR CUSTOMIZATIONS)"
    echo "Filters: /etc/fail2ban/filter.d/"
    echo "Actions: /etc/fail2ban/action.d/"
    echo
    echo "=== USEFUL COMMANDS ==="
    echo "Check status:        fail2ban-client status"
    echo "Check SSH jail:      fail2ban-client status sshd"
    echo "Unban IP:           fail2ban-client set sshd unbanip <IP>"
    echo "Ban IP manually:    fail2ban-client set sshd banip <IP>"
    echo "Reload config:      fail2ban-client reload"
    echo "View logs:          tail -f /var/log/fail2ban.log"
    echo
    echo "=== COMMON CONFIGURATIONS ==="
    echo
    echo "1. Enable Nginx protection (add to /etc/fail2ban/jail.local):"
    echo "[nginx-http-auth]"
    echo "enabled = true"
    echo "filter = nginx-http-auth"
    echo "logpath = /var/log/nginx/error.log"
    echo "maxretry = 3"
    echo
    echo "[nginx-limit-req]"
    echo "enabled = true"
    echo "filter = nginx-limit-req"
    echo "logpath = /var/log/nginx/error.log"
    echo "maxretry = 10"
    echo
    echo "2. Enable Apache protection (add to /etc/fail2ban/jail.local):"
    echo "[apache-auth]"
    echo "enabled = true"
    echo "filter = apache-auth"
    echo "logpath = /var/log/apache2/error.log"
    echo "maxretry = 3"
    echo
    echo "3. Change SSH settings (edit /etc/fail2ban/jail.local):"
    echo "[sshd]"
    echo "enabled = true"
    echo "port = 2222          # If you changed SSH port"
    echo "maxretry = 5         # Number of failed attempts"
    echo "bantime = 7200       # Ban duration in seconds"
    echo "findtime = 600       # Time window for failures"
    echo
    echo "4. Email notifications (edit /etc/fail2ban/jail.local):"
    echo "[DEFAULT]"
    echo "destemail = admin@yourdomain.com"
    echo "sender = fail2ban@yourserver.com"
    echo "action = %(action_mwl)s  # Send email with logs"
    echo
    echo "=== IMPORTANT NOTES ==="
    echo "• Always test configurations before applying"
    echo "• Keep a backup SSH session open when testing"
    echo "• Whitelist your own IP if needed"
    echo "• Monitor /var/log/fail2ban.log for issues"
    echo "• Restart fail2ban after config changes: systemctl restart fail2ban"
    echo
    echo "=== WHITELIST YOUR IP ==="
    echo "To avoid locking yourself out, add to /etc/fail2ban/jail.local:"
    echo "[DEFAULT]"
    echo "ignoreip = 127.0.0.1/8 ::1 YOUR_IP_HERE"
    echo
    echo "Current server IP addresses:"
    hostname -I | tr ' ' '\n' | grep -v '^$' | while read ip; do
        echo "  $ip"
    done
    echo
    echo "========================================="
}

# ---------------------------------
# Main Execution
# ---------------------------------
main() {
    echo "================================="
    echo " Fail2ban Security Setup Tool"
    echo "================================="
    echo
    
    check_root
    update_system
    install_fail2ban
    create_basic_config
    check_status
    show_setup_guide
}

# Run main function
main "$@"