#!/bin/bash
#
# Periodically checks static pod container states.
# If unhealthy for a period of time, restart kubelet.service
#

PROG=$(basename "$0")

# Tag for logs in journald
declare logtag="static-pod-check-workaround"

# Debug logs
declare verbose="no"

# Log to stdout instead of journald
declare log_to_stdout="no"

# Location of static pod manifests
declare manifests_dir="/etc/kubernetes/manifests"

# Minimum time kubelet should be active before we check states
declare kubelet_up_minimum_secs=1200

# Time between checks when static pods are healthy
declare interval_healthy_secs=300

# Time between checks when static pods are unhealthy
declare interval_unhealthy_secs=30

# Number of failed health checks for a given pod before restarting kubelet
declare max_consecutive_failures=20

# For testing, force health check failure by creating this flag file
declare test_failure_flag_file=/tmp/force_static_pod_check_failure.flag

# For testing, allow dry-run to only log
declare dryrun="no"

# Associative array for tracking consecutive failures
declare -A health_failures

#
# Logging functions
#
function loginfo {
    if [ "${log_to_stdout}" = "no" ]; then
        logger -t "${logtag}" --id=$BASHPID "$1"
    else
        echo "$(date): $1"
    fi
}

function logdebug {
    if [ "${verbose}" = "no" ]; then
        return
    fi

    if [ "${log_to_stdout}" = "no" ]; then
        logger -t "${logtag}" --id=$BASHPID "$1"
    else
        echo "$(date): $1"
    fi
}

#
# Verify kubelet has been running for at least kubelet_up_minimum_secs seconds
#
function kubelet_running {
    if ! systemctl -q is-active kubelet.service ; then
        logdebug "kubelet.service is not active"
        return 1
    fi

    local kubelet_start_time
    local kubelet_start_time_secs
    local secs_since_start

    kubelet_start_time=$(systemctl show kubelet.service --property ActiveEnterTimestamp --value)
    kubelet_start_time_secs=$(date --date="${kubelet_start_time}" +%s)
    secs_since_start=$(($(date +%s)-kubelet_start_time_secs))

    if [ "${secs_since_start}" -lt "${kubelet_up_minimum_secs}" ]; then
        logdebug "kubelet.service running only ${secs_since_start} seconds (minimum ${kubelet_up_minimum_secs})"
        return 1
    fi

    return 0
}

#
# Verify that each container in configured static pods are in a running state
#
function check_static_pod_container_health {
    local current_ps_output
    local f
    local name
    local state
    local failures=0

    current_ps_output=$(crictl ps -o json 2>/dev/null)
    for f in "${manifests_dir}"/*.yaml ; do
        if [ ! -f "${f}" ]; then
            loginfo "Static pod manifest not found: ${manifests_dir}"
            continue
        fi

        # Get container state of system-node-critical pods
        for name in $(jq -r 'select(.spec.priorityClassName=="system-node-critical") | .spec.containers[].name' $f); do
            state=$(echo "${current_ps_output}" | jq -r --arg name "${name}" '.containers[] | select(.metadata.name==$name).state')
            if [ "${state}" != "CONTAINER_RUNNING" ]; then
                if [ -z "${state}" ]; then
                    loginfo "${name} is not found in crictl ps output"
                else
                    loginfo "${name} is not running: state=${state}"
                fi

                failures=$((failures+1))
                health_failures["${name}"]=$((${health_failures["${name}"]}+1))
                break
            else
                health_failures["${name}"]=0
            fi
        done
    done

    if [ -f "${test_failure_flag_file}" ]; then
        local testname
        # shellcheck disable=SC2013
        for testname in $(cat "${test_failure_flag_file}"); do
            health_failures["${testname}"]=$((${health_failures["${testname}"]}+1))
            failures=$((failures+1))
            loginfo "Testing failure with ${test_failure_flag_file} presence: ${testname}: ${health_failures[${testname}]}"
        done
    fi

    return "${failures}"
}

#
# Check health_failures array to see if any pods have reached maximum consecutive failures
#
function check_health_failures {
    local name
    local rc=0
    for name in "${!health_failures[@]}"; do
        if [ "${health_failures[${name}]}" -ge "${max_consecutive_failures}" ]; then
            loginfo "${name} has reached maximum consecutive failures (${health_failures[${name}]}"
            rc=$((rc+1))
        fi
    done

    return "${rc}"
}

#
# Run the container pod check, with limited retries in failure scenario
#
function run_check {
    while ! check_static_pod_container_health; do
        if ! check_health_failures; then
            loginfo "static pod containers unhealthy for too long"
            return 1
        fi

        sleep "${interval_unhealthy_secs}"
    done

    # Reset health_failures
    health_failures=()

    logdebug "static pod containers healthy"
    return 0
}

#
# Usage
#
function usage {
    cat <<EOF
Usage: ${PROG}
Options:
    --dryrun | -n                 Dry run (don't restart kubelet, log only)
    --verbose | -v                Turn on debug logs
    --log-to-stdout               Log to stdout instead of journald
    --manifests-dir | -m          Location of static pod manifests (default: /etc/kubernetes/manifests)
    --kubelet-up-minimum <secs>   Minimum time, in seconds, kubelet must be active
                                  before allowing health checks to run (default: 1200)
    --healthy-interval <secs>     Interval between checks, in seconds, when static
                                  pods are healthy (default: 300)
    --unhealthy-interval <secs>   Interval between checks, in seconds, when static
                                  pods are unhealthy (default: 30)
    --max-failures <int>          Maximum consecutive health check failures for any given pod
                                  before restarting kubelet (default: 20)
EOF
    exit 1
}

#
# Process cmdline arguments
#

longopts=(
    "help"
    "dryrun"
    "verbose"
    "log-to-stdout"
    "manifests-dir:"
    "kubelet-up-minimum:"
    "healthy-interval:"
    "unhealthy-interval:"
    "max-failures:"
)

longopts_str=$(IFS=,; echo "${longopts[*]}")

if ! OPTS=$(getopt -o "hvnm:" --long "${longopts_str}" --name "$0" -- "$@"); then
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
        -n|--dryrun)
            dryrun="yes"
            shift
            ;;
        --log-to-stdout)
            log_to_stdout="yes"
            shift
            ;;
        -m|--manifests-dir)
            manifests_dir="${2}"
            shift 2
            ;;
        --kubelet-up-minimum)
            kubelet_up_minimum_secs="${2}"
            shift 2
            ;;
        --healthy-interval)
            interval_healthy_secs="${2}"
            shift 2
            ;;
        --unhealthy-interval)
            interval_unhealthy_secs="${2}"
            shift 2
            ;;
        --max-failures)
            max_consecutive_failures="${2}"
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

#
# Run health check
#
while :; do
    if kubelet_running && ! run_check ; then
        if [ "${dryrun}" = "no" ]; then
            loginfo "Restarting kubelet.service"
            systemctl stop kubelet.service
            systemctl start kubelet.service
        else
            loginfo "Health check failed (dryrun only, not restarting kubelet)"
        fi

        # Reset health_failures
        health_failures=()
    fi

    sleep "${interval_healthy_secs}"
done

