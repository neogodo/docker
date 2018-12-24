#!/bin/bash
# ===============================================================================================
# Coredns containers Manager
# ===============================================================================================
# Requirements
#      Need GNU sed version, for photonOS, uninstall toybox and install sed package.
#      Load container with option:
#      Link do docker unix socket: "-v /var/run/docker.run:/var/run/docker.run"
#      Munt coredns volume as /data: "-v coredns:/data"
# ===============================================================================================
# Container Image Setup (template):
#     docker volume create coredns
#     docker run -dit --name coredns-updater-image --hostname coredns-updater-image vmware/photon2
#     docker cp $(which docker) dns-updater:/
#     docker exec -it coredns-updater.vlab bash
#     yum remove -y toybox
#     yum install -y libltdl sed
#     yum update -y
#     chmod 700 /coredns-manager.sh
#     exit
#     docker commit coredns-updater-image coredns-manager
# ===============================================================================================
# Startup of manager container from host docker:
#     docker run -dit --name coredns-manager.vlab --hostname coredns-manager.vlab -v coredns:/data -v /var/run/docker.sock:/var/run/docker.sock --entrypoint="/coredns-manager.sh daemon" coredns-manager
# ===============================================================================================
# Adding new dnsserver containers
#     docker exec -it coredns-manager bash
#     coredns.container.new
#     exit
# ===============================================================================================

# ===============================================================================================
#                      !!!!! Pending Features / Upgrades !!!!!
#
# --> Check SOA master dns, if server is down, find the next server and than
#     update zone file SOA registry, and, update all containers about that zone
#     with de correct master dns server
#
# --> When add a new dns server, update all related container with the new
#     nameserver at /etc/resolv.conf file. Attention to fact of the linux path maybe
#     some different between releases/distros.
#
# --> A config file with starter main zone, for example, this docker cluster will stay
#     behind a ".bd.intranet" master dns zone, and zones will maybe 
#     ".prod.bd.intranet" => (/data/zones/prod) 
#     ".qa.bd.intranet" => (/data/zones/qa)
# 
# ===============================================================================================

set PATH=/:$PATH

# -----------------------------------------------------------------------------

function docker.report.dnsentry-container () {
    docker container inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{.Config.Hostname}}' ${1}
}

# -----------------------------------------------------------------------------

function docker.report.dnsserver-containers () {
    docker container ps -a --format "{{.Names}} {{.Ports}}" |grep '53/tcp' |cut -d" " -f1
}

# -----------------------------------------------------------------------------

function docker.report.container-dnsservers-hostlist () {
    ZONEFILTER=${1:-.NoZoneNameEntered.}
    while read DNSCONTAINER; do
        docker.report.dnsentry-container $DNSCONTAINER |grep -e ".${ZONEFILTER}"
    done < <( docker.report.dnsserver-containers )
}


# -----------------------------------------------------------------------------

function docker.event-monitor () {
    while read -ra EVENTMESSAGE; do
        EVENTNAME="${EVENTMESSAGE[1]} ${EVENTMESSAGE[2]}"
        CONTAINERID=${EVENTMESSAGE[3]}
        CONTAINERIMAGE="${EVENTMESSAGE[4]##*=}"
        CONTAINERIMAGE="${CONTAINERIMAGE/,/}"
        CONTAINERNAME="${EVENTMESSAGE[5]##*=}"
        CONTAINERNAME="${CONTAINERNAME/)/}"
        case "$EVENTNAME" in
            "container create")
                # A start event will occours after a create event.
                # So nothing to do now about update dns.
                ;;
            "container start"|"container unpause")
                echo "Found activation event for container name '${CONTAINERNAME}' image of '${CONTAINERIMAGE}'."
                coredns.zone.update-host "$( docker.report.dnsentry-container "${CONTAINERID}" )"
                ;;
            "container stop") ;;
            "container destroy") ;;
            "container kill") ;;
            "container die") ;;
            "container pause") ;;
        esac
    done < <( docker events --filter='event=create' --filter='event=start' --filter='event=stop' --filter='event=destroy' --filter='event=kill' --filter='event=die' --filter='event=pause' --filter='event=unpause')
}

# -----------------------------------------------------------------------------

