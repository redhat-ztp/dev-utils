#!/bin/bash
#
# Utility script for running IBU over and over in a loop, until it hits an upgrade failure.
#

PROG=$(basename "$0")

function usage {
    cat <<EOF >&2
${PROG}:
IBU test tool that loops over running upgrades, until a failure is reached, or specified limits.
Each pass will run through Prep, Upgrade, Rollback, and back to Idle.

Options:
    -k|--ssh-key <ssh-key>      Specify ssh key to use for ssh to SNO
    -n|--node    <node>         Specify SNO hostname - nu default, uses "oc get node" info
    -r|--rollout                Halt if a rollout is detected
    --sriov                     Halt if SRIOV workaround is detected
    -m|--max-loops <integer>    Maximum number of upgrade loops to run
    --hours <integer>           Halt once completed loop has exceeded overall time specified
    -i|--ignore-reboots         Don't halt if additional reboots were detected

Examples:
    # To run loops for (just over) 24 hours, ignoring additional reboot detection
    ${PROG} --hours 24 --ignore-reboots

    # To run loops forever until a rollout is detected, or interrupted
    ${PROG} --rollout

    # To run up to 3 loops
    ${PROG} --max-loops 3

EOF
    exit 1
}

function systemCheck {
    log_without_pass_counter "Running initial system checks"

    if [ -z "${KUBECONFIG}" ]; then
        echo "KUBECONFIG not set" >&2
        exit 1
    fi

    local deployment=
    deployment=$(oc get -n openshift-lifecycle-agent deployments.apps lifecycle-agent-controller-manager -o json)
    if [ -z "${deployment}" ]; then
        echo "Unable to get LCA deployment info" >&2
        exit 1
    fi

    local lcaAvailable=
    lcaAvailable=$(echo "${deployment}" | jq -r '.status.conditions[] | select(.type == "Available") | .status')
    if [ "${lcaAvailable}" != "True" ]; then
        echo "LCA deployment is not available" >&2
        exit 1
    fi

    CLUSTER_LCA_IMAGE=$(echo "${deployment}" | jq -r '.spec.template.spec.containers[] | select(.name == "manager") | .image')
    if [ -z "${CLUSTER_LCA_IMAGE}" ]; then
        echo "Unable to determine LCA image" >&2
        exit 1
    fi

    local ibu=
    ibu=$(oc get ibu upgrade -o json)
    if [ -z "${ibu}" ]; then
        echo "Unable to retrieve IBU CR" >&2
        exit 1
    fi

    local ibuImage=
    local ibuVersion=
    local ibuStage=
    local ibuIdleReason=

    ibuImage=$(echo "${ibu}" | jq -r '.spec.seedImageRef.image')
    if [ -z "${ibuImage}" ] || [ "${ibuImage}" = "null" ]; then
        echo "IBU CR .spec.seedImageRef.image is not set" >&2
        exit 1
    fi

    ibuVersion=$(echo "${ibu}" | jq -r '.spec.seedImageRef.version')
    if [ -z "${ibuVersion}" ] || [ "${ibuVersion}" = "null" ]; then
        echo "IBU CR .spec.seedImageRef.version is not set" >&2
        exit 1
    fi

    ibuStage=$(echo "${ibu}" | jq -r '.spec.stage')
    if [ "${ibuStage}" != "Idle" ]; then
        echo "IBU CR must be in Idle stage" >&2
        exit 1
    fi

    ibuIdleReason=$(getCondition Idle reason)
    if [ "${ibuIdleReason}" != "Idle" ]; then
        echo "IBU CR must be Idle" >&2
        exit 1
    fi

    if ! healthCheck; then
        echo "Ensure system is in healthy state" >&2
        exit 1
    fi

    CLUSTER_VERSION=$(oc get clusterversions.config.openshift.io version -o jsonpath='{.status.desired.version}')
    if [ -z "${CLUSTER_VERSION}" ]; then
        echo "Unable to determine cluster version" >&2
        exit 1
    fi
}

function duration {
    local total=$1
    local hours=
    local mins=
    local secs=

    hours=$((total/3600))
    mins=$((total/60%60))
    secs=$((total%60))

    if [ "${hours}" -ne 0 ]; then
        printf "%d:%02d:%02d" "${hours}" "${mins}" "${secs}"
    else
        printf "%d:%02d" "${mins}" "${secs}"
    fi
}

