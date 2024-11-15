#!/bin/bash
set -e  # Exit on error

# Add this near the start of the script
if [ ! -f "/app/app/config/parameters.yml" ]; then
    log_message "Error: parameters.yml not found"
    exit 1
fi

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check PHP-FPM
check_php_fpm() {
    for i in {1..30}; do
        if nc -z 127.0.0.1 9000; then
            log_message "PHP-FPM is accepting connections"
            return 0
        fi
        log_message "Waiting for PHP-FPM to be ready... ($i/30)"
        sleep 1
    done
    log_message "PHP-FPM failed to start"
    return 1
}

# Clean up function
cleanup() {
    log_message "Shutting down services..."
    pkill -f rsyslogd || true
    pkill -f nginx || true
    pkill -f php-fpm || true
}

# Set up trap for cleanup
trap cleanup EXIT TERM INT

log_message "Starting initialization..."

# Check required environment variables
if [ -z "$SAMLIDP_HOSTNAME" ]; then
    log_message "Error: SAMLIDP_HOSTNAME not set"
    exit 1
fi

if [ -z "$VAULT_PASS" ]; then
    log_message "Error: VAULT_PASS not set"
    exit 1
fi

# Create required directories
mkdir -p /run/php /run/nginx
chown -R nginx:nginx /run/php /run/nginx

# Database update
log_message "Updating database..."
/app/bin/console d:s:u -f

# Create domain if needed
log_message "Checking domain..."
/app/bin/console samli:createDomainOne

# Configure and start rsyslog
log_message "Configuring rsyslog..."
if [ ! -z "$REMOTE_LOGSERVER_AND_PORT" ]; then
    sed -i -e "s/REMOTE_LOGSERVER_AND_PORT/@@$REMOTE_LOGSERVER_AND_PORT/" /etc/rsyslog.conf
fi

# Kill any existing processes and remove PID files
pkill -f rsyslogd || true
pkill -f nginx || true
pkill -f php-fpm || true
rm -f /var/run/rsyslogd.pid
rm -f /run/nginx.pid
rm -f /run/php-fpm.pid

log_message "Starting rsyslog..."
/rsyslog-start.sh &

if [ ! -z "$SAMLIDP_RUNNING_MODE" ]; then
    if [ "$SAMLIDP_RUNNING_MODE" = "frontend" ]; then
        log_message "Starting in frontend mode..."
        
        # Check and configure nginx
        if [ ! -f "/etc/nginx/sites-available/default.conf" ]; then
            log_message "Error: Nginx config file not found"
            exit 1
        fi
        
        log_message "Configuring Nginx..."
        sed -i -e "s/SAMLIDP_HOSTNAME/$SAMLIDP_HOSTNAME/" /etc/nginx/sites-available/default.conf
        
        # Test nginx configuration
        nginx -t || {
            log_message "Error: Nginx configuration test failed"
            exit 1
        }
        
        # Decrypt certificate
        cd /etc/pki
        if [ ! -f "wildcard_certificate.key.enc" ]; then
            log_message "Error: Encrypted certificate not found in /etc/pki/"
            ls -la /etc/pki/
            exit 1
        fi
        
        log_message "Decrypting certificate..."
        openssl aes-256-cbc -md md5 -d -a -k "$VAULT_PASS" -in wildcard_certificate.key.enc -out wildcard_certificate.key || {
            log_message "Error: Certificate decryption failed"
            exit 1
        }
        chmod 600 wildcard_certificate.key
        
        # Start PHP-FPM
        log_message "Starting PHP-FPM..."
        php-fpm --test || {
            log_message "Error: PHP-FPM configuration test failed"
            exit 1
        }
        
        php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.conf &
        PHP_FPM_PID=$!
        
        # Check if PHP-FPM is accepting connections
        check_php_fpm || {
            log_message "Error: PHP-FPM failed to start properly"
            exit 1
        }
        
        # Start Nginx
        log_message "Starting Nginx..."
        exec nginx -g 'daemon off;'
        
    elif [ "$SAMLIDP_RUNNING_MODE" = "backend" ]; then
        log_message "Starting in backend mode..."
        exec crond -l 2 -f
    else
        log_message "Invalid SAMLIDP_RUNNING_MODE: $SAMLIDP_RUNNING_MODE"
        exit 1
    fi
else
    log_message "SAMLIDP_RUNNING_MODE not set"
    exit 1
fi
