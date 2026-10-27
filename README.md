# Basic Company (Helix + Unicorn) for Sitecore XP 10.3 on-premise

The Sitecore [Helix.Examples](https://github.com/Sitecore/Helix.Examples) *helix-basic-unicorn* example, upgraded from
Sitecore 10.1 to **Sitecore XP 10.3** and deployed to an existing **on-premise IIS** instance (XP0 / XP Single).
No Docker and no xConnect setup are needed.

Full guide (Vietnamese): [DEPLOY-XP103.md](DEPLOY-XP103.md). It covers the changes from the original example,
the hosts file / IIS binding for `basiccompany.local`, post-deploy steps and troubleshooting.

## Prerequisites

- Sitecore XP 10.3.x installed with SIF (XP0 / XP Single) and Solr. A blank instance is enough.
- Visual Studio 2019/2022 or Build Tools with the *ASP.NET and web development* workload, .NET Framework 4.8 Developer Pack.
- Access to `api.nuget.org` and `nuget.sitecore.com`.
- PowerShell 5.1 run as Administrator.

## Quick start

```powershell
git clone https://github.com/thinhnh021097/helix-basic-unicorn-xp103.git C:\src\basic-company
cd C:\src\basic-company
.\build-package.ps1
.\artifacts\deploy.ps1 -WebRoot C:\inetpub\wwwroot\sc103.dev.local
```

`-WebRoot` is the physical path of the Sitecore IIS site (the folder that contains `bin\Sitecore.Kernel.dll`).
`deploy.ps1` copies the files, applies the module XDT transforms, and adds the `basiccompany.local` IIS binding and hosts file entry.

Then, once:

1. Log in to `https://<your-cm-host>/sitecore`, open `/unicorn.aspx` and click **Sync**.
2. Publish the site (smart publish).
3. Control Panel: **Populate Solr Managed Schema**, then rebuild `sitecore_master_index` and `sitecore_web_index`.
4. Browse `http://basiccompany.local/`.

When the Sitecore machine has no Visual Studio, run `build-package.ps1` on a dev machine. Copy the generated
`BasicCompany-Unicorn-*.zip` across, extract it and run `deploy.ps1` from the extracted folder.

## Repository layout

| Path | Contents |
|---|---|
| `src/` | Helix modules (Foundation / Feature / Project), each with its Unicorn `serialization` items |
| `src/Environment/Website` | Web project that publishes all modules; `App_Config/Include/zzz/BasicCompany.Environment.config` holds per-environment settings |
| `build-package.ps1` | Builds the solution and creates `artifacts\` plus a zip |
| `deploy.ps1` | Deploys the package to an IIS Sitecore web root, optionally runs a Unicorn sync |
| `tools/unicorn` | Unicorn remote sync PowerShell module (`Unicorn.psm1`, `MicroCHAP.dll`) |
