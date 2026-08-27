# Jenkins Pipeline

`Jenkinsfile` at the repository root builds, tests and deploys this solution.
It reproduces the behaviour of the GitHub Actions workflows described in
[`DEPLOYMENT.md`](DEPLOYMENT.md) — same applications, same change detection,
same robocopy deployment — as a single declarative pipeline.

| File | Purpose |
| --- | --- |
| `Jenkinsfile` | The pipeline: CI, change detection, approval gates, publish, deploy. |
| `jenkins/deploy-app.ps1` | Deploy script run on the Windows agent (robocopy mirror, service stop/start). |
| `jenkins/deploy-targets.properties.example` | Optional in-repo fallback for deploy paths. |

---

## Pipeline flow

```
CI · Build & Test          restore -> build -> test -> detect changes
        |
CD · Publish & Deploy      four independent lanes, run in parallel
        +-- Dashboard Web    [approve] -> publish -> deploy
        +-- MJH API          [approve] -> publish -> deploy
        +-- Dashboard SSO    [approve] -> publish -> deploy
        +-- Windows Service  [approve] -> publish -> deploy
```

A lane only runs when its application changed. The approval gate sits **before**
the publish, so a reviewer signs off on the change rather than on an artifact
already sitting on disk, and an aborted approval never blocks the other lanes.

### What gets deployed

The pipeline diffs the current commit against the previous **successful build**
of the same branch (`GIT_PREVIOUS_SUCCESSFUL_COMMIT`), falling back to the first
parent `HEAD^`:

| Changed paths | Web | API | SSO | Service |
| --- | --- | --- | --- | --- |
| `mvc web/**` | ✅ | — | — | — |
| `web api/**` | — | ✅ | — | — |
| `SSO/**` | — | — | ✅ | — |
| `WindowsService/**` | — | — | — | ✅ |
| `Domain/**` | ✅ | ✅ | ✅ | ✅ |
| anything else | — | — | — | — |

Deployment only happens on the branches in the `DEPLOY_BRANCHES` environment
value in the `Jenkinsfile` (`dev`, `staging`, `hotfix`). Every other branch runs
CI only.

---

## Creating the job

Use a **Multibranch Pipeline** (Jenkins → New Item → Multibranch Pipeline) so
each branch gets its own job and its own `disableConcurrentBuilds` lock:

1. **Branch Sources → Git/GitHub**, point it at this repository and add the
   read credentials.
2. **Build Configuration → by Jenkinsfile**, script path `Jenkinsfile`.
3. **Scan Multibranch Pipeline Triggers** — periodically, or add a GitHub
   webhook for push builds.

A plain Pipeline job also works; it reads the branch from git instead of
`BRANCH_NAME`.

### Required plugins

Pipeline (workflow-aggregator), Pipeline: Stage View, Git, and Credentials
Binding — all part of the suggested Jenkins install. No extra plugins are used:
the properties file is parsed in the pipeline rather than with `readProperties`,
because the Java properties format would eat the backslashes in `D:\DevOps\...`.

---

## Agents

| Label (build parameter) | Default | Requirements |
| --- | --- | --- |
| `BUILD_AGENT_LABEL` | `dotnet` | .NET SDK **8.0** and **10.0** (Web + API target net10.0; SSO + WindowsService target net8.0). Linux or Windows. |
| `DEPLOY_AGENT_LABEL` | `windows` | Windows agent with write access to the deploy paths, and permission to stop/start the service named in `SVC_SERVICE_NAME`. |

Publishing is framework-dependent, so a Linux build agent can produce artifacts
that a Windows agent deploys. If you only have one Windows agent, give it both
labels (`dotnet windows`).

Both labels are build parameters, so a run can be pointed at other agents
without editing the pipeline.

---

## Configuration

Set these under **Manage Jenkins → System → Global properties → Environment
variables** (or on the folder holding the job, which keeps them scoped).

Every setting is looked up as `<KEY>_<BRANCH>` first and then as `<KEY>`, so one
job serves all three branches:

```
WEB_DEPLOY_PATH_DEV      = D:\DevOps\dev\web
WEB_DEPLOY_PATH_STAGING  = D:\DevOps\staging\web
WEB_DEPLOY_PATH_HOTFIX   = D:\DevOps\hotfix\web
```

