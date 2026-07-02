# CI/CD Pipeline — ASP.NET Core on GitHub Actions

Two-stage pipeline:

| Workflow | Trigger | Does |
|----------|---------|------|
| `.github/workflows/ci.yml` | push / PR to `main` | restore → build → test |
| `.github/workflows/cd.yml` | after **CI** succeeds on `main`, or manual dispatch | publish → upload artifact → deploy to local IIS |

CD runs only after CI succeeds (`workflow_run` trigger). You can also run it
manually from the **Actions** tab.

Deployment target: **IIS site rooted at `D:\DevOps\test`**, deployed by a
**self-hosted runner** installed on that machine. A GitHub-hosted runner runs in
Microsoft's cloud and cannot reach your local `D:\` drive — hence self-hosted.

---

## ⚠️ Before your first run

1. **Framework version.** `DevOps.csproj` targets `net10.0`; the workflows default
   `DOTNET_VERSION` to `8.0.x`. Make them agree — set `<TargetFramework>net8.0</TargetFramework>`
   in the csproj, **or** change `DOTNET_VERSION` to `10.0.x` in both `ci.yml` and `cd.yml`.
2. **App pool name.** The deploy job cycles an IIS app pool named `DevOpsAppPool`
   by default. Set a repo **Variable** `IIS_APP_POOL` to your real pool name
   (Settings → Secrets and variables → Actions → **Variables**), or rename your
   pool to match.

---

## 1. Install the self-hosted runner (one time)

On the machine that hosts `D:\DevOps\test`:

1. In GitHub: **Settings → Actions → Runners → New self-hosted runner** →
   choose **Windows** and follow the download/config commands shown.
2. When configuring, give it the labels the workflow expects: `self-hosted` and
   `windows` (the Windows default label is added automatically).
3. **Run the runner as a service with admin rights** so it can manage IIS:
   ```powershell
   # from the runner folder, in an elevated PowerShell
   .\svc.sh install    # or: .\config.cmd  then  .\run.cmd  for interactive
   ```
   Ensure the service account is an **Administrator** (required for
   `Import-Module WebAdministration` and stopping/starting the app pool).

## 2. Prepare IIS (one time)

1. Install **IIS** and the **.NET Core Hosting Bundle** (adds the ASP.NET Core
   Module so IIS can host the app).
2. Create an **Application Pool** (e.g. `DevOpsAppPool`) with **.NET CLR version =
   No Managed Code** (ASP.NET Core runs out-of-process/in-process via ANCM).
3. Create a **Website / Application** whose **physical path = `D:\DevOps\test`**
   and that uses the app pool from step 2.

That's it — no GitHub Secrets are needed for this local deploy, because the
self-hosted runner already runs on the target machine.

---

## How the deploy job works (`cd.yml`)

1. **publish** (GitHub-hosted Ubuntu) runs `dotnet publish` and uploads the
   output as the `app-publish` artifact.
2. **deploy-windows** (your self-hosted runner):
   - downloads the artifact,
   - **stops** the app pool (so DLLs aren't file-locked),
   - `robocopy /MIR` mirrors the files into `D:\DevOps\test` (removing stale files),
   - **starts** the app pool again.
   - Fails the job if robocopy returns an error code ≥ 8.

> Tip: if you keep secrets in `appsettings.Production.json` on the server, exclude
> it from the mirror by adding `/XF appsettings.Production.json` to the robocopy
> line so a deploy never overwrites it.

---

## Optional: Linux (Nginx + systemd)

The `deploy/devops-app.service` and `deploy/nginx-devops-app.conf` files remain in
this folder for an optional Linux deployment. The Linux job was removed from
`cd.yml`; re-add it (see git history / the original template) if you later target Linux.

---

## Requirement mapping
- **Build & test on every push to main** → `ci.yml`.
- **`dotnet publish`** → `publish` job.
- **Upload published files as an artifact** → `actions/upload-artifact` (`app-publish`).
- **Auto-deploy after a successful build** → `workflow_run` trigger + `needs: publish`.
- **Windows (IIS)** → `deploy-windows` job on a self-hosted runner.
- **Production best-practices** → CI-gated CD, app-pool cycling to avoid file locks,
  stale-file cleanup, and deploy-failure detection.
