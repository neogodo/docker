

# ====================================================================================================================================

function docker.container.inspect.hostname () {
    docker container inspect -f '{{.Config.Hostname}} ' ${1}
}

function docker.container.inspect.ipaddress () {
    docker container inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${1}
}

function docker.report.container-dns-entry () {
    docker container inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{.Config.Hostname}}' ${1}
}

function docker.container.list () {
    docker container ps --format "{{.Names}}"
}

function docker.container.listall () {
    docker container ps -a --format "{{.Names}}"
}

function docker.report.hostsip () {
    while read CONTAINERNAME; do
    	echo "$( docker.container.inspect.hostname $CONTAINERNAME ) $(docker.container.inspect.ipaddress ${CONTAINERNAME} )"
    done < <( docker.container.list )
}

function docker.container.exec () {
    docker exec -it ${1} ${@:2}
}

function docker.container.shell () {
    docker.container.exec ${1} bash
}

function docker.dummy.centos () {
    docker run -dit --name dummy --hostname dummy.vlab --link dns --entrypoint=bash centos
    docker exec -it dummy yum install -y net-utils bind-utils nmap vim iproute
    docker.shell dummy
}

function docker.iptables.container.exposeport () {
    CONTAINERIP=$( docker.container.inspect.ipaddress ${1} )
    YOURPORT=${2}
    iptables -t nat -A DOCKER -p tcp --dport ${YOURPORT} -j DNAT --to-destination ${CONTAINERIP}:${YOURPORT}
    iptables -t nat -A POSTROUTING -j MASQUERADE -p tcp --source ${CONTAINERIP} --destination ${CONTAINERIP} --dport ${YOURPORT}
    iptables -A DOCKER -j ACCEPT -p tcp --destination ${CONTAINERIP} --dport ${YOURPORT}
}

function docker.container.config.resolvconf () {
    DNSSERVER=${3:-dns}
    DOMAIN=${2:-vlab}
    CONTAINER=${1}
    eval "docker exec -it ${CONTAINER} bash -c 'cp -f /etc/resolv.conf /etc/resolv.conf.bak'"
    eval "docker exec -it ${CONTAINER} bash -c 'echo "search ${DOMAIN}" > /etc/resolv.conf'"
    eval "docker exec -it ${CONTAINER} bash -c 'echo "nameserver $( docker.container.inspect.ipaddress ${DNSSERVER} )" >> /etc/resolv.conf'"
}


