#!/bin/bash

# SSL Management Tool
# Validates SSL certificates and converts SSL bundles to PFX format

set -e

# Global variables
OPERATION=""
DOMAIN_NAME=""
CERT_FILE=""
KEY_FILE=""
CA_FILE=""
SSL_BUNDLE_ZIP=""
PFX_FILE=""
PFX_PASSWORD=""
PFX_OUTPUT_DIR="./pfx-files"
SSL_OUTPUT_DIR="./ssl-bundles"

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

handle_error() {
    local exit_code=$?
    local line_number=$1
    if [ $exit_code -ne 0 ]; then
        log_error "Command failed at line $line_number with exit code $exit_code"
        exit $exit_code
    fi
}

trap 'handle_error $LINENO' ERR

check_openssl() {
    if ! command -v openssl >/dev/null 2>&1; then
        log_error "OpenSSL is not installed. Please install it first."
        exit 1
    fi
}

# ---------------------------------
# Input Collection
# ---------------------------------
collect_inputs() {
    echo "================================="
    echo "     SSL Management Tool"
    echo "================================="
    echo
    echo "Available operations:"
    echo "1. Validate SSL Certificate"
    echo "2. Convert SSL Bundle to PFX"
    echo "3. Convert PFX to SSL Bundle"
    echo
    
    read -rp "Select operation (1, 2, or 3): " OPERATION_NUM
    
    case $OPERATION_NUM in
        1)
            OPERATION="validate"
            collect_validation_inputs
            ;;
        2)
            OPERATION="convert"
            collect_conversion_inputs
            ;;
        3)
            OPERATION="pfx_to_ssl"
            collect_pfx_inputs
            ;;
        *)
            log_error "Invalid operation selected"
            exit 1
            ;;
    esac
}

collect_validation_inputs() {
    echo
    echo "=== SSL Validation Options ==="
    echo "1. Validate by domain (online check)"
    echo "2. Validate by certificate file"
    echo "3. Validate SSL bundle (cert + key + CA)"
    echo
    
    read -rp "Select validation method (1, 2, or 3): " VALIDATION_METHOD
    
    case $VALIDATION_METHOD in
        1)
            read -rp "Enter domain name (e.g., example.com): " DOMAIN_NAME
            ;;
        2)
            read -rp "Enter path to certificate file (.crt): " CERT_FILE
            if [ ! -f "$CERT_FILE" ]; then
                log_error "Certificate file not found: $CERT_FILE"
                exit 1
            fi
            ;;
        3)
            read -rp "Enter path to certificate file (.crt): " CERT_FILE
            read -rp "Enter path to private key file (.key): " KEY_FILE
            read -rp "Enter path to CA bundle file (.crt): " CA_FILE
            
            if [ ! -f "$CERT_FILE" ]; then
                log_error "Certificate file not found: $CERT_FILE"
                exit 1
            fi
            if [ ! -f "$KEY_FILE" ]; then
                log_error "Private key file not found: $KEY_FILE"
                exit 1
            fi
            if [ ! -f "$CA_FILE" ]; then
                log_error "CA bundle file not found: $CA_FILE"
                exit 1
            fi
            ;;
        *)
            log_error "Invalid validation method selected"
            exit 1
            ;;
    esac
}

collect_conversion_inputs() {
    echo
    echo "=== SSL Bundle to PFX Conversion ==="
    read -rp "Enter path to SSL bundle (ZIP file or folder): " SSL_BUNDLE_ZIP
    
    if [ ! -e "$SSL_BUNDLE_ZIP" ]; then
        log_error "SSL bundle path not found: $SSL_BUNDLE_ZIP"
        exit 1
    fi
    
    if [ -f "$SSL_BUNDLE_ZIP" ]; then
        log_success "SSL bundle ZIP file found: $SSL_BUNDLE_ZIP"
    elif [ -d "$SSL_BUNDLE_ZIP" ]; then
        log_success "SSL bundle directory found: $SSL_BUNDLE_ZIP"
    fi
}

