#!/bin/bash

DBUSER=$2
DBPASSWD=$3

function checkCredentials(){
    source /etc/jelastic/metainf.conf
    jem service start >> /dev/null
    if [ "$COMPUTE_TYPE" == "postgres" ]; then
        PGPASSWORD="${DBPASSWD}" psql -U ${DBUSER} -d postgres -c "SELECT current_user" || exit 1;
    elif [ "$COMPUTE_TYPE" == "mariadb" ] || [ "$COMPUTE_TYPE" == "mysql" ] || [ "$COMPUTE_TYPE" == "percona" ]; then
        mysql -h localhost -u ${DBUSER} -p${DBPASSWD} mysql --execute="SHOW COLUMNS FROM user" 1>/dev/null || exit 1;
    elif [ "$COMPUTE_TYPE" == "mongodb" ]; then
        which mongo && CLIENT="mongo" || CLIENT="mongosh" 
        TLS_MODE=$(yq eval  '.net.tls.mode' /etc/mongod.conf)
        if [ "$TLS_MODE" == "requireTLS" ]; then
	        SSL_TLS_OPTIONS="--tls --tlsCertificateKeyFile /var/lib/jelastic/keys/SSL-TLS/client/client.pem --tlsCAFile /var/lib/jelastic/keys/SSL-TLS/client/root.pem --tlsAllowInvalidHostnames"
        else
	        SSL_TLS_OPTIONS=""
        fi
        echo "show dbs" | ${CLIENT} --shell ${SSL_TLS_OPTIONS} --username ${DBUSER} --password ${DBPASSWD} --authenticationDatabase admin "mongodb://localhost:27017"
    else
        true;
    fi
}

if [ "x$1" == "xcheckCredentials" ]; then
    checkCredentials
fi