function printWaterMarks {
    local high="$1"
    local low="$2"
    local average="$3"

    printf "    %s: %7s  |  %s: %7s  |  %s: %7s\n" "High" "${high}" "Low" "${low}" "Average" "${average}"
}

function display_summary {
    if [ ${upgrades_completed:-0} -eq 0 ]; then
        if [ -n "${halt_reason}" ]; then
            echo "Execution halted due to: ${halt_reason}"
        fi
        echo "Exiting with no completed upgrades"
        return
    fi

    cat <<EOF
#########################################################
Summary:

Starting cluster info:
    Version:      ${CLUSTER_VERSION}
    LCA Image:    ${CLUSTER_LCA_IMAGE}

Seed info:
    Image Name:   ${SEEDIMG}
    Version:      ${SEED_VERSION}
    LCA Image:    ${SEED_LCA_IMAGE}
    Recert Image: ${SEED_RECERT}

Upgrades completed: ${upgrades_completed}

Upgrades with static pod revision rollouts: ${rollouts} in ${counter} loop(s)
Upgrades with additional reboots detected:  ${reboots} in ${counter} loop(s)

EOF
    if [ $upgrades_completed_wo_reboots -gt 0 ]; then
        w_reboot_high=$(duration ${upgrade_duration_high})
        w_reboot_low=$(duration ${upgrade_duration_low})
        w_reboot_average=$(duration $((upgrade_duration_total/upgrades_completed_wo_reboots)))

        wo_reboot_high=$(duration ${upgrade_duration_since_init_high})
        wo_reboot_low=$(duration ${upgrade_duration_since_init_low})
        wo_reboot_average=$(duration $((upgrade_duration_since_init_total/upgrades_completed_wo_reboots)))

        just_reboot_high=$(duration ${upgrade_reboot_duration_high})
        just_reboot_low=$(duration ${upgrade_reboot_duration_low})
        just_reboot_average=$(duration $((upgrade_reboot_duration_total/upgrades_completed_wo_reboots)))

        cat <<EOF
Upgrade timing information, excluding loops where additional reboots were detected:

- Upgrade stage completion times, including reboot:
$(printWaterMarks "${w_reboot_high}" "${w_reboot_low}" "${w_reboot_average}")

- Upgrade stage completion times, from cluster init:
$(printWaterMarks "${wo_reboot_high}" "${wo_reboot_low}" "${wo_reboot_average}")

- Reboot times, from Upgrade trigger to cluster init:
$(printWaterMarks "${just_reboot_high}" "${just_reboot_low}" "${just_reboot_average}")

EOF
    fi

    if [ $rollbacks_completed -gt 0 ]; then
        w_reboot_high=$(duration ${rollback_duration_high})
        w_reboot_low=$(duration ${rollback_duration_low})
        w_reboot_average=$(duration $((rollback_duration_total/rollbacks_completed)))

        wo_reboot_high=$(duration ${rollback_duration_since_init_high})
        wo_reboot_low=$(duration ${rollback_duration_since_init_low})
        wo_reboot_average=$(duration $((rollback_duration_since_init_total/rollbacks_completed)))

        just_reboot_high=$(duration ${rollback_reboot_duration_high})
        just_reboot_low=$(duration ${rollback_reboot_duration_low})
        just_reboot_average=$(duration $((rollback_reboot_duration_total/rollbacks_completed)))

        cat <<EOF
Rollback timing information (including system health checks):

- Rollback stage completion times, including reboot:
$(printWaterMarks "${w_reboot_high}" "${w_reboot_low}" "${w_reboot_average}")

- Rollback stage completion times, from cluster init:
$(printWaterMarks "${wo_reboot_high}" "${wo_reboot_low}" "${wo_reboot_average}")

- Reboot times, from Rollback  trigger to cluster init:
$(printWaterMarks "${just_reboot_high}" "${just_reboot_low}" "${just_reboot_average}")

EOF
    fi

    if [ -n "${halt_reason}" ]; then
        echo "Execution halted due to: ${halt_reason}"
        echo
    fi

    echo "Total execution duration: $(duration $((SECONDS-START_SECONDS)))"
    echo
}

trap display_summary EXIT

function log_with_pass_counter {
    echo "### $(date): Pass ${counter}: $*"
}

function log_without_pass_counter {
    echo "### $(date): $*"
}

