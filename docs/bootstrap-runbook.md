# Bootstrap runbook

Stands up `volumes` from nothing. Follow in order — several steps depend on
outputs of earlier ones.

Adapted from mccarthy-infra's runbook, which was executed between 2026-07-31 and
2026-08-11 and had its rough edges folded back in. The steps below are in the
order that actually works there, not the order they were first written in.

**Status: nothing executed.**

| Step | State |
|---|---|
| 0. GitHub repo + environments | repo created and pushed (public, `f46b550`, 2026-11-02); environments not checked |
| 1. Bootstrap script | not started |
| 2. Repo secrets, variables, deploy key | not started |
| 3. `environments/secrets` | not started |
| 4. Manual Key Vault secrets | not started |
| 5. `environments/devtest` | not started |
| 6. First image build (bootstrap) | not started |
| 7. `environments/production` | not started |
| 8. Harden state account | not started |
| 9. App repo wiring | not started |
| 10. No start/stop schedule | n/a — workflow removed |

**Nothing in this repository has ever run.** mccarthy-infra's first three
dispatches each failed on a different latent defect — OIDC subject format,
Packer's build resource group, and a Drush-less Composer fallback — none of
which were visible from reading the code. Those three are fixed here. The
private-repo checkout and tarball path is new here and has never run in CI.

---

## Prerequisites

- `az` CLI, logged in, with rights to create Entra app registrations and to
  assign roles at resource-group scope (activate PIM first — without it, `az ...
  list` returns **empty** instead of erroring)
- `terraform` >= 1.0, `gh` CLI, `ssh-keygen`
- Access to the `UTK-Library-Systems` subscription
- Write access to `lib-main-images-rg` (the shared gallery lives there)
- Admin on `utkdigitalinitiatives/volumes` (to add a deploy key)

---

## 0. Create the GitHub repo and its environments

`bootstrap/azure-setup.sh` reads the OIDC subject prefix from the GitHub repo,
so the repo must exist first. A repo created now gets the immutable subject
form (`repo:utkdigitalinitiatives@<orgid>/volumes-infra@<repoid>`); the script
stops rather than guess.

```bash
gh repo create utkdigitalinitiatives/volumes-infra --public   # or --private; see below
```

Already done: the repo exists, is public, and has the scaffold commit pushed
(`f46b550`, 2026-11-02). The rest of this step — the environments — has not been
checked.

Public or private is a real choice. mccarthy-infra is public, and everything
here is written as if this repo is too: no secrets in git, tfvars ignored, the
DB dump goes to private blob storage rather than an artifact. Private loses
nothing.

**Create the environments with a reviewer before anything can dispatch.**
GitHub auto-creates a missing environment on first use **with no protection
rules**, so `environment: production` in the YAML enforces nothing on its own.
mccarthy-infra ran that way unnoticed. Check with
`gh api repos/utkdigitalinitiatives/volumes-infra/environments`.

## 1. Run the bootstrap script

```bash
./bootstrap/azure-setup.sh
```

Creates the five resource groups, the Terraform state storage account, the
`volumes-rocky-linux-9` image definition inside the **shared** gallery, and the
`volumes-github-actions` service principal with federated OIDC credentials and
no password. It is idempotent; re-run freely.

It does **not**:

- accept Rocky Linux marketplace terms — already accepted in this subscription
  for lib-main;
- build a base image — `lib-main-infra` owns that;
- create the Compute Gallery — shared, already exists;
- grant anything on the Asimov AKS VNet — no Solr peering yet.

## 2. Set repo secrets, variables and the deploy key

The script prints the `gh secret set` / `gh variable set` commands for
everything known at this point. Run them.

It also prints the deploy-key commands. The app repo is private, so the image
build checks it out with a read-only deploy key. The private half lives only in
this repo's `APP_REPO_DEPLOY_KEY` secret:

```bash
ssh-keygen -t ed25519 -N '' -C "volumes-infra image build" -f ./app-repo-deploy-key
gh repo deploy-key add ./app-repo-deploy-key.pub --repo utkdigitalinitiatives/volumes \
  --title "volumes-infra image build"
gh secret set APP_REPO_DEPLOY_KEY --repo utkdigitalinitiatives/volumes-infra < ./app-repo-deploy-key
rm -f ./app-repo-deploy-key ./app-repo-deploy-key.pub
```

`gh repo deploy-key add` is read-only unless you pass `--allow-write`. Do not.

## 3. Apply `environments/secrets/`

```bash
cd environments/secrets
cp backend.hcl.example backend.hcl          # fill in the storage account name
cp terraform.tfvars.example terraform.tfvars # fill in subscription, cost center, SP object ID
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply
```

