#!/bin/bash

cd /var/www/html/yappli

for CONFIG in datasource_*.inc.php
do
  sed -e "s/__ANEMOMETER_MYSQL_HOST__/${ANEMOMETER_MYSQL_HOST}/" \
      -e "s/__ANEMOMETER_MYSQL_PORT__/${ANEMOMETER_MYSQL_PORT}/" \
      -e "s/__ANEMOMETER_MYSQL_USER__/${ANEMOMETER_MYSQL_USER}/" \
      -e "s/__ANEMOMETER_MYSQL_PASSWORD__/${ANEMOMETER_MYSQL_PASSWORD}/" \
      -e "s/__ANEMOMETER_MYSQL_DB__/${ANEMOMETER_MYSQL_DB}/" < $CONFIG > ../conf/$CONFIG
done

exec /usr/sbin/httpd -DFOREGROUND

