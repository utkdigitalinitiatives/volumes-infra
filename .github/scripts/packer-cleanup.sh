#!/usr/bin/env bash
#
# Packer leftover cleanup. Shared copy - keep in sync with lib-main-infra/.github/scripts/packer-cleanup.sh.
#
# Packer's azure-arm builder always creates an intermediate managed image on the
# way to a gallery version, plus a build VM and its network kit. None of it is
# cleaned up by anything else, so it grows forever (~17 scratch images/month). A
# cancelled build is not hypothetical: build-on-dispatch.yml runs with
# cancel-in-progress: true, and a cancelled base build once left a D2s_v5 running
# for 50 days.
#
# Where the build VM leaks depends on how the project configures Packer, and the
# two shapes need different sweeps:
#   * no build_resource_group_name (lib-main-infra) -> Packer makes a throwaway
#     pkr-* resource group, and a dead build leaks the whole group.
#     -> sweep-build-groups
#   * build_resource_group_name set (volumes-infra) -> Packer builds inside an
#     existing RG, and a dead build leaks loose pkrvm/pkrni/pkros resources with
#     no group to find.
#     -> sweep-build-resources
#
# Every sweep deletes only what is older than max_age_hours (default 24). A
# GitHub job is capped at 6 hours, so nothing belonging to a running build can
# ever qualify. Anything lacking a BuildDate tag is reported, never deleted.
#
# Deleting a scratch managed image is safe: the published gallery version keeps
# its own replicated copy, and storageProfile.source.id is provenance only.
#
# Usage:
#   packer-cleanup.sh sweep-build-groups [max_age_hours]
#   packer-cleanup.sh sweep-build-resources <resource-group> [max_age_hours]
#   packer-cleanup.sh sweep-scratch-images <resource-group> [max_age_hours]
#   packer-cleanup.sh delete-scratch-image <resource-group> <image-name>
#
set -uo pipefail

# Delete leftover pkr-* resource groups from builds that died before Packer could
# clean up. Only groups whose BuildDate tag is older than max_age_hours (default
# 24) are touched, so a build running right now is never disturbed. Groups with
# no BuildDate tag are reported, never deleted.
sweep_build_groups() {
  local max_age_hours="${1:-24}"
  local cutoff
  # python3 rather than `date -d`, which is GNU-only and not portable to macOS
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$max_age_hours")

  local groups
  groups=$(az group list \
    --query "[?starts_with(name,'pkr-')].{name:name,built:tags.BuildDate}" \
    -o tsv 2>/dev/null)

  if [ -z "$groups" ]; then
    echo "No leftover pkr-* resource groups."
    return 0
  fi

  echo "Leftover pkr-* resource groups found (cutoff ${cutoff}):"
  while IFS=$'\t' read -r name built; do
    [ -z "$name" ] && continue
    if [ -z "${built:-}" ]; then
      echo "::warning::Packer build group $name has no BuildDate tag - leaving it, delete by hand after checking no build is running."
      continue
    fi
    if [[ "$built" < "$cutoff" ]]; then
      echo "::warning::Deleting leaked Packer build group $name (built $built) - a build was cancelled or crashed."
      az group delete --name "$name" --yes --no-wait \
        || echo "::warning::Could not delete $name - delete it by hand."
    else
      echo "Skipping $name (built $built) - too recent, a build may still be using it."
    fi
  done <<< "$groups"
}

# Delete the intermediate managed image this build just created. Runs after the
# gallery version has been published, and also after a failed build (where the
# image, if it exists at all, is dead weight nothing references).
delete_scratch_image() {
  local rg="$1" name="$2"

  if ! az image show -g "$rg" -n "$name" -o none 2>/dev/null; then
    echo "No intermediate managed image $name in $rg - nothing to clean up."
    return 0
  fi

  echo "Deleting intermediate managed image $name from $rg"
  if az image delete -g "$rg" -n "$name"; then
    echo "Deleted $name."
  else
    echo "::warning::Could not delete intermediate managed image $name in $rg - delete it by hand."
  fi
}