collect_pfx_inputs() {
    echo
    echo "=== PFX to SSL Bundle Conversion ==="
    read -rp "Enter path to PFX file: " PFX_FILE
    
    if [ ! -f "$PFX_FILE" ]; then
        log_error "PFX file not found: $PFX_FILE"
        exit 1
    fi
    
    log_success "PFX file found: $PFX_FILE"
    read -rsp "Enter PFX password: " PFX_PASSWORD
    echo
    echo
}

# ---------------------------------
# SSL Validation Functions
# ---------------------------------
validate_ssl_by_domain() {
    log_info "Validating SSL certificate for domain: $DOMAIN_NAME"
    
    # Get certificate info from domain
    local cert_info=$(echo | openssl s_client -servername "$DOMAIN_NAME" -connect "$DOMAIN_NAME:443" 2>/dev/null | openssl x509 -noout -dates -subject 2>/dev/null)
    
    if [ -z "$cert_info" ]; then
        log_error "Failed to retrieve SSL certificate for $DOMAIN_NAME"
        return 1
    fi
    
    # Extract expiry date
    local expiry_date=$(echo "$cert_info" | grep "notAfter" | cut -d= -f2)
    local expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null)
    local current_timestamp=$(date +%s)
    
    if [ $expiry_timestamp -gt $current_timestamp ]; then
        local days_left=$(( (expiry_timestamp - current_timestamp) / 86400 ))
        log_success "SSL certificate is valid"
        log_success "Expires on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        log_success "Days remaining: $days_left"
        
        # Extract subject
        local subject=$(echo "$cert_info" | grep "subject" | cut -d= -f2-)
        log_info "Certificate subject: $subject"
    else
        log_error "SSL certificate has expired on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        return 1
    fi
}

validate_ssl_by_file() {
    log_info "Validating SSL certificate file: $CERT_FILE"
    
    # Check if certificate is valid
    if ! openssl x509 -in "$CERT_FILE" -noout -text >/dev/null 2>&1; then
        log_error "Invalid certificate file format"
        return 1
    fi
    
    # Get certificate details
    local expiry_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)
    local expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null)
    local current_timestamp=$(date +%s)
    
    if [ $expiry_timestamp -gt $current_timestamp ]; then
        local days_left=$(( (expiry_timestamp - current_timestamp) / 86400 ))
        log_success "SSL certificate is valid"
        log_success "Expires on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        log_success "Days remaining: $days_left"
        
        # Extract subject and issuer
        local subject=$(openssl x509 -in "$CERT_FILE" -noout -subject | cut -d= -f2-)
        local issuer=$(openssl x509 -in "$CERT_FILE" -noout -issuer | cut -d= -f2-)
        log_info "Certificate subject: $subject"
        log_info "Certificate issuer: $issuer"
    else
        log_error "SSL certificate has expired on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        return 1
    fi
}

