#!/bin/bash

if grep -q ^[[:space:]]*replSetName /etc/mongod.conf; then 
    export RS_NAME=$(grep ^[[:space:]]*replSetName /etc/mongod.conf|awk '{print $2}'); 
    export RS_SUFFIX="/?replicaSet=${RS_NAME}&readPreference=nearest"; 
else 
    export RS_SUFFIX=""; 
fi
TLS_MODE=$(yq eval  '.net.tls.mode' /etc/mongod.conf)
if [ "$TLS_MODE" == "requireTLS" ]; then
	SSL_TLS_OPTIONS="--ssl --sslPEMKeyFile=/var/lib/jelastic/keys/SSL-TLS/client/client.pem --sslCAFile=/var/lib/jelastic/keys/SSL-TLS/client/root.pem --tlsInsecure"
else
	SSL_TLS_OPTIONS=""
fi
mongorestore ${SSL_TLS_OPTIONS} --uri="mongodb://${1}:${2}@localhost${RS_SUFFIX}" ~/dump 1>/dev/null
