# ESP Proxy that forwards requests into the application server.

FROM debian:jessie

# Install all of the needed dependencies

# Upgrade the OS and core packages
# Install core required utilities
# Install ESP dependencies.
# Clean up
RUN apt-get update && \
    apt-get install --no-install-recommends -y -q ca-certificates && \
    apt-get -y -q upgrade && \
    apt-get install -y -q --no-install-recommends \
      apt-utils adduser cron curl logrotate python wget \
      libc6 libgcc1 libstdc++6 libuuid1 && \
    apt-get clean && rm /var/lib/apt/lists/*_*

# This file path is currently hard coded because there's no way to pass input
# parameters into Dockerfiles or `docker build`
ADD endpoints-runtime.deb endpoints-runtime.deb
RUN dpkg -i /endpoints-runtime.deb && rm /endpoints-runtime.deb

# Add the custom Endpoints nginx configuration templates.
ADD nginx.conf.template /etc/nginx/nginx.conf.template
ADD ssl.conf.template /etc/nginx/ssl.conf.template

RUN mkdir -p /var/lib/nginx/optional && \
    mkdir -p /var/lib/nginx/extra && \
    mkdir -p /var/lib/nginx/bin

ADD static.conf /var/lib/nginx/optional/static.conf
ADD start_nginx.sh /var/lib/nginx/bin/start_nginx.sh
ADD nginx.logrotate /etc/logrotate.d/nginx


EXPOSE 8080
EXPOSE 8090

# to run nginx that proxies the requests to server at HOST:PORT
# docker run -p 8080:8080 --expose 8090 \
#   --entrypoint=/var/lib/nginx/bin/start_nginx.sh -a HOST:PORT

ENTRYPOINT ["/var/lib/nginx/bin/start_nginx.sh"]