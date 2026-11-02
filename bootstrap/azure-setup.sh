#!/usr/bin/env bash
# ==============================================================================
# Azure bootstrap for volumes-infra
# ==============================================================================
# Creates the foundational Azure resources that Terraform cannot create for
# itself, then prints the gh commands to configure the repository.
#
# Idempotent: every step checks for an existing resource first, so re-running
# after a partial failure is safe.
#
# What this creates:
#   - Five resource groups (tfstate, secrets, production, devtest, dev)
#   - The Terraform state storage account + tfstate container
#   - An app image definition in the SHARED Compute Gallery owned by
#     lib-main-infra (the gallery itself is NOT created here)
#   - An Entra app registration + service principal with federated (OIDC)
#     credentials and NO password
#   - Least-privilege role assignments scoped to the above
#
# What this deliberately does NOT do:
#   - Accept Rocky Linux marketplace terms. Those are per-subscription and were
#     already accepted for lib-main in this same subscription.
#   - Build a base image. lib-main-infra owns and rebuilds it monthly.
#   - Seed Key Vault secrets. See docs/bootstrap-runbook.md step 4.
#
# Prerequisites: az CLI logged in with rights to create app registrations and
# assign roles at resource-group scope; gh CLI logged in; and the GitHub repo
# utkdigitalinitiatives/volumes-infra already created (the OIDC subject is read
# from it).
#
# Usage:
#   ./bootstrap/azure-setup.sh
#   PROJECT_NAME=othersite ./bootstrap/azure-setup.sh
# ==============================================================================

set -euo pipefail

# --- Configuration ------------------------------------------------------------

PROJECT_NAME="${PROJECT_NAME:-volumes}"
STORAGE_PREFIX="${STORAGE_PREFIX:-vol}"
LOCATION="${LOCATION:-eastus2}"
SUBSCRIPTION_NAME="${SUBSCRIPTION_NAME:-UTK-Library-Systems}"

GITHUB_ORG="${GITHUB_ORG:-utkdigitalinitiatives}"
INFRA_REPO="${INFRA_REPO:-${PROJECT_NAME}-infra}"

# Shared with lib-main-infra. This script only ADDS an image definition here.
SHARED_GALLERY_RG="${SHARED_GALLERY_RG:-lib-main-images-rg}"

# The PRIVATE app repo the image is built from. The build checks it out with a
# read-only deploy key; see the summary at the end and runbook step 2.
APP_REPO="${APP_REPO:-${GITHUB_ORG}/${PROJECT_NAME}}"

# No Asimov (Solr) peering yet, so unlike mccarthy-infra there is no Network
# Contributor grant on the Asimov AKS VNet below. Add it with the peering.
SHARED_GALLERY_NAME="${SHARED_GALLERY_NAME:-lib_main_gallery}"
BASE_IMAGE_DEF="${BASE_IMAGE_DEF:-drupal-base-rocky-linux-9}"
APP_IMAGE_DEF="${APP_IMAGE_DEF:-${PROJECT_NAME}-rocky-linux-9}"

SP_NAME="${PROJECT_NAME}-github-actions"

TFSTATE_RG="${PROJECT_NAME}-tfstate-rg"
SECRETS_RG="${PROJECT_NAME}-secrets-rg"
PRODUCTION_RG="${PROJECT_NAME}-production-rg"
DEVTEST_RG="${PROJECT_NAME}-devtest-rg"
DEV_RG="${PROJECT_NAME}-dev-rg"

ALL_RGS=("$TFSTATE_RG" "$SECRETS_RG" "$PRODUCTION_RG" "$DEVTEST_RG" "$DEV_RG")

banner() { printf '\n=== %s ===\n' "$1"; }

# --- Subscription -------------------------------------------------------------

banner "Subscription"
az account set --subscription "$SUBSCRIPTION_NAME"
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"
echo "Tenant:       $TENANT_ID"

# --- Preflight: the shared gallery must already exist --------------------------

