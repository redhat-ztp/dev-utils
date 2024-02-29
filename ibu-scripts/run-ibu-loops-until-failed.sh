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
# SSH to the node to get the current static pod revisions from the cluster
#
function getClusterRevisions {
    CLUSTER_REVISIONS=$(${SSH_CMD} "sudo jq -c '.metadata.labels | {app,revision}' /etc/kubernetes/manifests/*-pod.yaml | sort")
    if [ -z "${CLUSTER_REVISIONS}" ]; then
        echo "Failed to collect static pod revision info" >&2
        exit 1
    fi

    if [ "${CLUSTER_REVISIONS}" = "${SEED_REVISIONS}" ]; then
        echo "### $(date): Pass ${counter}: No static pod revision updates"
        return 0
    else
        echo "### $(date): Pass ${counter}: Static pod revision update detected"
        echo ${SEED_REVISIONS} | jq -r '.app' | while read -r app; do
            seedrev=$(echo "${SEED_REVISIONS}" | jq -r --arg app "${app}" 'select(.app == $app) | .revision')
            clusterrev=$(echo "${CLUSTER_REVISIONS}" | jq -r --arg app "${app}" 'select(.app == $app) | .revision')
            if [ "${seedrev}" != "${clusterrev}" ]; then
                echo "### $(date): Pass ${counter}: Static pod ${app} at revision ${seedrev} in seed image, now at ${clusterrev}"
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
        oc wait --for=condition=PrepCompleted ibu upgrade --timeout=1200s && \
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
            return 0
        elif [ "${upgreason}" = "Completed" ]; then
            return 1
        fi
    done
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

SSH_CMD="ssh -q ${SSH_KEY_ARG} core@${SSH_HOST}"

# Collect the seed info to get the expected static pod revisions
getSeedInfo

#
# Run IBU upgrades in a loop, until an upgrade fails
#
counter=0
workarounds=0
rollouts=0
while :; do
    counter=$((counter+1))
    echo "### $(date): Pass ${counter}: Triggering upgrade"
    kickUpgrade
    if [ $? -ne 0 ]; then
        echo "### $(date): Pass ${counter}: Failed."
        exit 1
    fi

    echo "### $(date): Pass ${counter}: Waiting for upgrade to finish"
    waitForUpgradeFinish
    if [ $? -eq 0 ]; then
        echo "### $(date): Pass ${counter}: Upgrade failed"
        exit 0
    fi

    echo "### $(date): Pass ${counter}: Upgrade successful. Checking for SRIOV workaround"
    checkForSriovKick
    if [ $? -eq 0 ]; then
        echo "### $(date): Pass ${counter}: Annotation found"
        workarounds=$((workarounds+1))
    else
        echo "### $(date): Pass ${counter}: Workaround was not required"
    fi

    echo "### $(date): Pass ${counter}: Checking for revisions"
    getClusterRevisions
    if [ $? -eq 1 ]; then
        rollouts=$((rollouts+1))
        if [ "${HALT_ON_ROLLOUT}" = "yes" ]; then
            echo "### $(date): Pass ${counter}: Halting due to rollout detection."
            exit 1
        fi
    fi

    echo "### $(date): Pass ${counter}: Triggering rollback"
    kickRollback
    if [ $? -ne 0 ]; then
        echo "### $(date): Pass ${counter}: Failed."
        exit 1
    fi

    echo "### $(date): Pass ${counter}: Waiting for rollback to finish"
    waitForRollbackFinish
    if [ $? -ne 0 ]; then
        echo "### $(date): Pass ${counter}: Failed."
        exit 1
    fi

    echo "### $(date): Pass ${counter}: Rollback successful. Triggering cleanup"
    kickIdle
    if [ $? -ne 0 ]; then
        echo "### $(date): Pass ${counter}: Failed."
        exit 1
    fi

    echo "### $(date): Pass ${counter}: Waiting for finalize to finish"
    waitForIdleFinish
    if [ $? -ne 0 ]; then
        echo "### $(date): Pass ${counter}: Failed."
        exit 1
    fi

    echo "### $(date): Pass ${counter}: Waiting to start next loop"
    echo "### $(date): Pass ${counter}: SRIOV workaround was needed ${workarounds} loop(s) so far"
    echo "### $(date): Pass ${counter}: Static pod rollouts occurred during ${rollouts} loop(s) so far"
    sleep 10
done

exit 0

