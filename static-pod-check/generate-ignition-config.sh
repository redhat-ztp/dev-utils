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
        "mode": 744,
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

function usage {
    cat <<EOF
Options:
    --override            Generate ignitionConfigOverride
    --opts "<options>"    Set of options to pass as arguments to static pod health check utility
EOF
    exit 1
}

#
# Process cmdline arguments
#
if ! OPTS=$(getopt -o "ho:" --long "help,override,opts:" --name "$0" -- "$@"); then
    usage
    exit 1
fi

GEN_OVERRIDE="no"

eval set -- "${OPTS}"

while :; do
    case "$1" in
        --override)
            GEN_OVERRIDE="yes"
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
else
    generate_ignition_config
fi

