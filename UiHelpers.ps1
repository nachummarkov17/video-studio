# UiHelpers.ps1 - the handful of primitives every Studio window and dialog needs.
#
# These live outside Studio.ps1 so the dialogs that were split out of it
# (caption editor, music picker) don't have to reach back into their old host.

# Build a Window (or any element) from a XAML string. Every dialog in the app is
# authored as a XAML literal and loaded through here.
function New-Win {
    param([Parameter(Mandatory = $true)][string]$XamlText)
    [xml]$x = $XamlText
    $reader = New-Object System.Xml.XmlNodeReader $x
    return [Windows.Markup.XamlReader]::Load($reader)
}

# UTF-8 with no byte-order mark: what .srt files and project JSON are written as.
function Utf8NoBom { New-Object System.Text.UTF8Encoding($false) }

# Seconds -> "m:ss" for the transport readouts.
function Format-Clock {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds)) { $Seconds = 0 }
    $m = [math]::Floor($Seconds / 60)
    $s = [math]::Floor($Seconds - $m * 60)
    return ('{0}:{1:00}' -f [int]$m, [int]$s)
}
