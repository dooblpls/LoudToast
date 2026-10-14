@{
    RootModule           = 'LoudToast.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '33b74cf6-ee48-4382-94c3-bbfe937bb2a4'
    Author               = 'dooblpls'
    Copyright            = '(c) 2026 dooblpls. MIT License.'
    Description          = 'Windows toast and balloon notifications that get through Do Not Disturb. Every toast option (buttons, inputs, images, progress bars, headers, sounds, scenarios, scheduling, click results), per-toast banner display time, and control of Windows 11 Do Not Disturb, its priority list and per-app notification settings. No dependencies, no admin rights. Windows PowerShell 5.1; Do Not Disturb features tested on Windows 11 25H2.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')
    FunctionsToExport    = @(
        'Show-Toast', 'Show-Balloon', 'Update-ToastProgress', 'Remove-Toast', 'Get-ToastHistory', 'New-ToastXml',
        'New-ToastButton', 'New-ToastSystemButton', 'New-ToastTextBox', 'New-ToastSelectionBox', 'New-ToastProgressBar', 'New-ToastHeader',
        'Get-ToastDisplayDuration', 'Set-ToastDisplayDuration',
        'Register-ToastApp', 'Unregister-ToastApp', 'Set-ToastDefaultAppId', 'Get-ToastDefaultAppId', 'Get-ToastAppSetting', 'Set-ToastAppSetting',
        'Get-DndState', 'Set-DndMode', 'Disable-Dnd', 'Get-DndPriorityApp', 'Add-DndPriorityApp', 'Remove-DndPriorityApp', 'Test-ToastBreakThrough'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    FileList             = @('LoudToast.psd1', 'LoudToast.psm1', 'LoudToast.cs', 'Test-LoudToast.ps1', 'README.md', 'LICENSE')
    PrivateData          = @{
        PSData = @{
            Tags         = @('Toast', 'Notification', 'Notifications', 'Balloon', 'DoNotDisturb', 'FocusAssist', 'QuietHours', 'Windows11', 'Windows10', 'WinRT', 'PSEdition_Desktop', 'Windows')
            LicenseUri   = 'https://github.com/dooblpls/LoudToast/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/dooblpls/LoudToast'
            ReleaseNotes = 'Initial release.'
        }
    }
}
