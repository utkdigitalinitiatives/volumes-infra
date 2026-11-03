#!/usr/bin/env bash
#
# Publish a Packer managed image to the shared image gallery, with the wait and
# retry Packer's own gallery publish lacks. Shared copy - keep in sync with
# lib-main-infra/.github/scripts/gallery-publish.sh.
#
# Why not let Packer publish. The subscription's auto-tagging writes tags to
# every new resource a few seconds after it is created, and that update holds a
# new managed image in a transient state for ~15 s. Packer starts its gallery
# publish ~10 s after capture, so it fails with "Conflict ... is in a transient
# state" (2 of 2 builds on 2026-10-20). Packer has no setting to wait or retry.
# Capturing the build VM straight into the gallery is no way out either: the VM
# carries the Rocky Linux marketplace plan, the gallery image definitions have
# none, and Azure refuses a VM source whose plan differs from its definition's.
# A managed image source is not plan-checked, which is why this path works.
#
# A failed publish leaves a gallery version in state Failed behind, which blocks
# the next attempt with the same name and which gallery-prune.py never deletes
# (it skips anything not Succeeded). Both commands below remove one first.
#
# Usage:
#   gallery-publish.sh check-version-free <resource-group> <gallery> <definition> <version>
#       Run before the build. Fails if the version already exists, so a build
#       with a taken name stops in seconds instead of after the whole build.
#   gallery-publish.sh publish <resource-group> <gallery> <definition> <version> <managed-image> <region>
#
set -uo pipefail

ATTEMPTS=6
RETRY_DELAY=30

# Azure answers "ResourceNotFound" alike for a missing version, definition or
# gallery, so prove the definition exists before reading "not found" as "free".
require_definition() {
  local rg="$1" gallery="$2" definition="$3"
  if ! az sig image-definition show -g "$rg" --gallery-name "$gallery" \
      --gallery-image-definition "$definition" -o none; then
    echo "::error::Gallery image definition $gallery/$definition not found in $rg."
    exit 1
  fi
}

# Print the version's provisioningState, or "absent" if it does not exist. Any
# other read error fails: an error must never be mistaken for "free".
version_state() {
  local rg="$1" gallery="$2" definition="$3" version="$4" out
  if out=$(az sig image-version show -g "$rg" --gallery-name "$gallery" \
      --gallery-image-definition "$definition" --gallery-image-version "$version" \
      --query provisioningState -o tsv 2>&1); then
    echo "$out"
    return 0
  fi
  if grep -qiE 'ResourceNotFound|NotFound|could not be found|was not found' <<< "$out"; then
    echo "absent"
    return 0
  fi
  echo "::error::Could not read gallery version $definition/$version: $out" >&2
  return 1
}

delete_failed_version() {
  local rg="$1" gallery="$2" definition="$3" version="$4" state
  echo "::warning::Deleting gallery version $definition/$version in state Failed - a publish that failed left it behind."
  az sig image-version delete -g "$rg" --gallery-name "$gallery" \
    --gallery-image-definition "$definition" --gallery-image-version "$version" \
    || echo "::warning::Delete of $definition/$version returned an error - checking whether it is gone."
  for _ in $(seq 1 20); do
    state=$(version_state "$@") || return 1
    [ "$state" = "absent" ] && return 0
    sleep 15
  done
  echo "::error::Gallery version $definition/$version is still there (state $state) - delete it by hand."
  return 1
}

check_version_free() {
  local state
  require_definition "$1" "$2" "$3"
  state=$(version_state "$@") || exit 1
  case "$state" in
    absent) echo "Gallery version $3/$4 is free." ;;
    Failed) delete_failed_version "$@" || exit 1 ;;
    *)
      echo "::error::Gallery version $3/$4 already exists (state $state). Pick another version."
      exit 1
      ;;
  esac
}

