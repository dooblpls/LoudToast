#Requires -Version 5.1
# LoudToast - Windows toast and balloon notifications that get through Do Not Disturb.
# https://github.com/dooblpls/LoudToast  (MIT License)
Set-StrictMode -Version 2

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'LoudToast requires Windows PowerShell 5.1 (powershell.exe). PowerShell 7 has no WinRT projection.'
}

# ---- Native core: compiled once per session against the WinRT metadata shipped with Windows ----
if (-not ('LoudToast.Toasts' -as [type])) {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $wm = "$env:windir\System32\WinMetadata"
    $fx = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
    $cp = New-Object -TypeName CodeDom.Compiler.CompilerParameters
    $cp.GenerateInMemory = $true
    $cp.ReferencedAssemblies.AddRange([string[]]@('System.dll', "$wm\Windows.UI.winmd", "$wm\Windows.Foundation.winmd", "$wm\Windows.Data.winmd",
            "$fx\System.Runtime.WindowsRuntime.dll", "$fx\System.Runtime.dll", "$fx\System.Runtime.InteropServices.WindowsRuntime.dll", "$fx\System.Threading.dll"))
    $res = (New-Object -TypeName Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromFile($cp, "$PSScriptRoot\LoudToast.cs")
    if ($res.Errors.HasErrors) { throw "LoudToast.cs: $(($res.Errors | ForEach-Object ToString) -join "`n")" }
}
Add-Type -Name Native -Namespace LoudToast -ErrorAction SilentlyContinue -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr id);
[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, uint p, IntPtr v, uint flags);
[DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, uint p, ref uint v, uint flags);
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Windows PowerShell ships a Start menu shortcut with this AUMID, so toasts work without any registration.
$script:DefaultAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:DefaultGroup = 'LoudToast'  # Windows rejects Remove/Update with an empty group
$script:Profiles = @{ Off = [LoudToast.Dnd]::Off; PriorityOnly = [LoudToast.Dnd]::PriorityOnly; AlarmsOnly = [LoudToast.Dnd]::AlarmsOnly }

function Get-ProfileName([string]$Id) {
    foreach ($k in $script:Profiles.Keys) { if ($script:Profiles[$k] -eq $Id) { return $k } }
    ''
}

#region App identity

function Register-ToastApp {
    <#
    .SYNOPSIS
        Registers an app identity (name and icon shown in the toast header) for unpackaged scripts.
    .DESCRIPTION
        Writes HKCU:\Software\Classes\AppUserModelId\<AppId>, the documented way for unpackaged apps to get their own
        notification identity. The app then also appears in Settings > System > Notifications.
    .EXAMPLE
        Register-ToastApp -AppId Contoso.Monitor -DisplayName 'Server Monitor' -IconPath .\icon.png -SetDefault
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Application User Model ID, e.g. 'Contoso.Monitor'.
        [Parameter(Mandatory)][string]$AppId,
        # Name shown in the toast header and in Windows settings.
        [Parameter(Mandatory)][string]$DisplayName,
        # Path to a PNG/ICO used as app icon.
        [string]$IconPath,
        # Icon background as ARGB hex, e.g. 'FF0078D4'.
        [string]$IconBackgroundColor,
        # Also make this the default AppId for all LoudToast commands in this session (see Set-ToastDefaultAppId).
        [switch]$SetDefault
    )
    $key = "HKCU:\Software\Classes\AppUserModelId\$AppId"
    if ($PSCmdlet.ShouldProcess($key, 'Register notification app')) {
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -Path $key -Name DisplayName -Value $DisplayName
        if ($IconPath) { Set-ItemProperty -Path $key -Name IconUri -Value (Resolve-Path -Path $IconPath).ProviderPath }
        if ($IconBackgroundColor) { Set-ItemProperty -Path $key -Name IconBackgroundColor -Value $IconBackgroundColor }
        if ($SetDefault) { Set-ToastDefaultAppId -AppId $AppId }
    }
}

function Unregister-ToastApp {
    <#
    .SYNOPSIS
        Removes an app identity created with Register-ToastApp and clears its notifications.
    .EXAMPLE
        Unregister-ToastApp -AppId Contoso.Monitor
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Application User Model ID to remove.
        [Parameter(Mandatory)][string]$AppId
    )
    if ($PSCmdlet.ShouldProcess($AppId, 'Unregister notification app')) {
        Remove-Item -Path "HKCU:\Software\Classes\AppUserModelId\$AppId" -Recurse -ErrorAction SilentlyContinue
        [LoudToast.Toasts]::Remove($AppId, $null, $null)
    }
}

function Set-ToastDefaultAppId {
    <#
    .SYNOPSIS
        Sets the AppId used by all LoudToast commands in this session.
    .DESCRIPTION
        Also sets it as the explicit AppUserModelID of the current process. Windows uses that identity for balloon
        notifications too, so balloons share name, settings and priority-list membership with your toasts.
    .EXAMPLE
        Set-ToastDefaultAppId -AppId Contoso.Monitor
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Session-only state')]
    [CmdletBinding()]
    param(
        # Application User Model ID.
        [Parameter(Mandatory)][string]$AppId
    )
    $script:DefaultAppId = $AppId
    [void][LoudToast.Native]::SetCurrentProcessExplicitAppUserModelID($AppId)
}

function Get-ToastDefaultAppId {
    <#
    .SYNOPSIS
        Returns the AppId used by LoudToast commands in this session.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $script:DefaultAppId
}

function Get-ToastAppSetting {
    <#
    .SYNOPSIS
        Shows the per-app notification settings (as in Settings > System > Notifications > <app>).
    .EXAMPLE
        Get-ToastAppSetting
    #>
    [CmdletBinding()]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId
    )
    $h = [LoudToast.AppSettings]::Get($AppId)
    [pscustomobject]@{
        AppId                 = $AppId
        Setting               = [LoudToast.Toasts]::Setting($AppId)
        Enabled               = $h.Enabled
        ShowBanner            = $h.ShowBanner
        ShowInActionCenter    = $h.ShowInActionCenter
        AllowContentAboveLock = $h.AllowContentAboveLock
        AllowUrgent           = $h.AllowUrgent
        OnPriorityList        = (Get-DndPriorityApp) -contains $AppId
    }
}

function Set-ToastAppSetting {
    <#
    .SYNOPSIS
        Changes per-app notification settings.
    .DESCRIPTION
        -AllowUrgent $true has the same effect as clicking "Allow" on the Windows prompt "Allow important notifications
        from <app>?". Toasts with -Scenario Urgent then show while Do Not Disturb is on.
    .EXAMPLE
        Set-ToastAppSetting -AllowUrgent $true -ShowBanner $true
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId,
        # Notifications on/off for this app.
        [Nullable[bool]]$Enabled,
        # Show banners (pop-ups).
        [Nullable[bool]]$ShowBanner,
        # Keep notifications in the notification center.
        [Nullable[bool]]$ShowInActionCenter,
        # Show content on the lock screen.
        [Nullable[bool]]$AllowContentAboveLock,
        # Let -Scenario Urgent toasts through Do Not Disturb.
        [Nullable[bool]]$AllowUrgent
    )
    foreach ($name in 'Enabled', 'ShowBanner', 'ShowInActionCenter', 'AllowContentAboveLock', 'AllowUrgent') {
        $value = Get-Variable -Name $name -ValueOnly
        if ($null -ne $value -and $PSCmdlet.ShouldProcess($AppId, "Set $name = $value")) { [LoudToast.AppSettings]::Set($AppId, $name, $value) }
    }
    Get-ToastAppSetting -AppId $AppId
}

#endregion

#region Do Not Disturb

function Get-DndState {
    <#
    .SYNOPSIS
        Shows the Do Not Disturb state, its priority settings and the priority list.
    .DESCRIPTION
        Active is what is in effect right now. UserSelected is the toggle in Settings/notification center. QuietMoment
        is an active automatic rule (schedule, game, full screen, presentation, focus).
    .EXAMPLE
        Get-DndState
    #>
    [CmdletBinding()]
    param()
    $null = [Windows.UI.Shell.FocusSessionManager, Windows.UI.Shell, ContentType = WindowsRuntime]
    $p = [LoudToast.Dnd]::PriorityOnly
    [pscustomobject]@{
        Active            = Get-ProfileName ([LoudToast.Dnd]::Active)
        UserSelected      = Get-ProfileName ([LoudToast.Dnd]::UserSelected)
        QuietMoment       = Get-ProfileName ([LoudToast.Dnd]::QuietMomentProfile)
        FocusSession      = [Windows.UI.Shell.FocusSessionManager]::GetDefault().IsFocusActive
        AllowCalls        = [LoudToast.Dnd]::GetFlag($p, 0)
        AllowPhoneSms     = [LoudToast.Dnd]::GetFlag($p, 1)
        AllowReminders    = [LoudToast.Dnd]::GetFlag($p, 2)
        PriorityApps      = [LoudToast.Dnd]::PriorityApps($p)
        AlwaysAllowedApps = [LoudToast.Dnd]::AlwaysAllowedApps()
    }
}

function Set-DndMode {
    <#
    .SYNOPSIS
        Switches Do Not Disturb.
    .DESCRIPTION
        PriorityOnly is the Windows 11 "Do not disturb" toggle. AlarmsOnly is the stricter legacy Focus Assist mode,
        still supported by Windows but no longer exposed in Settings.
    .EXAMPLE
        Set-DndMode -Mode PriorityOnly
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Off, PriorityOnly or AlarmsOnly.
        [Parameter(Mandatory)][ValidateSet('Off', 'PriorityOnly', 'AlarmsOnly')][string]$Mode
    )
    if ($PSCmdlet.ShouldProcess('Do Not Disturb', "Set mode $Mode")) { [LoudToast.Dnd]::Set($script:Profiles[$Mode]) }
}

function Disable-Dnd {
    <#
    .SYNOPSIS
        Turns Do Not Disturb completely off, including an active automatic rule. Returns the previous mode.
    .EXAMPLE
        $previous = Disable-Dnd; ...; Set-DndMode $previous
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    $prev = [LoudToast.Dnd]::UserSelected
    if (-not $PSCmdlet.ShouldProcess('Do Not Disturb', 'Turn off')) { return Get-ProfileName $prev }
    if ($prev -ne [LoudToast.Dnd]::Off) { [LoudToast.Dnd]::Set([LoudToast.Dnd]::Off) }
    if ([LoudToast.Dnd]::Active -ne [LoudToast.Dnd]::Off) { [LoudToast.Dnd]::TurnOffQuietMoment() }
    if ([LoudToast.Dnd]::Active -ne [LoudToast.Dnd]::Off) { throw "Do Not Disturb is still active: $(Get-DndState | Out-String)" }
    Get-ProfileName $prev
}

function Get-DndPriorityApp {
    <#
    .SYNOPSIS
        Lists the AppIds on the Do Not Disturb priority list.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [LoudToast.Dnd]::PriorityApps([LoudToast.Dnd]::PriorityOnly)
}

function Add-DndPriorityApp {
    <#
    .SYNOPSIS
        Adds an app to the Do Not Disturb priority list, so its toasts show while DND is on (not in AlarmsOnly).
    .EXAMPLE
        Add-DndPriorityApp -AppId Contoso.Monitor
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId
    )
    if ($PSCmdlet.ShouldProcess($AppId, 'Add to Do Not Disturb priority list')) {
        [LoudToast.Dnd]::AddPriorityApp([LoudToast.Dnd]::PriorityOnly, $AppId)
        Start-Sleep -Seconds 2  # the service reloads the list asynchronously; right after a mode switch this took 1-2 s
    }
}

function Remove-DndPriorityApp {
    <#
    .SYNOPSIS
        Removes an app from the Do Not Disturb priority list.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId
    )
    if ($PSCmdlet.ShouldProcess($AppId, 'Remove from Do Not Disturb priority list')) {
        [LoudToast.Dnd]::RemovePriorityApp([LoudToast.Dnd]::PriorityOnly, $AppId)
        Start-Sleep -Seconds 2
    }
}

function Test-ToastBreakThrough {
    <#
    .SYNOPSIS
        Predicts whether a toast would show as a banner under the current Do Not Disturb state.
    .DESCRIPTION
        Re-implements the decision of the Windows notification filter (QuietHoursToastFilterSink, build 26200).
    .EXAMPLE
        Test-ToastBreakThrough -Scenario reminder
    #>
    [CmdletBinding()]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId,
        # Toast scenario: default, reminder, alarm, incomingCall, callProgress, urgent, systemDialog.
        [string]$Scenario = 'default',
        # Toast tag (some tags are special-cased by Windows).
        [string]$Tag = ''
    )
    $active = [LoudToast.Dnd]::Active
    $result = { param($ok, $why) [pscustomobject]@{ BreaksThrough = $ok; Reason = $why; Profile = (Get-ProfileName $active) } }
    if ($active -eq [LoudToast.Dnd]::Off) { return & $result $true 'Do Not Disturb is off' }
    if ($Tag -eq 'QUIET_MOMENT_START_AND_END_TOAST') { return & $result $true 'system tag' }
    if ($Scenario -in 'alarm', 'systemDialog') { return & $result $true "scenario $Scenario always shows" }
    if ($active -eq [LoudToast.Dnd]::PriorityOnly) {
        $p = [LoudToast.Dnd]::PriorityOnly
        # The decompiled filter would also allow urgent in AlarmsOnly; measured it does not (another stage filters it).
        if ($Scenario -eq 'urgent' -and [LoudToast.AppSettings]::Get($AppId).AllowUrgent) { return & $result $true 'urgent toasts allowed for app' }
        if ($Scenario -eq 'reminder' -and [LoudToast.Dnd]::GetFlag($p, 2)) { return & $result $true 'reminders allowed' }
        if (($Scenario -in 'incomingCall', 'callProgress' -or $Tag -match 'XDeviceIncomingCall|XDeviceMissedCall') -and [LoudToast.Dnd]::GetFlag($p, 0)) { return & $result $true 'calls allowed' }
        if ($Tag -match 'XDeviceIncomingSMS' -and [LoudToast.Dnd]::GetFlag($p, 1)) { return & $result $true 'phone SMS allowed' }
        if (([LoudToast.Dnd]::PriorityApps($p) + [LoudToast.Dnd]::AlwaysAllowedApps()) -contains $AppId) { return & $result $true 'app is on the priority list' }
    }
    & $result $false 'suppressed by Do Not Disturb'
}

# Turns DND off now and restores it after $Seconds from a hidden process (survives the caller exiting).
function Invoke-BreakThrough([int]$Seconds) {
    $prev = Disable-Dnd
    if ($prev -eq 'Off') { return }  # only an automatic rule was active; it stays off until it triggers again
    $cmd = "Start-Sleep $Seconds; Import-Module '$PSScriptRoot\LoudToast.psd1'; if ([LoudToast.Dnd]::UserSelected -eq [LoudToast.Dnd]::Off) { Set-DndMode -Mode $prev }"
    Start-Process -FilePath powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd
}

#endregion

#region Banner display time
# Windows reads SPI_MESSAGEDURATION ("Dismiss notifications after this amount of time") when it builds a banner.
# duration="long" is a fixed 25 s and ignores it. Effective minimum is 5 s.

function Get-ToastDisplayDuration {
    <#
    .SYNOPSIS
        Returns the system-wide banner display time in seconds ("Dismiss notifications after this amount of time").
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param()
    $v = [uint32]0
    if (-not [LoudToast.Native]::SystemParametersInfo(0x2016, 0, [ref]$v, 0)) { throw [ComponentModel.Win32Exception]::new() }  # SPI_GETMESSAGEDURATION
    $v
}

function Set-ToastDisplayDuration {
    <#
    .SYNOPSIS
        Sets the system-wide banner display time for all apps.
    .DESCRIPTION
        Same as Settings > Accessibility > Visual effects > "Dismiss notifications after this amount of time", but any
        value from 5 seconds up. For a single toast use Show-Toast -DisplaySeconds instead.
    .EXAMPLE
        Set-ToastDisplayDuration -Seconds 15
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Display time in seconds.
        [Parameter(Mandatory)][ValidateRange(5, 3600)][int]$Seconds,
        # Change it for this logon session only, without saving it.
        [switch]$NoPersist
    )
    $flags = if ($NoPersist) { 0 } else { 3 }  # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    if ($PSCmdlet.ShouldProcess('Notification display time', "Set to $Seconds s")) {
        if (-not [LoudToast.Native]::SystemParametersInfo(0x2017, 0, [IntPtr]$Seconds, $flags)) { throw [ComponentModel.Win32Exception]::new() }  # SPI_SETMESSAGEDURATION
    }
}

# Runs $Show with a temporary banner display time, then restores the system value.
function Invoke-WithDisplayDuration([int]$Seconds, [scriptblock]$Show) {
    if (-not $Seconds) { return & $Show }
    if ($Seconds -lt 5) { Write-Warning 'Windows shows banners for at least 5 seconds.' }
    $old = Get-ToastDisplayDuration
    Set-ToastDisplayDuration -Seconds ([Math]::Max(5, $Seconds)) -NoPersist -WhatIf:$false -Confirm:$false
    try { & $Show; Start-Sleep -Milliseconds 1000 }  # time for the service to build the banner (measured sufficient)
    finally { Set-ToastDisplayDuration -Seconds $old -NoPersist -WhatIf:$false -Confirm:$false }
}

#endregion

#region Toast content

function ConvertTo-ToastUri([string]$Path) {
    if ($Path -match '^(https?|ms-appx|ms-appdata|file):') { return $Path }
    ([Uri](Resolve-Path -Path $Path).ProviderPath).AbsoluteUri
}

function New-ToastButton {
    <#
    .SYNOPSIS
        Creates a button for Show-Toast -Buttons.
    .EXAMPLE
        New-ToastButton -Content 'Open log' -Arguments 'file:///C:/build/log.txt' -ActivationType Protocol
    .EXAMPLE
        New-ToastButton Send send -InputId reply -Style Success
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Button text.
        [Parameter(Mandatory, Position = 0)][string]$Content,
        # Returned in the result of Show-Toast -Wait. With -ActivationType Protocol: the URL or file to open.
        [Parameter(Position = 1)][string]$Arguments = $Content,
        # Foreground/Background raise the Activated event; Protocol opens Arguments (works after your script ended).
        [ValidateSet('Foreground', 'Background', 'Protocol')][string]$ActivationType = 'Foreground',
        # Small icon on the button.
        [string]$ImageUri,
        # Place the button next to the text box with this id.
        [string]$InputId,
        # Green (Success) or red (Critical) button. Requires Show-Toast -ButtonStyles.
        [ValidateSet('Success', 'Critical')][string]$Style,
        # Tooltip, useful for icon-only buttons.
        [string]$ToolTip,
        # Show the entry in the toast's context menu instead of as a button.
        [switch]$ContextMenu,
        # Keep the toast open after the click (for in-place updates).
        [switch]$PendingUpdate
    )
    $a = [ordered]@{ content = $Content; arguments = $Arguments; activationType = $ActivationType.ToLower() }
    if ($ImageUri) { $a.imageUri = ConvertTo-ToastUri $ImageUri }
    if ($InputId) { $a.'hint-inputId' = $InputId }
    if ($Style) { $a.'hint-buttonStyle' = $Style }
    if ($ToolTip) { $a.'hint-toolTip' = $ToolTip }
    if ($ContextMenu) { $a.placement = 'contextMenu' }
    if ($PendingUpdate) { $a.afterActivationBehavior = 'pendingUpdate' }
    [pscustomobject]@{ Kind = 'action'; Attributes = $a }
}

function New-ToastSystemButton {
    <#
    .SYNOPSIS
        Creates a Snooze or Dismiss button handled by Windows itself.
    .EXAMPLE
        New-ToastSystemButton -Action Snooze -SelectionBoxId snooze
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Snooze or Dismiss.
        [Parameter(Mandatory, Position = 0)][ValidateSet('Snooze', 'Dismiss')][string]$Action,
        # Button text. Empty = localized Windows default.
        [string]$Content = '',
        # Snooze only: id of a New-ToastSelectionBox whose keys are minutes.
        [string]$SelectionBoxId
    )
    $a = [ordered]@{ content = $Content; arguments = $Action.ToLower(); activationType = 'system' }
    if ($SelectionBoxId) { $a.'hint-inputId' = $SelectionBoxId }
    [pscustomobject]@{ Kind = 'action'; Attributes = $a }
}

function New-ToastTextBox {
    <#
    .SYNOPSIS
        Creates a text input for Show-Toast -Inputs. The value is returned in the result of Show-Toast -Wait.
    .EXAMPLE
        New-ToastTextBox -Id reply -PlaceholderContent 'Type a reply'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Key of the value in UserInput.
        [Parameter(Mandatory, Position = 0)][string]$Id,
        # Label above the box.
        [string]$Title,
        # Grey hint text.
        [string]$PlaceholderContent,
        # Prefilled text.
        [string]$DefaultInput
    )
    $a = [ordered]@{ id = $Id; type = 'text' }
    if ($Title) { $a.title = $Title }
    if ($PlaceholderContent) { $a.placeHolderContent = $PlaceholderContent }
    if ($DefaultInput) { $a.defaultInput = $DefaultInput }
    [pscustomobject]@{ Kind = 'input'; Attributes = $a; Items = $null }
}

function New-ToastSelectionBox {
    <#
    .SYNOPSIS
        Creates a drop-down for Show-Toast -Inputs.
    .EXAMPLE
        New-ToastSelectionBox -Id snooze -Items ([ordered]@{ '5' = '5 minutes'; '60' = '1 hour' })
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Key of the value in UserInput.
        [Parameter(Mandatory, Position = 0)][string]$Id,
        # Entries: key = returned value, value = displayed text. Use [ordered] to keep the order.
        [Parameter(Mandatory, Position = 1)][Collections.IDictionary]$Items,
        # Label above the box.
        [string]$Title,
        # Key of the preselected entry.
        [string]$DefaultSelection
    )
    $a = [ordered]@{ id = $Id; type = 'selection' }
    if ($Title) { $a.title = $Title }
    if ($DefaultSelection) { $a.defaultInput = $DefaultSelection }
    [pscustomobject]@{ Kind = 'input'; Attributes = $a; Items = $Items }
}

function New-ToastProgressBar {
    <#
    .SYNOPSIS
        Creates a progress bar for Show-Toast -ProgressBar. Update it later with Update-ToastProgress.
    .EXAMPLE
        New-ToastProgressBar -Status 'Downloading' -Value 0.25 -Title 'setup.exe' -ValueDisplay '25 / 100 MB'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Text below the bar.
        [Parameter(Position = 0)][string]$Status = '',
        # 0 to 1, or 'indeterminate'.
        [Parameter(Position = 1)][string]$Value = '0',
        # Text above the bar.
        [string]$Title,
        # Replaces the percentage shown on the right.
        [string]$ValueDisplay
    )
    [pscustomobject]@{ Kind = 'progress'; Status = $Status; Value = $Value; Title = $Title; ValueDisplay = $ValueDisplay }
}

function New-ToastHeader {
    <#
    .SYNOPSIS
        Creates a header that groups toasts in the notification center.
    .EXAMPLE
        New-ToastHeader -Id builds -Title 'Builds'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param(
        # Toasts with the same header id are grouped.
        [Parameter(Mandatory, Position = 0)][string]$Id,
        # Header text.
        [Parameter(Mandatory, Position = 1)][string]$Title,
        # Arguments when the header is clicked.
        [string]$Arguments = '',
        # Foreground or Protocol (Arguments = URL).
        [ValidateSet('Foreground', 'Protocol')][string]$ActivationType = 'Foreground'
    )
    [pscustomobject]@{ Kind = 'header'; Attributes = [ordered]@{ id = $Id; title = $Title; arguments = $Arguments; activationType = $ActivationType.ToLower() } }
}

function New-ToastXml {
    <#
    .SYNOPSIS
        Builds toast XML (ToastGeneric template). Takes the content parameters of Show-Toast.
    .EXAMPLE
        New-ToastXml -Title Hello -Body World
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a string only')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # First line, bold.
        [Parameter(Position = 0)][string]$Title,
        # Further lines (up to two are shown).
        [Parameter(Position = 1)][string[]]$Body,
        # Small grey source line at the bottom.
        [string]$Attribution,
        # Image replacing the app icon.
        [string]$AppLogo,
        # Crop the app logo to a circle.
        [switch]$AppLogoCircle,
        # Wide image at the top.
        [string]$HeroImage,
        # Inline images below the text.
        [string[]]$Image,
        # Default, Reminder, Alarm, IncomingCall or Urgent. Reminder/Alarm/IncomingCall stay until dismissed and need a button.
        [ValidateSet('Default', 'Reminder', 'Alarm', 'IncomingCall', 'Urgent')][string]$Scenario = 'Default',
        # Short (system default) or Long (25 s).
        [ValidateSet('Short', 'Long')][string]$Duration,
        # Arguments when the toast body is clicked.
        [string]$Launch,
        # Activation type of the toast body.
        [ValidateSet('Foreground', 'Background', 'Protocol')][string]$ActivationType,
        # Custom time shown in the toast.
        [datetime]$Timestamp,
        # Windows notification sound. Alarm* and Call* are looping sounds.
        [ValidateSet('Default', 'IM', 'Mail', 'Reminder', 'SMS', 'Alarm', 'Alarm2', 'Alarm3', 'Alarm4', 'Alarm5', 'Alarm6', 'Alarm7', 'Alarm8', 'Alarm9', 'Alarm10',
            'Call', 'Call2', 'Call3', 'Call4', 'Call5', 'Call6', 'Call7', 'Call8', 'Call9', 'Call10')][string]$Sound,
        # Custom sound file.
        [string]$SoundFile,
        # Repeat the sound until the toast is dismissed (needs -Duration Long or a persistent scenario).
        [switch]$LoopSound,
        # No sound.
        [switch]$Silent,
        # Objects from New-ToastButton / New-ToastSystemButton (max. 5).
        [object[]]$Buttons,
        # Objects from New-ToastTextBox / New-ToastSelectionBox.
        [object[]]$Inputs,
        # Objects from New-ToastProgressBar.
        [object[]]$ProgressBar,
        # Object from New-ToastHeader.
        [object]$Header,
        # Enable colored buttons (New-ToastButton -Style).
        [switch]$ButtonStyles
    )
    $x = New-Object -TypeName Xml.XmlDocument
    $el = {
        param($parent, $name, $attrs)
        $e = $x.CreateElement($name)
        if ($attrs) { foreach ($k in $attrs.Keys) { if ($null -ne $attrs[$k]) { $e.SetAttribute($k, [string]$attrs[$k]) } } }
        [void]$parent.AppendChild($e)
        $e
    }

    $t = & $el $x 'toast' $null
    if ($Scenario -ne 'Default') { $t.SetAttribute('scenario', $Scenario.Substring(0, 1).ToLower() + $Scenario.Substring(1)) }
    if ($Duration) { $t.SetAttribute('duration', $Duration.ToLower()) }
    if ($Launch) { $t.SetAttribute('launch', $Launch) }
    if ($ActivationType) { $t.SetAttribute('activationType', $ActivationType.ToLower()) }
    if ($PSBoundParameters.ContainsKey('Timestamp')) { $t.SetAttribute('displayTimestamp', $Timestamp.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) }
    if ($ButtonStyles) { $t.SetAttribute('useButtonStyle', 'true') }
    if ($Header) { [void](& $el $t 'header' $Header.Attributes) }

    $b = & $el (& $el $t 'visual' $null) 'binding' @{ template = 'ToastGeneric' }
    foreach ($line in @($Title) + @($Body) | Where-Object { $_ }) { (& $el $b 'text' $null).InnerText = $line }
    if ($Attribution) { (& $el $b 'text' @{ placement = 'attribution' }).InnerText = $Attribution }
    if ($AppLogo) { [void](& $el $b 'image' ([ordered]@{ placement = 'appLogoOverride'; src = (ConvertTo-ToastUri $AppLogo); 'hint-crop' = $(if ($AppLogoCircle) { 'circle' }) })) }
    if ($HeroImage) { [void](& $el $b 'image' @{ placement = 'hero'; src = (ConvertTo-ToastUri $HeroImage) }) }
    foreach ($i in @($Image) | Where-Object { $_ }) { [void](& $el $b 'image' @{ src = (ConvertTo-ToastUri $i) }) }
    $n = 0
    foreach ($p in @($ProgressBar) | Where-Object { $_ }) {
        # bound values ({progressValue}, ...) so Update-ToastProgress can change them
        $sfx = if ($n) { "$n" } else { '' }; $n++
        $a = [ordered]@{ status = "{progressStatus$sfx}"; value = "{progressValue$sfx}" }
        if ($p.Title) { $a.title = "{progressTitle$sfx}" }
        if ($p.ValueDisplay) { $a.valueStringOverride = "{progressValueString$sfx}" }
        [void](& $el $b 'progress' $a)
    }

    if ($Silent -or $Sound -or $SoundFile -or $LoopSound) {
        $src = if ($SoundFile) { ConvertTo-ToastUri $SoundFile } elseif ($Sound -match '^(Alarm|Call)') { "ms-winsoundevent:Notification.Looping.$Sound" } elseif ($Sound) { "ms-winsoundevent:Notification.$Sound" }
        [void](& $el $t 'audio' ([ordered]@{ src = $src; loop = $(if ($LoopSound) { 'true' }); silent = $(if ($Silent) { 'true' }) }))
    }

    if ($Buttons -or $Inputs) {
        $acts = & $el $t 'actions' $null
        foreach ($in in @($Inputs) | Where-Object { $_ }) {
            $ie = & $el $acts 'input' $in.Attributes
            if ($in.Items) { foreach ($k in $in.Items.Keys) { [void](& $el $ie 'selection' ([ordered]@{ id = $k; content = $in.Items[$k] })) } }
        }
        foreach ($btn in @($Buttons) | Where-Object { $_ }) { [void](& $el $acts 'action' $btn.Attributes) }
    }
    $x.OuterXml
}

function Get-ProgressData([object[]]$ProgressBar) {
    $d = @{}; $n = 0
    foreach ($p in @($ProgressBar) | Where-Object { $_ }) {
        $sfx = if ($n) { "$n" } else { '' }; $n++
        $d["progressStatus$sfx"] = $p.Status; $d["progressValue$sfx"] = $p.Value
        if ($p.Title) { $d["progressTitle$sfx"] = $p.Title }
        if ($p.ValueDisplay) { $d["progressValueString$sfx"] = $p.ValueDisplay }
    }
    $d
}

#endregion

#region Show, update, remove

function Show-Toast {
    <#
    .SYNOPSIS
        Shows a toast notification. Gets through Do Not Disturb if needed.
    .DESCRIPTION
        Supports every option of the ToastGeneric schema plus tag/group, expiration, priority, scheduling, progress
        updates, events and banner display time. With -BreakThrough Auto (default) LoudToast predicts whether Do Not
        Disturb would suppress the banner (Test-ToastBreakThrough). If so, it turns DND off for the banner's lifetime
        and restores it from a hidden process afterwards.
    .EXAMPLE
        Show-Toast 'Build finished' 'All tests passed'
    .EXAMPLE
        $r = Show-Toast 'Deploy?' -Inputs (New-ToastTextBox note) -Buttons (New-ToastButton Yes yes), (New-ToastButton No no) -Wait
        $r.Arguments; $r.UserInput.note
    .EXAMPLE
        Show-Toast 'Download' -ProgressBar (New-ToastProgressBar 'Starting' 0) -Tag dl
        Update-ToastProgress -Tag dl -Value 0.5 -Status 'Half way'
    .EXAMPLE
        Show-Toast 'Stand-up' 'in 5 minutes' -Scenario Reminder -Inputs (New-ToastSelectionBox snooze ([ordered]@{ '5' = '5 min'; '15' = '15 min' })) `
            -Buttons (New-ToastSystemButton Snooze -SelectionBoxId snooze), (New-ToastSystemButton Dismiss)
    .OUTPUTS
        With -Wait: an object with Result (Activated, Dismissed, Failed, Timeout), Arguments, UserInput, Reason, ErrorCode, Tag.
    #>
    [CmdletBinding()]
    param(
        # First line, bold.
        [Parameter(Position = 0)][string]$Title,
        # Further lines (up to two are shown).
        [Parameter(Position = 1)][string[]]$Body,
        # Small grey source line at the bottom.
        [string]$Attribution,
        # Image replacing the app icon.
        [string]$AppLogo,
        # Crop the app logo to a circle.
        [switch]$AppLogoCircle,
        # Wide image at the top.
        [string]$HeroImage,
        # Inline images below the text.
        [string[]]$Image,
        # Default, Reminder, Alarm, IncomingCall or Urgent. Reminder/Alarm/IncomingCall stay until dismissed and need a button.
        [ValidateSet('Default', 'Reminder', 'Alarm', 'IncomingCall', 'Urgent')][string]$Scenario = 'Default',
        # Short (system default) or Long (25 s). Ignored with -DisplaySeconds.
        [ValidateSet('Short', 'Long')][string]$Duration,
        # Arguments when the toast body is clicked.
        [string]$Launch,
        # Activation type of the toast body.
        [ValidateSet('Foreground', 'Background', 'Protocol')][string]$ActivationType,
        # Custom time shown in the toast.
        [datetime]$Timestamp,
        # Windows notification sound. Alarm* and Call* are looping sounds.
        [ValidateSet('Default', 'IM', 'Mail', 'Reminder', 'SMS', 'Alarm', 'Alarm2', 'Alarm3', 'Alarm4', 'Alarm5', 'Alarm6', 'Alarm7', 'Alarm8', 'Alarm9', 'Alarm10',
            'Call', 'Call2', 'Call3', 'Call4', 'Call5', 'Call6', 'Call7', 'Call8', 'Call9', 'Call10')][string]$Sound,
        # Custom sound file.
        [string]$SoundFile,
        # Repeat the sound until the toast is dismissed.
        [switch]$LoopSound,
        # No sound.
        [switch]$Silent,
        # Objects from New-ToastButton / New-ToastSystemButton (max. 5).
        [object[]]$Buttons,
        # Objects from New-ToastTextBox / New-ToastSelectionBox.
        [object[]]$Inputs,
        # Objects from New-ToastProgressBar.
        [object[]]$ProgressBar,
        # Object from New-ToastHeader.
        [object]$Header,
        # Enable colored buttons (New-ToastButton -Style).
        [switch]$ButtonStyles,
        # Your own toast XML instead of the content parameters.
        [string]$Xml,
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId,
        # Identifier for updating/removing this toast. Same tag and group replaces an existing toast.
        [string]$Tag,
        # Group of the tag.
        [string]$Group = $script:DefaultGroup,
        # Remove the toast from the notification center at this time.
        [datetime]$ExpirationTime,
        # Only add to the notification center, no banner.
        [switch]$SuppressPopup,
        # Sort to the top of the notification center.
        [switch]$HighPriority,
        # Remove the toast on reboot.
        [switch]$ExpiresOnReboot,
        # Schedule the toast for this time. Do Not Disturb handling does not apply.
        [datetime]$At,
        # How long the banner stays on screen, in seconds (minimum 5). Default: Get-ToastDisplayDuration.
        [ValidateRange(1, 3600)][int]$DisplaySeconds,
        # Auto: turn Do Not Disturb off temporarily if it would hide the banner. Never: respect it. KeepOff: turn it off and leave it off.
        [ValidateSet('Auto', 'Never', 'KeepOff')][string]$BreakThrough = 'Auto',
        # When to restore Do Not Disturb. Default: banner display time + 2 s.
        [int]$BreakThroughSeconds,
        # Block until the toast is clicked, dismissed or times out, and return the result.
        [switch]$Wait,
        # Timeout for -Wait.
        [int]$TimeoutSeconds = 300,
        # Return the Windows.UI.Notifications.ToastNotification object.
        [switch]$PassThru,
        # Return the generated XML without showing anything.
        [switch]$AsXml
    )
    if (-not $Xml) {
        $xp = @{}
        foreach ($k in (Get-Command -Name New-ToastXml).Parameters.Keys) { if ($PSBoundParameters.ContainsKey($k)) { $xp[$k] = $PSBoundParameters[$k] } }
        if ($DisplaySeconds) { [void]$xp.Remove('Duration') }  # duration="long" is fixed and would override DisplaySeconds
        $Xml = New-ToastXml @xp
    }
    if ($AsXml) { return $Xml }
    if (-not $Tag -and ($ProgressBar -or $Wait)) { $Tag = [guid]::NewGuid().ToString('n').Substring(0, 16) }

    if ($PSBoundParameters.ContainsKey('At')) {
        [LoudToast.Toasts]::Schedule($AppId, $Xml, $At, $Tag, $Group, [bool]$SuppressPopup)
        return
    }

    if ($BreakThrough -ne 'Never' -and -not $SuppressPopup) {
        $scenarioAttr = ([xml]$Xml).toast.GetAttribute('scenario')
        if (-not (Test-ToastBreakThrough -AppId $AppId -Scenario $(if ($scenarioAttr) { $scenarioAttr } else { 'default' }) -Tag $Tag).BreaksThrough) {
            if (-not $BreakThroughSeconds) {
                $banner = if ($DisplaySeconds) { [Math]::Max(5, $DisplaySeconds) } elseif ($Duration -eq 'Long') { 25 } else { Get-ToastDisplayDuration }
                $BreakThroughSeconds = $banner + 2
            }
            if ($BreakThrough -eq 'KeepOff') { [void](Disable-Dnd -Confirm:$false) } else { Invoke-BreakThrough $BreakThroughSeconds }
        }
    }

    $exp = if ($PSBoundParameters.ContainsKey('ExpirationTime')) { $ExpirationTime } else { $null }
    $t = [LoudToast.Toasts]::Create($Xml, $Tag, $Group, $exp, [bool]$SuppressPopup, [bool]$HighPriority, [bool]$ExpiresOnReboot, (Get-ProgressData $ProgressBar))
    $w = Invoke-WithDisplayDuration $DisplaySeconds { [LoudToast.Toasts]::Show($AppId, $t, [bool]$Wait) }
    if ($Wait) { $w.Wait($TimeoutSeconds * 1000) | Add-Member -NotePropertyName Tag -NotePropertyValue $Tag -PassThru }
    elseif ($PassThru) { $t }
}

function Update-ToastProgress {
    <#
    .SYNOPSIS
        Updates the progress bar of a toast that is still shown or in the notification center.
    .EXAMPLE
        Update-ToastProgress -Tag dl -Value 0.8 -Status 'Almost done' -ValueDisplay '80 / 100 MB'
    .OUTPUTS
        Succeeded or NotificationNotFound.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates own notification only')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # Tag passed to Show-Toast.
        [Parameter(Mandatory)][string]$Tag,
        # Group passed to Show-Toast.
        [string]$Group = $script:DefaultGroup,
        # 0 to 1, or 'indeterminate'.
        [string]$Value,
        # Text below the bar.
        [string]$Status,
        # Text above the bar.
        [string]$Title,
        # Replaces the percentage shown on the right.
        [string]$ValueDisplay,
        # Which progress bar, if the toast has several (0-based).
        [int]$Index = 0,
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId
    )
    $sfx = if ($Index) { "$Index" } else { '' }
    $d = @{}
    if ($PSBoundParameters.ContainsKey('Value')) { $d["progressValue$sfx"] = $Value }
    if ($PSBoundParameters.ContainsKey('Status')) { $d["progressStatus$sfx"] = $Status }
    if ($PSBoundParameters.ContainsKey('Title')) { $d["progressTitle$sfx"] = $Title }
    if ($PSBoundParameters.ContainsKey('ValueDisplay')) { $d["progressValueString$sfx"] = $ValueDisplay }
    # Sequence numbers must increase, also across processes: tenths of a second since 2025
    $seq = [uint32](([DateTime]::UtcNow - [DateTime]'2025-01-01').TotalMilliseconds / 100)
    if ((Test-Path -Path variable:script:Seq) -and $seq -le $script:Seq) { $seq = $script:Seq + 1 }
    $script:Seq = $seq
    [LoudToast.Toasts]::Update($AppId, $Tag, $Group, $d, $seq)
}

function Remove-Toast {
    <#
    .SYNOPSIS
        Removes toasts from the notification center, or scheduled toasts.
    .EXAMPLE
        Remove-Toast -Tag dl
    .EXAMPLE
        Remove-Toast -All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # Tag of the toast.
        [string]$Tag,
        # Group of the tag. Without -Tag: removes the whole group.
        [string]$Group = $script:DefaultGroup,
        # Remove all toasts of the app.
        [switch]$All,
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId,
        # Act on scheduled toasts instead of shown ones.
        [switch]$Scheduled
    )
    $t = if ($Tag) { $Tag } else { $null }
    $g = if ($All -or ($Scheduled -and -not $PSBoundParameters.ContainsKey('Group'))) { $null } else { $Group }
    $target = if ($All) { "all toasts of $AppId" } else { "tag '$Tag' group '$g' of $AppId" }
    if (-not $PSCmdlet.ShouldProcess($target, $(if ($Scheduled) { 'Remove scheduled toasts' } else { 'Remove toasts' }))) { return }
    if ($Scheduled) { [LoudToast.Toasts]::Unschedule($AppId, $t, $g) }
    elseif ($All) { [LoudToast.Toasts]::Remove($AppId, $null, $null) }
    else { [LoudToast.Toasts]::Remove($AppId, $t, $g) }
}