validate_ssl_bundle() {
    log_info "Validating SSL bundle (certificate + private key + CA bundle)"
    
    # Validate certificate file
    if ! openssl x509 -in "$CERT_FILE" -noout -text >/dev/null 2>&1; then
        log_error "Invalid certificate file format"
        return 1
    fi
    log_success "Certificate file is valid"
    
    # Validate private key file
    if ! openssl rsa -in "$KEY_FILE" -check -noout >/dev/null 2>&1; then
        log_error "Invalid private key file format"
        return 1
    fi
    log_success "Private key file is valid"
    
    # Check if private key matches certificate
    local cert_modulus=$(openssl x509 -noout -modulus -in "$CERT_FILE" | openssl md5)
    local key_modulus=$(openssl rsa -noout -modulus -in "$KEY_FILE" | openssl md5)
    
    if [ "$cert_modulus" = "$key_modulus" ]; then
        log_success "Private key matches the certificate"
    else
        log_error "Private key does not match the certificate"
        return 1
    fi
    
    # Validate CA bundle
    if ! openssl x509 -in "$CA_FILE" -noout -text >/dev/null 2>&1; then
        log_error "Invalid CA bundle file format"
        return 1
    fi
    log_success "CA bundle file is valid"
    
    # Verify certificate chain
    if openssl verify -CAfile "$CA_FILE" "$CERT_FILE" >/dev/null 2>&1; then
        log_success "Certificate chain is valid"
    else
        log_error "Certificate chain verification failed"
        return 1
    fi
    
    # Get certificate expiry
    local expiry_date=$(openssl x509 -in "$CERT_FILE" -noout -enddate | cut -d= -f2)
    local expiry_timestamp=$(date -d "$expiry_date" +%s 2>/dev/null)
    local current_timestamp=$(date +%s)
    
    if [ $expiry_timestamp -gt $current_timestamp ]; then
        local days_left=$(( (expiry_timestamp - current_timestamp) / 86400 ))
        log_success "SSL bundle is completely valid"
        log_success "Certificate expires on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        log_success "Days remaining: $days_left"
    else
        log_error "SSL certificate has expired on: $(date -d "$expiry_date" '+%d-%m-%Y')"
        return 1
    fi
}

# ---------------------------------
# SSL Bundle to PFX Conversion
# ---------------------------------
convert_ssl_to_pfx() {
    log_info "Converting SSL bundle to PFX format"
    
    # Check if SSL bundle path exists
    if [ ! -e "$SSL_BUNDLE_ZIP" ]; then
        log_error "SSL bundle path does not exist: $SSL_BUNDLE_ZIP"
        return 1
    fi
    
    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)
    local extract_dir="$temp_dir/ssl_bundle"
    
    # Handle both ZIP files and directories
    if [ -f "$SSL_BUNDLE_ZIP" ]; then
        # It's a file - check if it's a ZIP and extract
        log_info "Extracting SSL bundle ZIP file..."
        mkdir -p "$extract_dir"
        
        # Check if unzip command is available
        if ! command -v unzip >/dev/null 2>&1; then
            log_error "unzip command not found. Please install unzip utility."
            rm -rf "$temp_dir"
            return 1
        fi
        
        if ! unzip -q "$SSL_BUNDLE_ZIP" -d "$extract_dir" 2>/dev/null; then
            log_error "Failed to extract SSL bundle ZIP file. Please check if it's a valid ZIP file."
            rm -rf "$temp_dir"
            return 1
        fi
    elif [ -d "$SSL_BUNDLE_ZIP" ]; then
        # It's a directory - copy contents to extract_dir
        log_info "Using SSL bundle directory..."
        extract_dir="$SSL_BUNDLE_ZIP"
    else
        log_error "SSL bundle path is neither a file nor a directory: $SSL_BUNDLE_ZIP"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Find certificate files
    local cert_file=$(find "$extract_dir" -name "*.crt" -not -name "*ca-bundle*" -not -name "*ca_bundle*" | head -1)
    local key_file=$(find "$extract_dir" -name "*.key" -o -name "*private*key*" | head -1)
    local ca_file=$(find "$extract_dir" -name "*ca-bundle*" -o -name "*ca_bundle*" -o -name "*ca*.crt" | head -1)
    
    # Debug: List all files in extract directory
    log_info "Files found in SSL bundle:"
    find "$extract_dir" -type f -exec basename {} \;
    
    if [ -z "$cert_file" ]; then
        log_error "Certificate file (.crt) not found in SSL bundle"
        rm -rf "$temp_dir"
        return 1
    fi
    
    if [ -z "$key_file" ]; then
        log_error "Private key file (.key) not found in SSL bundle"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log_success "Found certificate file: $(basename "$cert_file")"
    log_success "Found private key file: $(basename "$key_file")"
    
    if [ -n "$ca_file" ]; then
        log_success "Found CA bundle file: $(basename "$ca_file")"
    fi
    
    # Extract domain name from certificate
    local domain=$(openssl x509 -in "$cert_file" -noout -subject | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
    if [ -z "$domain" ]; then
        domain="certificate"
    fi
    
    # Generate password (Domain@CurrentYear)
    local current_year=$(date +%Y)
    local domain_capitalized=$(echo "$domain" | sed 's/\b\w/\U&/g' | sed 's/\..*$//')
    local pfx_password="${domain_capitalized}@${current_year}"
    
    # Create PFX output directory
    mkdir -p "$PFX_OUTPUT_DIR"
    
    # Generate PFX file
    local pfx_filename="${domain}.pfx"
    local pfx_path="$PFX_OUTPUT_DIR/$pfx_filename"
    
    log_info "Creating PFX file with password: $pfx_password"
    
    if [ -n "$ca_file" ]; then
        # Include CA bundle in PFX
        if openssl pkcs12 -export -out "$pfx_path" -inkey "$key_file" -in "$cert_file" -certfile "$ca_file" -password "pass:$pfx_password" >/dev/null 2>&1; then
            log_success "PFX file created successfully: $pfx_path"
            log_success "PFX password: $pfx_password"
        else
            log_error "Failed to create PFX file with CA bundle"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        # Create PFX without CA bundle
        if openssl pkcs12 -export -out "$pfx_path" -inkey "$key_file" -in "$cert_file" -password "pass:$pfx_password" >/dev/null 2>&1; then
            log_success "PFX file created successfully: $pfx_path"
            log_success "PFX password: $pfx_password"
            log_info "Note: CA bundle not found, PFX created without intermediate certificates"
        else
            log_error "Failed to create PFX file"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    # Create password file
    echo "$pfx_password" > "$PFX_OUTPUT_DIR/${domain}_password.txt"
    log_success "Password saved to: $PFX_OUTPUT_DIR/${domain}_password.txt"
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Display summary
    echo
    echo "=== PFX Conversion Summary ==="
    echo "Domain: $domain"
    echo "PFX File: $pfx_path"
    echo "Password: $pfx_password"
    echo "Password File: $PFX_OUTPUT_DIR/${domain}_password.txt"
    echo "============================"
}

