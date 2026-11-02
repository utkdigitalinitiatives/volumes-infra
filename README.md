# volumes-infra

Infrastructure as Code for the `volumes` Drupal site ("Volumes | UTK Libraries").

**Status: scaffolded, never run.** Nothing exists in Azure yet, no pipeline has
executed, and this repository has not been pushed to GitHub. It was built on
2026-10-14 from [mccarthy-infra](https://github.com/utkdigitalinitiatives/mccarthy-infra)
at commit `283390b`. See [docs/bootstrap-runbook.md](docs/bootstrap-runbook.md)
for how to stand it up and [docs/TODO.md](docs/TODO.md) for what is open.

Every first run in mccarthy-infra failed on a different latent defect, eight in
a row. Assume the same here for any stage that has not yet executed — which, for
now, is all of them.

## The two-repo split

This is the **ops-owned** half of a pair, modelled on
[mccarthy-index](https://github.com/utkdigitalinitiatives/mccarthy-index) /
[mccarthy-infra](https://github.com/utkdigitalinitiatives/mccarthy-infra), which
was itself modelled on lib-main / lib-main-infra:

| Repo | Owner | Contains |
|---|---|---|
| [`volumes`](https://github.com/utkdigitalinitiatives/volumes) (**private**) | devs | The Drupal 11 codebase. No build or deploy CI — only branch policy and cross-repo dispatch. |
| `volumes-infra` (this repo) | ops | Packer image build, Terraform per environment, all deploy workflows. |

Deployment is **VM-image based, not container based**. There is no container
registry anywhere in this system; the deployable artifact is an Azure Compute
Gallery image version.

```
app repo: feature -> dev  --(drupal-dev-merge)-->  check out the pushed SHA (deploy key)
                                                   build image 0.0.N from it
                                                   sync prod DB  -> devtest
                                                   sync prod blobs -> devtest
                                                   apply environments/dev (replace VM)
                                                   health check + email
   (a human validates the dev VM)
app repo: dev -> main     --(drupal-main-merge)--> resolve newest gallery image
                                                   apply environments/production (rolling, MaxSurge)
                                                   destroy environments/dev
```

## Architecture

- **Azure Load Balancer** (Standard, L4) → **VMSS** (Rocky Linux 9) → **PostgreSQL Flexible Server 18**
- **Azure Blob Storage** for Drupal media, via the `az_blob_fs` Drupal module
- **Azure Files** share for durable `private://` files (production only)
- **Azure Key Vault** for shared secrets, read at boot through managed identity
- **Azure Compute Gallery** for Packer-built images — *shared with lib-main-infra and mccarthy-infra*
- **Anubis** bot protection in front of Drupal, falling back to direct serving if it cannot start
- **Postmark** for Drupal's own mail (password resets), over SMTP or the Postmark module
- TLS via Let's Encrypt on the VM (not on the load balancer), with certs
  persisted to blob storage so they survive reimages

Region `eastus2`. Production is deallocated overnight and at weekends by
`production-schedule.yml`; disable that workflow once the site is public-facing.

**Not carried over from mccarthy-infra: Solr.** This site has no `search_api`,
so there is no VNet peering to Asimov, no `search.utklib.internal` zone, no Solr
connector passwords and no reindex step. The VNet range is still allocated
below, so adding the peering later is not also a re-address. See
[docs/TODO.md](docs/TODO.md) for how to add it.

## Shared base image

This repo does **not** build a base image. `lib-main-infra` builds
`drupal-base-rocky-linux-9` monthly into `lib-main-images-rg/lib_main_gallery`,
and that image is pure Rocky 9 + PHP 8.3 + Apache + Composer with nothing
site-specific in it. This project publishes only its **app** image definition,
`volumes-rocky-linux-9`, into that same gallery. mccarthy-infra does the same.

Consequences worth understanding before you rely on it:

1. **Drift.** A PHP or Apache change made for lib-main lands in this site's next
   app image without warning. Set the `BASE_IMAGE_VERSION` repository variable
   to pin a known-good base; leave it empty to track the newest.
2. **Cross-project permission.** The `volumes-github-actions` service principal
   holds Contributor on `lib-main-images-rg`, which is lib-main's resource
   group. A custom role scoped to the single image definition is the tighter
   option if that is unacceptable.
3. **Housekeeping.** This repo deletes its own intermediate managed image after
   each build and sweeps stray `pkr*` build resources before it, via
   `.github/scripts/packer-cleanup.sh` (a shared copy — keep it in sync with
   lib-main-infra's). The monthly gallery prune runs from lib-main-infra and
   finds this image definition on its own, but it **skips** a definition whose
   running version it cannot see. Until lib-main-infra's SP gets Reader on this
   project's resource groups, nothing prunes `volumes-rocky-linux-9`. See
   [docs/TODO.md](docs/TODO.md).

If `lib-main-infra` ever tears down its images resource group, this project's
builds break.

## VNet address allocation

Every library Drupal site is a **spoke**; the hub is the Asimov AKS cluster,
which hosts the SolrCloud these sites search against. Sites do not share a VNet
— each gets its own and peers to Asimov independently. Peering is
non-transitive, so every site reaches Solr and no site reaches another site.

The constraint is that **address spaces must not overlap**. Two of the reserved
ranges below are non-obvious:

- `10.0.0.0/16` is Asimov's Kubernetes **service** CIDR. Peering a spoke on this
  range still *succeeds*, because Azure only validates VNet address spaces — but
  reply traffic to a VM can be intercepted inside the cluster as a ClusterIP.
- `10.1.0.0/16` is partly consumed by the `vireo-db` spoke, which is already
  peered to Asimov.

**Reserved — never allocate from these:**

| Range | Owner |
|---|---|
| `10.0.0.0/16` | Asimov Kubernetes service CIDR |
| `10.1.0.0/16` | vireo-db spoke (`10.1.0.0/24`, `10.1.1.0/24`) |
| `10.224.0.0/12` | Asimov AKS node VNet |
| `10.244.0.0/16` | Asimov pod CIDR (Azure CNI overlay) |
| `172.16.0.0/16` | `dns-test-rg` |

**Per-site allocation — claim the next free /16 and add a row:**

| Range | Site | Status |
|---|---|---|
| `10.10.0.0/16` | mccarthy | allocated (mccarthy-infra) |
| `10.11.0.0/16` | volumes | allocated (this repo), not yet created — checked free with `az network vnet list` on 2026-10-14 |
| `10.12.0.0/16` | — | free |
| `10.20.0.0/16` | lib-main | allocated (lib-main-infra) |

Within a site: `x.x.1.0/24` web subnet, `x.x.2.0/24` private endpoints.

**Tell mccarthy-infra and lib-main-infra.** Their READMEs carry the same table,
and both still show `10.11.0.0/16` as free.

Verify against reality before allocating — `az network vnet list -o table` is the
authoritative source, not this table.

## Repository layout

```
volumes-infra/
├── .github/
│   ├── scripts/packer-cleanup.sh  # shared with lib-main-infra
│   └── workflows/
│       ├── build-on-dispatch.yml      # drupal-dev-merge  -> build image, sync DB+blobs, deploy dev VM
│       ├── deploy-on-main-merge.yml   # drupal-main-merge -> production rolling deploy, destroy dev VM
│       ├── deploy-production.yml      # manual rollback / emergency deploy
│       ├── test-cloud-init.yml        # manual cloud-init iteration on an existing image
│       ├── dump-production-db.yml     # manual -> production dump into private blob, for local DDEV
│       └── production-schedule.yml    # nightly/weekend deallocate (cost control)
├── packer/
│   ├── plugins.pkr.hcl
│   ├── variables.pkr.hcl
│   ├── volumes-rocky9.pkr.hcl     # app image only; base comes from the shared gallery
│   └── ansible/                   # unpack app tarball -> composer install -> settings.php wiring -> Anubis
├── modules/                       # 7 reusable Terraform modules
├── environments/
│   ├── secrets/                   # shared Key Vault + RBAC        (apply 1st)
│   ├── devtest/                   # persistent PSQL + blob + auto-stop (apply 2nd)
│   ├── production/                # VNet, LB, PSQL, blob, Files, VMSS (apply 3rd)
│   └── dev/                       # ephemeral dev VM               (apply 3rd; CI only)
├── bootstrap/azure-setup.sh       # one-time Azure setup, idempotent
└── docs/
    ├── bootstrap-runbook.md       # stand it up from nothing
    └── TODO.md                    # known issues and deferred work
```

**Apply order is load-bearing:** `secrets` → `devtest` → `production` / `dev`.
The dev stack reads `devtest-storage-account-key` from the vault.

Resource groups are created by `bootstrap/azure-setup.sh` and read by Terraform
via `data "azurerm_resource_group"`, not created by it. That is what allows the
CI service principal to be scoped per-resource-group instead of holding
subscription-wide Contributor.

## The private app repo

`volumes` is private; `mccarthy-index` is public. That one difference changes
how the image gets its code. mccarthy-infra's Packer build VM runs
`ansible.builtin.git` against a public HTTPS URL. Here that would need a
credential on the build VM, and anything on the build VM can end up in the
published image — a token in a clone URL lands in `.git/config`.

So the build VM never clones. Instead `build-on-dispatch.yml`:

1. checks out `vars.APP_REPO` at the dispatched `drupal_sha` on the runner,
   using a **read-only deploy key** (`secrets.APP_REPO_DEPLOY_KEY`) with
   `persist-credentials: false`;
2. packs that one commit with `git archive` — tracked files only, no `.git`;
3. passes the tarball's path to Packer as `drupal_archive`, and Ansible copies
   it to the build VM and unpacks it.

The image is built from the **pushed SHA**, not the tip of `dev`, so a later
push cannot change what a run builds. The unpack tasks were tested against a
Rocky 9 container on 2026-10-14; the full build has never run.

## Authentication

Workflows authenticate to Azure with **GitHub OIDC federated credentials**.
There is no `AZURE_CLIENT_SECRET`; the service principal has no password
credential at all.

Federated credential subjects registered on `volumes-github-actions`
(`<prefix>` is read from GitHub by `bootstrap/azure-setup.sh`; a repo created in
2026 gets the immutable form `repo:utkdigitalinitiatives@<orgid>/volumes-infra@<repoid>`):

| Subject | Covers |
|---|---|
| `<prefix>:ref:refs/heads/main` | `repository_dispatch` and `schedule` events, which always run on the default branch |
| `<prefix>:environment:production` | jobs declaring `environment: production` |
| `<prefix>:environment:dev` | jobs declaring `environment: dev` |
| `<prefix>:pull_request` | PR-triggered jobs |

Terraform state uses Entra auth (`use_azuread_auth=true`) rather than shared
storage keys.

## Repository configuration

### Secrets

| Secret | Notes |
|---|---|
| `AZURE_CLIENT_ID` | App ID of `volumes-github-actions` |
| `AZURE_TENANT_ID` | |
| `AZURE_SUBSCRIPTION_ID` | |
| `SSH_PUBLIC_KEY` | Authorized key for the `drupaladmin` account |
| `APP_REPO_DEPLOY_KEY` | Private half of a read-only deploy key on `volumes`. Not in mccarthy-infra. |

Application secrets (DB passwords, hash salts, storage keys, Postmark tokens)
live in Key Vault, not here.

### Variables

| Variable | Value | Set when |
|---|---|---|
| `PROJECT_NAME` | `volumes` | bootstrap |
| `APP_REPO` | `utkdigitalinitiatives/volumes` | bootstrap — the repo the image is built from. Not in mccarthy-infra. |
| `STORAGE_PREFIX` | `vol` | bootstrap |
| `LOCATION` | `eastus2` | bootstrap |
| `COST_CENTER` | | bootstrap |
| `GALLERY_NAME` | `lib_main_gallery` | bootstrap (shared) |
| `GALLERY_RESOURCE_GROUP` | `lib-main-images-rg` | bootstrap (shared) |
| `BASE_IMAGE_NAME` | `drupal-base-rocky-linux-9` | bootstrap (shared) |
| `BASE_IMAGE_VERSION` | *(empty)* | optional — pin the base image |
| `APP_IMAGE_NAME` | `volumes-rocky-linux-9` | bootstrap |
| `TF_STATE_RESOURCE_GROUP` | `volumes-tfstate-rg` | bootstrap |
| `TF_STATE_STORAGE_ACCOUNT` | generated | bootstrap |
| `DB_ADMIN_USERNAME` / `DB_NAME` | `drupaladmin` / `drupal` | bootstrap |
| `PG_MAJOR` | `18` | bootstrap — pins the server *and* the runner's `pg_dump` |
| `MEDIA_CONTAINER` | `drupal-media` | bootstrap |
| `PROD_DB_HOST` | `volumes-production-psql.postgres.database.azure.com` | bootstrap |
| `NOTIFY_EMAIL_TO` / `NOTIFY_EMAIL_FROM` | | bootstrap |
| `DEVTEST_DB_HOST` / `DEVTEST_STORAGE_ACCOUNT` | | after devtest apply |
| `PROD_STORAGE_ACCOUNT` / `SUBNET_ID` | | after production apply |
| `DRUPAL_SITE_UUID` | `f9411c09-e1c6-476c-b13e-430189fba5b8` | before production apply — read from the app repo, never generated |
| `DOMAIN_NAME` / `PUBLIC_IP_ID` / `LB_DNS_LABEL` | | before production apply |

No workflow contains a hardcoded resource group, server, or storage account
name — all are derived from `PROJECT_NAME` or read from a variable.

## Contract the app repo must satisfy

State of `volumes` as checked on 2026-10-14 (commit `9852d20`, branch `main`
only):

| Item | Value | State |
|---|---|---|
| Branch flow | `topic → dev → main`; PRs into `main` only from `dev` | **missing** — no `dev` branch |
| On push to `dev` | dispatch `drupal-dev-merge` to `volumes-infra` with `client_payload[drupal_repo]`, `[drupal_ref]=dev`, `[drupal_sha]` (full SHA — **required** here; the build checks out exactly that commit) | **missing** — no workflows |
| On push to `main` | dispatch `drupal-main-merge` with `client_payload[drupal_sha]` | **missing** |
| Dispatch auth | GitHub App token via `actions/create-github-app-token`, scoped `repositories: volumes-infra`. Reuse lib-main's `lib-dispatch` App (ID `2828711`), which holds `contents: write`; add `volumes-infra` to its selected repositories and set `vars.DISPATCH_APP_ID` + `secrets.DISPATCH_APP_PRIVATE_KEY` **on `volumes`** | **missing** |
| Image build access | read-only deploy key on `volumes`, private half in this repo's `APP_REPO_DEPLOY_KEY` | **missing** — runbook step 2 |
| Config sync dir | `config/` at project root | satisfied — `dirname(DRUPAL_ROOT) . '/config'` |
| Left empty in the repo | `$databases = []` and `$settings['hash_salt'] = ''` — infra injects both at boot | satisfied |
| Site UUID | `f9411c09-e1c6-476c-b13e-430189fba5b8` in `config/system.site.yml`. Never re-generate — a reinstall+re-export changes it and breaks production config import. | satisfied |
| Install profile | `minimal` in `config/core.extension.yml`; must match `drupal_install_profile` here | satisfied |
| Database driver | `pgsql` enabled; DDEV on PostgreSQL 18 | satisfied |
| Drush | in `composer.json` (cloud-init drives everything through it) | satisfied — `drush/drush ^13.8` |
| Blob media | `drupal/az_blob_fs` + `drupal/key` in `composer.json` and `core.extension.yml`, with a `key.key.azure_blob_key` config entity | **missing** — cloud-init's overrides are inert until then. mccarthy-index PR #5 is the model. |
| PHP pin | `config.platform.php = "8.3"` in `composer.json`, so a lock resolved on a newer PHP still installs on the image | **missing** |
| Cron | `automated_cron` enabled (the `minimal` profile does not), or nothing ever runs cron | **missing** |
| Custom theme location | `web/themes/custom/` | n/a yet |

The event type names (`drupal-dev-merge` / `drupal-main-merge`) are deliberately
the same as lib-main's and mccarthy's, so the workflows stay diffable.

Things the app repo should do that the earlier sites learned the hard way:

- **Retry and alert on the dispatch.** A dispatch POST once failed server-side
  in lib-main and no pipeline ran — silently. Wrap the `gh api` call in a retry
  with backoff and add an `if: failure()` notification.
- **`paths-ignore` on BOTH dispatches.** mccarthy-index's main dispatch had
  none, and a two-line comment change redeployed production. Ignore at least
  `**.md`, `LICENSE.txt`, `.editorconfig`, `.gitattributes`, `.github/**` and
  `.ddev/**` — the change that bit mccarthy lived under `.ddev/`.
- **Do not commit the main dispatcher until production is ready for it.** A
  workflow fires on the push that adds it, so adding an `on: push: main`
  dispatcher *is* a production deploy. Create the `production` GitHub
  environment with a required reviewer first.

## Differences from mccarthy-infra

| | mccarthy-infra | here |
|---|---|---|
| App repo | public; Packer build VM clones it over HTTPS | private; runner checks out with a deploy key, Packer gets a `git archive` tarball |
| What gets built | the tip of `drupal_ref` (the branch) | exactly `drupal_sha` |
| Solr | peered to Asimov, own DNS zone, connector passwords | none yet |
| VNet | `10.10.0.0/16` | `10.11.0.0/16` |
| Key Vault after a long step | `az keyvault` can fail with AADSTS700024 (open bug there) | `azure/login` again before each late Key Vault step |
| Runner `pg_dump` in DB syncs | bare `pg_dump`, works through Debian's wrapper | versioned bin dir on `PATH`, major asserted |
| PGDG apt codename | `lsb_release -cs` | `/etc/os-release`, which Ubuntu 26.04 is sure to have |
| Bootstrap, OIDC prefix unreadable | warns and guesses the name-based form | stops — a new repo always gets the immutable form |
| First-boot install | site name = project name, admin mail `admin@example.com`, no site mail | `Volumes \| UTK Libraries`, `librarieswebsite@utk.edu` for site and admin, username `admin` — the devs' choices, as variables |
| lib-main leftovers in cloud-init | Pantheon `migrate` DB, `s3fs` cleanup, inert `file_default_scheme` | removed |
| `docs/` | `TODO.md` is ~3,300 lines of history | fresh; history stays in mccarthy-infra |

Everything else — OIDC, per-RG scoping, data-source resource groups, the
three-gate health checks, the image-version guard, the private files share,
Anubis, Postmark, the DB dump workflow — is carried over unchanged apart from
names.

## Local Terraform

```bash
cd environments/<env>
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl -backend-config="use_azuread_auth=true"
terraform plan
```

Set `use_oidc = false` in `terraform.tfvars` for local runs — there is no GitHub
OIDC token outside CI, so the Azure CLI session is used instead.

**Do not apply `environments/dev` locally.** It is owned by CI and is destroyed
and recreated on every promotion to main.

Treat this repository as public. `*.tfvars` and `backend.hcl` are gitignored
because they carry subscription IDs, tenant IDs, AAD object IDs, and SSH public
keys — commit only the `.example` templates.

## License

UTK Libraries
