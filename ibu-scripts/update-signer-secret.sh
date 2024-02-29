#!/bin/bash
#
# Update the expiry annotations for the openshift-kube-controller-manager-operator csr-signer-signer secret
#
# TODO: Provide option to specify a window
#

function update_signer_secret {
    local day_in_secs
    local expiry_window
    local expiry_in_two_hours
    local now
    local not_after_secs
    local not_before_secs
    local not_after
    local not_before

    local namespace="openshift-kube-controller-manager-operator"
    local secret="csr-signer-signer"

    #
    # Certs are rotated once 80% through the validity period.
    # We can then adjust the cert so that the ceritficate manager
    # thinks it is due to rotate in 2 hours, giving a buffer for:
    # - time to generate and publish seed image
    # - time to run through a couple of IBUs without having a rollout occur
    # - once 2 hours pass from the time we update the certificate on the seed SNO,
    #   the next IBU attempt should see a rollout occur during the postpivot recovery
    #
    day_in_secs=$((24*60*60))
    expiry_window=$((day_in_secs*20/100))
    expiry_in_two_hours=$((expiry_window+7200))

    # Current time
    now=$(date +%s)

    # Calculate the Before and After times, based on current time + expiry window
    not_after_secs=$((now+expiry_in_two_hours))
    not_after=$(date --date="@${not_after_secs}" -u "+%Y-%m-%dT%H:%M:%SZ")

    not_before_secs=$((not_after_secs-day_in_secs))
    not_before=$(date --date="@${not_before_secs}" -u "+%Y-%m-%dT%H:%M:%SZ")

    # Patch the annotations
    new_annotation=$(oc get secret -n ${namespace} ${secret} -o json \
        | jq -c --arg after "${not_after}" --arg before "${not_before}" '
            .metadata.annotations
            | with_entries(select(.key == "auth.openshift.io/certificate-not-after").value |= $after)
            | with_entries(select(.key == "auth.openshift.io/certificate-not-before").value |= $before)
        ')

    oc patch secret -n ${namespace} ${secret} --type=merge \
        -p='"metadata": {"annotations": '"${new_annotation}"'}'

    if [ $? -eq 0 ]; then
        echo "Secret updated: $namespace / $secret"
        echo "Not after: ${not_after}"
        echo "Not before: ${not_before}"
        echo
        echo "To check secret, run:"
        echo "oc get secret -n ${namespace} ${secret} -o yaml"
    else
        echo "Failed to patch"
    fi
}

update_signer_secret

