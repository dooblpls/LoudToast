# End-to-end test for LoudToast. Checks with screenshots + Windows OCR that banners really appear.
# Switches Do Not Disturb temporarily and restores everything afterwards. Takes about 4 minutes; keep the screen on
# and do not cover the bottom right corner of the primary monitor.
#   powershell -ExecutionPolicy Bypass -File .\Test-LoudToast.ps1 [-SkipDnd]
param([switch]$SkipDnd)
$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\LoudToast.psd1" -Force
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -Name Dpi -Namespace LoudToastTest -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][LoudToastTest.Dpi]::SetProcessDPIAware()

$asTask = [WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [type]$t) { $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op)); [void]$task.Wait(-1); $task.Result }
$ocr = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
$png = Join-Path $env:TEMP 'loudtoast_test.png'
$scr = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$rect = New-Object Drawing.Rectangle ($scr.Right - 700), ($scr.Bottom - 1100), 700, 1100

function Seen([string]$word, [int]$tries = 8) {
    foreach ($i in 1..$tries) {
        Start-Sleep -Milliseconds 700
        $b = New-Object Drawing.Bitmap $rect.Width, $rect.Height; $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($rect.Location, [Drawing.Point]::Empty, $rect.Size); $g.Dispose(); $b.Save($png); $b.Dispose()
        $f = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($png)) ([Windows.Storage.StorageFile])
        $st = Await ($f.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($st)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $text = (Await ($ocr.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])).Text; $st.Dispose()
        if (($text -replace '\s', '') -match ($word -replace '\s', '')) { return $true }
    }
    $false
}
$script:fail = 0
function Check([string]$name, [bool]$ok) {
    if (-not $ok) { $script:fail++; Copy-Item $png "$env:TEMP\loudtoast_fail_$script:fail.png" -ErrorAction SilentlyContinue }
    '{0} {1}' -f $(if ($ok) { '[OK]  ' } else { "[FAIL] (screenshot: %TEMP%\loudtoast_fail_$script:fail.png)" }), $name
}
function Restored([string]$mode) { foreach ($i in 1..20) { if ((Get-DndState).UserSelected -eq $mode) { return $true }; Start-Sleep 1 }; $false }
function Id { -join (1..6 | ForEach-Object { Get-Random -Minimum 2 -Maximum 10 }) }  # no 0/1: OCR confuses them with O/l
function Balloon([string]$id, [string]$mode, [string]$appId) {
    # Show-Balloon blocks while the balloon is visible -> separate process, checked in parallel
    $pre = if ($appId) { "Set-ToastDefaultAppId '$appId';" } else { '' }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
    "Import-Module '$PSScriptRoot\LoudToast.psd1'; $pre Show-Balloon 'WNTEST $id' 'balloon' -Seconds 6 -BreakThrough $mode"
    Start-Sleep 2  # module import in the child process
    Seen $id 8
}

# ---------------- 1. XML builder (no UI) ----------------
$img = Join-Path $env:TEMP 'loudtoast_test_img.png'
$bmp = New-Object Drawing.Bitmap 364, 180; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::SteelBlue); $g.Dispose(); $bmp.Save($img); $bmp.Dispose()
$x = [xml](Show-Toast 'T' 'B1', 'B2' -Attribution 'via Test' -AppLogo $img -AppLogoCircle -HeroImage $img -Image $img -Scenario Reminder -Duration Long `
        -Launch 'l=1' -Timestamp ([datetime]'2026-01-02 03:04:05') -Sound Alarm2 -LoopSound -ButtonStyles `
        -Inputs (New-ToastTextBox reply -PlaceholderContent 'Antwort'), (New-ToastSelectionBox snooze ([ordered]@{ '5' = '5 Min'; '15' = '15 Min' })) `
        -Buttons (New-ToastButton 'Senden' send -InputId reply -Style Success), (New-ToastSystemButton Snooze -SelectionBoxId snooze), (New-ToastSystemButton Dismiss) `
        -ProgressBar (New-ToastProgressBar 'Loading' 0.3 -Title 'Datei' -ValueDisplay '3/10') -Header (New-ToastHeader h1 'Group') -AsXml)
