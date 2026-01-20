#!/bin/bash

# Web Application Troubleshooting Tool
# Supports WordPress, Magento, Laravel, and general web apps

set -e

# Global variables
OUTPUT_DIR="/tmp/troubleshoot_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$OUTPUT_DIR/troubleshoot_report.log"
APP_TYPE=""
LOG_PATHS=()
CONFIG_PATHS=()
TIME_RANGE=""
START_TIME=""
END_TIME=""

# ---------------------------------
# Utility Functions
# ---------------------------------
log_info() {
    echo "[INFO] $1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1" >> "$LOG_FILE"
}

log_error() {
    echo "[ERROR] $1" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$LOG_FILE"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script should be run as root for complete access to logs and configs"
        echo "Continue anyway? (yes/no): "
        read -r continue_choice
        [ "$continue_choice" != "yes" ] && exit 1
    fi
}

setup_output() {
    mkdir -p "$OUTPUT_DIR"
    touch "$LOG_FILE"
    log_info "Troubleshooting session started - Output directory: $OUTPUT_DIR"
}

# ---------------------------------
# Input Collection
# ---------------------------------
collect_app_info() {
    echo "================================="
    echo " Web Application Troubleshooter"
    echo "================================="
    echo
    echo "Select application type:"
    echo "1) WordPress"
    echo "2) Magento"
    echo "3) Laravel"
    echo "4) Generic PHP Application"
    echo "5) Custom (specify manually)"
    read -rp "Choice [1-5]: " app_choice
    
    case $app_choice in
        1) APP_TYPE="wordpress" ;;
        2) APP_TYPE="magento" ;;
        3) APP_TYPE="laravel" ;;
        4) APP_TYPE="php" ;;
        5) APP_TYPE="custom" ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    log_info "Application type: $APP_TYPE"
}

collect_log_paths() {
    echo
    echo "=== Log Path Configuration ==="
    echo "Enter log file paths (one per line, empty line to finish):"
    echo "Common paths: /var/log/nginx/, /var/log/apache2/, /var/log/php/, /var/www/html/wp-content/debug.log"
    
    while true; do
        read -rp "Log path: " log_path
        [ -z "$log_path" ] && break
        
        if [ -r "$log_path" ]; then
            LOG_PATHS+=("$log_path")
            echo "  ✓ Added: $log_path"
        else
            echo "  ✗ Cannot read: $log_path (skipping)"
        fi
    done
    
    log_info "Configured ${#LOG_PATHS[@]} log paths"
}

collect_config_paths() {
    echo
    echo "=== Config Path Configuration ==="
    echo "Enter config file paths (one per line, empty line to finish):"
    echo "Common paths: /etc/php/*/fpm/pool.d/www.conf, /etc/php/*/fpm/php.ini, /etc/nginx/sites-available/"
    
    while true; do
        read -rp "Config path: " config_path
        [ -z "$config_path" ] && break
        
        if [ -r "$config_path" ]; then
            CONFIG_PATHS+=("$config_path")
            echo "  ✓ Added: $config_path"
        else
            echo "  ✗ Cannot read: $config_path (skipping)"
        fi
    done
    
    log_info "Configured ${#CONFIG_PATHS[@]} config paths"
}

collect_time_range() {
    echo
    echo "=== Time Range Configuration ==="
    echo "Select time range for log analysis:"
    echo "1) Last 1 hour"
    echo "2) Last 6 hours"
    echo "3) Last 24 hours"
    echo "4) Custom range"
    read -rp "Choice [1-4]: " time_choice
    
    case $time_choice in
        1) START_TIME=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S') ;;
        2) START_TIME=$(date -d '6 hours ago' '+%Y-%m-%d %H:%M:%S') ;;
        3) START_TIME=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S') ;;
        4) 
            read -rp "Start time (YYYY-MM-DD HH:MM:SS): " START_TIME
            read -rp "End time (YYYY-MM-DD HH:MM:SS or 'now'): " END_TIME
            [ "$END_TIME" = "now" ] && END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    [ -z "$END_TIME" ] && END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    TIME_RANGE="$START_TIME to $END_TIME"
    log_info "Time range: $TIME_RANGE"
}