# Safety net for scratch images that delete_scratch_image never got to: a build
# killed between publishing the image and running its cleanup step, or a repo
# that has not adopted that step yet. Nothing ever boots a scratch managed image,
# and a live build's own image is only minutes old, so anything past max_age_hours
# is dead by definition - whichever project built it. Images with no BuildDate tag
# are reported, never deleted.
sweep_scratch_images() {
  local rg="$1" max_age_hours="${2:-24}"
  local cutoff
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$max_age_hours")

  local images
  images=$(az image list -g "$rg" --query "[].{name:name,built:tags.BuildDate}" -o tsv 2>/dev/null)

  if [ -z "$images" ]; then
    echo "No leftover scratch managed images in $rg."
    return 0
  fi

  echo "Scratch managed images in $rg (cutoff ${cutoff}):"
  while IFS=$'\t' read -r name built; do
    [ -z "$name" ] && continue
    if [ -z "${built:-}" ]; then
      echo "::warning::Scratch image $name has no BuildDate tag - leaving it, delete by hand once you know what built it."
    elif [[ "$built" < "$cutoff" ]]; then
      echo "::warning::Deleting stale scratch image $name (built $built) - its build never cleaned up after itself."
      az image delete -g "$rg" -n "$name" \
        || echo "::warning::Could not delete $name - delete it by hand."
    else
      echo "Skipping $name (built $built) - too recent, a build may still be publishing it."
    fi
  done <<< "$images"
}

# The other leak shape. lib-main lets Packer create a throwaway pkr-* resource
# group, so a dead build leaks the whole group and sweep_build_groups finds it.
# volumes-infra instead passes build_resource_group_name, so Packer builds
# *inside* an existing RG - a dead build there leaks loose pkrvm/pkrni/pkros
# resources into a shared RG and leaves NO group to find. Same running-VM bill,
# invisible to the group sweep.
#
# Two independent conditions before anything is deleted: the name starts with
# "pkr" AND the resource is tagged Builder=packer. Deletion is ordered - VMs
# first, since a NIC or disk cannot be deleted while a VM holds it.
sweep_build_resources() {
  local rg="$1" max_age_hours="${2:-24}"
  local cutoff
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$max_age_hours")

  local found
  found=$(az resource list -g "$rg" \
    --query "[?starts_with(name,'pkr') && tags.Builder=='packer'].{id:id,name:name,type:type,built:tags.BuildDate}" \
    -o tsv 2>/dev/null)

  if [ -z "$found" ]; then
    echo "No stray Packer build resources in $rg."
    return 0
  fi

  # Bucket by type so VMs can be deleted before the things they hold.
  local vms="" nics="" others=""
  while IFS=$'\t' read -r id name type built; do
    [ -z "$id" ] && continue
    if [ -z "${built:-}" ]; then
      echo "::warning::Stray Packer resource $name ($type) has no BuildDate tag - leaving it, check it by hand."
      continue
    fi
    if [[ ! "$built" < "$cutoff" ]]; then
      echo "Skipping $name (built $built) - too recent, a build may still be using it."
      continue
    fi
    echo "::warning::Leaked Packer resource $name ($type, built $built) - its build died without cleaning up."
    case "$type" in
      Microsoft.Compute/virtualMachines)   vms="$vms $id" ;;
      Microsoft.Network/networkInterfaces) nics="$nics $id" ;;
      *)                                   others="$others $id" ;;
    esac
  done <<< "$found"

  local phase
  for phase in "$vms" "$nics" "$others"; do
    [ -z "${phase// /}" ] && continue
    # shellcheck disable=SC2086
    az resource delete --ids $phase \
      || echo "::warning::Some stray Packer resources in $rg could not be deleted - remove them by hand."
  done
}

case "${1:-}" in
  sweep-build-groups)   sweep_build_groups "${2:-24}" ;;
  sweep-build-resources) sweep_build_resources "${2:?resource group required}" "${3:-24}" ;;
  sweep-scratch-images) sweep_scratch_images "${2:?resource group required}" "${3:-24}" ;;
  delete-scratch-image) delete_scratch_image "${2:?resource group required}" "${3:?image name required}" ;;
  *) echo "Usage: $0 {sweep-build-groups [max_age_hours]|sweep-build-resources <rg> [max_age_hours]|sweep-scratch-images <rg> [max_age_hours]|delete-scratch-image <rg> <image-name>}" >&2; exit 2 ;;
esac
