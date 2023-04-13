#!/bin/bash
#
# Analyze sosreport to look for condition
#

PROG=$(basename "$0")

# Debug logs
declare verbose="no"

declare sosreportdir="${PWD}"
declare SOSHOSTNAME=""

#
# Logging functions
#
function loginfo {
    echo "$1"
}

function logdebug {
    if [ "${verbose}" = "no" ]; then
        return
    fi

    echo "debug: $1"
}

function check_static_pod_container_health {
    local current_ps_output
    local f
    local name
    local state

    local count=0

    current_ps_output=$(find "${sosreportdir}"/sos_commands/crio -name 'crictl_inspect_*' -exec grep -q -v '^time' {} \; -print | sort | xargs --no-run-if-empty cat)
    for f in "${sosreportdir}"/etc/kubernetes/manifests/*.yaml ; do
        if [ ! -f "${f}" ]; then
            continue
        fi

        podname=$(jq -r '.metadata.name' ${f})

        logdebug "Parsing manifest: ${f}"
        # Get container state of system-node-critical pods
        for name in $(jq -r 'select(.spec.priorityClassName=="system-node-critical") | .spec.containers[].name' $f); do
            logdebug "Checking container: ${name}"
            state=$(echo "${current_ps_output}" | jq -r --arg name "${name}" '.status | select(.metadata.name==$name).state')
            if [[ ! "${state}" =~ CONTAINER_RUNNING ]]; then
                loginfo "${podname}: Container ${name} is not running: ${state}"
                count=$((count+1))
            else
                logdebug "${podname}: ${name} is running"
            fi
        done
    done

    if [ "${count}" -gt 0 ]; then
        logdebug "static pod containers failed health check"
    else
        logdebug "static pod containers healthy"
    fi

    return "${count}"
}

function check_static_pod_container_revision {
    local f
    local expected_revision
    local current_revision
    local podname
    local namespace
    local installer
    local installer_created

    local count=0

    current_pods_output=$(find "${sosreportdir}"/sos_commands/crio -name 'crictl_inspectp_*' -exec grep -q -v '^time' {} \; -print | sort | xargs --no-run-if-empty cat)
    for f in "${sosreportdir}"/etc/kubernetes/manifests/*.yaml ; do
        if [ ! -f "${f}" ]; then
            continue
        fi

        logdebug "Parsing ${f}"
        expected_revision=$(jq -r '.metadata.labels.revision' ${f})
        podname="$(jq -r '.metadata.name' ${f})-${SOSHOSTNAME}"
        logdebug "Podname: ${podname}, expected revision: ${expected_revision}"

        logdebug "Parsing pod info"
        current_revision=$(echo "${current_pods_output}" | jq -r '.status | select(.metadata.name=="'"${podname}"'").labels.revision')
        logdebug "Current revision: ${current_revision}"

        if [ "${expected_revision}" != "${current_revision}" ]; then
            # Check age of installer pod
            namespace=$(jq -r '.metadata.namespace' ${f})
            installer="installer-${expected_revision}-${SOSHOSTNAME}"
            installer_created=$(echo "${current_pods_output}" | jq -r '.status | select(.metadata.namespace=="'"${namespace}"'" and .metadata.name=="'"${installer}"'").createdAt')

            loginfo "Pod ${podname} revision change from ${current_revision} to ${expected_revision} in progress, started ${installer_created}"
            count=$((count+1))
        fi
    done

    if [ "${count}" -gt 0 ]; then
        logdebug "static pod container revision check failed"
    else
        logdebug "static pod container revision check healthy"
    fi

    return "${count}"
}

function usage {
    cat <<EOF
Usage: ${PROG}
Options:
    --dir | -d                    Directory with extracted sosreport
    --verbose | -v                Turn on debug logs

EOF
    exit 1
}

#
# Process cmdline arguments
#
if ! OPTS=$(getopt -o "hvd:" --long "help,verbose,dir:" --name "$0" -- "$@"); then
    usage
    exit 1
fi

eval set -- "${OPTS}"

while :; do
    case "$1" in
        -v|--verbose)
            verbose="yes"
            shift
            ;;
        -d|--dir)
            sosreportdir="${2}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [ ! -d "${sosreportdir}/sos_commands" ]; then
    echo "Could not find ${sosreportdir}/sos_commands directory" >&2
    exit 1
fi

SOSHOSTNAME=$(cat "${sosreportdir}"/sos_commands/host/hostname)

#
# Run health check
#

echo "##########################################"
echo "Checking sosreportdir=${sosreportdir}"
echo
echo "Running container health check:"
if check_static_pod_container_health; then
    loginfo "Container health check passed"
else
    loginfo "Container health check failed"
fi
echo

echo "Running pod revision check:"
if check_static_pod_container_revision; then
    loginfo "Revision check passed"
else
    loginfo "Revision check failed"
fi

echo
echo "Date of sosreport: $(cat ${sosreportdir}/date)"
echo "modification timestamp  of date file:" $(stat -c '%y' ${sosreportdir}/date)