# ---------------------------------
# PFX to SSL Bundle Conversion
# ---------------------------------
convert_pfx_to_ssl() {
    log_info "Converting PFX to SSL bundle format"
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    
    # Extract domain name from PFX file for naming
    local pfx_basename=$(basename "$PFX_FILE" .pfx)
    local domain_name="$pfx_basename"
    
    # Create SSL output directory with absolute path
    local ssl_output_abs=$(realpath "$SSL_OUTPUT_DIR" 2>/dev/null || readlink -f "$SSL_OUTPUT_DIR" 2>/dev/null || echo "$(pwd)/$SSL_OUTPUT_DIR")
    mkdir -p "$ssl_output_abs"
    
    # Extract private key from PFX
    local key_file="$temp_dir/${domain_name}.key"
    log_info "Extracting private key..."
    if ! openssl pkcs12 -in "$PFX_FILE" -nocerts -out "$key_file" -nodes -password "pass:$PFX_PASSWORD" >/dev/null 2>&1; then
        log_error "Failed to extract private key from PFX file. Check password."
        rm -rf "$temp_dir"
        return 1
    fi
    log_success "Private key extracted successfully"
    
    # Extract certificate from PFX
    local cert_file="$temp_dir/${domain_name}.crt"
    log_info "Extracting certificate..."
    if ! openssl pkcs12 -in "$PFX_FILE" -clcerts -nokeys -out "$cert_file" -password "pass:$PFX_PASSWORD" >/dev/null 2>&1; then
        log_error "Failed to extract certificate from PFX file"
        rm -rf "$temp_dir"
        return 1
    fi
    log_success "Certificate extracted successfully"
    
    # Extract CA bundle from PFX (if present)
    local ca_file="$temp_dir/${domain_name}_ca_bundle.crt"
    log_info "Extracting CA bundle..."
    if openssl pkcs12 -in "$PFX_FILE" -cacerts -nokeys -out "$ca_file" -password "pass:$PFX_PASSWORD" >/dev/null 2>&1; then
        # Check if CA file has content
        if [ -s "$ca_file" ] && grep -q "BEGIN CERTIFICATE" "$ca_file"; then
            log_success "CA bundle extracted successfully"
        else
            log_info "No CA bundle found in PFX file"
            rm -f "$ca_file"
            ca_file=""
        fi
    else
        log_info "No CA bundle found in PFX file"
        rm -f "$ca_file"
        ca_file=""
    fi
    
    # Create CSR file (optional - generate from private key)
    local csr_file="$temp_dir/${domain_name}.csr"
    log_info "Generating CSR from private key..."
    if openssl req -new -key "$key_file" -out "$csr_file" -subj "/CN=$domain_name" >/dev/null 2>&1; then
        log_success "CSR generated successfully"
    else
        log_info "CSR generation skipped"
        csr_file=""
    fi
    
    # Create SSL bundle ZIP file
    local zip_file="$ssl_output_abs/${domain_name}_ssl_bundle.zip"
    log_info "Creating SSL bundle ZIP file..."
    
    # Create ZIP file from temp directory
    local files_to_zip="$(basename "$key_file") $(basename "$cert_file")"
    
    if [ -n "$ca_file" ] && [ -f "$ca_file" ]; then
        files_to_zip="$files_to_zip $(basename "$ca_file")"
    fi
    
    if [ -n "$csr_file" ] && [ -f "$csr_file" ]; then
        files_to_zip="$files_to_zip $(basename "$csr_file")"
    fi
    
    # Change to temp directory and create ZIP with absolute path
    (cd "$temp_dir" && zip -q "$zip_file" $files_to_zip)
    
    if [ $? -eq 0 ] && [ -f "$zip_file" ]; then
        log_success "SSL bundle ZIP created: $zip_file"
    else
        log_error "Failed to create SSL bundle ZIP file"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    # Display summary
    echo
    echo "=== PFX to SSL Conversion Summary ==="
    echo "Source PFX: $PFX_FILE"
    echo "SSL Bundle: $zip_file"
    echo "Files included:"
    echo "  - ${domain_name}.key (Private Key)"
    echo "  - ${domain_name}.crt (Certificate)"
    if [ -n "$ca_file" ]; then
        echo "  - ${domain_name}_ca_bundle.crt (CA Bundle)"
    fi
    if [ -n "$csr_file" ]; then
        echo "  - ${domain_name}.csr (Certificate Signing Request)"
    fi
    echo "====================================="
}

