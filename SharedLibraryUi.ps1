# SharedLibraryUi.ps1 - the "Shared library" toolbar button.
#
# First click, it OFFERS a folder rather than asking for one. "Pick a folder
# both computers can see" is a perfectly clear sentence and still leaves you
# staring at a folder tree wondering which one counts - so it looks for the
# stick you installed from and proposes the obvious spot inside it:
#
#     <stick>\Video Studio\shared-library
#
# Say yes and it is created and remembered. Everything after that is one click.
#
# Where the folder is (and finding it again when the stick changes letter) is
# LibraryLocation.ps1; what gets copied is SharedLibrary.ps1. Only the window
# belongs here.

# 'sync', 'choose', a folder path to adopt, or $null for "leave it alone".
function Show-LibraryChoice {
    param([string]$Current, [string]$Suggestion)
    $nl = [Environment]::NewLine

    if ($Current) {
        # Set up already: syncing is the common case, so Yes just syncs.
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

    $what = "Your b-roll, your pop-up pictures and your music get copied both ways, so you" + $nl +
            "and your editor end up with everything. Your videos and saved edits stay here."

    if ($Suggestion) {
        $answer = [System.Windows.MessageBox]::Show(
            $what + $nl + $nl +
            "Use this folder?" + $nl + "    $Suggestion" + $nl + $nl +
            "It's on the USB stick, so you each sync when the stick is in - and it still" + $nl +
            "works if the stick comes up as a different drive letter on their computer." + $nl + $nl +
            "Yes  -  use it (it will be created)" + $nl +
            "No   -  choose a different folder instead",
            'Shared library', [System.Windows.MessageBoxButton]::YesNoCancel,
            [System.Windows.MessageBoxImage]::Question)
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { return $Suggestion }
        if ($answer -eq [System.Windows.MessageBoxResult]::No)  { return 'choose' }
        return $null
    }

    # Nothing to suggest - no stick in, no OneDrive. Say so plainly.
    $first = [System.Windows.MessageBox]::Show(
        $what + $nl + $nl +
        "Pick a folder BOTH computers can see: a folder on the USB stick, a shared" + $nl +
        "OneDrive or Dropbox folder, or a folder on the office network." + $nl + $nl +
        "(Plug the stick in first if you want to use that - it will be offered.)",
        'Shared library', [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Information)
    if ($first -eq [System.Windows.MessageBoxResult]::OK) { return 'choose' }
    return $null
}

function Sync-Library {
    if ($script:proc) { Write-LogLine "Finish the current step before syncing the shared library."; return }

    $current = Get-LibraryLocation $Root
    $suggestion = @(Get-SuggestedLibraryFolders) | Select-Object -First 1
    $choice = Show-LibraryChoice $current $suggestion
    if (-not $choice) { return }

    if ($choice -ne 'sync') {
        $picked = if ($choice -eq 'choose') {
            Select-Folder "Choose the folder both computers share" (Get-LibraryStartFolder $current $suggestion)
        } else {
            $choice          # the suggested folder, accepted
        }
        if (-not $picked) { return }
        try { New-Item -ItemType Directory -Force -Path $picked | Out-Null }
        catch {
            Write-LogLine "That folder couldn't be created: $($_.Exception.Message)"
            return
        }
        Set-LibraryLocation $Root $picked
        Write-LogLine "Shared library folder set to: $picked"
    }

    # No refresh callback: the editor asks for the b-roll list each time it
    # opens it, so whatever arrived is simply there the next time you look.
    Start-Task "Shared library" 'Sync-Library.ps1' @() $null
}

# Where to open the folder picker. Somewhere that exists, as close to the answer
# as possible - the stick's own folder beats "This PC" every time.
function Get-LibraryStartFolder {
    param([string]$Current, [string]$Suggestion)
    foreach ($p in @($Current, $Suggestion)) {
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p) { return $p }
        $parent = Split-Path -Parent $p
        if ($parent -and (Test-Path -LiteralPath $parent)) { return $parent }
    }
    return $null
}