function coredns.generate.empty-zonefile () {
    ZONENAMENEW=${1}
    if ! [[ "${ZONENAMENEW:-.NoDefinedZoneNameNew.}" == ".NoDefinedZoneNameNew." ]]; then
        unset DNSHOSTNAME
        unset DNSHOSTFQDN
        unset DNSHOSTIP
        while read -ra ENTRY; do
            DNSHOSTNAME[${#DNSHOSTNAME[@]}+1]=${ENTRY[1]%.*}
            DNSHOSTFQDN[${#DNSHOSTFQDN[@]}+1]=${ENTRY[1]}
            DNSHOSTIP[${#DNSNHOSTIP[@]}+1]=${ENTRY[0]}
        done < <( docker.report.container-dnsservers-hostlist "${ZONENAMENEW}" )
        if [[ ${#DNSHOSTNAME[@]} -eq 0 ]]; then
            return 1
        else
            echo "\$ORIGIN ${ZONENAMENEW}."
            echo "@ 3600 IN SOA ${DNSHOSTFQDN[1]}. ${ZONENAMENEW}. ("
            echo "    $(date +%s) ; serial"
            echo "    7200       ; refresh (2 hours)"
            echo "    3600       ; retry (1 hour)"
            echo "    1209600    ; expire (2 weeks)"
            echo "    3600       ; minimum (1 hour)"
            echo "    )"
            for NAME in ${DNSHOSTFQDN[@]}; do
                echo "    IN NS ${NAME}."
            done
            for N in {1..999999}; do
                [[ ${DNSHOSTNAME[$N]:-...} == "..." ]] && break
                [[ ${DNSHOSTIP[$N]:-...} == "..." ]] && break
                echo "${DNSHOSTNAME[$N]} IN A ${DNSHOSTIP[$N]}"
            done
            return 0
        fi
    else
        return 1
    fi
}

# -----------------------------------------------------------------------------

function coredns.zone.update-host () {
    read -ra DNSENTRY < <( echo ${1} )
    IP=${DNSENTRY[0]}
    HOST=${DNSENTRY[1]}
    ZONENAME=${HOST##*.}
    ZONENAME=${ZONENAME:-vlab}
    ZONEFILE="/data/zones/${ZONENAME}"
    ZONEHOSTA=${HOST/%.${ZONENAME}/}
    ZONEENTRY="${ZONEHOSTA} IN A ${IP}"
    if ! [ -e "${ZONEFILE}" ]; then
        echo "Zone file '${ZONEFILE}' not found, creating a new empty file for '${ZONENAME}'."
        coredns.generate.empty-zonefile >$ZONEFILE
    else
        echo "Archiving a backup file: $( cp -va "${ZONEFILE}" "/data/backup/${ZONEFILE##*/}.$(date +%s)" )"
        if [[ $( grep -i -e "^${ZONEHOSTA}\s" -e "^${ZONEHOSTA}\t" "${ZONEFILE}" |wc -l ) -eq 0 ]]; then
            echo "Adding a new dns host to zone file '${ZONEFILE}' with entry '${ZONEENTRY}'."
            echo "${ZONEENTRY}" >>"${ZONEFILE}"
        else
            echo "Updating dns registry hosts file '${ZONEFILE}' with entry '${ZONEENTRY}'."
            ZONEFILETMP="/tmp/zone-hosts-$(date +%s).${ZONENAME}"
            eval "cat ${ZONEFILE} |sed -e '3,\$s/^[^ ]*/\L&\E/' |sed -e '/^${ZONEHOSTA}\t/c ${ZONEENTRY}' -e '/^${ZONEHOSTA} /c ${ZONEENTRY}' -e '/^${DNSENTRY[1]}\t/c ${ZONEENTRY}' -e '/; serial\$/c  $(date +%s) ; serial'" >${ZONEFILETMP}
            echo "Replacing old file: $( mv -f -v ${ZONEFILETMP} ${ZONEFILE} )"
            echo "Done."
        fi
    fi
}

# -----------------------------------------------------------------------------

function coredns.container.new () {
    ZONENAME="${1}"
    if [[ "${ZONENAME:-.ZoneNotInformed.}" == ".ZoneNotInformed." ]]; then
        echo "No zone name informed, aborted."
        exit 1
    fi
    SERVERLIST=( $( echo $( docker.report.container-dnsservers-hostlist "${ZONENAME}" ) ) )
    CONTAINERNAME="coredns-server.${ZONENAME}"
    while [[ $( docker ps --filter="name=${CONTAINERNAME}" |tail +2 |wc -l ) -ne 0 ]]; do
        COUNTER=$(( ${#SERVERLIST[@]+1} ))
        CONTAINERNAME="coredns-server$(( ${#SERVERLIST[@]}+1 )).${ZONENAME}"
    done
    CONTAINERID=$( docker run -dit --name $CONTAINERNAME --hostname $CONTAINERNAME -v coredns:/data -v /var/run/docker.sock:/var/run/docker.sock coredns/coredns -conf /data/Corefile )
    docker ps --filter="id=$CONTAINERID"
    docker.report.dnsentry-container "${CONTAINERID}"
}

# ------------------- Main ------------------

case "${1}" in
    daemon)
        docker.event-monitor
        ;;
    emptyzonefile)
        coredns.generate.empty-zonefile "${2}" >"/tmp/zone.${2}"
        if [[ $? -ne 0 ]]; then
            echo "Failed, not found any coredns-server at zone '${2}'."
            echo "Consider to rerun script with option 'newcontainer ${2}'."
        else
            cat "/tmp/zone.${2}"
            mkdir -p /data/backup
            mv -i --backup=t "/tmp/zone.${2}" "/data/zones/${2}"
            mv -v /data/zones/*.~* /data/backup/
        fi
        [[ -e "/tmp/zone.${2}" ]] && rm -f "/tmp/zone.${2}"
        ;;
    newcontainer)
        coredns.container.new "${2}"
        ;;
    monitor)
        docker.event-monitor
        ;;
    *) echo "options:
        daemon | emptyzonefile [zone] | newcontainer [zone]
        " ;;
esac
