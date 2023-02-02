#!/bin/bash
#
# This utility helps setup an rhcos image build based on a specific Z-stream release.
#
# If no packages are specified, it downloads the generated lockfile from the specified
# build, then scans the list of packages in the lockfile to see which RPMs, if any, are
# unavailable in the rhcos repos. Any missing packages are then downloaded from brewroot
# into the overrides folder.
#
# If a package list is specified, the lockfile is not downloaded, and just those specific
# packages are downloaded to the overrides folder. This functionality is provided primarily
# for downloaded the required kernel-rt RPMs, which are not in the lockfile.
#

PROG=$(basename "$0")
WORKDIR=
function cleanup {
    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}

trap cleanup EXIT

function usage {
    cat <<EOF
Usage: ${PROG} --rel <release> --build <build-id> [ --pkg <pkg> ] ...
EOF
    exit 1
}

function fatal {
    echo "$*" >&2
    exit 1
}

function log {
    echo "$(date): $*"
}

#
# Download a specific RPM
#
function download_rpm {
    local nevra=$1
    local a=${nevra/*.}
    local nevr=${nevra%.*}
    local r=${nevr/*-}
    local nev=${nevr%-*}
    local ev=${nev/*-}
    local v=${ev/*:}
    local n=${nev%-*}

    local baseurl=
    local fname=
    local url=

    local BREW_DL_URL=http://download.eng.bos.redhat.com/brewroot/vol/rhel-8/packages

    # Predicted location, based on package info
    url=${BREW_DL_URL}/${n}/${v}/${r}/${a}/${n}-${v}-${r}.${a}.rpm

    fname=$(basename "${url}")
    if [ -f "${fname}" ]; then
        log "${fname} already exists"
        return
    fi

    #
    # First try the predicted location for the RPM. If that fails, use repoquery
    # to determine the location.
    #
    log "Trying ${url}"
    if wget -q --backups=0 "${url}"; then
        log "Downloaded ${fname}"
        return
    fi
    log "Failed to download ${url}"

    log "Querying repo for ${pkg}"
    url=$(repoquery -q --setopt reposdir="${WORKDIR}" "${pkg}" --location 2>/dev/null)
    if [ -n "${url}" ]; then
        log "Trying ${url}"
        if wget -q --backups=0 "${url}"; then
            log "Downloaded ${fname}"
            return
        fi
    fi

    #
    # In some cases, the predicted location fails, most likely because the package is grouped
    # with others (like the kernel-rt RPMs), and the specific version we're looking for
    # doesn't exist in the repodata. So as a workaround, we'll query the package name without
    # the version, then use that URL to predict the location.
    #
    log "Querying for ${n}"
    url=$(repoquery -q --setopt reposdir="${WORKDIR}" "${n}" --location 2>/dev/null)
    baseurl=${url%/[^/]*/[^/]*/[^/]*/[^/]*}
    if [ -n "${baseurl}" ]; then
        url=${baseurl}/${v}/${r}/${a}/${n}-${v}-${r}.${a}.rpm
        log "Trying ${url}"
        if wget -q --backups=0 "${url}"; then
            log "Downloaded ${fname}"
            return
        fi
    fi

    fatal "Could not find ${nevra}"
}

#
# Query the rhcos repos to find packages that are unavailable
#
function find_missing_pkgs {
    local found=
    local pkg=
    for pkg in "$@"; do
        found=$(repoquery -q --setopt reposdir="${CONFIG_DIR}" "${pkg}" 2>/dev/null)
        if [ -z "${found}" ]; then
            echo "${pkg}"
        fi
    done
}

#
# Download specified packages to the overrides dir and generate repodata
#
function download_pkgs {
    local pkg=

    if ! cd "${OVERRIDES_DIR}"; then
        fatal "Unable to cd to ${OVERRIDES_DIR}"
    fi

    for pkg in "$@"; do
        download_rpm "${pkg}"
    done
    rm -rf repodata/
    createrepo .
    yum clean expire-cache >/dev/null 2>&1
}

