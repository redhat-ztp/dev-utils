#!/bin/bash
#
# Utility script for running IBU over and over in a loop, until it hits an upgrade failure.
#

function usage {
    cat <<EOF >&2
Options:
    -k|--ssh-key <ssh-key>      Specify ssh key to use for ssh to SNO
    -n|--node    <node>         Specify SNO hostname - nu default, uses "oc get node" info
    -r|--rollout                Halt if a rollout is detected
EOF
    exit 1
}

function duration {
    local total=$1
    echo "$((total/60)):$((total%60))"
}

function display_summary {
    if [ ${upgrades_completed} -eq 0 ]; then
        echo "Exiting with no completed upgrades"
        return
    fi

    w_reboot_high=$(duration $upgrade_duration_high)
    w_reboot_low=$(duration $upgrade_duration_low)
    w_reboot_average=$(duration $((upgrade_duration_total/upgrades_completed)))

    wo_reboot_high=$(duration $upgrade_duration_since_init_high)
    wo_reboot_low=$(duration $upgrade_duration_since_init_low)
    wo_reboot_average=$(duration $((upgrade_duration_since_init_total/upgrades_completed)))

    just_reboot_high=$(duration $reboot_duration_high)
    just_reboot_low=$(duration $reboot_duration_low)
    just_reboot_average=$(duration $((reboot_duration_total/upgrades_completed)))

    cat <<EOF
#########################################################
Summary:

Upgrades completed: ${upgrades_completed}
Upgrades with static pod revision rollouts: ${completed_with_rollouts}

Upgrade stage completion times, including reboot:
    High:    ${w_reboot_high}
    Low:     ${w_reboot_low}
    Average: ${w_reboot_average}

Upgrade stage completion times, from cluster init:
    High:    ${wo_reboot_high}
    Low:     ${wo_reboot_low}
    Average: ${wo_reboot_average}

Reboot times, from Upgrade trigger to cluster init:
    High:    ${just_reboot_high}
    Low:     ${just_reboot_low}
    Average: ${just_reboot_average}

EOF
}

trap display_summary EXIT

function log_with_pass_counter {
    echo "### $(date): Pass ${counter}: $*"
}

#
# SSH to the SNO to pull the seed image and collect information
#
function getSeedInfo {
    local imgmnt

    echo "### $(date): Getting seed information"
    SEEDIMG=$(oc get ibu upgrade -o jsonpath='{.spec.seedImageRef.image}')
    if [ -z "${SEEDIMG}" ]; then
        echo "Failed to get seed image ref" >&2
        exit 1
    fi

    echo "### $(date): Pulling seed image"
    ${SSH_CMD} "sudo podman pull ${SEEDIMG}"
    if [ $? -ne 0 ]; then
        echo "Failed to pull image" >&2
        exit 1
    fi

    imgmnt=$(${SSH_CMD} "sudo podman image mount ${SEEDIMG}")
    if [ -z "${imgmnt}" ]; then
        echo "Failed to mount image" >&2
        exit 1
    fi

    # Get the current static pod revisions, for use in checking for rollouts
    SEED_REVISIONS=$(${SSH_CMD} "sudo tar xzf ${imgmnt}/etc.tgz -O 'etc/kubernetes/manifests/*-pod.yaml' | jq -c '.metadata.labels | {app,revision}' | sort")
    if [ -z "${SEED_REVISIONS}" ]; then
        echo "Failed to collect static pod revision info" >&2
        exit 1
    fi

    ${SSH_CMD} "sudo podman image unmount ${SEEDIMG}"
    ${SSH_CMD} "sudo podman rmi ${SEEDIMG}"
    echo "### $(date): Seed info collected"
    echo "${SEED_REVISIONS}" | jq
}

#
# Get the current timestamp from the cluster
#
function current_timestamp {
    local t
    for ((i=0;i<5;i++)); do
        t=$(${SSH_CMD} "date +%s")
        if [ ${t} -gt 0 ]; then
            echo ${t}
            return
        fi

        log_with_pass_counter "WARNING: Failed to connect to cluster" >&2
        sleep 1
    done
}

#
# Get the init timestamp from the cluster
#
function init_timestamp {
    local t
    for ((i=0;i<5;i++)); do
        t=$(${SSH_CMD} "stat -c %Z /proc")
        if [ ${t} -gt 0 ]; then
            echo ${t}
            return
        fi

        log_with_pass_counter "WARNING: Failed to connect to cluster" >&2
        sleep 1
    done
}

#
# Get the UpgradeComplete transition time
#
function completion_timestamp {
    date -d "$(getCondition UpgradeCompleted lastTransitionTime)" +%s
}

