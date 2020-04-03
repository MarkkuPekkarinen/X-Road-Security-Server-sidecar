#!/bin/bash

usage="\n
To create a sidecar security server instance you need to provide the five arguments described here below.

#1 Name for the sidecar security server container
#2 Local port number to bind the sidecar security server admin UI
#3 Software token PIN code for autologin service
#4 Username for sidecar security server admin UI
#5 Password for sidecar security server admin UI
"

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    printf "$usage";
    exit;
fi

if [[ ! ( $2 =~ ^-?[0-9]+$ ) || ($2 -lt 1024) ]] ; then
    printf "Illegal port number parameter"
    exit 0;
fi

httpport=$(($2 + 1))

# Create xroad-network to provide container-to-container communication
docker network inspect xroad-network >/dev/null 2>&1 || docker network create -d bridge xroad-network

echo "=====> Build sidecar image"
docker build -f sidecar/Dockerfile -t xroad-sidecar-security-server-image sidecar/ 
echo "=====> Run container"
docker run -v sidecar-config:/etc/xroad --detach -p $2:4000 -p $httpport:80 -p 5588:5588 --network xroad-network -e XROAD_TOKEN_PIN=$3 -e XROAD_ADMIN_USER=$4 -e XROAD_ADMIN_PASSWORD=$5 --name $1 xroad-sidecar-security-server-image 

printf "\n
Sidecar security server software token PIN is set to $3
Sidecar security server admin UI should be accessible shortly in https://localhost:$2
$1-container port 80 is mapped to $httpport
"