# Wait until the auto-tagging is done with the new image: at least 60 s, then
# provisioningState Succeeded on two reads 15 s apart. Gives up after ~5 min and
# lets the retry loop deal with it.
wait_for_image() {
  local rg="$1" image="$2" state streak=0
  echo "Waiting for managed image $image to settle..."
  sleep 60
  for _ in $(seq 1 20); do
    state=$(az image show -g "$rg" -n "$image" --query provisioningState -o tsv 2>/dev/null)
    if [ "$state" = "Succeeded" ]; then
      streak=$((streak + 1))
      [ "$streak" -ge 2 ] && return 0
    else
      streak=0
      echo "Managed image $image is ${state:-unreadable} - waiting."
    fi
    sleep 15
  done
  echo "::warning::Managed image $image did not settle in 5 minutes - trying the publish anyway."
}

publish() {
  local rg="$1" gallery="$2" definition="$3" version="$4" image="$5" region="$6"
  local image_id state attempt line
  local tag_args=()

  require_definition "$rg" "$gallery" "$definition"
  wait_for_image "$rg" "$image"

  if ! image_id=$(az image show -g "$rg" -n "$image" --query id -o tsv); then
    echo "::error::Managed image $image not found in $rg - did the Packer build finish?"
    exit 1
  fi

  # Carry Packer's tags over to the version, as Packer's own publish did. Leave
  # out the ones subscription governance stamps: it stamps the version itself.
  while IFS= read -r line; do
    [ -n "$line" ] && tag_args+=("$line")
  done < <(az image show -g "$rg" -n "$image" --query tags -o json | python3 -c '
import json, sys
tags = json.load(sys.stdin) or {}
for key, value in tags.items():
    if key == "CostCenter" or key.startswith(("Creator", "Creation", "LastModifie")):
        continue
    print(f"{key}={value}")
')
  [ "${#tag_args[@]}" -gt 0 ] && tag_args=(--tags "${tag_args[@]}")

  for attempt in $(seq 1 "$ATTEMPTS"); do
    state=$(version_state "$rg" "$gallery" "$definition" "$version") || exit 1
    case "$state" in
      absent) ;;
      Succeeded)
        if [ "$attempt" -eq 1 ]; then
          echo "::error::Gallery version $definition/$version already exists - another build published it."
          exit 1
        fi
        # An earlier attempt went through even though az reported an error.
        echo "Gallery version $definition/$version is published."
        return 0
        ;;
      Failed)
        delete_failed_version "$rg" "$gallery" "$definition" "$version" || exit 1
        ;;
      *)
        echo "Gallery version $definition/$version is $state - waiting before attempt $attempt."
        sleep "$RETRY_DELAY"
        continue
        ;;
    esac

    echo "Publishing $image to $gallery/$definition/$version (attempt $attempt of $ATTEMPTS)..."
    if az sig image-version create -g "$rg" --gallery-name "$gallery" \
        --gallery-image-definition "$definition" --gallery-image-version "$version" \
        --managed-image "$image_id" \
        --location "$region" --target-regions "$region" --replica-count 1 \
        --storage-account-type Standard_LRS \
        ${tag_args[@]+"${tag_args[@]}"} \
        --output none; then
      echo "Published $definition/$version."
      return 0
    fi
    echo "::warning::Publish attempt $attempt of $ATTEMPTS failed - retrying in ${RETRY_DELAY}s."
    sleep "$RETRY_DELAY"
  done

  state=$(version_state "$rg" "$gallery" "$definition" "$version") || exit 1
  if [ "$state" = "Succeeded" ]; then
    echo "Gallery version $definition/$version is published."
    return 0
  fi
  [ "$state" = "Failed" ] && delete_failed_version "$rg" "$gallery" "$definition" "$version"
  echo "::error::Could not publish $definition/$version after $ATTEMPTS attempts."
  exit 1
}

case "${1:-}" in
  check-version-free) check_version_free "${2:?resource group required}" "${3:?gallery required}" "${4:?definition required}" "${5:?version required}" ;;
  publish) publish "${2:?resource group required}" "${3:?gallery required}" "${4:?definition required}" "${5:?version required}" "${6:?managed image required}" "${7:?region required}" ;;
  *) echo "Usage: $0 {check-version-free <rg> <gallery> <definition> <version>|publish <rg> <gallery> <definition> <version> <managed-image> <region>}" >&2; exit 2 ;;
esac
