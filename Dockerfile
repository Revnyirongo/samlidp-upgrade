FROM richarvey/nginx-php-fpm:1.7.1

# Install required packages first
RUN apk update --no-cache && \
    apk add --no-cache \
    openssl \
    rsyslog \
    rsyslog-tls \
    php7-pdo_pgsql \
    postgresql-dev \
    git \
    unzip \
    php7-simplexml \
    php7-tokenizer \
    php7-xmlwriter \
    php7-pcntl \
    php7-posix \
    php7-opcache \
    php7-curl \
    php7-json \
    php7-openssl \
    php7-mbstring \
    php7-xml \
    php7-dom \
    php7-gd \
    npm \
    yarn \
    && rm -rf /var/cache/apk/*

# Install Composer 2
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer --version=2.5.8

# Set up environment
ENV COMPOSER_ALLOW_SUPERUSER=1
ENV COMPOSER_HOME=/composer
ENV COMPOSER_MEMORY_LIMIT=-1
ENV COMPOSER_NO_INTERACTION=1
ENV APP_ENV=prod
ENV SYMFONY_ENV=prod
ENV PHP_FPM_USER=nginx
ENV PHP_FPM_GROUP=nginx

# Create base directories
WORKDIR /app
RUN mkdir -p \
    /composer/cache \
    /etc/pki \
    /app/var \
    /app/var/cache \
    /app/var/logs \
    /app/var/sessions \
    /app/web/images/idp_logo \
    /app/web/uploads/tmp \
    /app/web/bundles \
    /app/web/css \
    /app/web/js \
    /var/www/html \
    /app/app/config \
    /certs

# Configure PHP with proper session handling first
RUN { \
    echo 'error_reporting = E_ALL'; \
    echo 'display_errors = Off'; \
    echo 'display_startup_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /var/log/php-fpm.log'; \
    echo 'memory_limit = 256M'; \
    echo 'max_execution_time = 300'; \
    echo 'max_input_time = 300'; \
    echo 'post_max_size = 50M'; \
    echo 'upload_max_filesize = 50M'; \
    echo 'opcache.enable = 1'; \
    echo 'date.timezone = UTC'; \
    echo 'session.auto_start = 0'; \
    echo 'output_buffering = 4096'; \
    echo 'session.use_strict_mode = 1'; \
    echo 'session.save_handler = files'; \
    echo 'session.save_path = "/app/var/sessions"'; \
    echo 'session.gc_probability = 1'; \
    echo 'session.gc_divisor = 100'; \
    echo 'session.gc_maxlifetime = 1440'; \
    echo 'session.use_cookies = 1'; \
    echo 'session.use_only_cookies = 1'; \
    } > /usr/local/etc/php/conf.d/custom.ini

# Copy composer files first
COPY app/composer.json /app/
COPY app/app /app/app/

# Ensure parameters.yml exists during build
COPY app/app/config/parameters.yml.dist /app/app/config/parameters.yml
RUN chown nginx:nginx /app/app/config/parameters.yml

# First ensure proper directory structure and bootstrap file
RUN mkdir -p /app/var && \
    touch /app/var/bootstrap.php.cache && \
    chown nginx:nginx /app/var/bootstrap.php.cache && \
    chmod 644 /app/var/bootstrap.php.cache

# Install dependencies without scripts
RUN composer config -g repos.packagist composer https://packagist.org && \
    composer config -g github-protocols https https && \
    composer config -g secure-http true && \
    composer clear-cache && \
    COMPOSER_MEMORY_LIMIT=-1 composer install \
    --no-scripts \
    --prefer-dist \
    --no-progress \
    --no-dev \
    --optimize-autoloader

# Copy all application files
COPY app /app/

# Run post-install tasks
RUN cd /app && \
    composer run-script post-install-cmd --no-interaction || true && \
    php bin/console cache:clear --env=prod --no-debug || true && \
    php bin/console cache:warmup --env=prod --no-debug || true && \
    [ -f var/bootstrap.php.cache ] || touch var/bootstrap.php.cache && \
    chmod 644 var/bootstrap.php.cache && \
    chown nginx:nginx var/bootstrap.php.cache

# Ensure proper directory permissions
RUN chmod -R 777 /app/var && \
    chown -R nginx:nginx /app/var && \
    mkdir -p /app/var/cache/prod && \
    chmod -R 777 /app/var/cache && \
    chmod -R 777 /app/var/sessions && \
    chown -R nginx:nginx /app/var/sessions

# Copy configuration files
COPY conf/nginx/nginx-site.conf /etc/nginx/sites-available/default.conf
COPY conf/rsyslog/rsyslog.conf /etc/
COPY conf/rsyslog/10-simplesamlphp.conf /etc/rsyslog.d/

# Copy and modify start scripts
COPY misc/samlidp-start.sh /samlidp-start.sh
COPY misc/rsyslog-start.sh /rsyslog-start.sh

# Create log files with proper permissions
RUN touch /var/log/php-fpm.log && \
    touch /var/log/php-fpm.access.log && \
    touch /var/log/nginx/error.log && \
    touch /var/log/nginx/access.log && \
    chown nginx:nginx /var/log/php-fpm* && \
    chown nginx:nginx /var/log/nginx/* && \
    chmod 666 /var/log/php-fpm* && \
    chmod 666 /var/log/nginx/*

# Make directories and set permissions for SimpleSAMLphp
RUN mkdir -p /app/vendor/simplesamlphp/simplesamlphp && \
    mkdir -p /app/vendor/simplesamlphp/simplesamlphp/cert && \
    mkdir -p /app/vendor/simplesamlphp/simplesamlphp/config && \
    mkdir -p /app/vendor/simplesamlphp/simplesamlphp/metadata && \
    mkdir -p /app/vendor/simplesamlphp/simplesamlphp/attributemap && \
    chown -R nginx:nginx /app/vendor/simplesamlphp && \
    chmod -R 755 /app/vendor/simplesamlphp

# Configure PHP-FPM
RUN { \
    echo '[www]'; \
    echo 'user = nginx'; \
    echo 'group = nginx'; \
    echo 'listen = 9000'; \
    echo 'listen.owner = nginx'; \
    echo 'listen.group = nginx'; \
    echo 'listen.mode = 0660'; \
    echo 'pm = dynamic'; \
    echo 'pm.max_children = 5'; \
    echo 'pm.start_servers = 2'; \
    echo 'pm.min_spare_servers = 1'; \
    echo 'pm.max_spare_servers = 3'; \
    echo 'catch_workers_output = yes'; \
    echo 'php_admin_value[error_log] = /var/log/php-fpm.log'; \
    echo 'php_admin_flag[log_errors] = on'; \
    echo 'access.log = /var/log/php-fpm.access.log'; \
    echo 'slowlog = /var/log/php-fpm.slow.log'; \
    echo 'request_slowlog_timeout = 10s'; \
    } > /usr/local/etc/php-fpm.d/www.conf

# Configure PHP-FPM global settings
RUN { \
    echo '[global]'; \
    echo 'error_log = /var/log/php-fpm.log'; \
    echo 'log_level = debug'; \
    echo 'emergency_restart_threshold = 10'; \
    echo 'emergency_restart_interval = 1m'; \
    echo 'process_control_timeout = 10s'; \
    echo 'include=/usr/local/etc/php-fpm.d/*.conf'; \
    } > /usr/local/etc/php-fpm.conf

# Create runtime directories with proper permissions
RUN mkdir -p /run/nginx && \
    mkdir -p /run/php && \
    chown -R nginx:nginx /run/nginx && \
    chown -R nginx:nginx /run/php

# Create and configure cache clear script
RUN echo '#!/bin/sh' > /clear-cache.sh && \
    echo 'rm -rf /app/var/cache/*' >> /clear-cache.sh && \
    echo 'rm -rf /app/var/sessions/*' >> /clear-cache.sh && \
    echo 'php /app/bin/console cache:clear --env=prod --no-debug || true' >> /clear-cache.sh && \
    echo 'php /app/bin/console cache:warmup --env=prod --no-debug || true' >> /clear-cache.sh && \
    echo 'php /app/bin/console assets:install --env=prod --no-debug || true' >> /clear-cache.sh && \
    echo 'php /app/bin/console assetic:dump --env=prod --no-debug || true' >> /clear-cache.sh && \
    echo 'chown -R nginx:nginx /app/var/*' >> /clear-cache.sh && \
    echo 'chown -R nginx:nginx /app/web/*' >> /clear-cache.sh && \
    chmod +x /clear-cache.sh

# Set final permissions
RUN chmod +x /samlidp-start.sh && \
    chmod +x /rsyslog-start.sh && \
    find /app/web -type d -exec chmod 755 {} \; && \
    find /app/web -type f -exec chmod 644 {} \; && \
    chown -R nginx:nginx /app/web && \
    chown -R nginx:nginx /app/var && \
    chmod -R 777 /app/var && \
    chown -R nginx:nginx /app/app/config && \
    chmod -R 777 /app/app/config

# Add cache clearing to startup
RUN sed -i '1a /clear-cache.sh' /samlidp-start.sh

CMD ["/samlidp-start.sh"]
