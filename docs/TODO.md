# TODO

Known issues and deferred work. Committed, like mccarthy-infra's — a local-only
note helps exactly one person.

Entries should carry enough evidence that the next person does not have to
re-derive the problem: what breaks, how it was verified, and what the fix is.

The history behind most of the code here — every incident, every first-run
defect — lives in mccarthy-infra's `docs/TODO.md`. This file does not repeat it.
Look there before "fixing" something that looks odd.

---

## Work in flight — scaffold written 2026-10-14, nothing applied, nothing pushed

| What | State |
|---|---|
| Repo scaffold, copied from mccarthy-infra `283390b` and adapted | written; `git init` done, **no commit yet**; GitHub repo `utkdigitalinitiatives/volumes-infra` **not created** (checked 2026-10-14) |
| Azure | nothing exists — no `volumes-*` resource groups (checked 2026-10-14) |
| `terraform validate` on all four environments | passes (2026-10-14, Terraform 1.5.7, `-backend=false`) |
| `terraform fmt`, `packer validate`, `actionlint`, `shellcheck bootstrap/` | all pass |
| Private-repo unpack tasks (`packer/ansible/playbook.yml`) | passed against a `rockylinux:9` container with a `git archive` of `volumes` `9852d20` |
| First-boot install identity, asked for by a volumes dev 2026-10-14: site name `Volumes \| UTK Libraries`, site and super-user mail `librarieswebsite@utk.edu`, super user `admin` | done as `drupal_site_name` / `drupal_site_mail` / `drupal_admin_username` / `drupal_admin_mail` in `environments/production`; rendered `site:install` line checked, validations tested. Not yet reported back to the dev. |
| Everything else | never run — see `docs/bootstrap-runbook.md` |

**Resume here:** review the untracked tree, decide whether this repo is public,
then runbook step 0 (create the GitHub repo, first commit and push, disable the
schedule workflow at once, create the `production` and `dev` environments).

---

## Open

### Decide before step 0: domain, public IP, and repo visibility

- **Domain name.** Not chosen. It drives the TLS cert, trusted hosts and the
  media URLs (`az_blob_cdn_host_name`), so it is needed before the first real
  production apply. A bootstrap apply can run on the Terraform-created IP's
  `<label>.eastus2.cloudapp.azure.com` name with `enable_https = false`.
- **Public IP.** Recommended: a hand-made, `CanNotDelete`-locked
  `volumes-production-pip` in `volumes-production-rg`, as mccarthy production
  has used since 2026-09-24, so DNS survives any rebuild. Runbook step 7.
- **Is volumes-infra public?** mccarthy-infra is. Everything here is written to
  be safe in a public repo, so this is a preference, not a blocker.

### The app repo is private — the build's checkout path has never run

New here; mccarthy-infra clones a public repo on the build VM. Here the runner
checks `vars.APP_REPO` out at `drupal_sha` with a read-only deploy key
(`secrets.APP_REPO_DEPLOY_KEY`), packs it with `git archive`, and Ansible
unpacks the tarball on the build VM. Why: a credential on the build VM can end
up in the published image (a token in a clone URL lands in `.git/config`).

Rejected, 2026-10-14: a `lib-dispatch` App token for the checkout. The App holds
`contents: write`, would have to be installed on `volumes`, and its private key
would then sit in this repo too — more reach than a one-repo, read-only deploy
key. Also rejected: a zip archive to dodge the GNU tar need (see below); tar.gz
plus an explicit `tar` install is the standard shape.

**Tested:** the three unpack tasks, against `rockylinux:9`, with a real archive
of `volumes` — files owned by `drupal`, no `.git`, 644/755 modes thanks to
`tar.umask=0022`. **Found by that test:** `unarchive` needs GNU tar on the
target; the base image installs `unzip` but does not name `tar`, so the playbook
now ensures it.

**Not tested:** the checkout with a deploy key in Actions, Packer's piped
transfer of a ~100 KB tarball, `restorecon` on the real base image, and
`composer install` from an unpacked tree with no `.git`. The first real dispatch
tests all four. Runbook step 6 shows how to send one by hand.

### The app repo does not meet the contract yet

Checked 2026-10-14 against `volumes` `9852d20` (`main` only). The README's
contract table is the authoritative list. Missing:

- no `dev` branch and no workflows — nothing can dispatch;
- no `drupal/az_blob_fs` / `drupal/key` — cloud-init's blob overrides are inert
  until they land (mccarthy-index PR #5 is the model, and the first deploy of
  it broke mccarthy's dev; the `enable_blob_modules` pre-install is the fix);
- no `config.platform.php` pin — lock files resolved on a newer PHP may not
  install on the image's 8.3;
- no `automated_cron` — the `minimal` profile does not enable it, and nothing in
  the infra runs cron;
- no `ddev refresh-local` — the DB dump summary tells devs to
  `ddev drush sql:sanitize -y` after import until one exists. Port
  mccarthy-index's once the site stores files in blob storage.

These are the devs' changes. Dispatch-side, copy mccarthy-index's workflows but
give `dispatch-main-merge.yml` a `paths-ignore` that includes `.ddev/**` — the
missing ignore there redeployed mccarthy production on a comment-only change.

### Tell the other infra repos that 10.11.0.0/16 is taken

mccarthy-infra's and lib-main-infra's READMEs both still list `10.11.0.0/16` as
free. `az network vnet list` showed it unused on 2026-10-14. Add a row to each.
(volopedia-infra's Terraform defaults to `10.0.0.0/16`, the Asimov service CIDR
— not created in Azure as of that check, but worth a word with whoever owns it.)

### Nothing prunes `volumes-rocky-linux-9` until lib-main-infra can see this site

lib-main-infra's monthly `gallery-prune.py` discovers every image definition,
but skips one when no VM or VMSS it can see runs any version of it — its SP is
scoped to named resource groups, and `az vmss list` silently omits the rest.
That guard is right: without it, the prune could delete the version production
runs. Fix: add this project's production and dev resource groups to
`CONSUMER_RESOURCE_GROUPS` in lib-main-infra's `bootstrap/azure-setup.sh` and
re-run it, after production exists. Until then images just accumulate.

### Solr was not carried over — how to add it

The site has no `search_api`, so the scaffold leaves out everything mccarthy
built for the shared SolrCloud. When it is wanted, port mccarthy-infra commit
`de0c42b` ("Add the Solr network path, connector passwords and Drupal
overrides"):

- `environments/production`: bidirectional peering with the Asimov AKS VNet,
  this site's own `search.utklib.internal` zone with `solr` → `10.224.255.10`,
  the prod connector password secret, the `search_api.server.<id>` overrides in
  cloud-init;
- `environments/devtest`: the dev connector password (owned there, not in
  `dev`, which is destroyed every promotion);
- `environments/secrets`: Key Vault Secrets User for Asimov's External Secrets
  Operator;
- `bootstrap/azure-setup.sh`: Network Contributor on the Asimov VNet, or every
  CI production plan fails on refresh;
- the dev cloud-init reindex step;
- asimov: a `site-volumes.yaml` that creates the collections and logins.

mccarthy's Solr rollout notes list the traps hit on the way (Security API, the
configset POST, ICU collation needing analysis-extras).

### Fixed here, unfixed in mccarthy-infra — none of it has run

Taken while greenfield made them cheap. Each is open in mccarthy-infra's
`docs/TODO.md`.

- **OIDC 5-minute limit.** `az` needs the GitHub OIDC token again for a new
  resource such as Key Vault, and that token lives 5 minutes. An `azure/login`
  now runs right before each Key Vault step that can come late: the DB syncs in
  `build-on-dispatch.yml` and `test-cloud-init.yml` (after a PostgreSQL start
  that can wait 10 minutes), the Postmark fetches in the three deploy paths, and
  the dump in `dump-production-db.yml`. Same fix as lib-main-infra PR #18.
- **Runner `pg_dump`.** The DB syncs put `/usr/lib/postgresql/$PG_MAJOR/bin`
  first on `PATH` and assert the major, as `dump-production-db.yml` already did.
- **Ubuntu 26.04.** The three PGDG steps read the codename from
  `/etc/os-release` instead of `lsb_release`, which is not in 26.04's software
  list. Still worth one run on `ubuntu-26.04` before `ubuntu-latest` moves
  (2026-10-19 to 2026-11-19).
- **Bootstrap OIDC prefix.** The script stops if it cannot read the prefix from
  GitHub, instead of guessing the name-based form a new repo never gets.
- **Built from the SHA.** mccarthy builds the tip of `drupal_ref`.

### Inherited from mccarthy-infra, still open here

Read the mccarthy-infra entry before changing any of these.

- **A red dev run does not block promotion.** `deploy-on-main-merge.yml` deploys
  the newest gallery image regardless of how the dev run that built it ended.
  Options (gate on the run's conclusion, a human "verified on dev" marker, or
  accept it) were never decided.
- **Production never reads its own boot log.** Only the dev deploy scans
  `cloud-init-output.log`.
- **OIT tag drift.** OIT's CostCenter policy and Event Grid auto-tagging write
  tags Terraform does not know about; every plan will try to strip them. Fix is
  `lifecycle { ignore_changes = [tags] }` (or per key) on tagged resources.
- **RBAC Administrator on `volumes-secrets-rg` has no condition.** The CI SP
  could grant itself anything there. Add the standard "no Owner / UAA / RBAC
  Administrator" condition.
- **One SP for every environment**, against Microsoft's CAF guidance. Noted,
  not planned.
- **Anubis lets any non-browser user agent through.** The policy weighs only
  `Mozilla|Opera`; a scraper with any other user agent walks past. The fix
  (challenge every user agent, as digital.lib.utk.edu does) is filed in
  mccarthy-infra, not built.
- **`pm.max_children = 50` does not fit in 4 GiB**, and there is no memory
  alert. The pool comes from the shared base image.
- **MaxSurge deploys are not fully zero-downtime.** ~46 s of intermittent HTTPS
  failures when the surge instance joins the load balancer (lib-main,
  2026-10-07).
- **azurerm 4.81 misreads `runbook_type`**, forcing a phantom replacement of the
  automation runbook on every devtest plan. Re-test on provider upgrades.
- **`DefenderForStorageSettings/current` must be imported**, never created, on
  devtest and on the production private-files account. Runbook steps 5 and 7.