# ---------------------------------
# System Information
# ---------------------------------
collect_system_info() {
    log_info "Collecting system information..."
    
    {
        echo "=== SYSTEM INFORMATION ==="
        echo "Timestamp: $(date)"
        echo "Hostname: $(hostname)"
        echo "Uptime: $(uptime)"
        echo "Load Average: $(cat /proc/loadavg)"
        echo "Memory Usage:"
        free -h
        echo
        echo "Disk Usage:"
        df -h
        echo
        echo "Active Processes (Top 10 CPU):"
        ps aux --sort=-%cpu | head -11
        echo
        echo "Active Processes (Top 10 Memory):"
        ps aux --sort=-%mem | head -11
        echo
    } >> "$OUTPUT_DIR/system_info.txt"
    
    echo "✓ System info saved to system_info.txt"
}

# ---------------------------------
# Service Status
# ---------------------------------
check_services() {
    log_info "Checking service status..."
    
    local services=("nginx" "apache2" "mysql" "mariadb" "redis" "memcached")
    
    # Add PHP-FPM services
    for php_ver in 8.4 8.3 8.2 8.1 8.0 7.4; do
        services+=("php$php_ver-fpm")
    done
    
    {
        echo "=== SERVICE STATUS ==="
        for service in "${services[@]}"; do
            if systemctl list-unit-files | grep -q "^$service.service"; then
                echo "$service: $(systemctl is-active $service 2>/dev/null || echo 'inactive')"
                if systemctl is-active $service >/dev/null 2>&1; then
                    echo "  Memory: $(systemctl show $service --property=MemoryCurrent --value 2>/dev/null | numfmt --to=iec 2>/dev/null || echo 'N/A')"
                fi
            fi
        done
        echo
    } >> "$OUTPUT_DIR/service_status.txt"
    
    echo "✓ Service status saved to service_status.txt"
}

# ---------------------------------
# Configuration Analysis
# ---------------------------------
analyze_configs() {
    log_info "Analyzing configuration files..."
    
    echo
    echo "=== CONFIGURATION ANALYSIS ==="
    
    for config_path in "${CONFIG_PATHS[@]}"; do
        echo
        echo "--- $config_path ---"
        
        read -rp "Enter config prefix to search (e.g., 'pm', 'memory_limit', or 'all'): " prefix
        
        if [ "$prefix" = "all" ]; then
            echo "Full configuration:"
            grep -v '^[[:space:]]*;\|^[[:space:]]*#\|^[[:space:]]*$' "$config_path" 2>/dev/null | head -50
        else
            echo "Configuration for '$prefix':"
            grep -i "^[[:space:]]*$prefix" "$config_path" 2>/dev/null || echo "No matches found"
        fi
        
        # Save to file
        {
            echo "=== $config_path ==="
            if [ "$prefix" = "all" ]; then
                grep -v '^[[:space:]]*;\|^[[:space:]]*#\|^[[:space:]]*$' "$config_path" 2>/dev/null
            else
                grep -i "^[[:space:]]*$prefix" "$config_path" 2>/dev/null
            fi
            echo
        } >> "$OUTPUT_DIR/config_analysis.txt"
    done
}

