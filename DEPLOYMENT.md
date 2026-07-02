# Deployment Guide

CI/CD for this ASP.NET Core solution is driven by two GitHub Actions
workflows in [`.github/workflows`](.github/workflows):

| Workflow | File | Purpose |
| --- | --- | --- |
| CI | `ci.yml` | Restore → build → test on every push/PR to `dev`, `staging`, `hotfix`. |
| CD | `cd.yml` | Publishes and deploys the changed app(s) after CI succeeds. |

The solution contains three projects:

| Project | Path | Deployed as |
| --- | --- | --- |
| Web (MVC) | `mvc web/DevOps.csproj` | Web app |
| API | `web api/web api.csproj` | API app |
| Domain | `Domain/Domain.csproj` | Shared library (referenced by Web **and** API) |

---

## How deployment decides what to deploy

`cd.yml` diffs the pushed commit against its parent and deploys only what changed:

| Changed paths | Web deployed? | API deployed? |
| --- | --- | --- |
| `mvc web/**` only | ✅ | — |
| `web api/**` only | — | ✅ |
| `Domain/**` (any) | ✅ | ✅ |
| Domain + one app | ✅ | ✅ |
| none of the above | — | — |

A change in **Domain** redeploys **both** apps because they reference it.

> Detection uses a first-parent diff (`HEAD^..HEAD`). Merge/squash commits into
> a branch capture the full diff; a direct multi-commit push only diffs the last
> commit.

---

## Branches, environments, and directories

Each branch deploys to its **own directories**, driven by a matching GitHub
**Environment** of the same name. The deploy job sets
`environment: <branch>`, so the same secret name resolves to that branch's
value.

| Branch | Environment | Deploy target |
| --- | --- | --- |
| `dev` | `dev` | dev directories |
| `staging` | `staging` | staging directories |
| `hotfix` | `hotfix` | hotfix directories |

---

## Required GitHub Environments & secrets

Create the environments under **Settings → Environments**, then add these
**environment secrets** to *each* one (`dev`, `staging`, `hotfix`).

| Secret | Required | Description | Example |
| --- | --- | --- | --- |
| `MVC_DEPLOY_PATH` | ✅ | Destination directory for the Web app. Local path or UNC share. | `D:\DevOps\dev\web` |
| `API_DEPLOY_PATH` | ✅ | Destination directory for the API app. | `D:\DevOps\dev\api` |
| `DEPLOY_USER` | ⚠️ Remote only | Username used to authenticate to a remote UNC share. | `DOMAIN\deployer` |
| `DEPLOY_PASSWORD` | ⚠️ Remote only | Password for `DEPLOY_USER`. | *(secret)* |

Example values per environment:

| Secret | `dev` | `staging` | `hotfix` |
| --- | --- | --- | --- |
| `MVC_DEPLOY_PATH` | `D:\DevOps\dev\web` | `D:\DevOps\staging\web` | `D:\DevOps\hotfix\web` |
| `API_DEPLOY_PATH` | `D:\DevOps\dev\api` | `D:\DevOps\staging\api` | `D:\DevOps\hotfix\api` |

### Local vs. remote targets

- **Local path** (`D:\...`): the self-hosted runner writes directly to disk.
  Leave `DEPLOY_USER` / `DEPLOY_PASSWORD` unset.
- **Remote UNC share** (`\\server\share\...`): set `DEPLOY_USER` and
  `DEPLOY_PASSWORD`. The deploy script runs `net use` to authenticate to the
  share before `robocopy`, then disconnects afterwards.

Nothing (paths or credentials) is hard-coded in the workflow — all of it comes
from environment secrets.

---

## Runner requirements

Deployment jobs run on a **self-hosted Windows runner** labelled
`self-hosted, windows`, installed on the target machine (or one with access to
the deploy shares). It needs:

- The **.NET runtime** matching the app (publish is framework-dependent).
- Write access to the deploy directories / shares.
- IIS sites pointed at the deploy directories (deployment mirrors files with
  `robocopy /MIR`).

> `robocopy /MIR` removes files at the destination that no longer exist in the
> build. To preserve server-only files (e.g. `appsettings.Production.json`),
> add `/XF appsettings.Production.json` to the `robocopy` line in `cd.yml`.

---

## Optional: approval gates (Approve / Reject buttons)

Because each deploy job targets a GitHub Environment, you can add manual
approval per branch:

1. **Settings → Environments →** pick an environment (e.g. `staging`).
2. Enable **Required reviewers** and add at least one reviewer, then **Save**.
   (The Save button stays disabled until a reviewer is added.)
3. Optionally set a **Wait timer** and a **Deployment branch rule**.

The run then pauses with **Approve and deploy / Reject** buttons before the
deploy job starts.

> Required reviewers on **private** repositories need a paid plan
> (GitHub Pro / Team / Enterprise). Environment **secrets** work on all plans.

---

## Triggering a deployment

- **Automatic:** push (or merge) to `dev`, `staging`, or `hotfix`. CI runs; on
  success CD deploys the changed app(s) to that branch's directories.
- **Manual:** **Actions → CD → Run workflow**, choose the branch, and pick
  `web`, `api`, or `both`. This force-deploys the selected project(s) to the
  chosen branch's environment regardless of the git diff.
