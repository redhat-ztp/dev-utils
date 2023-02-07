#!/bin/bash
#
# Build a custom release based on a specific Z-stream release, with overridden packages
#

PROG=$(basename "$0")
SCRIPTDIR=$(dirname "$(readlink -f "$0")")

OPTV_REPO_DIR=
WORKDIR=
function cleanup {
    if [ -n "${OPTV_REPO_DIR}" ] && [ -d "${OPTV_REPO_DIR}" ]; then
        rm -rf "${OPTV_REPO_DIR}"
    fi

    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}

trap cleanup EXIT

#
# Check required tools
#
REQUIRED_TOOLS=(
    createrepo
    curl
    git
    jq
    oc
    podman
    repoquery
    rpmdev-vercmp
    skopeo
    wget
)
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        MISSING_TOOLS+=( "${tool}" )
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "The following required tools are missing:" >&2
    echo "${MISSING_TOOLS[@]}" >&2
    exit 1
fi

function usage {
    cat <<EOF
Usage: ${PROG} ...
Parameters:
    --auth <auth file>              Auth file for oc commands and OPTV registry
    --optv-registry <reg>           Registry for built images
    --suffix <name>                 Suffix for custom release version
    -z <z-stream>                   Baseline Z-stream (eg. 4.10.26)

Optional parameters:
    --optv-htpath <url>             URL for OPTV software repo server basedir
    --pkg-dir <dir>                 Directory containing custom RPMs to override
    --add-pkg <pkgname>             New rpm in pkg-dir to install in image
    --add-kernel-rt-pkg <pkgname>   New rpm in pkg-dir to install with kernel-rt packages
    --img-override <img>            Additional image to override
    --summary-yaml                  Generate yaml summary image

The add-pkg and img-override options can be specified multiple times.

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
# The cosa function comes from:
# https://coreos.github.io/coreos-assembler/building-fcos/#define-a-bash-alias-to-run-cosa
#
# Note: Minor formatting changes have been made to appease shellcheck and bashate
# Note: Added origflags check to avoid clearing bash -x flag
#
function cosa {
    env | grep COREOS_ASSEMBLER
    local -r COREOS_ASSEMBLER_CONTAINER_LATEST="quay.io/coreos-assembler/coreos-assembler:latest"
    local origflags="$-"
    # shellcheck disable=SC2091
    if [[ -z ${COREOS_ASSEMBLER_CONTAINER} ]] && $(podman image exists ${COREOS_ASSEMBLER_CONTAINER_LATEST}); then
        local cosa_build_date_str=
        local cosa_build_date=
        cosa_build_date_str="$(podman inspect -f "{{.Created}}" ${COREOS_ASSEMBLER_CONTAINER_LATEST} | awk '{print $1}')"
        # shellcheck disable=SC2086
        cosa_build_date="$(date -d ${cosa_build_date_str} +%s)"
        if [[ $(date +%s) -ge $((cosa_build_date + 60*60*24*7)) ]] ; then
            echo -e "\e[0;33m----" >&2
            echo "The COSA container image is more that a week old and likely outdated." >&2
            echo "You should pull the latest version with:" >&2
            echo "podman pull ${COREOS_ASSEMBLER_CONTAINER_LATEST}" >&2
            echo -e "----\e[0m" >&2
            sleep 10
        fi
    fi
    set -x
    # shellcheck disable=SC2086
    podman run --rm -ti --security-opt label=disable --privileged                                     \
                --uidmap=1000:0:1 --uidmap=0:1:1000 --uidmap 1001:1001:64536                          \
                -v ${PWD}:/srv/ --device /dev/kvm --device /dev/fuse                                  \
                --tmpfs /tmp -v /var/tmp:/var/tmp --name cosa                                         \
                ${COREOS_ASSEMBLER_CONFIG_GIT:+-v $COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro}   \
                ${COREOS_ASSEMBLER_GIT:+-v $COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro}  \
                ${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}                                            \
                ${COREOS_ASSEMBLER_CONTAINER:-$COREOS_ASSEMBLER_CONTAINER_LATEST} "$@"
    rc=$?; [[ $origflags != *x* ]] && set +x; return $rc
}

#
# Generate a YAML summary image
#
function summary_yaml {
    cat <<EOF
---
build:
  zstream: ${REL_Z}
  version: ${CUSTOM_VERSION}
  images:
EOF
    for img in "${sorted_overrides[@]}"; do
        echo "    - ${img}"
    done

    if [ "${#CARRYOVER_PKGS[@]}" -gt 0 ]; then
        echo "  customized-packages:"
        mapfile -t sorted_pkgs < <( IFS=$'\n'; sort -u <<<"${!CARRYOVER_PKGS[*]}" )
        for pkg in "${sorted_pkgs[@]}"; do
            echo "    - name: ${pkg}"
            echo "      version: ${CARRYOVER_PKGS[${pkg}]}"
        done
    fi

    if [ "${#USER_PKGS[@]}" -gt 0 ]; then
        echo "  user-customized-packages:"
        mapfile -t sorted_pkgs < <( IFS=$'\n'; sort -u <<<"${!USER_PKGS[*]}" )
        for pkg in "${sorted_pkgs[@]}"; do
            echo "    - name: ${pkg}"
            echo "      version: ${USER_PKGS[${pkg}]}"
        done
    fi

    if [ "${#EXTRA_PKGS[@]}" -gt 0 ]; then
        echo "  added-packages:"
        for pkg in "${EXTRA_PKGS[@]}"; do
            echo "    - ${pkg}"
        done
    fi

    if [ "${#EXTRA_KERNEL_RT_PKGS[@]}" -gt 0 ]; then
        echo "  added-realtime-packages:"
        for pkg in "${EXTRA_KERNEL_RT_PKGS[@]}"; do
            echo "    - ${pkg}"
        done
    fi
}

#
# Process command-line args
#
if ! OPTS=$(getopt -o "h,z:" --long "help,,auth:,optv-registry:,optv-htpath:,pkg-dir:,quay:,suffix:,img-override:,add-kernel-rt-pkg:,add-pkg:,summary-yaml" --name "$0" -- "$@"); then
    usage
    exit 1
fi

eval set -- "${OPTS}"

declare OPTV_REGISTRY=
declare OPTV_HTPATH=
declare OPTV_BUILD_URL=
declare AUTH_FILE=${HOME}/.docker/config.json
declare PKG_DIR=
declare REL_Z=
declare SUFFIX=
declare SUMMARY_YAML=no
declare -a IMG_OVERRIDES=()
declare -a EXTRA_KERNEL_RT_PKGS=()
declare -a EXTRA_PKGS=()

declare -A USER_PKGS=()
declare -A CARRYOVER_PKGS=()

while :; do
    case "$1" in
        --auth)
            AUTH_FILE="$2"
            shift 2
            ;;
        --optv-registry)
            OPTV_REGISTRY="$2"
            shift 2
            ;;
        --optv-htpath)
            OPTV_HTPATH="$2"
            shift 2
            ;;
        --pkg-dir)
            PKG_DIR="$2"
            shift 2
            ;;
        --suffix)
            SUFFIX="$2"
            shift 2
            ;;
        --summary-yaml)
            SUMMARY_YAML=yes
            shift
            ;;
        -z)
            REL_Z="$2"
            shift 2
            ;;
        --img-override)
            IMG_OVERRIDES+=("$2")
            shift 2
            ;;
        --add-kernel-rt-pkg)
            EXTRA_KERNEL_RT_PKGS+=("$2")
            shift 2
            ;;
        --add-pkg)
            EXTRA_PKGS+=("$2")
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