### Deploy paths (required)

| Key | Application |
| --- | --- |
| `WEB_DEPLOY_PATH[_BRANCH]` | Dashboard Web |
| `API_DEPLOY_PATH[_BRANCH]` | MJH API |
| `SSO_DEPLOY_PATH[_BRANCH]` | Dashboard SSO |
| `SVC_DEPLOY_PATH[_BRANCH]` | Windows Service |

A missing path fails that lane with a clear message; the other lanes continue.

### Optional settings

| Key | Default | Meaning |
| --- | --- | --- |
| `SVC_SERVICE_NAME[_BRANCH]` | *(none)* | Windows Service stopped before the copy and started after. Without it, locked binaries cannot be replaced. |
| `<APP>_EXCLUDE_FILES[_BRANCH]` | `appsettings.json,appsettings.*.json` | Files preserved on the target. |
| `<APP>_EXCLUDE_DIRS[_BRANCH]` | `uploads` (empty for `SVC`) | Folders preserved on the target. |
| `CD_APPROVERS` | *(empty)* | Comma-separated Jenkins user/group IDs allowed to approve. Empty means anyone who can see the build — the pipeline logs a warning. |
| `REQUIRE_APPROVAL` | `true` | Set to `false` to deploy without a manual gate (e.g. on a `dev`-only controller). |
| `APPROVAL_TIMEOUT_MINUTES` | `60` | How long an approval waits before the lane aborts. |
| `DEPLOY_CREDENTIALS_ID` | *(empty)* | Credentials ID (username/password) used to authenticate to a remote UNC share. Leave unset for local `D:\` targets. |

`<APP>` is `WEB`, `API`, `SSO` or `SVC`.

Instead of Jenkins properties, the same keys can live in
`jenkins/deploy-targets.properties` (copy the `.example`); Jenkins properties
win when both are set.

### Local vs. remote targets

- **Local path** (`D:\...`) — the Windows agent writes straight to disk. Leave
  `DEPLOY_CREDENTIALS_ID` unset.
- **Remote UNC share** (`\\server\share\...`) — create a *Username with
  password* credential and put its ID in `DEPLOY_CREDENTIALS_ID`. The deploy
  script runs `net use` against the share root before robocopy and disconnects
  afterwards. The password is passed through the agent environment, so it never
  appears in the build log.

---

## Preserving server-managed files

Deployment mirrors the build with `robocopy /MIR`: anything at the target that
is not in the build is deleted. Excluded files and folders are skipped by both
the copy and the purge, so server-side `appsettings.json` and an `uploads`
folder survive every deploy — and are never overwritten.

> First deploy: because `appsettings.json` is excluded from copying, put the
> production config on the target once, by hand.

---

## Running a deployment

- **Automatic** — push to `dev`, `staging` or `hotfix`. CI runs, the changed
  applications' lanes ask for approval, then publish and deploy.
- **Manual** — *Build with Parameters*:
  - `APPLICATION` — pick one application to force-deploy regardless of the diff.
  - `CONFIRM_DEPLOY` — must be ticked; an unticked forced deploy fails
    immediately, before anything is built or copied.

  Leaving `APPLICATION` on `auto-detect` reruns normal change detection.

Approvals appear as a **Deploy** button on the running build (stage view, or
Blue Ocean). Each lane is approved separately.

---

## Behaviour notes

- **One build at a time per branch** (`disableConcurrentBuilds`), so a deploy is
  never interrupted by the next push. A build waiting on an approval holds that
  lock — the approval itself sits on `agent none`, so it does not hold an
  executor.
- **Tests** run when the solution contains a project whose name mentions "test";
  otherwise the step is skipped with a log line. `test-results.trx` is archived
  when present.
- **Artifacts** — each published application is archived on the build and passed
  to the deploy agent via `stash`, so the deployed bits are exactly the bits
  that were built and approved.
- **First build on a new branch** has no previous successful commit and may have
  no `HEAD^` to diff against; the pipeline then deploys nothing and says so. Use
  a manual run with `APPLICATION` to deploy in that case.