#
# SSH to the node to get the current static pod revisions from the cluster
#
function getClusterRevisions {
    CLUSTER_REVISIONS=$(${SSH_CMD} "sudo jq -c '.metadata.labels | {app,revision}' /etc/kubernetes/manifests/*-pod.yaml | sort")
    if [ -z "${CLUSTER_REVISIONS}" ]; then
        log_with_pass_counter "Failed to collect static pod revision info" >&2
        exit 1
    fi

    if [ "${CLUSTER_REVISIONS}" = "${SEED_REVISIONS}" ]; then
        log_with_pass_counter "No static pod revision updates"
        return 0
    else
        log_with_pass_counter "Static pod revision update detected"
        echo ${SEED_REVISIONS} | jq -r '.app' | while read -r app; do
            seedrev=$(echo "${SEED_REVISIONS}" | jq -r --arg app "${app}" 'select(.app == $app) | .revision')
            clusterrev=$(echo "${CLUSTER_REVISIONS}" | jq -r --arg app "${app}" 'select(.app == $app) | .revision')
            if [ "${seedrev}" != "${clusterrev}" ]; then
                log_with_pass_counter "Static pod ${app} at revision ${seedrev} in seed image, now at ${clusterrev}"
            fi
        done
        return 1
    fi
}

#
# Get the IBU condition
#
function getCondition {
    local ctype="$1"
    local field="$2"
    echo "${json}" | jq -r --arg ctype "${ctype}" --arg field "${field}" '.status.conditions[] | select(.type==$ctype)[$field]'
}

#
# Patch the IBU with Prep and Upgrade stages to trigger an upgrade
#
function kickUpgrade {
    oc patch imagebasedupgrades.lca.openshift.io upgrade -p='{"spec": {"stage": "Prep"}}' --type=merge && \
        oc wait --for=condition=PrepCompleted ibu upgrade --timeout=1200s
    local rc=$?
    if [ $rc -ne 0 ]; then
        return $rc
    fi

    # Get the current timestamp from the cluster
    upgrade_triggered_timestamp=$(current_timestamp)

    oc patch imagebasedupgrades.lca.openshift.io upgrade -p='{"spec": {"stage": "Upgrade"}}' --type=merge
}

#
# Patch the IBU to set stage to Rollback
#
function kickRollback {
    oc patch imagebasedupgrades.lca.openshift.io upgrade -p='{"spec": {"stage": "Rollback"}}' --type=merge
}

#
# Patch the IBU to set stage back to Idle
#
function kickIdle {
    oc patch imagebasedupgrades.lca.openshift.io upgrade -p='{"spec": {"stage": "Idle"}}' --type=merge
}

#
# Wait for the IBU to report that the upgrade has either completed successfully or failed
#
function waitForUpgradeFinish {
    local json=
    while :; do
        sleep 10
        json=$(oc get ibu upgrade -o json 2>/dev/null)
        upgreason=$(getCondition UpgradeCompleted reason)
        if [ "${upgreason}" = "Failed" ]; then
            return 1
        elif [ "${upgreason}" = "Completed" ]; then
            break
        fi
    done

    # Collect timestamps
    cluster_init_timestamp=$(init_timestamp)
    upgrade_completed_timestamp=$(completion_timestamp)
    upgrade_duration=$((upgrade_completed_timestamp-upgrade_triggered_timestamp))
    upgrade_duration_since_init=$((upgrade_completed_timestamp-cluster_init_timestamp))
    reboot_duration=$((cluster_init_timestamp-upgrade_triggered_timestamp))

    # Totals
    upgrade_duration_total=$((upgrade_duration_total+upgrade_duration))
    upgrade_duration_since_init_total=$((upgrade_duration_since_init_total+upgrade_duration_since_init))
    reboot_duration_total=$((reboot_duration_total+reboot_duration))

    # Record watermarks
    if [ ${upgrade_duration} -lt ${upgrade_duration_low} ]; then
        upgrade_duration_low=${upgrade_duration}
    fi

    if [ ${upgrade_duration} -gt ${upgrade_duration_high} ]; then
        upgrade_duration_high=${upgrade_duration}
    fi

    if [ ${upgrade_duration_since_init} -lt ${upgrade_duration_since_init_low} ]; then
        upgrade_duration_since_init_low=${upgrade_duration_since_init}
    fi

    if [ ${upgrade_duration_since_init} -gt ${upgrade_duration_since_init_high} ]; then
        upgrade_duration_since_init_high=${upgrade_duration_since_init}
    fi

    if [ ${reboot_duration} -lt ${reboot_duration_low} ]; then
        reboot_duration_low=${reboot_duration}
    fi

    if [ ${reboot_duration} -gt ${reboot_duration_high} ]; then
        reboot_duration_high=${reboot_duration}
    fi

    log_with_pass_counter "Duration: $(duration upgrade_duration)"
    log_with_pass_counter "Duration: $(duration upgrade_duration_since_init) (from cluster init)"
    log_with_pass_counter "Reboot:   $(duration reboot_duration)"

    return 0
}

#
# Wait for the rollback to complete
#
function waitForRollbackFinish {
    local json=
    while :; do
        sleep 10
        json=$(oc get ibu upgrade -o json 2>/dev/null)
        upgreason=$(getCondition RollbackCompleted reason)
        if [ "${upgreason}" = "Completed" ]; then
            return 0
        fi
    done
}