banner "Preflight: shared gallery"
if ! az sig show --resource-group "$SHARED_GALLERY_RG" --gallery-name "$SHARED_GALLERY_NAME" >/dev/null 2>&1; then
  echo "ERROR: shared gallery $SHARED_GALLERY_RG/$SHARED_GALLERY_NAME not found." >&2
  echo "This project builds on lib-main-infra's gallery. Either it was renamed," >&2
  echo "or you are in the wrong subscription." >&2
  exit 1
fi
echo "Found $SHARED_GALLERY_NAME"

if ! az sig image-definition show \
  --resource-group "$SHARED_GALLERY_RG" \
  --gallery-name "$SHARED_GALLERY_NAME" \
  --gallery-image-definition "$BASE_IMAGE_DEF" >/dev/null 2>&1; then
  echo "ERROR: base image definition $BASE_IMAGE_DEF not found in the shared gallery." >&2
  echo "lib-main-infra owns it; check that repo's base-image-build.yml has run." >&2
  exit 1
fi
echo "Found base image definition $BASE_IMAGE_DEF"

# --- Resource groups ----------------------------------------------------------
#
# ALL resource groups are created here, not by Terraform. That lets the service
# principal below be scoped per-RG rather than holding subscription-wide
# Contributor, and it avoids the first-apply `terraform import` that lib-main
# hits by creating its production RG in two places.

banner "Resource groups"
for rg in "${ALL_RGS[@]}"; do
  if az group show --name "$rg" >/dev/null 2>&1; then
    echo "exists:  $rg"
  else
    az group create --name "$rg" --location "$LOCATION" --output none
    echo "created: $rg"
  fi
done

# --- App image definition in the shared gallery --------------------------------

banner "App image definition"
if az sig image-definition show \
  --resource-group "$SHARED_GALLERY_RG" \
  --gallery-name "$SHARED_GALLERY_NAME" \
  --gallery-image-definition "$APP_IMAGE_DEF" >/dev/null 2>&1; then
  echo "exists:  $APP_IMAGE_DEF"
else
  az sig image-definition create \
    --resource-group "$SHARED_GALLERY_RG" \
    --gallery-name "$SHARED_GALLERY_NAME" \
    --gallery-image-definition "$APP_IMAGE_DEF" \
    --publisher UTKLibraries \
    --offer "$PROJECT_NAME" \
    --sku rocky-linux-9 \
    --os-type Linux \
    --os-state Generalized \
    --hyper-v-generation V2 \
    --output none
  echo "created: $APP_IMAGE_DEF"
fi

# --- Terraform state storage --------------------------------------------------

banner "Terraform state storage"
STORAGE_NAME=$(az storage account list --resource-group "$TFSTATE_RG" \
  --query "[?starts_with(name, '${PROJECT_NAME//-/}tfstate')].name | [0]" -o tsv 2>/dev/null || true)

if [ -n "$STORAGE_NAME" ] && [ "$STORAGE_NAME" != "null" ]; then
  echo "exists:  $STORAGE_NAME"
