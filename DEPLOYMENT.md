# Deployment Guide

CI/CD for this ASP.NET Core solution is driven by GitHub Actions workflows in
[`.github/workflows`](.github/workflows):

| Workflow | File | Purpose |
| --- | --- | --- |
| Build & Test (CI) | `build-and-test.yml` | Restore → build → test the whole solution on every push/PR to `dev`, `staging`, `hotfix`. |
| Deploy Applications (CD) | `deploy-applications.yml` | Publishes and deploys the changed application(s) after CI succeeds. |
| Provision Deploy Environments | `setup-environments.yml` | One-time: creates the 12 environments and their variables/secrets. |

## Applications

The solution contains four deployable applications plus a shared library:

| Application | Project | Deploy job / lane |
| --- | --- | --- |
| **Dashboard Web** | `mvc web/DevOps.csproj` | `deploy-web` |
| **MJH API** | `web api/web api.csproj` | `deploy-api` |
| **Dashboard SSO** | `SSO/SSO.csproj` | `deploy-sso` |
| **Windows Service** | `WindowsService/WindowsService.csproj` | `deploy-svc` |
| Domain (shared) | `Domain/Domain.csproj` | — (library; a change fans out to all four) |

---

## How deployment decides what to deploy

`deploy-applications.yml` diffs the pushed commit against its parent and deploys
only the applications whose files changed:

| Changed paths | Web | API | SSO | Service |
| --- | --- | --- | --- | --- |
| `mvc web/**` | ✅ | — | — | — |
| `web api/**` | — | ✅ | — | — |
| `SSO/**` | — | — | ✅ | — |
| `WindowsService/**` | — | — | — | ✅ |
| `Domain/**` (any) | ✅ | ✅ | ✅ | ✅ |
| none of the above | — | — | — | — |

A change in **Domain** redeploys **all four** applications, since it is the
shared layer they build on.

> Detection uses a first-parent diff (`HEAD^..HEAD`). Merge/squash commits into
> a branch capture the full diff; a direct multi-commit push only diffs the last
> commit.

---

## Pipeline flow

Four independent lanes run after change detection, so a failure or approval in
one application never blocks another:

```
detect-changes ─┬─ publish-web ─ deploy-web   (Dashboard Web)
                ├─ publish-api ─ deploy-api   (MJH API)
                ├─ publish-sso ─ deploy-sso   (Dashboard SSO)
                └─ publish-svc ─ deploy-svc   (Windows Service)
```

---

## Branches, environments, and directories

Each **application + branch** pair uses its own GitHub **Environment**, so every
application is configured and approved separately. The deploy job sets
`environment: <app>-<branch>`, and reads that environment's deploy-path
**variable**.

| App \ Branch | `dev` | `staging` | `hotfix` |
| --- | --- | --- | --- |
| Dashboard Web | `web-dev` | `web-staging` | `web-hotfix` |
| MJH API | `api-dev` | `api-staging` | `api-hotfix` |
| Dashboard SSO | `sso-dev` | `sso-staging` | `sso-hotfix` |
| Windows Service | `svc-dev` | `svc-staging` | `svc-hotfix` |

That is **12 environments** total.

---

## Required environment configuration

Create the 12 environments under **Settings → Environments** (or run the
`setup-environments.yml` workflow). Each environment needs the config below.

### Variables (non-sensitive — Variables tab)

Each environment holds **one** deploy-path variable, named for its application:

| Environment prefix | Variable | Example (`dev`) |
| --- | --- | --- |
| `web-*` | `WEB_DEPLOY_PATH` | `D:\DevOps\dev\web` |
| `api-*` | `API_DEPLOY_PATH` | `D:\DevOps\dev\api` |
| `sso-*` | `SSO_DEPLOY_PATH` | `D:\DevOps\dev\sso` |
| `svc-*` | `SVC_DEPLOY_PATH` | `D:\DevOps\dev\svc` |

Optional per-environment variables:

| Variable | Applies to | Description |
| --- | --- | --- |
| `SVC_SERVICE_NAME` | `svc-*` | Name of the Windows Service to stop before copy and start after. Required for the service deploy to swap locked binaries. |
| `WEB_EXCLUDE_FILES` / `WEB_EXCLUDE_DIRS` | `web-*` | Files/folders to preserve on the target (see below). Also `API_`, `SSO_`, `SVC_` variants. |