#
# Wait for the transition back to idle to complete
#
function waitForIdleFinish {
    local json=
    while :; do
        sleep 10
        json=$(oc get ibu upgrade -o json 2>/dev/null)
        upgreason=$(getCondition Idle reason)
        if [ "${upgreason}" = "Idle" ]; then
            return 0
        fi
    done
}

#
# Check to see if the SRIOV workaround was needed
#
function checkForSriovKick {
    oc get sriovnetworknodepolicies.sriovnetwork.openshift.io -n openshift-sriov-network-operator default -o jsonpath='{.metadata.annotations}{"\n"}' 2>/dev/null \
        | grep kick-reconciler
}

#
# Process cmdline arguments
#
declare SSH_KEY_ARG=
declare SSH_HOST=
declare HALT_ON_ROLLOUT=no
declare SSH_CMD=
declare SEEDIMG=
declare SEED_REVISIONS=

LONGOPTS="help,ssh-key:,node:,rollout"
OPTS=$(getopt -o "hk:n:r" --long "${LONGOPTS}" --name "$0" -- "$@")

if [ $? -ne 0 ]; then
    usage
    exit 1
fi

eval set -- "${OPTS}"

while :; do
    case "$1" in
        -k|--ssh-key)
            SSH_KEY_ARG="-i $2"
            shift 2
            ;;
        -n|--node)
            SSH_HOST=$2
            shift 2
            ;;
        -r|--rollout)
            HALT_ON_ROLLOUT=yes
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "${SSH_HOST}" ]; then
    SSH_HOST=$(oc get node -o json | jq -r 'first(.items[] | .status.addresses[] | select(.type == "Hostname") | .address)')
    if [ -z "${SSH_HOST}" ]; then
        echo "Unable to determine hostname" >&2
        exit 1
    fi
fi

SSH_CMD="ssh -q ${SSH_KEY_ARG} -o StrictHostKeyChecking=no core@${SSH_HOST}"

#
# Data collection variables
#
declare -i counter=0
declare -i workarounds=0
declare -i rollouts=0
declare -i upgrades_completed=0
declare -i completed_with_rollouts=0

declare -i upgrade_triggered_timestamp=0
declare -i cluster_init_timestamp=0
declare -i upgrade_completed_timestamp=0
declare -i upgrade_duration=0
declare -i upgrade_duration_low=999999999999
declare -i upgrade_duration_high=0
declare -i upgrade_duration_total=0
declare -i upgrade_duration_since_init=0
declare -i upgrade_duration_since_init_low=999999999999
declare -i upgrade_duration_since_init_high=0
declare -i upgrade_duration_since_init_total=0
declare -i reboot_duration=0
declare -i reboot_duration_low=999999999999
declare -i reboot_duration_high=0
declare -i reboot_duration_total=0

# Collect the seed info to get the expected static pod revisions
getSeedInfo

#
# Run IBU upgrades in a loop, until an upgrade fails
#
while :; do
    counter=$((counter+1))
    log_with_pass_counter "Triggering upgrade"
    kickUpgrade
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Failed."
        exit 1
    fi

    log_with_pass_counter "Waiting for upgrade to finish"
    waitForUpgradeFinish
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Upgrade failed"
        exit 0
    fi

    log_with_pass_counter "Upgrade successful. Checking for SRIOV workaround"
    checkForSriovKick
    if [ $? -eq 0 ]; then
        log_with_pass_counter "Annotation found"
        workarounds=$((workarounds+1))
    else
        log_with_pass_counter "Workaround was not required"
    fi

    log_with_pass_counter "Checking for revisions"
    getClusterRevisions
    if [ $? -eq 1 ]; then
        rollouts=$((rollouts+1))
        if [ "${HALT_ON_ROLLOUT}" = "yes" ]; then
            log_with_pass_counter "Halting due to rollout detection."
            exit 1
        fi
    fi

    log_with_pass_counter "Triggering rollback"
    kickRollback
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Failed."
        exit 1
    fi

    log_with_pass_counter "Waiting for rollback to finish"
    waitForRollbackFinish
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Failed."
        exit 1
    fi

    log_with_pass_counter "Rollback successful. Triggering cleanup"
    kickIdle
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Failed."
        exit 1
    fi

    log_with_pass_counter "Waiting for finalize to finish"
    waitForIdleFinish
    if [ $? -ne 0 ]; then
        log_with_pass_counter "Failed."
        exit 1
    fi

    upgrades_completed=${counter}
    completed_with_rollouts=${rollouts}

    log_with_pass_counter "Waiting to start next loop"
    log_with_pass_counter "SRIOV workaround was needed ${workarounds} loop(s) so far"
    log_with_pass_counter "Static pod rollouts occurred during ${rollouts} loop(s) so far"
    sleep 10
done

exit 0