function Get-ToastHistory {
    <#
    .SYNOPSIS
        Lists the app's toasts in the notification center, or its scheduled toasts.
    .EXAMPLE
        Get-ToastHistory -Scheduled
    #>
    [CmdletBinding()]
    param(
        # Application User Model ID. Defaults to Get-ToastDefaultAppId.
        [string]$AppId = $script:DefaultAppId,
        # List scheduled toasts.
        [switch]$Scheduled
    )
    if ($Scheduled) {
        [LoudToast.Toasts]::Scheduled($AppId) | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ Tag = $p[0]; Group = $p[1]; DeliveryTime = [datetime]$p[2] } }
    }
    else { [LoudToast.Toasts]::History($AppId) | ForEach-Object { [pscustomobject]$_ } }
}

function Show-Balloon {
    <#
    .SYNOPSIS
        Shows a classic notification area balloon. Gets through Do Not Disturb if needed.
    .DESCRIPTION
        Windows turns balloons into banner-only toasts under the process AppUserModelID (set it with
        Set-ToastDefaultAppId) or a generated NotifyIconGeneratedAumid_* identity. The command blocks while the
        balloon is visible, because the tray icon has to stay alive.
    .EXAMPLE
        Show-Balloon 'Disk almost full' 'C: has 2 GB left' -Icon Warning -Seconds 10
    #>
    [CmdletBinding()]
    param(
        # Bold first line.
        [Parameter(Mandatory, Position = 0)][string]$Title,
        # Message text.
        [Parameter(Position = 1)][string]$Text = ' ',
        # None, Info, Warning, Error, or a path to an .ico file.
        [string]$Icon = 'Info',
        # How long the balloon stays on screen (minimum 5).
        [ValidateRange(1, 3600)][int]$Seconds = 6,
        # Auto: turn Do Not Disturb off temporarily if it would hide the balloon. Never: respect it. KeepOff: turn it off and leave it off.
        [ValidateSet('Auto', 'Never', 'KeepOff')][string]$BreakThrough = 'Auto'
    )
    if ($BreakThrough -ne 'Never') {
        $ptr = [IntPtr]::Zero
        $id = if ([LoudToast.Native]::GetCurrentProcessExplicitAppUserModelID([ref]$ptr) -eq 0) { [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr) } else { '' }
        if (-not (Test-ToastBreakThrough -AppId $id).BreaksThrough) {
            if ($BreakThrough -eq 'KeepOff') { [void](Disable-Dnd -Confirm:$false) } else { Invoke-BreakThrough ([Math]::Max(5, $Seconds) + 2) }
        }
    }
    $ni = New-Object -TypeName Windows.Forms.NotifyIcon
    try {
        $tip = [Windows.Forms.ToolTipIcon]::None
        if ($Icon -in 'None', 'Info', 'Warning', 'Error') { $tip = [Windows.Forms.ToolTipIcon]$Icon; $ni.Icon = [Drawing.SystemIcons]::Information }
        else { $ni.Icon = New-Object -TypeName Drawing.Icon -ArgumentList (Resolve-Path -Path $Icon).ProviderPath }
        $ni.Visible = $true
        Invoke-WithDisplayDuration $Seconds { $ni.ShowBalloonTip($Seconds * 1000, $Title, $Text, $tip) }  # Windows ignores the timeout argument
        Start-Sleep -Seconds ([Math]::Max(5, $Seconds) - 1)
    }
    finally { $ni.Dispose() }
}

#endregion
