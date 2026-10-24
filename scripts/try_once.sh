#!/usr/bin/env bash
# Tries once to create the Reachline server on Oracle Cloud (Always Free Ampere A1).
# Safe to run again and again: does nothing if the server already exists, and exits
# quietly when Oracle simply has no free capacity. Meant to run from GitHub Actions
# (.github/workflows/oracle-grab-server.yml); reads everything from environment variables.
set -uo pipefail

NAME="reachline"
OCPUS="${OCI_OCPUS:-2}"        # this account's Always Free limit is 2 cores / 12 GB
MEMORY="${OCI_MEMORY_GB:-12}"
DISK="${OCI_BOOT_GB:-100}"     # inside the free 200 GB total
SHAPE="VM.Standard.A1.Flex"    # Always Free-eligible Ampere shape; never change this

for v in OCI_USER_OCID OCI_TENANCY_OCID OCI_FINGERPRINT OCI_PRIVATE_KEY OCI_REGION OCI_SUBNET_OCID OCI_SSH_PUBLIC_KEY; do
  if [ -z "${!v:-}" ]; then echo "Missing setting: $v"; exit 1; fi
done

umask 077
mkdir -p "$HOME/.oci"
printf '%s\n' "$OCI_PRIVATE_KEY" > "$HOME/.oci/key.pem"
printf '%s\n' "$OCI_SSH_PUBLIC_KEY" > "$HOME/.oci/ssh.pub"
cat > "$HOME/.oci/config" <<CFG
[DEFAULT]
user=$OCI_USER_OCID
fingerprint=$OCI_FINGERPRINT
tenancy=$OCI_TENANCY_OCID
region=$OCI_REGION
key_file=$HOME/.oci/key.pem
CFG
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True
T="$OCI_TENANCY_OCID"

emit() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

existing=$(oci compute instance list --compartment-id "$T" --display-name "$NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output 2>&1) || {
  echo "Could not list servers (check the Oracle key settings)."; echo "$existing" | grep -E '"(code|message)"' | head -3; exit 1; }
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  echo "A server named $NAME already exists. Nothing to do."
  emit "created=exists"
  exit 0
fi

AD=$(oci iam availability-domain list --compartment-id "$T" --query 'data[0].name' --raw-output) || exit 1
IMAGE=$(oci compute image list --compartment-id "$T" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
  --limit 1 --query 'data[0].id' --raw-output) || exit 1
if [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then echo "No Ubuntu 24.04 Arm image found."; exit 1; fi

# Rotate between "let Oracle choose" and the three fault domains: each is a separate pool.
FD_ARGS=()
pick=$((RANDOM % 4))
if [ "$pick" -gt 0 ]; then FD_ARGS=(--fault-domain "FAULT-DOMAIN-$pick"); fi
echo "Trying: $SHAPE, $OCPUS cores, ${MEMORY} GB, ${DISK} GB disk, ${FD_ARGS[*]:-any fault domain}"

out=$(oci compute instance launch --compartment-id "$T" --availability-domain "$AD" \
  --shape "$SHAPE" --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY}" \
  --image-id "$IMAGE" --subnet-id "$OCI_SUBNET_OCID" --assign-public-ip true \
  --display-name "$NAME" --ssh-authorized-keys-file "$HOME/.oci/ssh.pub" \
  --boot-volume-size-in-gbs "$DISK" "${FD_ARGS[@]}" \
  --wait-for-state RUNNING --max-wait-seconds 600 2>&1)
rc=$?

if [ $rc -eq 0 ]; then
  id=$(oci compute instance list --compartment-id "$T" --display-name "$NAME" \
    --query 'data[?"lifecycle-state"!=`TERMINATED`] | [0].id' --raw-output)
  ip=$(oci compute instance list-vnics --instance-id "$id" --query 'data[0]."public-ip"' --raw-output)
  echo "SERVER CREATED. (Address not shown in this public log; see the Oracle console.)"
  emit "created=yes"
  exit 0
fi

if grep -qiE 'out of (host )?capacity|OutOfHostCapacity|TooManyRequests|"status": 429' <<<"$out"; then
  echo "No free capacity right now. Will try again on the next run."
  emit "created=no"
  exit 0
fi

echo "Oracle refused for another reason:"
echo "$out" | grep -E '"(code|message)"' | head -3
exit 1