# ---------------------------------
# Log Analysis
# ---------------------------------
analyze_logs() {
    log_info "Analyzing log files for time range: $TIME_RANGE"
    
    local start_epoch=$(date -d "$START_TIME" +%s 2>/dev/null || echo "0")
    local end_epoch=$(date -d "$END_TIME" +%s 2>/dev/null || echo "$(date +%s)")
    
    {
        echo "=== LOG ANALYSIS ==="
        echo "Time Range: $TIME_RANGE"
        echo "Start Epoch: $start_epoch"
        echo "End Epoch: $end_epoch"
        echo
        
        for log_path in "${LOG_PATHS[@]}"; do
            echo "=== $log_path ==="
            
            if [ -f "$log_path" ]; then
                # Error patterns
                echo "--- ERROR PATTERNS ---"
                grep -i "error\|fatal\|critical\|emergency" "$log_path" 2>/dev/null | tail -20
                echo
                
                # Warning patterns
                echo "--- WARNING PATTERNS ---"
                grep -i "warning\|warn" "$log_path" 2>/dev/null | tail -10
                echo
                
                # Application-specific patterns
                case $APP_TYPE in
                    "wordpress")
                        echo "--- WORDPRESS SPECIFIC ---"
                        grep -i "wp-\|wordpress\|plugin\|theme" "$log_path" 2>/dev/null | tail -10
                        ;;
                    "magento")
                        echo "--- MAGENTO SPECIFIC ---"
                        grep -i "magento\|mage\|exception" "$log_path" 2>/dev/null | tail -10
                        ;;
                    "laravel")
                        echo "--- LARAVEL SPECIFIC ---"
                        grep -i "laravel\|artisan\|illuminate" "$log_path" 2>/dev/null | tail -10
                        ;;
                esac
                echo
                
                # Performance issues
                echo "--- PERFORMANCE INDICATORS ---"
                grep -i "timeout\|slow\|memory\|limit\|502\|503\|504" "$log_path" 2>/dev/null | tail -10
                echo
                
            else
                echo "Log file not accessible: $log_path"
            fi
            echo "==========================================="
            echo
        done
    } >> "$OUTPUT_DIR/log_analysis.txt"
    
    echo "✓ Log analysis saved to log_analysis.txt"
}

# ---------------------------------
# Network and Connectivity
# ---------------------------------
check_connectivity() {
    log_info "Checking network connectivity..."
    
    {
        echo "=== NETWORK CONNECTIVITY ==="
        echo "Active connections:"
        netstat -tuln 2>/dev/null | grep LISTEN | head -20
        echo
        
        echo "Network interfaces:"
        ip addr show 2>/dev/null | grep -E "inet |UP|DOWN"
        echo
        
        echo "DNS resolution test:"
        nslookup google.com 2>/dev/null | head -10
        echo
    } >> "$OUTPUT_DIR/network_info.txt"
    
    echo "✓ Network info saved to network_info.txt"
}

# ---------------------------------
# Summary Report
# ---------------------------------
generate_summary() {
    log_info "Generating summary report..."
    
    echo
    echo "=== TROUBLESHOOTING SUMMARY ==="
    echo "Application Type: $APP_TYPE"
    echo "Time Range: $TIME_RANGE"
    echo "Output Directory: $OUTPUT_DIR"
    echo
    echo "Generated Files:"
    ls -la "$OUTPUT_DIR/" | grep -v "^total"
    echo
    echo "Quick Recommendations:"
    
    # Basic recommendations based on common issues
    if grep -q "memory" "$OUTPUT_DIR/log_analysis.txt" 2>/dev/null; then
        echo "• Memory issues detected - Check PHP memory_limit and server RAM"
    fi
    
    if grep -q "timeout" "$OUTPUT_DIR/log_analysis.txt" 2>/dev/null; then
        echo "• Timeout issues detected - Check max_execution_time and server performance"
    fi
    
    if grep -q "502\|503\|504" "$OUTPUT_DIR/log_analysis.txt" 2>/dev/null; then
        echo "• Gateway errors detected - Check PHP-FPM and web server configuration"
    fi
    
    echo "• Review detailed logs in: $OUTPUT_DIR/"
    echo "• Check service status in: $OUTPUT_DIR/service_status.txt"
    echo "• Analyze configurations in: $OUTPUT_DIR/config_analysis.txt"
    
    log_info "Troubleshooting completed successfully"
}

# ---------------------------------
# Main Execution
# ---------------------------------
main() {
    check_root
    setup_output
    collect_app_info
    collect_log_paths
    collect_config_paths
    collect_time_range
    
    echo
    log_info "Starting analysis..."
    
    collect_system_info
    check_services
    analyze_configs
    analyze_logs
    check_connectivity
    generate_summary
    
    echo
    echo "==========================================="
    echo "Troubleshooting completed!"
    echo "All detailed logs saved to: $OUTPUT_DIR/"
    echo "==========================================="
}

# Run main function
main "$@"