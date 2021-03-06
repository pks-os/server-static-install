#!/usr/bin/env bash

set -exu

NOMAD_VERSION="0.5.6"
DOCKER_VERSION="17.03.2"
UNAME="$(uname -r)"
DEBIAN_FRONTEND=noninteractive

is_xenial(){
  [ "$(cut -d'.' -f1 <<< $UNAME)" = "4" ] && return 0 || return 1
}

guess_private_ip(){
  INET="eth0"
  is_xenial && INET="ens3"
  /sbin/ifconfig $INET | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'
}

docker_package_name(){
  # Determines the Docker package name based off the version.
  # The Ubuntu distro version is no longer required after 17.06.0
  docker_ver_major=$(echo $DOCKER_VERSION | cut -d "." -f1)
  docker_ver_minor=$(echo $DOCKER_VERSION | cut -d "." -f2)
  docker_ver_patch=$(echo $DOCKER_VERSION | cut -d "." -f3)

  if [[ $docker_ver_major -le 17 && $docker_ver_minor -lt 6 ]]
  then
    echo "${DOCKER_VERSION}~ce-0~ubuntu-$(lsb_release -cs)"
  else
    echo "${DOCKER_VERSION}~ce-0~ubuntu"
  fi
}

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

echo "--------------------------------------------"
echo "       Finding Private IP"
echo "--------------------------------------------"


PRIVATE_IP=${PRIVATE_IP:-$(guess_private_ip)}
export PRIVATE_IP

echo "Using address: ${PRIVATE_IP}"

if [ -z "${NOMAD_SERVER_ADDRESS}" ]; then
  echo "The NOMAD_SERVER_ADDRESS env var is required."
  echo "It should point to the ip address of your CircleCI"
  echo "services installation."
  exit 1
fi

echo "-------------------------------------------"
echo "     Performing System Updates"
echo "-------------------------------------------"
apt-get update && apt-get -y upgrade

echo "-------------------------------------------"
echo "     Installing Required Dependencies"
echo "-------------------------------------------"
apt-get install -y zip

echo "--------------------------------------"
echo "        Installing Docker"
echo "--------------------------------------"
apt-get install -y apt-transport-https ca-certificates curl
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
if is_xenial; then
  apt-get install -y "linux-image-${UNAME}"
else
  apt-get install -y "linux-image-extra-$(uname -r)" linux-image-extra-virtual
  apt-get -y install cgmanager
fi
apt-get -y install docker-ce=$(docker_package_name)

# force docker to use userns-remap to mitigate CVE 2019-5736
apt-get -y install jq
mkdir -p /etc/docker
[ -f /etc/docker/daemon.json ] || echo '{}' > /etc/docker/daemon.json
tmp=$(mktemp)
cp /etc/docker/daemon.json /etc/docker/daemon.json.orig
jq '."userns-remap"= "default"' /etc/docker/daemon.json > "$tmp" && mv "$tmp" /etc/docker/daemon.json

echo "--------------------------------------"
echo "         Installing nomad"
echo "--------------------------------------"
curl -o nomad.zip "https://releases.hashicorp.com/nomad/0.5.6/nomad_${NOMAD_VERSION}_linux_amd64.zip"
unzip nomad.zip
mv nomad /usr/bin
mkdir -p /etc/nomad

echo "--------------------------------------"
echo "      Creating config.hcl"
echo "--------------------------------------"
cat <<EOT > /etc/nomad/config.hcl
log_level = "DEBUG"

data_dir = "/opt/nomad"
datacenter = "us-east-1"

advertise {
    http = "$PRIVATE_IP"
    rpc = "$PRIVATE_IP"
    serf = "$PRIVATE_IP"
}

client {
    enabled = true
    servers = ["${NOMAD_SERVER_ADDRESS}:4647"]
    node_class = "linux-64bit"
    options = {"driver.raw_exec.enable" = "1"}
}
EOT

echo "--------------------------------------"
echo "      Creating nomad.conf"
echo "--------------------------------------"
if is_xenial; then
cat <<EOT > /etc/systemd/system/nomad.service
[Unit]
Description="nomad"
[Service]
Restart=always
RestartSec=30
TimeoutStartSec=1m
ExecStart=/usr/bin/nomad agent -config /etc/nomad/config.hcl
[Install]
WantedBy=multi-user.target
EOT
else
cat <<EOT > /etc/init/nomad.conf
start on filesystem or runlevel [2345]
stop on shutdown
script
    exec nomad agent -config /etc/nomad/config.hcl
end script
EOT
fi

echo "--------------------------------------"
echo "   Creating ci-privileged network"
echo "--------------------------------------"
docker network create --driver=bridge --opt com.docker.network.bridge.name=ci-privileged ci-privileged

echo "--------------------------------------"
echo "      Starting Nomad service"
echo "--------------------------------------"
service nomad restart
if is_xenial; then
  systemctl enable nomad
fi