`gh_actions_sp_object_id` is the **object ID**, not the app/client ID:

```bash
az ad sp show --id <appId> --query id -o tsv
```

Local applies authenticate with your `az login` session. This environment has no
`use_oidc` variable — omitting `-backend-config="use_oidc=true"` from `init` is
all that is needed. `devtest` and `production` *do* declare one, already `false`
in their example tfvars.

`use_azuread_auth=true` also means **you** need `Storage Blob Data Contributor`
on the state storage account. The bootstrap script grants it to the signed-in
user. Owner at subscription scope is not sufficient — it carries no data-plane
blob access.

## 4. Seed the manual Key Vault secrets

Terraform generates the hash salts, the Drupal admin password, the Anubis keys,
and mirrors the storage keys. These four must be seeded by hand:

```bash
KV=$(az keyvault list -g volumes-secrets-rg --query "[0].name" -o tsv)

az keyvault secret set --vault-name "$KV" --name production-db-admin-password     --value '<generated>'
az keyvault secret set --vault-name "$KV" --name devtest-db-admin-password        --value '<generated>'
az keyvault secret set --vault-name "$KV" --name shared-postmark-api-token        --value '<Postmark "DevOps" server token>'
az keyvault secret set --vault-name "$KV" --name production-drupal-postmark-token --value '<Postmark "Libraries Website" server token>'
```

- The two DB passwords **must differ**. The sync jobs fetch both; mccarthy's
  first end-to-end run failed because a step assumed one.
- Generate them with `openssl rand -base64 32 | tr -d '/+=' | head -c 32`.
  PostgreSQL rejects some punctuation, so stick to alphanumerics.
- `shared-postmark-api-token` sends the workflows' deploy email.
  `production-drupal-postmark-token` is Drupal's own mail (password resets).
  mccarthy's vault holds both; reuse them unless this site should get its own
  Postmark server. Without the second, production still serves but cannot send
  mail, and the boot log says so.
- Do not seed values through `sed -E` on macOS: `\s` is a literal `s` there,
  which once stored `db_admin_password = "..."` as a password in lib-main.

## 5. Apply `environments/devtest/`

```bash
cd environments/devtest
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply
```

