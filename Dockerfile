FROM php:8.4.27-fpm-alpine3.24

LABEL maintainer="Ric Harvey <ric@squarecows.com>"

ENV php_conf="/usr/local/etc/php-fpm.conf"
ENV fpm_conf="/usr/local/etc/php-fpm.d/www.conf"
ENV php_vars="/usr/local/etc/php/conf.d/docker-vars.ini"

ENV LUAJIT_LIB=/usr/lib
ENV LUAJIT_INC=/usr/include/luajit-2.1

# GNU iconv instead of musl's (resolves #166)
ENV LD_PRELOAD="/usr/lib/preloadable_libiconv.so php"
RUN apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/community gnu-libiconv

# musl locales
ENV MUSL_LOCALE_DEPS="cmake make musl-dev gcc gettext-dev libintl"
ENV MUSL_LOCPATH="/usr/share/i18n/locales/musl"

RUN apk add --no-cache \
    $MUSL_LOCALE_DEPS \
    && wget https://gitlab.com/rilian-la-te/musl-locales/-/archive/master/musl-locales-master.zip \
    && unzip musl-locales-master.zip \
      && cd musl-locales-master \
      && cmake -DLOCALE_PROFILE=OFF -D CMAKE_INSTALL_PREFIX:PATH=/usr . && make && make install \
      && cd .. && rm -r musl-locales-master

# nginx (+ lua / devel kit modules), supervisor, certbot, git and the
# runtime libraries + headers needed by the PHP extensions below
RUN apk update && apk upgrade && \
    apk add --no-cache \
    nginx \
    nginx-mod-http-lua \
    nginx-mod-devel-kit \
    bash \
    openssh-client \
    wget \
    supervisor \
    curl \
    libcurl \
    libpq \
    git \
    python3 \
    py3-pip \
    dialog \
    autoconf \
    make \
    libzip-dev \
    bzip2-dev \
    icu-dev \
    tzdata \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    libxslt-dev \
    certbot certbot-nginx \
    gcc 

RUN apk add --no-cache --virtual .sys-deps \
    musl-dev \
    linux-headers \
    augeas-dev \
    libmcrypt-dev \
    python3-dev \
    libffi-dev \
    sqlite-dev \
    imap-dev \
    postgresql-dev \
    lua-resty-core \
    libjpeg-turbo-dev \
    libwebp-dev \
    zlib-dev \
    libxpm-dev \
    libpng \
    libpng-dev && \
    docker-php-ext-configure gd \
      --enable-gd \
      --with-freetype \
      --with-jpeg && \
    docker-php-ext-install gd && \
    docker-php-ext-install pdo_mysql mysqli pdo_sqlite pgsql pdo_pgsql exif intl xsl soap zip && \
    pecl install -o -f xdebug && \
    pecl install -o -f redis && \ 
    pecl install -o -f mongodb && \
    echo "extension=redis.so" > /usr/local/etc/php/conf.d/redis.ini && \
    echo "extension=mongodb.so" > /usr/local/etc/php/conf.d/mongodb.ini && \
  # xdebug is installed but NOT enabled by default; start.sh enables it when ENABLE_XDEBUG=1
    docker-php-source delete && \
    mkdir -p /var/www/app /var/log/supervisor /etc/letsencrypt/webrootauth && \
  # composer, with the installer verified against the published sha384
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" && \
    EXPECTED_SIG="$(curl -fsSL https://composer.github.io/installer.sig)" && \
    php -r "if (hash_file('sha384', 'composer-setup.php') !== '${EXPECTED_SIG}') { fwrite(STDERR, 'ERROR: Invalid composer installer checksum' . PHP_EOL); unlink('composer-setup.php'); exit(1); }" && \
    php composer-setup.php --quiet --install-dir=/usr/bin --filename=composer && \
    rm composer-setup.php && \
    apk del gcc musl-dev linux-headers libffi-dev augeas-dev python3-dev make autoconf && \
    apk del .sys-deps

COPY conf/supervisord.conf /etc/supervisord.conf

# nginx config
COPY conf/nginx.conf /etc/nginx/nginx.conf

# nginx site conf
RUN mkdir -p /etc/nginx/sites-available/ && \
mkdir -p /etc/nginx/sites-enabled/ && \
mkdir -p /etc/nginx/ssl/ && \
rm -Rf /var/www/* && \
mkdir /var/www/html/
COPY conf/nginx-site.conf /etc/nginx/sites-available/default.conf
COPY conf/nginx-site-ssl.conf /etc/nginx/sites-available/default-ssl.conf
RUN ln -s /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

# tweak php-fpm config
RUN echo "cgi.fix_pathinfo=0" > ${php_vars} &&\
    echo "upload_max_filesize = 128M"  >> ${php_vars} &&\
    echo "post_max_size = 128M"  >> ${php_vars} &&\
    echo "variables_order = \"EGPCS\""  >> ${php_vars} && \
    echo "memory_limit = 256M"  >> ${php_vars} && \
    echo "expose_php = Off"  >> ${php_vars} && \
  # defence in depth for CVE-2026-109619 (stale upload-progress state); the real fix is the patched PHP release above
    echo "session.upload_progress.enabled = 0"  >> ${php_vars} && \
    sed -i \
        -e "s/;catch_workers_output\s*=\s*yes/catch_workers_output = yes/g" \
        -e "s/pm.max_children = 5/pm.max_children = 4/g" \
        -e "s/pm.start_servers = 2/pm.start_servers = 3/g" \
        -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" \
        -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 4/g" \
        -e "s/;pm.max_requests = 500/pm.max_requests = 200/g" \
        -e "s/user = www-data/user = nginx/g" \
        -e "s/group = www-data/group = nginx/g" \
        -e "s/;listen.mode = 0660/listen.mode = 0666/g" \
        -e "s/;listen.owner = www-data/listen.owner = nginx/g" \
        -e "s/;listen.group = www-data/listen.group = nginx/g" \
        -e "s/^;*listen = 127.0.0.1:9000/listen = \/var\/run\/php-fpm.sock/" \
        -e "s/^;clear_env = no$/clear_env = no/" \
        ${fpm_conf}

# opcache is already enabled by the official image via conf.d/docker-php-ext-opcache.ini;
# only uncomment the opcache.* settings here, don't load the extension a second time
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini && \
	sed -i \
	    -e "s/^;opcache\./opcache./g" \
            /usr/local/etc/php/php.ini


# container scripts
COPY --chmod=755 scripts/start.sh /start.sh
COPY --chmod=755 scripts/pull scripts/push scripts/letsencrypt-setup scripts/letsencrypt-renew /usr/bin/

# default site + error pages
COPY src/ /var/www/html/
COPY errors/ /var/www/errors

EXPOSE 443 80

WORKDIR "/var/www/html"
CMD ["/start.sh"]