else
  # <project>tfstate<8 hex> must stay within the 24-char storage account limit.
  STORAGE_NAME="${PROJECT_NAME//-/}tfstate$(openssl rand -hex 4)"
  if [ ${#STORAGE_NAME} -gt 24 ]; then
    echo "ERROR: generated storage account name '$STORAGE_NAME' is ${#STORAGE_NAME} chars (max 24)." >&2
    echo "Shorten PROJECT_NAME or set STORAGE_NAME manually." >&2
    exit 1
  fi
  az storage account create \
    --name "$STORAGE_NAME" \
    --resource-group "$TFSTATE_RG" \
    --location "$LOCATION" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    --output none
  echo "created: $STORAGE_NAME"
fi

if az storage container show --name tfstate --account-name "$STORAGE_NAME" --auth-mode login >/dev/null 2>&1; then
  echo "exists:  container tfstate"
else
  az storage container create --name tfstate --account-name "$STORAGE_NAME" --auth-mode login --output none
  echo "created: container tfstate"
fi

STORAGE_ID=$(az storage account show --name "$STORAGE_NAME" --resource-group "$TFSTATE_RG" --query id -o tsv)

# --- Service principal with federated (OIDC) credentials -----------------------
#
# No password is ever created. Workflows present a short-lived GitHub OIDC token
# and Entra exchanges it for an access token, so there is no AZURE_CLIENT_SECRET
# to store, rotate, or leak.

banner "Service principal (OIDC)"
APP_ID=$(az ad app list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [ -n "$APP_ID" ] && [ "$APP_ID" != "null" ]; then
  echo "exists:  app registration $SP_NAME ($APP_ID)"
else
  APP_ID=$(az ad app create --display-name "$SP_NAME" --query appId -o tsv)
  echo "created: app registration $SP_NAME ($APP_ID)"
fi

if az ad sp show --id "$APP_ID" >/dev/null 2>&1; then
  echo "exists:  service principal"
else
  az ad sp create --id "$APP_ID" --output none
  echo "created: service principal"
fi

SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)
echo "SP object ID: $SP_OBJECT_ID"

# Subjects must match exactly what GitHub presents -- Entra does no wildcarding.
#   - repository_dispatch and schedule events always run on the DEFAULT BRANCH,
#     so the refs/heads/main subject is what the deploy pipelines actually use.
#   - the environment: subjects cover jobs that declare `environment:`.
#
# The prefix is NOT always "repo:<org>/<repo>". GitHub has begun issuing
# immutable subject claims that embed the numeric org and repo IDs, e.g.
# "repo:utkdigitalinitiatives@11233454/mccarthy-infra@1316465775", which survive
# a rename where the name-based form does not. mccarthy-infra gets the immutable
# form and the older lib-main-infra does not, so this cannot be hardcoded either
# way -- ask GitHub what it will actually present. Guessing wrong costs you a
# failed run and an AADSTS700213 that names the subject it wanted.
#
# So the GitHub repo must exist BEFORE this runs. mccarthy-infra's copy fell
# back to the name-based form when GitHub did not answer; a repo created in 2026
# gets the immutable form, so that guess would be wrong every time. Stop instead.
SUB_PREFIX=$(gh api "repos/${GITHUB_ORG}/${INFRA_REPO}/actions/oidc/customization/sub" \
  --jq '.sub_claim_prefix // empty' 2>/dev/null)
if [ -z "$SUB_PREFIX" ]; then
  echo "ERROR: could not read the OIDC subject prefix for $GITHUB_ORG/$INFRA_REPO." >&2
  echo "Create the GitHub repository first, and check 'gh auth status'." >&2
  exit 1
fi
echo "OIDC subject prefix: $SUB_PREFIX"

add_federated_credential() {
  local name="$1" subject="$2" current
  # Match on name but reconcile on subject. The subject IS the credential; a
  # stale one is not a harmless leftover, it fails every single run. Checking
  # only for existence would leave an already-bootstrapped project broken after
  # GitHub changes the claim format, which is exactly when you re-run this.
  current=$(az ad app federated-credential show \
    --id "$APP_ID" --federated-credential-id "$name" \
    --query subject -o tsv 2>/dev/null || true)

  if [ "$current" = "$subject" ]; then
    echo "exists:  federated credential $name"
    return
  fi

  if [ -n "$current" ]; then
    az ad app federated-credential update \
      --id "$APP_ID" --federated-credential-id "$name" --parameters "{
      \"name\": \"$name\",
      \"issuer\": \"https://token.actions.githubusercontent.com\",
      \"subject\": \"$subject\",
      \"description\": \"GitHub Actions OIDC for $GITHUB_ORG/$INFRA_REPO\",
      \"audiences\": [\"api://AzureADTokenExchange\"]
    }" --output none
    echo "updated: federated credential $name"
    echo "           was: $current"
    echo "           now: $subject"
    return
  fi

  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\",
    \"description\": \"GitHub Actions OIDC for $GITHUB_ORG/$INFRA_REPO\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
  echo "created: federated credential $name -> $subject"
}

banner "Federated credentials"
add_federated_credential "github-main"        "${SUB_PREFIX}:ref:refs/heads/main"
add_federated_credential "github-env-prod"    "${SUB_PREFIX}:environment:production"
add_federated_credential "github-env-dev"     "${SUB_PREFIX}:environment:dev"
add_federated_credential "github-pull-request" "${SUB_PREFIX}:pull_request"

# --- Role assignments ---------------------------------------------------------
#
# Scoped per-resource-group rather than subscription-wide Contributor.

assign_role() {
  local role="$1" scope="$2"
  if az role assignment list --assignee "$SP_OBJECT_ID" --role "$role" --scope "$scope" \
      --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    echo "exists:  $role on ${scope##*/}"
  else
    az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --output none
    echo "created: $role on ${scope##*/}"
  fi
}

banner "Role assignments"
for rg in "${ALL_RGS[@]}"; do
  assign_role "Contributor" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$rg"
done

# Packer publishes the app image version into the shared gallery, and creates an
# intermediate managed image in that same resource group.
assign_role "Contributor" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SHARED_GALLERY_RG"

# environments/secrets creates role assignments on the Key Vault; Contributor
# alone cannot write role assignments.
assign_role "Role Based Access Control Administrator" "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$SECRETS_RG"

# Required because every `terraform init` passes use_azuread_auth=true.
# MUST exist before shared key access is disabled (see the note below).
assign_role "Storage Blob Data Contributor" "$STORAGE_ID"

# The same grant for the human running the local applies in runbook steps 3-6.
# Owner at subscription scope does NOT confer data-plane blob access, so without
# this a local `terraform init -backend-config=use_azuread_auth=true` cannot read
# state -- the SP grant above only helps CI.
OPERATOR_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [ -n "$OPERATOR_OBJECT_ID" ]; then
  if az role assignment list --assignee "$OPERATOR_OBJECT_ID" --role "Storage Blob Data Contributor" \
      --scope "$STORAGE_ID" --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    echo "exists:  Storage Blob Data Contributor on ${STORAGE_ID##*/} (operator)"
  else
    az role assignment create --assignee-object-id "$OPERATOR_OBJECT_ID" \
      --assignee-principal-type User \
      --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" --output none
    echo "created: Storage Blob Data Contributor on ${STORAGE_ID##*/} (operator)"
  fi
else
  echo "WARNING: could not resolve the signed-in user; grant yourself" >&2
  echo "         Storage Blob Data Contributor on $STORAGE_ID before a local apply." >&2
fi

# --- Summary ------------------------------------------------------------------

banner "Bootstrap complete"
cat <<EOF

Set the repository secrets and variables with:

  gh secret set AZURE_CLIENT_ID       --repo $GITHUB_ORG/$INFRA_REPO --body "$APP_ID"
  gh secret set AZURE_TENANT_ID       --repo $GITHUB_ORG/$INFRA_REPO --body "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID --repo $GITHUB_ORG/$INFRA_REPO --body "$SUBSCRIPTION_ID"
  gh secret set SSH_PUBLIC_KEY        --repo $GITHUB_ORG/$INFRA_REPO --body "\$(cat ~/.ssh/id_ed25519.pub)"

The app repo is private, so the image build needs a read-only deploy key on it.
Generate one, register the public half on $APP_REPO, store the private half
here, then delete both local copies:

  ssh-keygen -t ed25519 -N '' -C "$INFRA_REPO image build" -f ./app-repo-deploy-key
  gh repo deploy-key add ./app-repo-deploy-key.pub --repo $APP_REPO --title "$INFRA_REPO image build"
  gh secret set APP_REPO_DEPLOY_KEY  --repo $GITHUB_ORG/$INFRA_REPO < ./app-repo-deploy-key
  rm -f ./app-repo-deploy-key ./app-repo-deploy-key.pub

  gh variable set PROJECT_NAME            --repo $GITHUB_ORG/$INFRA_REPO --body "$PROJECT_NAME"
  gh variable set APP_REPO                --repo $GITHUB_ORG/$INFRA_REPO --body "$APP_REPO"
  gh variable set STORAGE_PREFIX          --repo $GITHUB_ORG/$INFRA_REPO --body "$STORAGE_PREFIX"
  gh variable set LOCATION                --repo $GITHUB_ORG/$INFRA_REPO --body "$LOCATION"
  gh variable set COST_CENTER             --repo $GITHUB_ORG/$INFRA_REPO --body "<cost center>"
  gh variable set GALLERY_NAME            --repo $GITHUB_ORG/$INFRA_REPO --body "$SHARED_GALLERY_NAME"
  gh variable set GALLERY_RESOURCE_GROUP  --repo $GITHUB_ORG/$INFRA_REPO --body "$SHARED_GALLERY_RG"
  gh variable set BASE_IMAGE_NAME         --repo $GITHUB_ORG/$INFRA_REPO --body "$BASE_IMAGE_DEF"
  gh variable set APP_IMAGE_NAME          --repo $GITHUB_ORG/$INFRA_REPO --body "$APP_IMAGE_DEF"
  gh variable set TF_STATE_RESOURCE_GROUP --repo $GITHUB_ORG/$INFRA_REPO --body "$TFSTATE_RG"
  gh variable set TF_STATE_STORAGE_ACCOUNT --repo $GITHUB_ORG/$INFRA_REPO --body "$STORAGE_NAME"
  gh variable set DB_ADMIN_USERNAME       --repo $GITHUB_ORG/$INFRA_REPO --body "drupaladmin"
  gh variable set DB_NAME                 --repo $GITHUB_ORG/$INFRA_REPO --body "drupal"
  gh variable set PG_MAJOR                --repo $GITHUB_ORG/$INFRA_REPO --body "18"
  gh variable set MEDIA_CONTAINER         --repo $GITHUB_ORG/$INFRA_REPO --body "drupal-media"
  gh variable set PROD_DB_HOST            --repo $GITHUB_ORG/$INFRA_REPO --body "${PROJECT_NAME}-production-psql.postgres.database.azure.com"
  gh variable set NOTIFY_EMAIL_TO         --repo $GITHUB_ORG/$INFRA_REPO --body "<comma-separated recipients>"
  gh variable set NOTIFY_EMAIL_FROM       --repo $GITHUB_ORG/$INFRA_REPO --body "$INFRA_REPO <sender@utk.edu>"

Values that only exist AFTER the corresponding terraform apply:

  DEVTEST_DB_HOST         <- terraform -chdir=environments/devtest output -raw postgresql_fqdn
  DEVTEST_STORAGE_ACCOUNT <- terraform -chdir=environments/devtest output -raw storage_account_name
  PROD_STORAGE_ACCOUNT    <- terraform -chdir=environments/production output -raw storage_account_name
  SUBNET_ID               <- terraform -chdir=environments/production output -raw web_subnet_id
  DRUPAL_SITE_UUID        <- grep '^uuid:' config/system.site.yml   (in a checkout of $APP_REPO)
                             NEVER generate one. It already exists in the app repo,
                             and config:import fails against a mismatched site UUID.
  DOMAIN_NAME             <- the site FQDN
  PUBLIC_IP_ID            <- resource ID of the externally-managed public IP, if used
  LB_DNS_LABEL            <- DNS label if Terraform creates the public IP instead

Next: docs/bootstrap-runbook.md, from step 3.

NOTE ON DISABLING SHARED KEYS:
The state storage account still permits shared key access. Terraform is already
configured for Entra auth (use_azuread_auth=true) and the role assignment above
grants it. Once you have confirmed a successful 'terraform init' + 'plan',
harden it with:

  az storage account update --name $STORAGE_NAME \\
    --resource-group $TFSTATE_RG --allow-shared-key-access false

Do NOT run that before the Storage Blob Data Contributor assignment has
propagated (allow a few minutes) or you will lock yourself out of state.
EOF