if [ -z "${OPTV_REGISTRY}" ] || \
    [ -z "${AUTH_FILE}" ] || \
    [ -z "${REL_Z}" ] || \
    [ -z "${SUFFIX}" ]; then
    usage
fi

#
# Validate options
#
if [[ ! "${REL_Z}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fatal "Z-stream does not match x.y.z format"
fi

DOWNLOAD_RPMS="${SCRIPTDIR}/optv-build-download-pkgs.sh"
if [ ! -x "${DOWNLOAD_RPMS}" ]; then
    fatal "Could not find optv-build-download-pkgs.sh executable script in ${SCRIPTDIR}"
fi

if [ -n "${PKG_DIR}" ]; then
    shopt -s nullglob
    OVERRIDES=( "${PKG_DIR}"/*.rpm )
    if [ ${#OVERRIDES} -eq 0 ]; then
        fatal "Did not find packages in ${PKG_DIR}"
    fi
    shopt -u nullglob
fi

#
# Setup environment variables
#
REL_Y=${REL_Z%\.*}

if [ -n "${OPTV_HTPATH}" ]; then
    OPTV_BUILD_URL="${OPTV_HTPATH}/${REL_Y}/${REL_Z}"
    if ! curl --fail -s "${OPTV_BUILD_URL}/" >/dev/null ; then
        fatal "Build not found: ${OPTV_BUILD_URL}"
    fi

    OPTV_REPO_DIR=$(mktemp --tmpdir -d optv-repo-XXXXXX)
    cat <<EOF >"${OPTV_REPO_DIR}/optv.repo"
[optv]
enabled=1
gpgcheck=0
baseurl=${OPTV_BUILD_URL}
EOF
    yum clean expire-cache >/dev/null 2>&1

    if [ -n "${PKG_DIR}" ]; then
        # Verify that each custom package is the newest in overrides, in case there was a newer package in the OPTV repo
        log "Checking packages in ${PKG_DIR} against ${OPTV_BUILD_URL}"
        for pkg in "${PKG_DIR}"/*.rpm; do
            name=$(rpm -qp --qf '%{NAME}' "${pkg}")
            custom_pkg_evra=$(rpm -qp --qf '%|EPOCH?{%{EPOCH}}:{0}|:%{VERSION}-%{RELEASE}.%{ARCH}' "${pkg}")

            # Store pkg info for summary
            USER_PKGS+=(["${name}"]="${custom_pkg_evra}")

            optv_evra=$(repoquery -q --setopt reposdir=${OPTV_REPO_DIR} --latest-limit 1 --qf '%{epoch}:%{version}-%{release}.%{arch}' "${name}")
            if [ -z "${optv_evra}" ]; then
                continue
            fi

            # rpmdev-vercmp compares two package versions and returns:
            # - 0 if equal
            # - 11 if first is newer
            # - 12 if second is newer
            rpmdev-vercmp "${custom_pkg_evra}" "${optv_evra}" >/dev/null
            case $? in
                0)
                    fatal "${pkg} has equivalent version in OPTV repo (version: ${optv_evra})"
                    ;;
                11)
                    continue
                    ;;
                12)
                    fatal "${pkg} has higher version in OPTV repo (version: ${optv_evra})"
                    ;;
                *)
                    fatal "Error comparing version of ${pkg} against OPTV repo (version: ${optv_evra})"
                    ;;
            esac
        done
    fi
fi

export COREOS_ASSEMBLER_CONTAINER=quay.io/coreos-assembler/coreos-assembler:rhcos-${REL_Y}

if [[ ! -f /dev/kvm && ! "${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}" =~ "--env COSA_NO_KVM=1" ]]; then
    log "No /dev/kvm found. Setting COSA_NO_KVM=1"
    export COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS="${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS} --env COSA_NO_KVM=1"
fi

if [[ ! "${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}" =~ "--env REGISTRY_AUTH_FILE=" ]]; then
    export COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS="${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS} --env REGISTRY_AUTH_FILE=${AUTH_FILE}"
fi

# Bind-mount certs for cosa
export COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS="${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS} -v /etc/pki/ca-trust:/etc/pki/ca-trust"

CUSTOM_VERSION="${REL_Z}-${SUFFIX}.$(date -u +%Y%m%d%H%M)"
CUSTOM_RELEASE="${OPTV_REGISTRY}/ocp-release:${CUSTOM_VERSION}-x86_64"

#
# Collect info from the base release
#
log "Retrieving release information for ${REL_Z}"
BASE_MACHINE_OS_CONTENT=$(oc adm release info -a "${AUTH_FILE}" "${REL_Z}" --image-for=machine-os-content)
if [ -z "${BASE_MACHINE_OS_CONTENT}" ]; then
    fatal "Unable to retrieve release info for ${REL_Z}"
fi

BASE_BUILD_ID=$(oc image info -a "${AUTH_FILE}" "${BASE_MACHINE_OS_CONTENT}" -o json | jq -r '.config.config.Labels.version')
if [ -z "${BASE_BUILD_ID}" ]; then
    fatal "Unable to determine build ID for ${REL_Z}"
fi

BASE_KERNEL_RT=$(oc image info -a "${AUTH_FILE}" "${BASE_MACHINE_OS_CONTENT}" -o json | jq -r '.config.config.Labels."com.coreos.rpm.kernel-rt-core"')
if [ -z "${BASE_KERNEL_RT}" ]; then
    fatal "Unable to determine kernel-rt version for ${REL_Z}"
fi

FROM_REL_DIGEST=$(oc adm release info -a "${AUTH_FILE}" "${REL_Z}" -o jsonpath='{.digest}')
FROM_REL_IMAGE="quay.io/openshift-release-dev/ocp-release@${FROM_REL_DIGEST}"

if [ -z "${FROM_REL_DIGEST}" ]; then
    fatal "Unable to determine release digest for ${REL_Z}"
fi

#
# Setup the build
#
log "Setting up the build"
if ! podman pull "${COREOS_ASSEMBLER_CONTAINER}"; then
    fatal "Failed to pull ${COREOS_ASSEMBLER_CONTAINER} image"
fi

if ! cosa init --branch "release-${REL_Y}" https://github.com/openshift/os.git; then
    fatal "cosa init failed"
fi

if ! git clone --branch "${REL_Y}" https://gitlab.cee.redhat.com/coreos/redhat-coreos.git; then
    fatal "git clone failed"
fi

if ! cp redhat-coreos/*.repo src/config/; then
    fatal "Failed to copy .repo files"
fi

if ! cp redhat-coreos/content_sets.yaml src/config/; then
    fatal "Failed to copy content_sets.yaml"
fi

#
# Workaround repo name mismatches
#
if [ "${REL_Y}" = "4.10" ]; then
    sed -i \
        -e 's/rhel-8.4-advanced-virt/rhel-8-advanced-virt/' \
        -e 's/rhel-8.4-appstream/rhel-8-appstream/' \
        -e 's/rhel-8.4-baseos/rhel-8-baseos/' \
        -e 's/rhel-8.4-fast-datapath/rhel-8-fast-datapath/' \
        -e 's/rhel-8.4-nfv/rhel-8-nfv/' \
        -e 's/rhel-8.4-server-ose-4.10/rhel-8-server-ose/' \
        src/config/manifest.yaml src/config/extensions.yaml
fi

#
# Download lockfile and any missing RPMs
#
log "Downloading lockfile and any required RPMs"
if ! "${DOWNLOAD_RPMS}" --rel "${REL_Y}" --build "${BASE_BUILD_ID}"; then
    fatal "Failed to download missing RPMs"
fi

#
# Fetch packages for build
#
log "Setting up package cache"
if ! cosa fetch --with-cosa-overrides; then
    fatal "cosa fetch failed"
fi

#
# Setup overrides
#

#
# Add custom packages
#
if [ -n "${PKG_DIR}" ]; then
    log "Adding custom packages"
    if ! cd overrides/rpm; then
        fatal "Failed to cd to overrides/rpm"
    fi

    if ! cp "${PKG_DIR}"/*.rpm .; then
        fatal "Failed to copy ${PKG_DIR}/*.rpm"
    fi

    rm -rf repodata/
    if !  createrepo .; then
        fatal "createrepo failed"
    fi

    yum clean expire-cache >/dev/null 2>&1

    if ! cd ../..; then
        fatal "Failed to cd to original pwd"
    fi
fi

#
# Download carryover custom packages
#
if [ -n "${OPTV_BUILD_URL}" ]; then
    if ! cd overrides/rpm; then
        fatal "Failed to cd to overrides/rpm"
    fi

    yum clean expire-cache >/dev/null 2>&1

    for pkg in $(repoquery -q --setopt reposdir="${OPTV_REPO_DIR}" --latest-limit 1 -a --qf '%{name}'); do
        # Check if package was overridden by the user
        if [ ${USER_PKGS["${pkg}"]+_} ]; then
            log "Skipping ${pkg}, as it is overridden in ${PKG_DIR}"
            continue
        fi

        pkg_url=$(repoquery -q --setopt reposdir="${OPTV_REPO_DIR}" --latest-limit 1 --location "${pkg}")
        log "Downloading ${pkg_url}"
        if ! wget -q --backups=0 "${pkg_url}"; then
            fatal "Failed to download ${pkg_url}"
        fi

        pkg_evra=$(rpm -qp --qf '%|EPOCH?{%{EPOCH}}:{0}|:%{VERSION}-%{RELEASE}.%{ARCH}' $(basename "${pkg_url}"))
        CARRYOVER_PKGS+=(["${pkg}"]="${pkg_evra}")
    done

    rm -rf repodata/
    if !  createrepo .; then
        fatal "createrepo failed"
    fi

    yum clean expire-cache >/dev/null 2>&1

    if ! cd ../..; then
        fatal "Failed to cd to original pwd"
    fi

    #
    # Get additional package lists
    #
    addpkgs=$(curl --fail -s ${OPTV_BUILD_URL}/add-pkg.txt | sed -e 's/[[:space:]]*//' -e 's/#.*//' -e '/^$/d' | sort -u)
    if [ -n "${addpkgs}" ]; then
        EXTRA_PKGS+=( "${addpkgs}" )
    fi

    addpkgsrt=$(curl --fail -s ${OPTV_BUILD_URL}/add-pkg-rt.txt | sed -e 's/[[:space:]]*//' -e 's/#.*//' -e '/^$/d' | sort -u)
    if [ -n "${addpkgsrt}" ]; then
        EXTRA_KERNEL_RT_PKGS+=( "${addpkgsrt}" )
    fi
fi

#
# Strip duplicates from package lists
#
if [ ${#EXTRA_PKGS[@]} -gt 0 ]; then
    mapfile -t EXTRA_PKGS < <( IFS=$'\n'; sort -u <<<"${EXTRA_PKGS[*]}" )
fi

if [ ${#EXTRA_KERNEL_RT_PKGS[@]} -gt 0 ]; then
    mapfile -t EXTRA_KERNEL_RT_PKGS < <( IFS=$'\n'; sort -u <<<"${EXTRA_KERNEL_RT_PKGS[*]}" )
fi

#
# Workaround for kernel-rt packages
#
OVERRIDE_KERNEL_RT_VER=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --qf '%{version}-%{release}.%{arch}' kernel-rt-core)

log "Locking kernel-rt version to ${OVERRIDE_KERNEL_RT_VER:-${BASE_KERNEL_RT}}"
if ! sed -i -e '/^  kernel-rt:/a\    repos:\n      - coreos-assembler-local-overrides' -e "s/\(- kernel-rt.*\)/\1-${OVERRIDE_KERNEL_RT_VER:-${BASE_KERNEL_RT}}/" src/config/extensions.yaml; then
    fatal "Failed to update extensions.yaml"
fi

if [ -z "${OVERRIDE_KERNEL_RT_VER}" ]; then
    if ! grep -- "- kernel-rt" src/config/extensions.yaml | sed 's/-/--pkg/' \
        | xargs --no-run-if-empty "${DOWNLOAD_RPMS}" --rel "${REL_Y}" --build "${BASE_BUILD_ID}"; then
        fatal "Failed to download kernel-rt RPMs"
    fi
fi

#
# Verify each required kernel-rt package is available
#
# shellcheck disable=SC2013
for pkg in $(grep -- "- kernel-rt" src/config/extensions.yaml | sed 's/-//'); do
    log "Checking for ${pkg}"
    location=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --location "${pkg}")
    if [ -z "${location}" ] || [ ! -f "overrides/rpm/$(basename "${location}")" ]; then
        fatal "RPM for ${pkg} not available in overrides/rpm"
    fi
done

#
# Since buildextend-extensions (used by upload-oscontainer) doesn't have override support (for kernel-rt),
# we need to copy coreos-assembler-local-overrides.repo to src/config as a workaround
#
if ! cp tmp/override/coreos-assembler-local-overrides.repo src/config/; then
    fatal "Failed to copy coreos-assembler-local-overrides.repo"
fi

#
# Add new packages, if any
#
if [ ${#EXTRA_PKGS[@]} -gt 0 ]; then
    log "Adding new packages"
    for pkg in "${EXTRA_PKGS[@]}"; do
        log "Adding ${pkg}"
        location=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --location "${pkg}")
        if [ -z "${location}" ] || [ ! -f "overrides/rpm/$(basename "${location}")" ]; then
            fatal "RPM for ${pkg} not available in overrides/rpm"
        fi

        nvra=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${pkg}")
        if [ -z "${nvra}" ]; then
            fatal "Failed to determine NVRA for ${pkg}"
        fi

        # Add NVRA to packages list in manifest.yaml
        if ! sed -i -e "/^packages:/a\ - ${nvra}" src/config/manifest.yaml; then
            fatal "Failed to update manifest.yaml"
        fi
    done
fi

if [ ${#EXTRA_KERNEL_RT_PKGS[@]} -gt 0 ]; then
    log "Adding new kernel-rt packages"
    for pkg in "${EXTRA_KERNEL_RT_PKGS[@]}"; do
        log "Adding ${pkg}"
        location=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --location "${pkg}")
        if [ -z "${location}" ] || [ ! -f "overrides/rpm/$(basename "${location}")" ]; then
            fatal "RPM for ${pkg} not available in overrides/rpm"
        fi

        nvra=$(repoquery -q --disablerepo '*' --repofrompath overrides,overrides/rpm --latest-limit 1 --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "${pkg}")
        if [ -z "${nvra}" ]; then
            fatal "Failed to determine NVRA for ${pkg}"
        fi

        # Add NVRA to extensions.yaml
        if ! sed -i -e "/^      - kernel-rt-core/a\      - ${nvra}" src/config/extensions.yaml; then
            fatal "Failed to update extensions.yaml"
        fi
    done
fi

#
# Run the build
#
log "Running build"
if ! cosa build --version "${CUSTOM_VERSION}"; then
    fatal "cosa build failed"
fi

#
# Get the build version
#
CUSTOM_BUILD_VERSION=$(jq .version -r builds/latest/x86_64/commitmeta.json)
if [ -z "${CUSTOM_BUILD_VERSION}" ]; then
    if [ -n "${RUNCMD}" ]; then
        # Performing dry run
        CUSTOM_BUILD_VERSION="XXXXXX"
    else
        fatal "Failed to get build version"
    fi
fi

#
# Build images required for baremetal host
#
log "Running buildextend-metal"
if ! cosa buildextend-metal; then
    fatal "cosa buildextend-metal failed"
fi

log "Running buildextend-metal4k"
if ! cosa buildextend-metal4k; then
    fatal "cosa buildextend-metal4k failed"
fi

log "Running buildextend-live"
if ! cosa buildextend-live; then
    fatal "cosa buildextend-live failed"
fi

#
# Generate the machine-os-content container image
#
log "Generating machine-os-content container image"
if ! cosa upload-oscontainer --name "${OPTV_REGISTRY}/machine-os-content"; then
    fatal "cosa upload-oscontainer failed"
fi

#
# Generate the custom release
#
log "Generating custom release"
CUSTOM_OS_CONTENT="${OPTV_REGISTRY}/machine-os-content:${CUSTOM_BUILD_VERSION}"
IMG_OVERRIDES+=( "machine-os-content=${CUSTOM_OS_CONTENT}" )
mapfile -t sorted_overrides < <( IFS=$'\n'; sort -u <<<"${IMG_OVERRIDES[*]}" )

if ! oc adm release new -a "${AUTH_FILE}" \
    --from-release="${FROM_REL_IMAGE}" \
    --to-image="${CUSTOM_RELEASE}" \
    --name "${CUSTOM_VERSION}" \
    "${sorted_overrides[@]}"; then
    fatal "Failed to create release"
fi

if podman image exists "${CUSTOM_RELEASE}" && ! podman rmi "${CUSTOM_RELEASE}"; then
    fatal "Failed to clean up image: ${CUSTOM_RELEASE}"
fi

#
# Determine the digest ID for the release image, in order to run the upgrade
#
CUSTOM_REL_DIGEST=$(skopeo inspect --authfile "${AUTH_FILE}" docker://"${CUSTOM_RELEASE}" | jq -r '.Digest')
if [ -z "${CUSTOM_REL_DIGEST}" ]; then
    fatal "Failed to determine custom release image digest"
fi

#
# Generate summary yaml, if requested
#
if [ "${SUMMARY_YAML}" = "yes" ]; then
    log "Generating summary"

    WORKDIR=$(mktemp --tmpdir -d summary-XXXXXX)
    summary_yaml > "${WORKDIR}/summary.yaml"

    # Generate summary image
    cat <<EOF > "${WORKDIR}/Dockerfile"
FROM scratch
COPY summary.yaml .
EOF

    BUILDINFO_IMG="${OPTV_REGISTRY}/buildinfo:${CUSTOM_VERSION}"
    BUILDINFO_IMG_LATEST="${OPTV_REGISTRY}/buildinfo:${REL_Z}-${SUFFIX}.latest"
    podman build -t "${BUILDINFO_IMG}" "${WORKDIR}" && \
        podman push --authfile "${AUTH_FILE}" "${BUILDINFO_IMG}" && \
        podman tag "${BUILDINFO_IMG}" "${BUILDINFO_IMG_LATEST}" && \
        podman push --authfile "${AUTH_FILE}" "${BUILDINFO_IMG_LATEST}" && \
    if [ $? -ne 0 ]; then
        fatal "Failed to generate and push buildinfo image"
    fi

    echo -e "\nPushed buildinfo image:"
    echo "    ${BUILDINFO_IMG}"
    echo "    ${BUILDINFO_IMG_LATEST}"
fi

#
# Build was successful.
#
set +x
echo -e "\nSuccessfully built release image:"
echo "    ${CUSTOM_RELEASE}"

echo -e "\nThe following image(s) have been overridden from release ${REL_Z}:"
for img in "${sorted_overrides[@]}"; do
    echo "    ${img}"
done

echo -e "\nTo upgrade to custom release:"
echo "    oc adm upgrade --allow-explicit-upgrade --force \\"
echo "        --to-image=${CUSTOM_REL_DIGEST}"
echo "    oc adm upgrade --allow-explicit-upgrade --force \\"
echo "        --to-image=${OPTV_REGISTRY}/ocp-release@${CUSTOM_REL_DIGEST}"

echo -e "\nTo rebuild the custom release, with modified --to-image or --name tags, run the following:"
cat <<EOF
    oc adm release new -a "${AUTH_FILE}" \\
        --from-release="${FROM_REL_IMAGE}" \\
        --to-image="${CUSTOM_RELEASE}" \\
        --name "${CUSTOM_VERSION}" \\
EOF
for ((idx=0; idx<${#sorted_overrides[@]}; idx++)); do
    echo -n "    ${sorted_overrides[${idx}]}"
    if [ $((idx+1)) -eq ${#sorted_overrides[@]} ]; then
        echo
    else
        echo " \\"
    fi
done

if [ "${#USER_PKGS[@]}" -gt 0 ]; then
    echo -e "\nThe following packages have been customized by the user:"
    for pkg in "${!USER_PKGS[@]}"; do
        echo "    ${pkg}-${USER_PKGS[${pkg}]}"
    done | sort
fi

if [ "${#CARRYOVER_PKGS[@]}" -gt 0 ]; then
    echo -e "\nThe following package customizations have been carried over:"
    for pkg in "${!CARRYOVER_PKGS[@]}"; do
        echo "    ${pkg}-${CARRYOVER_PKGS[${pkg}]}"
    done | sort
fi

exit 0