#
# Determine URL for lockfile
#
function get_lockfile_url {
    local baseurl=https://releases-rhcos-art.apps.ocp-virt.prod.psi.redhat.com
    local lockfile=manifest-lock.generated.x86_64.json

    local url="${baseurl}/storage/releases/rhcos-${RELEASE}/${BASE_BUILD_ID}/x86_64/${lockfile}"
    if curl -s -I "${url}" | grep -q '200 OK'; then
        echo "${url}"
    else
        url="${baseurl}/storage/prod/streams/${RELEASE}/builds/${BASE_BUILD_ID}/x86_64/${lockfile}"
        if curl -s -I "${url}" | grep -q '200 OK'; then
            echo "${url}"
        fi
    fi
}

#
# Process cmdline arguments
#
if ! OPTS=$(getopt -o "h,r:,b:,p:,l:" --long "help,rel:,build:,pkg:,lockfile:" --name "$0" -- "$@"); then
    usage
    exit 1
fi

eval set -- "${OPTS}"

declare BASE_BUILD_ID=
declare LOCAL_LOCKFILE=
declare -a PKGS=()
declare RELEASE=

while :; do
    case "$1" in
        -r|--rel)
            RELEASE="$2"
            shift 2
            ;;
        -b|--build)
            BASE_BUILD_ID="$2"
            shift 2
            ;;
        -p|--pkg)
            PKGS+=("$2")
            shift 2
            ;;
        -l|--lockfile)
            LOCAL_LOCKFILE="$2"
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

#
# Validate options
#
if [ -z "${RELEASE}" ] || [ -z "${BASE_BUILD_ID}" ]; then
    usage
fi

declare BASE_DIR=${PWD}
declare CONFIG_DIR=${BASE_DIR}/src/config
declare OVERRIDES_DIR=${BASE_DIR}/overrides/rpm

#
# Setup brewroot repo file
#
BREWROOT_URL="http://download.eng.bos.redhat.com/brewroot/repos/rhaos-${RELEASE}-rhel-8-build/latest/\$basearch"
log "Repo for downloads: ${BREWROOT_URL}"

WORKDIR=$(mktemp --tmpdir -d workdir-XXXXXX)
BREW_REPO=${WORKDIR}/brewroot.repo
cat <<EOF >"${BREW_REPO}"
[brewroot]
enabled=1
gpgcheck=0
baseurl=${BREWROOT_URL}
EOF

#
# If specific packages were requested, download them
#
if [ ${#PKGS} -gt 0 ]; then
    download_pkgs "${PKGS[@]}"
    exit 0
fi

#
# Download lockfile and any packages missing from main repos
#
LOCKFILE=${CONFIG_DIR}/manifest-lock.x86_64.json

if [ -n "${LOCAL_LOCKFILE}" ]; then
    log "Using local lockfile ${LOCAL_LOCKFILE}"
    if ! cp "${LOCAL_LOCKFILE}" "${LOCKFILE}"; then
        fatal "Unable to copy lockfile to ${LOCKFILE}"
    fi
else
    LOCKFILE_URL=$(get_lockfile_url)
    if [ -z "${LOCKFILE_URL}" ]; then
        fatal "Unable to find manifest-lock.x86_64.json for ${RELEASE}"
    fi

    log "Downloading ${LOCKFILE_URL}"
    if ! wget -q "${LOCKFILE_URL}" -O "${LOCKFILE}"; then
        fatal "Unable to download lockfile for ${BASE_BUILD_ID}"
    fi
fi

log "Scanning repos for unavailable packages"
readarray -t LOCKED_PKGS < <(jq -r '.packages | to_entries[] | .key + "-" + .value.evra' "${LOCKFILE}")
readarray -t MISSING_PKGS < <(find_missing_pkgs "${LOCKED_PKGS[@]}")

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    log "All packages are available in repos"
    exit 0
fi

download_pkgs "${MISSING_PKGS[@]}"

log "All packages have been downloaded."

exit 0

