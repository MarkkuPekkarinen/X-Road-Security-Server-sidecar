#!/bin/bash

XROAD_SCRIPT_LOCATION=/usr/share/xroad/scripts
DB_PROPERTIES=/etc/xroad/db.properties
ROOT_PROPERTIES=/etc/xroad.properties
GROUPNAMES="xroad-security-officer xroad-registration-officer xroad-service-administrator xroad-system-administrator xroad-securityserver-observer"

INSTALLED_VERSION=$(dpkg-query --showformat='${Version}' --show xroad-proxy)
PACKAGED_VERSION="$(cat /root/VERSION)"

# Update X-Road configuration on startup, if necessary

if [ -z "$(ls -A /etc/xroad/conf.d)" ]; then
    cp -a /root/VERSION /etc/xroad/VERSION
    cp -a /root/etc/xroad/* /etc/xroad/
    cp -a /tmp/local.conf /etc/xroad/services/local.conf
    chown xroad:xroad /etc/xroad/services/local.conf
    cp -a /tmp/*logback* /etc/xroad/conf.d/
    chown xroad:xroad /etc/xroad/conf.d/
    crudini --set /etc/xroad/conf.d/local.ini proxy health-check-interface 0.0.0.0
    crudini --set /etc/xroad/conf.d/local.ini proxy health-check-port 5588
fi

if [ "$INSTALLED_VERSION" == "$PACKAGED_VERSION" ]; then
    if [ -f /etc/xroad/VERSION ]; then
        CONFIG_VERSION="$(cat /etc/xroad/VERSION)"
    else
        echo "WARN: Current configuration version not known" >&2
        CONFIG_VERSION=
    fi
    if [ -n "$CONFIG_VERSION" ] && dpkg --compare-versions "$PACKAGED_VERSION" gt "$CONFIG_VERSION"; then
        echo "Updating configuration from $CONFIG_VERSION to $PACKAGED_VERSION"
        cp -a /root/etc/xroad/* /etc/xroad/
        pg_ctlcluster 10 main start
        pg_isready -t 10
        dpkg-reconfigure xroad-proxy
        pg_ctlcluster 10 main stop
        sleep 1
        echo "$PACKAGED_VERSION" >/etc/xroad/VERSION
    fi
else
    echo "WARN: Installed version ($INSTALLED_VERSION) does not match packaged version ($PACKAGED_VERSION)" >&2
fi

# Configure admin user with user-supplied username and password
user_exists=$(id -u ${XROAD_ADMIN_USER} > /dev/null 2>&1)
if [ $? != 0 ]
then
    echo "Creating admin user with user-supplied credentials"
    useradd -m ${XROAD_ADMIN_USER} -s /usr/sbin/nologin
    echo "${XROAD_ADMIN_USER}:${XROAD_ADMIN_PASSWORD}" | chpasswd
    echo "xroad-proxy xroad-common/username string ${XROAD_ADMIN_USER}" | debconf-set-selections

    echo "Configuring groups"
    usergroups=" $(id -Gn "${XROAD_ADMIN_USER}") "

    for groupname in ${GROUPNAMES}; do
        if [[ $usergroups != *" $groupname "* ]]; then
            echo "$groupname"
            usermod -a -G "$groupname" "${XROAD_ADMIN_USER}" || true
        fi
    done
fi

# Generate internal and admin UI TLS keys and certificates on the first run
if [ ! -f /etc/xroad/ssl/internal.crt ];
then
    echo "Generating new internal TLS key and certificate"
    ARGS="-n internal -f -S -p"
    $XROAD_SCRIPT_LOCATION/generate_certificate.sh $ARGS
fi

if [ ! -f /etc/xroad/ssl/proxy-ui-api.crt ];
then
    echo "Generating new SSL key and certificate for the admin UI"
    ARGS="-n proxy-ui-api -f -S -p"
    $XROAD_SCRIPT_LOCATION/generate_certificate.sh $ARGS
fi

# Recreate serverconf database and properties file with serverconf username and random password on the first run
if [ ! -f ${DB_PROPERTIES} ]
then
    if [[ ! -z "${XROAD_DB_PWD}" && "${XROAD_DB_HOST}" != "127.0.0.1" ]];
    then
        echo "xroad-proxy xroad-common/database-host string ${XROAD_DB_HOST}:${XROAD_DB_PORT}" | debconf-set-selections
        touch /etc/xroad.properties
        chown root:root /etc/xroad.properties
        chmod 600 /etc/xroad.properties
        echo "postgres.connection.password = ${XROAD_DB_PWD}" >> ${ROOT_PROPERTIES}
        if [ ! -z "${XROAD_CONF_DATABASE_NAME}" ]
        then
          touch /etc/xroad/db.properties
          chown xroad:xroad /etc/xroad/db.properties
          chmod 640 /etc/xroad/db.properties
          echo "serverconf.database.admin_user = ${XROAD_CONF_DATABASE_NAME}_admin" >> ${ROOT_PROPERTIES}
          echo "serverconf.hibernate.connection.username= ${XROAD_CONF_DATABASE_NAME}_serverconf" >> ${DB_PROPERTIES}
          echo "serverconf.hibernate.connection.url = jdbc:postgresql://${XROAD_DB_HOST}:${XROAD_DB_PORT}/${XROAD_CONF_DATABASE_NAME}_serverconf" >> ${DB_PROPERTIES}
        fi
        crudini --del /etc/supervisor/conf.d/xroad.conf program:postgres
        dpkg-reconfigure -fnoninteractive xroad-proxy
    else
        pg_ctlcluster 10 main start
        dpkg-reconfigure -fnoninteractive xroad-proxy
        pg_ctlcluster 10 main stop
    fi
fi

if [ ! -f ${XROAD_LOG_LEVEL} ];
    then
    echo "XROAD_LOG_LEVEL=${XROAD_LOG_LEVEL}" > /etc/xroad/conf.d/variables-logback.properties
fi

#Configure master pod for balanacer
sudo adduser --system --shell /bin/bash --ingroup xroad xroad-slave &&
sudo mkdir -m 755 -p /home/xroad-slave/.ssh && sudo touch /home/xroad-slave/.ssh/authorized_keys &&
crudini --set /etc/xroad/conf.d/node.ini node type 'master' &&
chown xroad:xroad /etc/xroad/conf.d/node.ini &&
crudini --set /etc/xroad/conf.d/local.ini proxy health-check-interface '0.0.0.0' &&
crudini --set /etc/xroad/conf.d/local.ini proxy health-check-port '5588' &&
crudini --set /etc/xroad/conf.d/local.ini proxy server-support-clients-pooled-connections 'false' &&
cat /etc/.ssh/id_rsa.pub >> /home/xroad-slave/.ssh/authorized_keys &&
sudo /etc/init.d/ssh restart

# Start services
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