#
# SSH to the SNO to pull the seed image and collect information
#
function getSeedInfo {
    local imgmnt

    log_without_pass_counter "Getting seed information"
    SEEDIMG=$(oc get ibu upgrade -o jsonpath='{.spec.seedImageRef.image}')
    if [ -z "${SEEDIMG}" ]; then
        echo "Failed to get seed image ref" >&2
        exit 1
    fi

    log_without_pass_counter "Pulling seed image"
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

    local manifest=
    manifest=$(${SSH_CMD} "sudo cat ${imgmnt}/manifest.json")

    SEED_VERSION=$(echo "${manifest}" | jq -r '.seed_cluster_ocp_version')
    SEED_RECERT=$(echo "${manifest}" | jq -r '.recert_image_pull_spec')

    ${SSH_CMD} "sudo podman image unmount ${SEEDIMG}"
    ${SSH_CMD} "sudo podman rmi ${SEEDIMG}"
    log_without_pass_counter "Seed info collected"
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
function clusterInitTimestamp {
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
# Get the transition time for the specified condition
#
function conditionTransitionTimestamp {
    local condition="$1"
    date -d "$(getCondition ${condition} lastTransitionTime)" +%s
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

    oc get ibu upgrade -o json 2>/dev/null | jq -r --arg ctype "${ctype}" --arg field "${field}" '.status.conditions[] | select(.type==$ctype)[$field]'
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
    # Get the current timestamp from the cluster
    rollback_triggered_timestamp=$(current_timestamp)

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
    while :; do
        sleep 10
        upgreason=$(getCondition UpgradeCompleted reason)
        if [ "${upgreason}" = "Failed" ]; then
            return 1
        elif [ "${upgreason}" = "Completed" ]; then
            break
        fi
    done

    local seed_lca_image=
    seed_lca_image=$(oc get -n openshift-lifecycle-agent deployments.apps lifecycle-agent-controller-manager -o json \
        | jq -r '.spec.template.spec.containers[] | select(.name == "manager") | .image')
    if [ -n "${seed_lca_image}" ]; then
        SEED_LCA_IMAGE="${seed_lca_image}"
    else
        echo "Unable to determine running LCA image" >&2
    fi
}

#
# Collect timestamps after the upgrade completed. If reboots were detected, skip updating the watermarks
#
function collectUpgradeTimestamps {
    local reboots_detected=$1

    # Collect timestamps
    upgrade_cluster_init_timestamp=$(clusterInitTimestamp)
    upgrade_completed_timestamp=$(conditionTransitionTimestamp UpgradeCompleted)
    upgrade_duration=$((upgrade_completed_timestamp-upgrade_triggered_timestamp))
    upgrade_duration_since_init=$((upgrade_completed_timestamp-upgrade_cluster_init_timestamp))
    upgrade_reboot_duration=$((upgrade_cluster_init_timestamp-upgrade_triggered_timestamp))

    log_with_pass_counter "Upgrade Duration: $(duration ${upgrade_duration})"
    log_with_pass_counter "Upgrade Duration: $(duration ${upgrade_duration_since_init}) (from cluster init)"
    log_with_pass_counter "Upgrade Reboot:   $(duration ${upgrade_reboot_duration})"

    if [ ${reboots_detected} -ne 0 ]; then
        # Return before updating watermarks
        return
    fi

    # Totals
    upgrade_duration_total=$((upgrade_duration_total+upgrade_duration))
    upgrade_duration_since_init_total=$((upgrade_duration_since_init_total+upgrade_duration_since_init))
    upgrade_reboot_duration_total=$((upgrade_reboot_duration_total+upgrade_reboot_duration))

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

    if [ ${upgrade_reboot_duration} -lt ${upgrade_reboot_duration_low} ]; then
        upgrade_reboot_duration_low=${upgrade_reboot_duration}
    fi

    if [ ${upgrade_reboot_duration} -gt ${upgrade_reboot_duration_high} ]; then
        upgrade_reboot_duration_high=${upgrade_reboot_duration}
    fi

    upgrades_completed_wo_reboots=$((upgrades_completed_wo_reboots+1))
}

#
# Collect timestamps after the rollback completed.
#
function collectRollbackTimestamps {
    # Collect timestamps
    rollback_cluster_init_timestamp=$(clusterInitTimestamp)
    rollback_completed_timestamp=$(conditionTransitionTimestamp RollbackCompleted)
    rollback_duration=$((rollback_completed_timestamp-rollback_triggered_timestamp))
    rollback_duration_since_init=$((rollback_completed_timestamp-rollback_cluster_init_timestamp))
    rollback_reboot_duration=$((rollback_cluster_init_timestamp-rollback_triggered_timestamp))

    log_with_pass_counter "Rollback Duration: $(duration ${rollback_duration})"
    log_with_pass_counter "Rollback Duration: $(duration ${rollback_duration_since_init}) (from cluster init)"
    log_with_pass_counter "Rollback Reboot:   $(duration ${rollback_reboot_duration})"

    # Totals
    rollback_duration_total=$((rollback_duration_total+rollback_duration))
    rollback_duration_since_init_total=$((rollback_duration_since_init_total+rollback_duration_since_init))
    rollback_reboot_duration_total=$((rollback_reboot_duration_total+rollback_reboot_duration))

    # Record watermarks
    if [ ${rollback_duration} -lt ${rollback_duration_low} ]; then
        rollback_duration_low=${rollback_duration}
    fi

    if [ ${rollback_duration} -gt ${rollback_duration_high} ]; then
        rollback_duration_high=${rollback_duration}
    fi

    if [ ${rollback_duration_since_init} -lt ${rollback_duration_since_init_low} ]; then
        rollback_duration_since_init_low=${rollback_duration_since_init}
    fi

    if [ ${rollback_duration_since_init} -gt ${rollback_duration_since_init_high} ]; then
        rollback_duration_since_init_high=${rollback_duration_since_init}
    fi

    if [ ${rollback_reboot_duration} -lt ${rollback_reboot_duration_low} ]; then
        rollback_reboot_duration_low=${rollback_reboot_duration}
    fi

    if [ ${rollback_reboot_duration} -gt ${rollback_reboot_duration_high} ]; then
        rollback_reboot_duration_high=${rollback_reboot_duration}
    fi

    rollbacks_completed=$((rollbacks_completed+1))
}

#
# Wait for the rollback to complete
#
function waitForRollbackFinish {
    local reason=
    while :; do
        sleep 10
        reason=$(getCondition RollbackCompleted reason)
        if [ "${reason}" = "Completed" ]; then
            return 0
        fi
    done
}

#
# Wait for the transition back to idle to complete
#
function waitForIdleFinish {
    local reason=
    while :; do
        sleep 10
        reason=$(getCondition Idle reason)
        if [ "${reason}" = "Idle" ]; then
            return 0
        elif [ "${reason}" = "FinalizeFailed" ] || [ "${reason}" = "AbortFailed" ]; then
            log_with_pass_counter "Transition to Idle failed"
            return 1
        fi
    done
}

#
# Check to see if the SRIOV workaround was needed
#
function checkForSriovKick {
    oc get sriovnetworknodepolicies.sriovnetwork.openshift.io -n openshift-sriov-network-operator default -o jsonpath='{.metadata.annotations}{"\n"}' 2>/dev/null \
        | grep kick-reconciler
    if [ $? -ne 0 ]; then
        return 0
    fi

    # SRIOV workaround was detected
    return 1
}

#
# Check to see reboots occurred during upgrade
#
function checkForReboots {
    local count=
    for ((i=0;i<5;i++)); do
        count=$(${SSH_CMD} "last reboot | grep '^reboot' | grep -v 'still running' | wc -l")
        if [ -n "${count}" ]; then
            if [ "${count}" = "0" ]; then
                return 0
            else
                log_with_pass_counter "Additional reboots detected: ${count}"
                return 1
            fi
        fi

        log_with_pass_counter "WARNING: Failed to connect to cluster" >&2
        sleep 1
    done

    log_with_pass_counter "Failed to determine if additional reboots occurred" >&2
    exit 1
}

#
# System health check
#
function healthCheck {
    # Check CSRs
    oc get csr --no-headers --ignore-not-found | grep -q Pending
    if [ $? -eq 0 ]; then
        log_without_pass_counter "Health check: Pending CSRs are present"
        return 1
    fi

    # Check cluster operators
    local coAvailable=
    local coUnavailable=
    local co=

    coAvailable=$(oc get co -o json | jq -r '
        .items[]
        | select(.status.conditions[] | select((.type == "Available" and .status == "True")))
        | select(.status.conditions[] | select((.type == "Progressing" and .status == "False")))
        | select(.status.conditions[] | select((.type == "Degraded" and .status == "False")))
        | select(. != null) | .metadata.name')

    coUnavailable=$(oc get co -o json | jq -r '
        .items[]
        | del (
            select(.status.conditions[] | select((.type == "Available" and .status == "True")))
            | select(.status.conditions[] | select((.type == "Progressing" and .status == "False")))
            | select(.status.conditions[] | select((.type == "Degraded" and .status == "False")))
        )
        | select(. != null) | .metadata.name')

    if [ -n "${coUnavailable}" ]; then
        log_without_pass_counter "Health check: One or more cluster operators are not ready"
        for co in ${coUnavailable}; do
            log_without_pass_counter "Health check: - ${co}"
        done
        return 1
    fi

    if [ -z "${coAvailable}" ]; then
        log_without_pass_counter "Health check: Failed to get available cluster operator list"
        return 1
    fi

    # Check MCP
    local mcp=
    mcp=$(oc get mcp -o json | jq -r '
        .items[]
        | select(.status.conditions[] | select((.type == "Updated" and .status == "True")))
        | select(.status.conditions[] | select((.type == "Updating" and .status == "False")))
        | select(.status.conditions[] | select((.type == "Degraded" and .status == "False")))
        | .metadata.name' | sort | xargs echo)

    if [ "${mcp}" != "master worker" ]; then
        log_without_pass_counter "Health check: MCPs not ready"
        return 1
    fi

    return 0
}

#
# Run health checks until satisfied
#
function waitForSystemHealth {
    log_without_pass_counter "Waiting for system stability"
    while :; do

        if healthCheck; then
            log_without_pass_counter "System is healthy"
            return 0
        fi
        sleep 5
    done
}

#
# Process cmdline arguments
#
declare SSH_KEY_ARG=
declare SSH_HOST=
declare HALT_ON_SRIOV_WORKAROUND=no
declare HALT_ON_ROLLOUT=no
declare HALT_ON_REBOOT_DETECTED=yes
declare SSH_CMD=
declare SEEDIMG=
declare SEED_REVISIONS=
declare SEED_VERSION=
declare SEED_RECERT=
declare SEED_LCA_IMAGE=
declare CLUSTER_VERSION=
declare CLUSTER_LCA_IMAGE=
declare -i MAX_LOOPS=-1
declare -i FINISH_AFTER_SECONDS=0
declare -i FINISH_AFTER_HOURS_LIMIT=0
declare -i START_SECONDS=${SECONDS}

LONGOPTS="help,ssh-key:,node:,rollout,max-loops:,ignore-reboots,hours:,sriov"
OPTS=$(getopt -o "hk:n:rm:i" --long "${LONGOPTS}" --name "$0" -- "$@")

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
        --sriov)
            HALT_ON_SRIOV_WORKAROUND=yes
            shift
            ;;
        -i|--ignore-reboots)
            HALT_ON_REBOOT_DETECTED=no
            shift
            ;;
        -m|--max-loops)
            MAX_LOOPS=$2
            shift 2
            ;;
        --hours)
            FINISH_AFTER_HOURS_LIMIT=$2
            if [ ${FINISH_AFTER_HOURS_LIMIT} -le 0 ]; then
                echo "--hours must be positive integer" >&2
                exit 1
            fi

            FINISH_AFTER_SECONDS=$((FINISH_AFTER_HOURS_LIMIT*3600+START_SECONDS))
            shift 2
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

if [ ${MAX_LOOPS} -eq 0 ]; then
    usage
fi

#
# Check that the system is ready for running IBU
#
systemCheck

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
declare -i reboots=0
declare -i upgrades_completed=0
declare -i upgrades_completed_wo_reboots=0

declare -i upgrade_triggered_timestamp=0
declare -i upgrade_cluster_init_timestamp=0
declare -i upgrade_completed_timestamp=0
declare -i upgrade_duration=0
declare -i upgrade_duration_low=999999999999
declare -i upgrade_duration_high=0
declare -i upgrade_duration_total=0
declare -i upgrade_duration_since_init=0
declare -i upgrade_duration_since_init_low=999999999999
declare -i upgrade_duration_since_init_high=0
declare -i upgrade_duration_since_init_total=0
declare -i upgrade_reboot_duration=0
declare -i upgrade_reboot_duration_low=999999999999
declare -i upgrade_reboot_duration_high=0
declare -i upgrade_reboot_duration_total=0

declare -i rollback_triggered_timestamp=0
declare -i rollback_cluster_init_timestamp=0
declare -i rollback_completed_timestamp=0
declare -i rollback_duration=0
declare -i rollback_duration_low=999999999999
declare -i rollback_duration_high=0
declare -i rollback_duration_total=0
declare -i rollback_duration_since_init=0
declare -i rollback_duration_since_init_low=999999999999
declare -i rollback_duration_since_init_high=0
declare -i rollback_duration_since_init_total=0
declare -i rollback_reboot_duration=0
declare -i rollback_reboot_duration_low=999999999999
declare -i rollback_reboot_duration_high=0
declare -i rollback_reboot_duration_total=0

declare halt_reason=

# Wait for system health checks to pass before starting
waitForSystemHealth

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
        halt_reason="Failed to trigger upgrade"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    log_with_pass_counter "Waiting for upgrade to finish"
    waitForUpgradeFinish
    if [ $? -ne 0 ]; then
        halt_reason="Upgrade failed"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    log_with_pass_counter "Upgrade successful. Checking for SRIOV workaround"
    checkForSriovKick
    sriov_rc=$?
    if [ ${sriov_rc} -eq 1 ]; then
        log_with_pass_counter "Annotation found"
        workarounds=$((workarounds+1))
    else
        log_with_pass_counter "Workaround was not required"
    fi

    # For stats, perform all checks before determining if halt is required for user request
    log_with_pass_counter "Checking for revisions"
    getClusterRevisions
    rollout_check_rc=$?
    if [ ${rollout_check_rc} -eq 1 ]; then
        rollouts=$((rollouts+1))
    fi

    log_with_pass_counter "Checking for additional reboots"
    checkForReboots
    reboot_check_rc=$?
    if [ ${reboot_check_rc} -eq 1 ]; then
        reboots=$((reboots+1))
    fi

    collectUpgradeTimestamps ${reboot_check_rc}

    # Check for halt
    if [ ${sriov_rc} -eq 1 ] && [ "${HALT_ON_SRIOV_WORKAROUND}" = "yes" ]; then
        halt_reason="Halted due to detection of sriov workaround"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    if [ ${reboot_check_rc} -eq 1 ] && [ "${HALT_ON_REBOOT_DETECTED}" = "yes" ]; then
        halt_reason="Halted due to detection of additional reboots"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    if [ ${rollout_check_rc} -eq 1 ] && [ "${HALT_ON_ROLLOUT}" = "yes" ]; then
        halt_reason="Halt requested due to rollout detection"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    # Upgrade completed, without being halted. Continue with rollback to move to next loop
    #
    log_with_pass_counter "Triggering rollback"
    kickRollback
    if [ $? -ne 0 ]; then
        halt_reason="Failed to trigger rollback"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    log_with_pass_counter "Waiting for rollback to finish"
    waitForRollbackFinish
    if [ $? -ne 0 ]; then
        halt_reason="Rollback failed"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    log_with_pass_counter "Rollback successful"

    # Wait for system health checks to pass before continuing
    waitForSystemHealth

    collectRollbackTimestamps

    log_with_pass_counter "Setting stage back to Idle"
    kickIdle
    if [ $? -ne 0 ]; then
        halt_reason="Failed to trigger transition to Idle"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    log_with_pass_counter "Waiting for finalize to finish"
    waitForIdleFinish
    if [ $? -ne 0 ]; then
        halt_reason="Finalize failed"
        log_with_pass_counter "${halt_reason}"
        exit 1
    fi

    upgrades_completed=${counter}

    log_with_pass_counter "Waiting to start next loop"
    log_with_pass_counter "SRIOV workaround was needed ${workarounds} loop(s) so far"
    log_with_pass_counter "Static pod rollouts occurred during ${rollouts} loop(s) so far"
    log_with_pass_counter "Additional reboots detected during ${reboots} loop(s) so far"

    if [ ${MAX_LOOPS} -gt 0 ] && [ ${counter} -eq ${MAX_LOOPS} ]; then
        halt_reason="Maximum loops reached (${MAX_LOOPS})"
        exit 0
    fi

    if [ ${FINISH_AFTER_SECONDS} -gt 0 ] && [ ${FINISH_AFTER_SECONDS} -le ${SECONDS} ]; then
        total_duration=$(duration $((SECONDS-START_SECONDS)))
        halt_reason="Halting after ${total_duration} total, after requested ${FINISH_AFTER_HOURS_LIMIT} hour(s) limit"
        exit 0
    fi

    sleep 10
done

exit 0