### Secrets (sensitive — Secrets tab)

Only needed when deploying to a **remote UNC share**; leave unset for local
`D:\` paths on the runner.

| Secret | Description | Example |
| --- | --- | --- |
| `DEPLOY_USER` | Username to authenticate to a remote UNC share. | `DOMAIN\deployer` |
| `DEPLOY_PASSWORD` | Password for `DEPLOY_USER`. | *(secret)* |

> **Deploy paths are Variables, not Secrets** — they are configuration, not
> sensitive data, so they are visible in logs. Credentials stay as Secrets.

### Local vs. remote targets

- **Local path** (`D:\...`): the self-hosted runner writes directly to disk.
  Leave `DEPLOY_USER` / `DEPLOY_PASSWORD` unset.
- **Remote UNC share** (`\\server\share\...`): set `DEPLOY_USER` and
  `DEPLOY_PASSWORD`. The deploy script runs `net use` to authenticate before
  `robocopy`, then disconnects afterwards.

---

## Preserving server-managed files & folders

Deployment mirrors the build with `robocopy /MIR`, which deletes anything at the
target not present in the build. Files/folders that must survive (e.g.
`appsettings.json`, an `uploads` directory) are excluded per application via
environment variables — entries separated by new lines, commas, or semicolons;
robocopy wildcards allowed:

| Variable | Default |
| --- | --- |
| `WEB_EXCLUDE_FILES` / `API_EXCLUDE_FILES` / `SSO_EXCLUDE_FILES` / `SVC_EXCLUDE_FILES` | `appsettings.json, appsettings.*.json` |
| `WEB_EXCLUDE_DIRS` / `API_EXCLUDE_DIRS` / `SSO_EXCLUDE_DIRS` | `uploads` |
| `SVC_EXCLUDE_DIRS` | *(empty)* |

Excluded items are skipped in both the copy and the `/MIR` purge, so existing
server copies are never overwritten or deleted.

> First deploy: because `appsettings.json` is excluded from copying, place the
> production config on the target once, manually — deployments won't clobber it.

---

## Runner requirements

Deployment jobs run on a **self-hosted Windows runner** labelled
`self-hosted, windows`, installed on the target machine (or one with access to
the deploy shares). It needs:

- The **.NET runtime** matching the apps (publish is framework-dependent).
- Write access to the deploy directories / shares.
- IIS sites pointed at the `web-*`, `api-*`, `sso-*` directories.
- Permission to **stop/start the Windows Service** named in `SVC_SERVICE_NAME`.

---

## Approval gates (Approve / Reject buttons)

Because each deploy job targets its own environment, every application is
approved **separately**:

1. **Settings → Environments →** pick an environment (e.g. `api-staging`).
2. Enable **Required reviewers** and add at least one reviewer, then **Save**.
   (The Save button stays disabled until a reviewer is added.)
3. Optionally set a **Wait timer** and a **Deployment branch rule**.

The run then pauses with **Approve and deploy / Reject** buttons before that
application's deploy job starts. Deploying to `dev` with several apps changed
raises one approval per app (`web-dev`, `api-dev`, …), each owned independently.

> Required reviewers on **private** repositories need a paid plan
> (GitHub Pro / Team / Enterprise). Environment **variables and secrets** work
> on all plans.

---

## Triggering a deployment

- **Automatic:** push (or merge) to `dev`, `staging`, or `hotfix`. CI runs; on
  success CD deploys each changed application to that branch's environment(s).
- **Manual:** **Actions → Deploy Applications (CD) → Run workflow**, choose the
  branch, and pick **one** application (`dashboard-web`, `mjh-api`,
  `dashboard-sso`, or `windows-service`). It force-deploys that single
  application to the chosen branch's environment, regardless of the git diff.
  Run it again to deploy another application.

---

## Note on `workflow_run` and the default branch

CD triggers via `workflow_run` after CI. GitHub only evaluates that trigger from
the workflow file on the **default branch (`main`)**. The workflows must be
present on `main` for automatic deployment to fire, even though the apps deploy
from `dev` / `staging` / `hotfix`.
