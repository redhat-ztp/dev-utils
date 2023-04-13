#!/bin/bash
#

SCRIPTDIR=$(dirname "$0")
WORKAROUND="static-pod-check-workaround.sh"
WORKAROUND_ENCODED="data:text/plain;charset=utf-8;base64,"$(base64 -w 0 "${SCRIPTDIR}/${WORKAROUND}")
NAME="static-pod-check-workaround"

#
# Add options to customize workaround arguments
#
WORKAROUND_OPTS=""

function generate_ignition_config {
    cat <<EOF
{
  "ignition": {
    "version": "3.2.0"
  },
  "systemd": {
    "units": [
      {
        "name": "${NAME}.service",
        "enabled": true,
        "contents": "[Unit]\nDescription=Check for stuck static pod revisions\nAfter=kubelet.service\n\n[Service]\nType=simple\nUser=root\n\nExecStart=/usr/local/bin/${NAME}.sh ${WORKAROUND_OPTS}\n\n[Install]\nWantedBy=multi-user.target\n"
      }
    ]
  },
  "storage": {
    "files": [
      {
        "overwrite": true,
        "path": "/usr/local/bin/${NAME}.sh",
        "mode": 0744,
        "user": {
          "name": "root"
        },
        "contents": {
          "source": "${WORKAROUND_ENCODED}"
        }
      }
    ]
  }
}
EOF
}

function generate_machine_config {
    local role=$1
    cat <<EOF
---
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: 99-${NAME}-${role}
  creationTimestamp:
  labels:
    machineconfiguration.openshift.io/role: ${role}
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: static-pod-check-workaround.service
        enabled: true
        contents: |
          [Unit]
          Description=Check for stuck static pod revisions
          After=kubelet.service

          [Service]
          Type=simple
          User=root
          ExecStart=/usr/local/bin/${NAME}.sh ${WORKAROUND_OPTS}

          [Install]
          WantedBy=multi-user.target
    storage:
      files:
      - overwrite: true
        path: "/usr/local/bin/static-pod-check-workaround.sh"
        mode: 0744
        user:
          name: root
        contents:
          source: "${WORKAROUND_ENCODED}"
EOF
}

function usage {
    cat <<EOF
Options:
    --override            Generate ignitionConfigOverride
    --mc                  Generate MachineConfig
    --opts "<options>"    Set of options to pass as arguments to static pod health check utility
EOF
    exit 1
}

#
# Process cmdline arguments
#
if ! OPTS=$(getopt -o "ho:" --long "help,override,opts:,mc" --name "$0" -- "$@"); then
    usage
    exit 1
fi

GEN_OVERRIDE="no"
GEN_MC="no"

eval set -- "${OPTS}"

while :; do
    case "$1" in
        --override)
            GEN_OVERRIDE="yes"
            shift
            ;;
        --mc)
            GEN_MC="yes"
            shift
            ;;
        -o|--opts)
            WORKAROUND_OPTS="${2}"
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

if [ "${GEN_OVERRIDE}" = "yes" ]; then
    echo "ignitionConfigOverride: '$(generate_ignition_config | sed -z 's/\n */ /g' ; echo)'"
elif [ "${GEN_MC}" = "yes" ]; then
    generate_machine_config master
    generate_machine_config worker
else
    generate_ignition_config
fi