**Expect the first apply to fail on `DefenderForStorageSettings/current`.**
devtest opts its storage account out of Defender, and Azure pre-creates that
singleton, so it must be imported, not created. mccarthy-infra's `docs/TODO.md`
has the exact `terraform import` line ("`DefenderForStorageSettings/current`
must be imported, never created").

Then publish the outputs the workflows need:

```bash
gh variable set DEVTEST_DB_HOST         --body "$(terraform output -raw postgresql_fqdn)"
gh variable set DEVTEST_STORAGE_ACCOUNT --body "$(terraform output -raw storage_account_name)"
```

## 6. First image build

Production reads the app image through a data source, so a plan fails outright
until `volumes-rocky-linux-9` has at least one version. Build one first.

Confirm the shared base image exists:

```bash
az sig image-version list \
  --resource-group lib-main-images-rg \
  --gallery-name lib_main_gallery \
  --gallery-image-definition drupal-base-rocky-linux-9 \
  --query "sort_by([].name, &@)[-1]" -o tsv
```

Only `build-on-dispatch.yml` writes into the image definition, and it is
`repository_dispatch`-only. Kick off a bootstrap build by hand:

```bash
gh api repos/utkdigitalinitiatives/volumes-infra/dispatches \
  -f event_type=drupal-dev-merge \
  -f 'client_payload[bootstrap_build]=true'
```

`bootstrap_build` builds the image with **no app repo**, from vanilla Drupal via
`composer create-project`, and skips the three downstream jobs (they all read
from a production that does not exist yet). That proves the load balancer,
public IP, TLS and cloud-init — but it is not the site. Rebuild from the app
repo once step 9 is done.

Use `-f`, not `-F`. `-F` sends a JSON boolean, and GitHub's expression
comparison coerces mismatched types to numbers, so a boolean `true` would walk
past a guard written against the string. The workflow normalises the flag into a
job output for exactly this reason.

To exercise the private-repo path before the app repo has workflows, dispatch a
real payload by hand once the deploy key is in place:

```bash
SHA=$(gh api repos/utkdigitalinitiatives/volumes/commits/main --jq .sha)
gh api repos/utkdigitalinitiatives/volumes-infra/dispatches \
  -f event_type=drupal-dev-merge \
  -f "client_payload[drupal_repo]=https://github.com/utkdigitalinitiatives/volumes.git" \
  -f 'client_payload[drupal_ref]=main' \
  -f "client_payload[drupal_sha]=$SHA"
```

Do that only after production exists: a non-bootstrap dispatch goes on to sync
the database and deploy the dev VM.

## 7. Apply `environments/production/`

**Do not generate a site UUID.** It already exists in the app repo:

```bash
gh api repos/utkdigitalinitiatives/volumes/contents/config/system.site.yml \
  --jq .content | base64 -d | grep '^uuid:'
#   uuid: f9411c09-e1c6-476c-b13e-430189fba5b8
```

Cloud-init runs `drush site:install` (which mints a throwaway random UUID),
immediately overwrites it with this value, then runs `config:import` — which
Drupal refuses if the two disagree.

The first boot also creates the super user. Its username (`admin`) and email,
and the site name and email, come from `drupal_site_name`, `drupal_site_mail`,
`drupal_admin_username` and `drupal_admin_mail` — defaults set to the devs'
choices (`Volumes | UTK Libraries`, `librarieswebsite@utk.edu`). The site name
and mail must match `config/system.site.yml`, which `config:import` re-asserts
on later boots; they do today. The admin account is never touched again, so
change those two before the first apply or not at all. Its password is in Key
Vault as `production-drupal-admin-password`.

Read the install profile from the same place, for the same reason:

```bash
gh api repos/utkdigitalinitiatives/volumes/contents/config/core.extension.yml \
  --jq .content | base64 -d | grep '^profile:'
#   profile: minimal
```

### Public IP and domain

Not decided yet. Two shapes worked for mccarthy:

- **Terraform-created IP** — leave `public_ip_id = null`, set `lb_dns_label`.
  Simple, but the address dies with the load balancer.
- **Hand-made, locked IP** (what mccarthy production runs since 2026-09-24) —
  create `volumes-production-pip` (Standard, static) in `volumes-production-rg`,
  put a `CanNotDelete` lock on it, and pass its ID as `public_ip_id`. It
  survives a rebuild, so DNS never has to change. Being inside an RG the SP
  already holds Contributor on, no extra grant is needed.

If you instead borrow an address from `dns-test-rg` (mccarthy's libtest1 era),
the SP needs `Network Contributor` scoped to that one IP, and the IP must first
be detached from whatever it fronts (`az network nic ip-config update ...
--remove publicIpAddress`; passing `""` fails with InvalidResourceReference).

`domain_name` is not only the TLS CN. It is baked into `settings.php` as a
trusted host pattern and as `az_blob_cdn_host_name`, which is what makes Drupal
emit media URLs on the site domain for Apache to rewrite to blob + SAS. Changing
it later is a re-apply plus a VMSS reimage.

```bash
cd environments/production
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars   # fill in UUID, domain, SSH key, IP
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform apply -var="image_version=<the version step 6 built>"
```

`image_version` has no default and is not in tfvars, on purpose. Pass it on
every manual run.

**Two-pass deployment.** Leave `enable_vmss_blob_access = false` for the first
apply — the VMSS does not exist yet, so there is no managed identity to grant
blob access to. Set it to `true` and apply again. Until the second pass the VMSS
cannot write the TLS certificate to blob storage; mccarthy's first certificate
was never persisted because of exactly this, and the first reimage took HTTPS
down for 25 minutes. After pass two, check the `tls-certs` container holds both
PEMs.

**The private files account needs the same Defender import as devtest** on its
first apply (`azapi_resource.private_files_defender_off`).

Then:

```bash
gh variable set PROD_STORAGE_ACCOUNT --body "$(terraform output -raw storage_account_name)"
gh variable set SUBNET_ID            --body "$(terraform output -raw web_subnet_id)"
gh variable set DRUPAL_SITE_UUID     --body "f9411c09-e1c6-476c-b13e-430189fba5b8"
gh variable set DOMAIN_NAME          --body "<site fqdn>"
```

## 8. Harden the state storage account

Once `terraform init` and `plan` have both succeeded against the Entra-auth
backend, and the role assignment has had a few minutes to propagate:

```bash
az storage account update --name <state account> \
  --resource-group volumes-tfstate-rg --allow-shared-key-access false
```

Doing this **before** `Storage Blob Data Contributor` has propagated locks you
out of your own state. Check every consumer first — there is no shared-key
fallback afterwards:

- all `terraform init` calls in `.github/workflows/` pass
  `use_azuread_auth=true` (and `use_oidc=true`)
- the `terraform_remote_state.secrets` data source in `production`, `devtest` and
  `dev` passes `use_azuread_auth = var.use_azuread_auth`, which defaults to `true`
- nothing sets `ARM_ACCESS_KEY` or a SAS token anywhere

## 9. Wire the app repository

See the README's "Contract the app repo must satisfy" for the full list and its
state. In order:

1. **Dispatch App.** Add `volumes-infra` to the `lib-dispatch` App's selected
   repositories (UI only:
   `https://github.com/organizations/utkdigitalinitiatives/settings/installations/109025518`).
   Set `vars.DISPATCH_APP_ID` (`2828711`) and `secrets.DISPATCH_APP_PRIVATE_KEY`
   **on `volumes`**, not here. The App needs `contents: write` — the dispatch
   endpoint requires write; an earlier mccarthy runbook said `read`, which 403s.
2. **`dev` branch and rulesets** — the dev team's call. Nothing dispatches until
   `dev` exists.
3. **`dispatch-dev-merge.yml`** on `dev`, with `paths-ignore` and a retry.
   Copy mccarthy-index's. It must send the full `drupal_sha`.
4. **`dispatch-main-merge.yml` last.** Committing it to `main` fires it on that
   same push, which is an unattended production deploy. Only after the
   `production` environment has a required reviewer.
5. App-side gaps: `az_blob_fs` + `key`, the PHP platform pin, `automated_cron`.

## 10. No start/stop schedule

Production runs all the time. mccarthy-infra deallocated it overnight and at
weekends with `production-schedule.yml` until 2026-10-01, then deleted that
workflow because a public site cannot go dark every evening. This repo never had
it live: it was removed from the scaffold before the first run. Do not bring it
back for production.

Every workflow is event-triggered or manual, so nothing fires before the app
repo exists.

---|---|---|
| `30 11 * * 1-5` | start | 07:30 EDT / 06:30 EST |
| `30 22 * * 1-5` | stop | 18:30 EDT / 17:30 EST |

GitHub cron is always UTC, so the local window shifts an hour across DST.
Weekdays only: production is off from Friday evening until Monday morning.
Disable the workflow for good once the site is public-facing — mccarthy did on
2026-10-01, before its go-live.

`ACTION` falls through to `stop` for any trigger that is not the start cron, so
editing the start cron string without also editing the `ACTION` expression
silently turns the morning start into a second stop.

---

## Acceptance test

The bootstrap is done when:

1. `secrets`, `devtest`, and `production` have all applied cleanly and re-plan clean
2. A dev-merge dispatch with a real `drupal_sha` builds an image from the
   private repo and deploys the dev VM
3. `curl -ksf https://<dev vm ip>/user/login` returns the login form
4. `/var/log/cloud-init-output.log` on the dev VM has no `[fetch-secrets]` errors
5. A main-merge dispatch rolls production and `https://<domain>/user/login`
   returns 200 with `user_login_form` in the body
6. `tls-certs` in the production storage account holds `<domain>/fullchain.pem`
   and `<domain>/privkey.pem`

---

## Known rough edges inherited from mccarthy-infra

| Issue | Where it bites |
|---|---|
| Stale `image_version` | Guarded: no default, not in tfvars, and a `check` block warns when it is not the newest. Still pass the *running* version on a manual apply. |
| Cross-node DB ceremony | With MaxSurge, two VMSS instances can run `drush updatedb` / `config:import` against the same database at once. Fine for additive changes; serialise with `pg_advisory_lock` before the first breaking schema change. |
| Media SAS expiry | `media_sas_expiry` is a hard date (`2028-01-01`). Media stops being served when it lapses. Put it on a calendar. |
| Base image drift | The shared base is rebuilt monthly by lib-main-infra. Set `BASE_IMAGE_VERSION` to pin. |
| PostgreSQL major changes | Change `PG_MAJOR` and the Terraform default together. It pins both the server and the runner's `pg_dump`. |
| An unset repo variable is `""`, not null | `TF_VAR_x: ${{ vars.X }}` with `X` unset gives Terraform the empty string, and any `var.x == null` gate takes the wrong branch. Cost mccarthy every CI production deploy via `PUBLIC_IP_ID`. Grep for `== null` against anything sourced from `vars.`. |
| `/health` proves nothing about Drupal | Apache serves it without bootstrapping Drupal. Every deploy gate here also checks `/user/login` for `user_login_form`. |
| A red dev run does not block promotion | `deploy-on-main-merge.yml` deploys the newest gallery image regardless of how its dev run ended. Open in mccarthy-infra; open here. |
| Production never reads its own boot log | Only the dev deploy scans `cloud-init-output.log`. Open in both. |
| `$settings['file_default_scheme']` is inert | Drupal reads `system.file:default_scheme` config instead. Removed from cloud-init here; set per-field `uri_scheme: azblob` on file fields. |