Check 'XML: scenario/duration/launch/useButtonStyle' ($x.toast.scenario -eq 'reminder' -and $x.toast.duration -eq 'long' -and $x.toast.launch -eq 'l=1' -and $x.toast.useButtonStyle -eq 'true')
Check 'XML: text + attribution' (($x.toast.visual.binding.text | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.'#text' } }) -join '|' -eq 'T|B1|B2|via Test')
Check 'XML: images (appLogo circle, hero, inline)' (@($x.toast.visual.binding.image).Count -eq 3 -and $x.SelectSingleNode('//image[@placement="appLogoOverride"]').'hint-crop' -eq 'circle')
Check 'XML: Audio Looping.Alarm2 loop' ($x.toast.audio.src -eq 'ms-winsoundevent:Notification.Looping.Alarm2' -and $x.toast.audio.loop -eq 'true')
Check 'XML: inputs + selection' (@($x.toast.actions.input).Count -eq 2 -and @($x.SelectNodes('//selection')).Count -eq 2)
Check 'XML: buttons (style, system snooze)' ($x.SelectSingleNode('//action[@arguments="send"]').'hint-buttonStyle' -eq 'Success' -and $x.SelectSingleNode('//action[@arguments="snooze"]').activationType -eq 'system')
Check 'XML: bound progress + header' ($x.toast.visual.binding.progress.value -eq '{progressValue}' -and $x.toast.header.id -eq 'h1')
Check 'XML: Timestamp UTC' ($x.toast.displayTimestamp -match '^2026-01-02T\d\d:04:05Z$')

