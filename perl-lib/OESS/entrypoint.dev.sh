#!/bin/bash
# Configure and start all oess services

# Start httpd
htpasswd -b -c /usr/share/oess-frontend/www/.htpasswd admin ${OESS_PASSWORD}
/usr/sbin/httpd
sleep 1

# Start mysql
/usr/bin/mysql_install_db --user=mysql --ldata=/var/lib/mysql --force
/usr/bin/mysqld_safe --datadir='/var/lib/mysql' &
sleep 3
/usr/bin/mysqladmin -u root password ${MYSQL_ROOT_PASSWORD}
/usr/bin/mysql --user=root --password=${MYSQL_ROOT_PASSWORD} < /usr/share/doc/perl-OESS-2.0.12/share/nddi.sql

# Start RabbitMQ
rabbitmq-server start -detached
sleep 15

# Populate OESS config with mysql credentials
sed -i "s/oess_test/oess/" /etc/oess/database.xml
sed -i "s/test/$MYSQL_PASS/" /etc/oess/database.xml
sed -i "s/vpn\-mpls/$OESS_NETWORK_TYPE/" /etc/oess/database.xml
sed -i "s/NSO_HOST/$NSO_HOST/" /etc/oess/database.xml
sed -i "s/NSO_PASSWORD/$NSO_PASSWORD/" /etc/oess/database.xml
sed -i "s/NSO_USERNAME/$NSO_USERNAME/" /etc/oess/database.xml
sed -i "s/OESS_LOCAL_ASN/$OESS_LOCAL_ASN/" /etc/oess/database.xml
sed -i "s/TSDS_URL/$TSDS_URL/" /etc/oess/database.xml
sed -i "s/TSDS_PASSWORD/$TSDS_PASSWORD/" /etc/oess/database.xml
sed -i "s/TSDS_USERNAME/$TSDS_USERNAME/" /etc/oess/database.xml
sed -i "s/TSDS_REALM/$TSDS_REALM/" /etc/oess/database.xml

sed -i "s/root/$NETCONF_USERNAME/" /etc/oess/.passwd.xml
sed -i "s/test/$NETCONF_PASSWORD/" /etc/oess/.passwd.xml

# Start OESS
/usr/bin/oess-notify.pl &
/usr/bin/mpls_discovery.pl &
/usr/bin/mpls_fwdctl.pl &
/usr/bin/oess-nsi &