# ---------------------------------
# Main Execution Functions
# ---------------------------------
execute_validation() {
    case $VALIDATION_METHOD in
        1)
            validate_ssl_by_domain
            ;;
        2)
            validate_ssl_by_file
            ;;
        3)
            validate_ssl_bundle
            ;;
    esac
}

execute_conversion() {
    convert_ssl_to_pfx
}

execute_pfx_conversion() {
    convert_pfx_to_ssl
}

show_summary() {
    echo
    echo "================================="
    echo "    SSL Management Complete!"
    echo "================================="
    
    if [ "$OPERATION" = "validate" ]; then
        echo "SSL validation completed successfully."
    elif [ "$OPERATION" = "convert" ]; then
        echo "SSL bundle converted to PFX format."
        echo "Check the '$PFX_OUTPUT_DIR' directory for output files."
    elif [ "$OPERATION" = "pfx_to_ssl" ]; then
        echo "PFX file converted to SSL bundle format."
        echo "Check the '$SSL_OUTPUT_DIR' directory for output files."
    fi
    
    echo "================================="
}

# ---------------------------------
# Main Function
# ---------------------------------
main() {
    check_openssl
    collect_inputs
    
    case $OPERATION in
        "validate")
            execute_validation
            ;;
        "convert")
            execute_conversion
            ;;
        "pfx_to_ssl")
            execute_pfx_conversion
            ;;
    esac
    
    show_summary
}

# Run main function
main "$@"