# ---------------- 2. Display, events, updates, history ----------------
$prevDnd = Disable-Dnd
try {
    $id = Id
    Show-Toast "WNTEST $id" 'all features' -AppLogo $img -HeroImage $img -Attribution 'Test-LoudToast' -Header (New-ToastHeader lt 'LoudToast Test') `
        -Inputs (New-ToastTextBox reply -PlaceholderContent 'Reply') -Buttons (New-ToastButton 'Send' send -InputId reply), (New-ToastSystemButton Dismiss) -Tag full
    Check 'toast with images/inputs/header visible' (Seen $id)
    Check 'history contains toast' (@(Get-ToastHistory | Where-Object Tag -eq 'full').Count -eq 1)
    Remove-Toast -Tag full
    Check 'Remove-Toast' (@(Get-ToastHistory | Where-Object Tag -eq 'full').Count -eq 0)

    $id = Id
    Show-Toast "WNTEST $id" 'progress' -ProgressBar (New-ToastProgressBar 'Start' 0.1 -ValueDisplay 'X1') -Tag prog -Duration Long
    Start-Sleep 1
    Check 'Update-ToastProgress' ((Update-ToastProgress -Tag prog -Value 0.8 -Status 'Almost done' -ValueDisplay 'X8') -eq 'Succeeded')
    Check 'update visible' (Seen 'Almost done')
    Remove-Toast -Tag prog

    $spi = Get-ToastDisplayDuration
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $id = Id; Show-Toast "WNTEST $id" 'duration' -DisplaySeconds 12 -Tag $id
    $v = 0  # time of the last frame showing the banner; robust against single OCR misses
    while ($sw.Elapsed.TotalSeconds -lt 25) { if (Seen $id 1) { $v = $sw.Elapsed.TotalSeconds } }
    Check ("DisplaySeconds 12: visible {0:N1} s" -f $v) ($v -ge 10 -and $v -le 15)
    Check "system MessageDuration unchanged ($spi)" ((Get-ToastDisplayDuration) -eq $spi)
    Remove-Toast -Tag $id

    $r = Show-Toast "WNTEST $(Id)" 'event test' -ExpirationTime (Get-Date).AddMinutes(1) -Wait -TimeoutSeconds 30
    Check "event Dismissed/TimedOut (got $($r.Result)/$($r.Reason))" ($r.Result -eq 'Dismissed' -and $r.Reason -eq 'TimedOut')

    Show-Toast "WNTEST $(Id)" 'scheduled' -At (Get-Date).AddMinutes(10) -Tag sched
    Check 'scheduled toast registered' (@(Get-ToastHistory -Scheduled | Where-Object Tag -eq 'sched').Count -eq 1)
    Remove-Toast -Tag sched -Scheduled
    Check 'scheduled toast removed' (@(Get-ToastHistory -Scheduled | Where-Object Tag -eq 'sched').Count -eq 0)
    Remove-Toast -All
} finally { Set-DndMode $prevDnd }
if ($SkipDnd) { "Failures: $script:fail"; return }

# ---------------- 3. Do Not Disturb: prediction vs. reality, BreakThrough ----------------
$origPrio = Get-DndPriorityApp
$origUrgent = (Get-ToastAppSetting).AllowUrgent
try {
    foreach ($mode in 'PriorityOnly', 'AlarmsOnly') {
        Set-DndMode $mode
        foreach ($sc in 'Default', 'Reminder', 'Alarm', 'IncomingCall', 'Urgent') {
            $id = Id
            $pred = (Test-ToastBreakThrough -Scenario $sc.ToLower()).BreaksThrough
            Show-Toast "WNTEST $id" $sc -Scenario $sc -Buttons (New-ToastButton OK ok) -BreakThrough Never -Tag $id
            $seen = Seen $id
            Remove-Toast -Tag $id
            Check "$mode/$sc Never: banner=$seen, predicted=$pred" ($seen -eq $pred)
        }
        $id = Id
        Show-Toast "WNTEST $id" 'auto' -BreakThrough Auto -BreakThroughSeconds 5
        Check "$mode/Default Auto: banner despite DND" (Seen $id)
        Check "$mode restored" (Restored $mode)
        Check "$mode/Balloon Never: suppressed" (-not (Balloon (Id) Never))
        Start-Sleep 5
        Check "$mode/Balloon Auto: banner despite DND" (Balloon (Id) Auto)
        Check "$mode restored (balloon)" (Restored $mode)
    }

    Set-DndMode PriorityOnly
    Add-DndPriorityApp
    $id = Id; Show-Toast "WNTEST $id" 'prio' -BreakThrough Never
    Check 'priority list: toast shows' (Seen $id)
    Remove-DndPriorityApp

    Register-ToastApp LoudToast.Test 'LoudToast Test'
    Add-DndPriorityApp LoudToast.Test
    Check 'priority list + process AUMID: balloon shows' (Balloon (Id) Never LoudToast.Test)
    Remove-DndPriorityApp LoudToast.Test

    [void](Set-ToastAppSetting -AllowUrgent $false)
    $id = Id; Show-Toast "WNTEST $id" 'urgent' -Scenario Urgent -Buttons (New-ToastButton OK ok) -BreakThrough Never
    Check 'urgent without consent: suppressed' (-not (Seen $id))
    [void](Set-ToastAppSetting -AllowUrgent $true)
    $id = Id; Show-Toast "WNTEST $id" 'urgent' -Scenario Urgent -Buttons (New-ToastButton OK ok) -BreakThrough Never
    Check 'urgent with Set-ToastAppSetting -AllowUrgent: shows' (Seen $id)
} finally {
    Set-DndMode $prevDnd
    foreach ($a in Get-DndPriorityApp) { if ($origPrio -notcontains $a) { Remove-DndPriorityApp $a } }
    [void](Set-ToastAppSetting -AllowUrgent $origUrgent)
    Unregister-ToastApp LoudToast.Test
    Remove-Toast -All
    Get-ChildItem 'HKCU:\Software\Classes\AppUserModelId' | Where-Object { (Get-ItemProperty $_.PSPath).DisplayName -eq 'LoudToast Test' } | Remove-Item -Recurse
}
"Failures: $script:fail"
