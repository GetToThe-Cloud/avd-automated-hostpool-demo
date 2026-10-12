# AVD automated host pools: demo environment

Two Azure Virtual Desktop host pools that build, scale and patch themselves, deployed with Bicep and driven with PowerShell.

Companion code for the [gettothe.cloud](https://www.gettothe.cloud) session on Azure Virtual Desktop. Both pools are automated host pools, built entirely from a session host configuration: one shows dynamic autoscaling, the other session host update. Everything is Bicep, and the demo itself is driven by a handful of PowerShell scripts that call the same preview API the portal uses.

All of it runs on preview APIs (`2026-04-01-preview`) and changes Azure on your behalf, including role assignments at subscription scope. Use a dedicated test subscription, read the scripts before you run them, and treat this as a demo, not a production pattern.

Two pools, because autoscale has to be off while a session host update runs. Pool A (`vdpool-avddemo-scale`) has a dynamic scaling plan that creates and deletes hosts. Pool B (`vdpool-avddemo-patch`) has no scaling plan and moves from image 1.0.0 to 2.0.0 during the talk. The slow part, the update, starts before you go on stage; the fast part, the scale-out, happens live.

## What gets deployed

Everything lands in one resource group, `rg-avddemo` by default, so cleaning up is one command.

| Resource | Name | Role in the demo |
| --- | --- | --- |
| Virtual network, NSG, NAT gateway | `vnet-avddemo`, `ng-avddemo` | Private subnet with explicit outbound access. Dynamic autoscaling needs outbound access to `wvdhpustgr0prod.blob.core.windows.net`. |
| Key Vault | `kv-avddemo-<hash>` | Local admin credentials. The session host configurations point at versionless secret URIs. |
| Log Analytics | `log-avddemo` | `WVDAutoscaleEvaluationPooled` and `WVDSessionHostManagement`, the two tables the demo reads. |
| Compute Gallery | `gal_avddemo` | Image versions 1.0.0 ("last month") and 2.0.0 ("this month"). |
| Pool A | `vdpool-avddemo-scale` | Session host configuration, management policy, dynamic scaling plan `vdscaling-avddemo`. Max 2 sessions per host. |
| Pool B | `vdpool-avddemo-patch` | Session host configuration, management policy with two hosts, no scaling plan. |
| Workspace | `vdws-avddemo` | Publishes both desktops as "Pool A \| Dynamic autoscaling" and "Pool B \| Session host update". |

The images deserve a word. A Marketplace image is already generalized, and a managed disk created from it has never booted, so it is still generalized and can go straight into a gallery. `bicep/modules/image.bicep` does exactly that with two consecutive Marketplace builds of Windows 11 Enterprise multi-session. That gives session host update a real patch level to move between without an image pipeline. In production you would build these versions with Azure Image Builder or Packer.

Nobody registers a session host anywhere. Pool B gets its two hosts through `provisioning.instanceCount` on the management policy, and Pool A gets its hosts from the scaling plan's minimum host pool size. No registration token appears in the code, which is half the point of the demo.

## Before you start

You need PowerShell 7.2 or later with Az.Accounts, Az.Resources, Az.Compute and Az.OperationalInsights, plus Azure CLI and the Bicep CLI (Az PowerShell calls Bicep to compile `main.bicep`). The preview Az.DesktopVirtualization module is optional; the scripts talk to the REST API directly. The prerequisites script can install missing PowerShell modules, Azure CLI (using winget), and Bicep. The PowerShell scripts automatically select a compatible VM size and fall back from UK South to West Europe if UK South has no eligible size; for direct Bicep deployments, set `vmSize` and `region` to values allowed by your subscription.

Use a subscription where you are Owner, or Contributor plus User Access Administrator. Dynamic autoscaling needs two roles for the Azure Virtual Desktop service principal at subscription scope (Power On Off Contributor and Virtual Machine Contributor), so a dedicated demo subscription keeps that blast radius small.

Create an Entra group with three test users who are licensed for Azure Virtual Desktop. The host pools use Microsoft Entra single sign-on (`enablerdsaadauth:i:1`); if that isn't switched on in your tenant yet, the prerequisites script can do it for you. If the default `Standard_D4ads_v5` is restricted, both scripts select a compatible size with the same vCPU and memory, Gen2, Trusted Launch, and Premium Storage support. If UK South has no eligible size, they use West Europe. Check the quota too: the demo peaks at six hosts, so 24 vCPUs in the selected VM family and region.

```powershell
cd scripts
./00-Prerequisites.ps1 -SubscriptionId <subscription-id> -InstallMissingPrerequisites
./00-Prerequisites.ps1 -SubscriptionId <subscription-id> -EnableEntraSso   # once per tenant, if needed
```

When `-EnableEntraSso` is used, missing Microsoft Graph modules are installed at a version compatible with the Graph module already loaded in the session. Complete the interactive browser sign-in when prompted; if sign-in is canceled, the script stops without changing the tenant setting.

## Deploy, the day before

```powershell
./01-Deploy-Environment.ps1 -SubscriptionId <subscription-id> -UsersGroupName 'AVD Demo Users'
```

The script picks the newest and the second-newest Marketplace build of `win11-25h2-avd`, generates a local admin password that only ever lives in Key Vault, and deploys `bicep/main.bicep` twice. The `foundation` run creates the network, Key Vault, Log Analytics, the image versions and both host pools with their managed identities and role assignments; count on 20 to 30 minutes, most of it gallery replication. The `complete` run adds the session host configurations, the management policies and the scaling plan, and takes a few minutes. Splitting it this way gives the role assignments time to propagate before AVD validates the configurations against Key Vault.

From then on AVD works on its own: Pool B gets its two hosts from image 1.0.0, Pool A gets the scaling plan's minimum for the current phase from image 2.0.0. Give it half an hour, then run the readiness check:

```powershell
./02-Test-Environment.ps1
```

The deployment outputs land in `scripts/demo-environment.json`, which every other script reads. The script also prints direct launch links for both desktops. Add `#loginHint=<upn>` to a link and a demo user skips the account picker.

## Demo day

| When | Do | Why |
| --- | --- | --- |
| T-60 min | `./02-Test-Environment.ps1` and `./10-Set-AutoscalePhase.ps1 -Phase RampUp` | Puts Pool A in ramp-up for the next four hours. Autoscale tops it up to 2 hosts, and ramp-up never scales in, so a host you create live stays put. |
| T-30 min | Sign in demo user 1 and 2 to the Pool A desktop, each in its own browser profile | 2 sessions on 2 hosts of 2 slots is 50%, under the 60% threshold, so nothing happens yet. Keep a third profile open on the Pool A launch link for demo user 3. |
| T-15 min | `./11-Start-PoolBUpdate.ps1` | Switches Pool B to image 2.0.0 and starts the update. The initial host goes first, then the second one; about 20 minutes per host. |
| T-5 min | `./02-Test-Environment.ps1 -AllowRunningUpdate` | Last go/no-go. Then open two terminals with `./21-Watch-PoolA.ps1` and `./22-Watch-PoolB.ps1`, and portal tabs for both pools' session hosts and Log Analytics with `kql/autoscale-decisions.kql`. |

The demo's run sheet (slide 21 in the deck) maps onto the scripts like this.

| Minute | Segment | Pool | What you show |
| --- | --- | --- | --- |
| 0-2 | Scene | Both | The service desk scenario from slide 18. |
| 2-6 | Define | Both | Session host configuration and management policy in the portal, or `./20-Show-Configuration.ps1` when the Wi-Fi is slow. `bicep/modules/hostpool.bicep` and `scalingplan.bicep` follow the code slides, with demo-sized values: 2 sessions per host, 2 to 4 hosts. |
| 6-8 | Trigger | A | Demo user 3 connects. `21-Watch-PoolA.ps1` shows 3 sessions on 4 slots, 75% against 60%, and the verdict that autoscale adds a host. |
| 8-12 | Patch | B | `22-Watch-PoolB.ps1` or the portal's Current version and Target version columns: one host on 2.0.0, one still on 1.0.0, same host names. |
| 12-15 | Harvest | A | `vdscale-2` appears and becomes available. `kql/autoscale-decisions.kql` shows autoscale's own reason, `kql/autoscale-timeline.kql` the step in the host count. |
| 15-18 | Scale in | A | `./23-Invoke-ScaleIn.ps1`: ramp-down now, users signed out, autoscale deletes empty hosts down to the ramp-down minimum of 1. |
| 18-20 | Buffer | | Questions, or a second look at whatever was still in flight. |

A new host needs roughly ten to fifteen minutes from the autoscale decision to Available, depending on region and image. Rehearse once and time it. If it's slower than the gap between Trigger and Harvest, let demo user 3 connect quietly at the start of Define and narrate the trigger at minute 6, which is the "trigger early, harvest later" tip from the slide.

### When something doesn't cooperate

If the third user can't sign in on stage, lower the threshold instead: `./10-Set-AutoscalePhase.ps1 -Phase RampUp -RampUpCapacityThresholdPct 40` makes the existing 50% count as too busy. Autoscale evaluates on session changes, so have one of the two users disconnect and reconnect to trigger an evaluation straight away.

If the new host takes longer than planned, show it while it's being created: the VM and its disk in the resource group, the host in the pool with its status, and the autoscale decision in Log Analytics. Come back to it in the buffer.

If Pool B's initial host fails, `22-Watch-PoolB.ps1` shows the error. The update stops after a failed initial host by design; that is a good moment to explain why the initial host exists. Retry from the portal (Session hosts, Manage session host update) or with `Invoke-AvdSessionHostUpdateControl -Action Retry` from the helper module.

Log Analytics trails a few minutes behind. The watch scripts read hosts and sessions live from the API and only use Log Analytics for autoscale's reasoning, so the console stays current even when the logs don't.

## After the demo

```powershell
./30-Reset-Demo.ps1                  # restore the schedule, autoscale on for Pool A
./30-Reset-Demo.ps1 -RollbackPoolB   # also update Pool B back to 1.0.0 for the next rehearsal
./99-Remove-Environment.ps1          # everything gone, Key Vault purged, AVD service principal roles removed
```

`99-Remove-Environment.ps1` switches autoscale off first, so it doesn't create hosts while you delete them. Add `-KeepAvdServicePrincipalRoles` if other host pools in the subscription use autoscale.

## Cost

Almost all of the cost is VM hours: two to four hosts of the selected 4-vCPU/16-GiB size (default `Standard_D4ads_v5`) in Pool A and two in Pool B while the environment exists, plus their Premium SSD OS disks. The NAT gateway, the gallery replicas, the two source disks, Key Vault and Log Analytics add a little on top. Deploy the day before, remove it after the talk, and check the Azure pricing calculator for your region.

## How the code maps to the slides

| Slide | Code |
| --- | --- |
| 19, WHAT | `configuration` in `bicep/modules/hostpool.bicep` |
| 19, HOW | `management` in `bicep/modules/hostpool.bicep` |
| 19, WHEN | `scripts/11-Start-PoolBUpdate.ps1` |
| 20 and 23 | `bicep/modules/scalingplan.bicep` |
| 22 | `hostPool` and `configuration` in `bicep/modules/hostpool.bicep` |
| 24 | Notes below |
| 31, cheat sheet | Functions in `scripts/AvdDemo.psm1`, with the preview cmdlet each one stands in for |

The scripts use these helper functions; the right-hand column is the preview cmdlet from the cheat sheet that does the same thing.

| Helper function | Preview cmdlet |
| --- | --- |
| `Get-AvdSessionHostConfiguration` | `Get-AzWvdSessionHostConfiguration` |
| `Set-AvdSessionHostImage` | `Update-AzWvdSessionHostConfiguration -ImageInfoType Custom -CustomInfoResourceId` |
| `Get-AvdSessionHostManagement` | `Get-AzWvdSessionHostManagement` |
| `Start-AvdSessionHostUpdate` | `Invoke-AzWvdInitiateSessionHostUpdate` |
| `Get-AvdSessionHostUpdateStatus` | `Get-AzWvdSessionHostManagementsUpdateStatus` |
| `Invoke-AvdSessionHostUpdateControl` | `Invoke-AzWvdControlSessionHostUpdate` |
| `Set-AvdAutoscale` | `Update-AzWvdScalingPlan -HostPoolReference` |
| `Set-AvdSchedulePhase` | `Update-AzWvdScalingPlanPooledSchedule` |

## Things to know

The resource provider calls all go to `2026-04-01-preview`. The GA API version doesn't have `managementType`, the session host configuration or `createDelete` yet, and the PowerShell support is a preview module, which is why the scripts use `Invoke-AzRestMethod`. That also means nothing here is supported for production until those parts reach GA, whatever the portal says.

Creating hosts through `provisioning.instanceCount` is what the management policy API offers, but the docs only describe adding hosts to an automated pool through the portal (Session hosts, Add). If Pool B has no hosts after half an hour and `02-Test-Environment.ps1` shows no provisioning run, add two hosts in the portal; the session host configuration does the rest.

A scheduled update (`11-Start-PoolBUpdate.ps1 -StartAt`) sends the start time in UTC together with the management policy's time zone. The script reads the scheduled time back and prints it; check it says what you meant.

Redeploying the template writes the session host configurations again. If the portal then flags hosts as behind the target version, nothing happens until you start an update. After the demo has moved Pool B to 2.0.0, redeploy with `-PoolBImageVersion 2.0.0` to keep the Bicep in line, or roll Pool B back with `30-Reset-Demo.ps1 -RollbackPoolB`.

The management approach is decided when a host pool is created. You can't turn an existing standard pool into an automated one, and automated pools are pooled only. Dynamic autoscaling only runs in Azure public cloud, not in Azure Government and not on Azure Local.

With single sign-on, users get an "Allow remote desktop connection" prompt the first time they reach a new host. Autoscale creates new hosts, so either click through it during the demo or hide it with a dynamic device group on the Windows Cloud Login service principal.

Intune enrollment is off by default because it needs automatic MDM enrollment configured in the tenant; deploy with `-IntuneEnrollment` to match the code slide exactly. The Key Vault firewall is off by default too. The AVD docs recommend trusted services only; switch `keyVaultTrustedServicesOnly` on in `main.bicep` once you've seen host creation work.

## Files

```text
bicep/
  main.bicep                 subscription-scope entry point, two phases
  main.bicepparam            example parameters for deploying without the scripts
  modules/
    types.bicep              typed settings shared by the modules
    network.bicep            VNet, NSG, NAT gateway
    keyvault.bicep           Key Vault and the local admin secrets
    monitoring.bicep         Log Analytics workspace
    image.bicep              gallery, image versions 1.0.0 and 2.0.0 from Marketplace builds
    hostpool.bicep           automated host pool: identity, roles, app group, WHAT and HOW
    scalingplan.bicep        dynamic scaling plan with its schedule
    workspace.bicep          workspace and diagnostics
scripts/
  AvdDemo.psm1               helper functions around the preview REST API
  00-Prerequisites.ps1       modules, providers, region, quota, Entra SSO
  01-Deploy-Environment.ps1  two-phase deployment and the outputs file
  02-Test-Environment.ps1    go/no-go check
  10-Set-AutoscalePhase.ps1  move the scaling plan into a phase right now
  11-Start-PoolBUpdate.ps1   switch Pool B's image and start the update
  20-Show-Configuration.ps1  the Define segment in the console
  21-Watch-PoolA.ps1         live autoscale view with the capacity math
  22-Watch-PoolB.ps1         live update view, host by host
  23-Invoke-ScaleIn.ps1      ramp-down now and sign the users out
  30-Reset-Demo.ps1          back to the starting point
  99-Remove-Environment.ps1  remove everything
kql/
  autoscale-decisions.kql    autoscale's reasons, newest first
  autoscale-timeline.kql     sessions against hosts over time
  autoscale-failures.kql     failed evaluations with error details
  session-host-update.kql    provisioning and update runs, minutes per host
  errors.kql                 everything WVDErrors has on the demo pools
PSScriptAnalyzerSettings.psd1  analyzer settings for the scripts
CHANGELOG.md
LICENSE
```

## Sources

- [Host pool management approaches](https://learn.microsoft.com/azure/virtual-desktop/host-pool-management-approaches)
- [Deploy Azure Virtual Desktop with a session host configuration](https://learn.microsoft.com/azure/virtual-desktop/deploy-azure-virtual-desktop?pivots=host-pool-session-host-configuration)
- [Update session hosts using session host update](https://learn.microsoft.com/azure/virtual-desktop/session-host-update-configure)
- [Create a dynamic scaling plan](https://learn.microsoft.com/azure/virtual-desktop/autoscale-create-assign-scaling-plan?pivots=dynamic)
- [Autoscale FAQ](https://learn.microsoft.com/azure/virtual-desktop/autoscale-faq)
- [Monitor autoscale operations with Insights](https://learn.microsoft.com/azure/virtual-desktop/autoscale-monitor-operations-insights)
- [Diagnostic queries for session host update](https://learn.microsoft.com/azure/virtual-desktop/session-host-update-diagnostics)
- [Configure single sign-on with Microsoft Entra ID](https://learn.microsoft.com/azure/virtual-desktop/configure-single-sign-on)
- [Azure REST API specs for Microsoft.DesktopVirtualization 2026-04-01-preview](https://github.com/Azure/azure-rest-api-specs/tree/main/specification/desktopvirtualization)

## License

MIT, see [LICENSE](LICENSE).
