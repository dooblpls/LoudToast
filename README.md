# LoudToast 🔔

**Windows notifications that actually get seen, even through Do Not Disturb.**

LoudToast is a PowerShell module for Windows 11 (toasts and balloons also work on Windows 10) that gives you every toast notification option in one command, classic
balloon tips, a configurable banner display time, and full control over Windows 11 *Do Not Disturb*. If DND would
swallow your notification, LoudToast lets it through and restores DND afterwards.

- No dependencies, no admin rights, nothing to install besides the module
- Buttons, text boxes, drop-downs, images, progress bars with live updates, headers, sounds, scenarios, scheduling
- Get the clicked button and typed input back (`-Wait`)
- Banner display time per toast (`-DisplaySeconds 20`)
- Read and control Do Not Disturb, its priority list and per-app notification settings

```powershell
Install-Module LoudToast -Scope CurrentUser
Show-Toast 'Build finished' 'All 312 tests passed'
```

> Requires **Windows PowerShell 5.1** (`powershell.exe`, built into Windows). PowerShell 7 lacks the WinRT projection.

## Toasts

```powershell
# Text, images, attribution, custom timestamp
Show-Toast 'New mail' 'From: Alice', 'Subject: Monday' -AppLogo .\alice.png -AppLogoCircle -HeroImage .\banner.png `
    -Attribution 'via Outlook' -Timestamp (Get-Date).AddMinutes(-5)

# Buttons and input; -Wait returns what the user did
$r = Show-Toast 'Deploy to production?' -ButtonStyles `
    -Inputs (New-ToastTextBox note -PlaceholderContent 'Comment') `
    -Buttons (New-ToastButton Deploy deploy -Style Success), (New-ToastButton Cancel cancel -Style Critical) -Wait
$r.Result      # Activated | Dismissed | Failed | Timeout
$r.Arguments   # 'deploy'
$r.UserInput   # @{ note = '...' }

# A button that opens a URL or file (works even after your script has ended)
Show-Toast 'Build failed' -Buttons (New-ToastButton 'Open log' 'file:///C:/build/log.txt' -ActivationType Protocol)

# Reminder with snooze options; stays on screen until the user acts
Show-Toast 'Stand-up' 'in 5 minutes' -Scenario Reminder `
    -Inputs (New-ToastSelectionBox snooze ([ordered]@{ '5' = '5 minutes'; '15' = '15 minutes' })) `
    -Buttons (New-ToastSystemButton Snooze -SelectionBoxId snooze), (New-ToastSystemButton Dismiss)

# Progress with live updates
Show-Toast 'Download' -ProgressBar (New-ToastProgressBar 'Starting' 0 -Title 'setup.exe') -Tag dl
1..10 | ForEach-Object { Start-Sleep 1; Update-ToastProgress -Tag dl -Value ($_ / 10) -Status "$($_ * 10) %" }

# Sound, grouping, expiration, scheduling
Show-Toast 'Wake up' -Scenario Alarm -Sound Alarm3 -LoopSound -Buttons (New-ToastSystemButton Dismiss)
Show-Toast 'Quiet one' -Silent -Header (New-ToastHeader builds 'Builds') -ExpirationTime (Get-Date).AddHours(1)
Show-Toast 'Later' -At (Get-Date).AddMinutes(30) -Tag later
Show-Toast 'Notification center only' -SuppressPopup -HighPriority

Show-Toast 'Hello' -AsXml          # inspect the generated XML
Show-Toast -Xml $myToastXml        # bring your own XML
Get-ToastHistory; Get-ToastHistory -Scheduled
Remove-Toast -Tag dl; Remove-Toast -Group builds; Remove-Toast -All; Remove-Toast -Tag later -Scheduled
```

## Balloons

```powershell
Show-Balloon 'Disk almost full' 'C: has 2 GB left' -Icon Warning -Seconds 10   # None | Info | Warning | Error | path to .ico
```

## Banner display time

```powershell
Show-Toast 'Hello' -DisplaySeconds 20      # this toast only (minimum 5 s)
Show-Balloon 'Hello' -Seconds 20           # same for balloons
Get-ToastDisplayDuration                   # system default (Windows ships with 5 s)
Set-ToastDisplayDuration 15                # change the default for all apps
```

| Option | Banner stays |
|---|---|
| default | `Get-ToastDisplayDuration` ("Dismiss notifications after this amount of time") |
| `-Duration Long` | 25 s, fixed |
| `-DisplaySeconds N` | N seconds, 5 and up |
| `-Scenario Reminder` / `Alarm` / `IncomingCall` with a button | until dismissed |

Windows reads the system display time when it builds a banner. `-DisplaySeconds` sets it for about one second and then
restores it, without saving it. Notifications from other apps arriving in that exact second get the same duration.

## Your own app name and icon

```powershell
Register-ToastApp Contoso.Monitor 'Server Monitor' -IconPath .\icon.png -SetDefault
```

`-SetDefault` makes it the AppId for all further commands and the AppUserModelID of the PowerShell process, so balloons
use the same identity, settings and priority list entry as your toasts.

## Do Not Disturb

By default `Show-Toast` and `Show-Balloon` use `-BreakThrough Auto`. `Test-ToastBreakThrough` re-implements the Windows
notification filter. If DND would hide the banner, LoudToast turns DND off for the banner's lifetime and restores it from
a hidden background process, even if your script has already ended. `-BreakThrough Never` respects DND, `KeepOff` leaves
it off.

These get through **without** touching DND (verified on Windows 11 25H2, build 26200):

| Option | Do not disturb | Alarms only |
|---|---|---|
| `-Scenario Alarm` | ✓ | ✓ |
| `-Scenario Reminder` / `IncomingCall` (if allowed in the priority settings) | ✓ | ✗ |
| `-Scenario Urgent` after `Set-ToastAppSetting -AllowUrgent $true` | ✓ | ✗ |
| App on the priority list (`Add-DndPriorityApp`), also balloons with `Set-ToastDefaultAppId` | ✓ | ✗ |

```powershell
Get-DndState                    # Active, UserSelected, QuietMoment, FocusSession, priority settings and apps
Set-DndMode PriorityOnly        # Off | PriorityOnly (the Windows 11 toggle) | AlarmsOnly
Disable-Dnd                     # also ends an active automatic rule; returns the previous mode
Add-DndPriorityApp; Remove-DndPriorityApp; Get-DndPriorityApp
Test-ToastBreakThrough -Scenario reminder
Get-ToastAppSetting; Set-ToastAppSetting -AllowUrgent $true -ShowBanner $true
```

Limitation: a running **Focus session** (Clock app) cannot be ended programmatically. That API is a Limited Access Feature.
`Disable-Dnd` does turn off the Do Not Disturb rule it activated.

## How it works

Toasts use the public WinRT notification API. The native part (`LoudToast.cs`) is compiled at import time against the
WinRT metadata that ships with Windows, so the module needs no binaries. Do Not Disturb and per-app settings use the
**undocumented** COM interfaces of the Windows notification service (`WpnUserService`). They were reverse engineered from
Windows 11 build 26200 and may change with Windows updates. After a feature update, run the end-to-end test:

```powershell
powershell -ExecutionPolicy Bypass -File (Join-Path (Split-Path (Get-Module LoudToast -ListAvailable)[0].Path) Test-LoudToast.ps1)
```

It checks with screenshots and Windows OCR that banners really appear (about 4 minutes; keep the screen on). It switches
Do Not Disturb temporarily and restores everything afterwards.

## License

MIT
