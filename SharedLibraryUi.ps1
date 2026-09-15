# SharedLibraryUi.ps1 - the "Shared library" toolbar button.
#
# All this does is ask which folder the two computers share (once), then hand
# the work to Sync-Library.ps1 through the normal job runner, so the copying
# tails into the log panel and the window never freezes behind it.
#
# The rules about WHAT is shared, and the merging, live in SharedLibrary.ps1.
# Nothing to do with the WPF window belongs there.

# 'sync', 'choose', or $null for "leave it alone".
function Show-LibraryChoice {
    param([string]$Current)
    $nl = [Environment]::NewLine
    if (-not $Current) {
        $first = [System.Windows.MessageBox]::Show(
            "Pick a folder that BOTH computers can see - a shared OneDrive or Dropbox folder, a" + $nl +
            "network folder, or a USB stick." + $nl + $nl +
            "Your b-roll, your pop-up pictures and your music get copied both ways, so you each" + $nl +
            "end up with everything. Your videos and saved edits stay private to this computer.",
            'Shared library', [System.Windows.MessageBoxButton]::OKCancel,
            [System.Windows.MessageBoxImage]::Information)
        if ($first -eq [System.Windows.MessageBoxResult]::OK) { return 'choose' }
        return $null
    }
    # Already set up: syncing is the common case, so Yes means "just sync".
    $answer = [System.Windows.MessageBox]::Show(
        "Share with:" + $nl + "    $Current" + $nl + $nl +
        "Yes  -  sync now" + $nl +
        "No   -  choose a different folder",
        'Shared library', [System.Windows.MessageBoxButton]::YesNoCancel,
        [System.Windows.MessageBoxImage]::Question)
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { return 'sync' }
    if ($answer -eq [System.Windows.MessageBoxResult]::No)  { return 'choose' }
    return $null
}

function Sync-Library {
    if ($script:proc) { Write-LogLine "Finish the current step before syncing the shared library."; return }

    $current = Get-LibraryLocation $Root
    $choice = Show-LibraryChoice $current
    if (-not $choice) { return }

    if ($choice -ne 'sync') {
        $picked = Select-Folder "Choose the folder both computers share" $current
        if (-not $picked) { return }
        Set-LibraryLocation $Root $picked
        Write-LogLine "Shared library folder set to: $picked"
    }

    # No refresh callback: the editor asks for the b-roll list each time it opens
    # it, so whatever arrived is simply there the next time you look.
    Start-Task "Shared library" 'Sync-Library.ps1' @() $null
}
