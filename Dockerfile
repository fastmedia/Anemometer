FROM amazonlinux:2
MAINTAINER Yappli SRE team  "team-sre@yappli.co.jp"

COPY . /var/www/html
WORKDIR /var/www/html

#RUN yum -y install python git nmap-ncat httpd php php-mysql php-bcmath php-xml jq
RUN yum -y install git nmap-ncat httpd php php-mysql php-bcmath php-xml jq
RUN yum -y update && yum clean all 

RUN cd /var/www/html && \
  curl -sS https://getcomposer.org/installer | php && \
  install -m 755 composer.phar /usr/local/bin/composer && \
  /usr/local/bin/composer update && \
  /usr/local/bin/composer install

RUN ln -sf /dev/stdout /var/log/httpd/access.log \
    && ln -sf /dev/stderr /var/log/httpd/error.log

RUN install -m 755 docker/run.sh /run.sh

EXPOSE 80

CMD ["/run.sh"]
