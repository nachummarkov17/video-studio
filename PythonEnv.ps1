# PythonEnv.ps1 - making the caption-timing aligner work on someone else's PC.
#
# THE PROBLEM. The aligner is a Python virtual environment (tools\align-venv)
# holding 1.3 GB of torch. A venv is not self-contained: it keeps a one-line
# pointer in pyvenv.cfg to the Python it was BUILT from, and uses that install's
# standard library. Ours says:
#
#     home = C:\Python312
#
# Copy it to a machine without exactly that path and its python.exe refuses to
# start - "No Python at '...'" - so caption timing silently drops to the
# fallback method, with nothing obviously wrong.
#
# THE FIX. Nothing about the 1.3 GB is machine-specific; only that pointer is.
# So find a Python 3.12 wherever it lives, rewrite the pointer, and the whole
# environment works. Verified: breaking the pointer breaks it, restoring it
# brings torch straight back.
#
# It must be 3.12 specifically. torch ships compiled extensions built against
# one Python minor version (cp312), and 3.11 or 3.13 will not load them.

$script:PythonMinor = '3.12'

# Everywhere a Python 3.12 might reasonably be, cheapest first. The py launcher
# is the reliable one - it is what Windows installs to keep track of versions.
function Get-PythonCandidates {
    $out = @()
    try {
        $listed = & py "-$($script:PythonMinor)" -c "import sys; print(sys.prefix)" 2>$null
        if ($listed) { $out += ([string]$listed).Trim() }
    } catch {}
    foreach ($p in @(
        "C:\Python312",
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312'),
        (Join-Path $env:ProgramFiles 'Python312'),
        "C:\Program Files (x86)\Python312"
    )) { if ($p) { $out += $p } }
    try {
        $onPath = Get-Command python -ErrorAction SilentlyContinue
        if ($onPath) { $out += (Split-Path -Parent $onPath.Source) }
    } catch {}
    # Returned PLAIN, and every caller wraps in @(). `return ,$arr` would emit
    # the whole array as ONE pipeline item, and a foreach over that iterates
    # once with the array itself - which is exactly how this silently found no
    # Python at all the first time.
    return ($out | Where-Object { $_ } | Select-Object -Unique)
}

# Is this folder a Python of the version we need? Asks the interpreter rather
# than trusting the folder name.
function Test-PythonDir {
    param([string]$Dir)
    if (-not $Dir) { return $false }
    $exe = Join-Path $Dir 'python.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    try {
        $v = (& $exe -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -First 1)
        return (([string]$v).Trim() -eq $script:PythonMinor)
    } catch { return $false }
}

# The install directory of a usable Python 3.12, or $null.
function Find-PythonBase {
    foreach ($c in @(Get-PythonCandidates)) { if (Test-PythonDir $c) { return $c } }
    return $null
}

# ---- the venv's pointer -----------------------------------------------------

function Get-VenvBase {
    param([Parameter(Mandatory = $true)][string]$VenvPath)
    $cfg = Join-Path $VenvPath 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    foreach ($line in [System.IO.File]::ReadAllLines($cfg)) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return $null
}

# Cheap: just "does the Python it points at still exist". No process started, so
# this is free to call before every use.
function Test-VenvBaseValid {
    param([Parameter(Mandatory = $true)][string]$VenvPath)
    $home_ = Get-VenvBase $VenvPath
    if (-not $home_) { return $false }
    return (Test-Path -LiteralPath (Join-Path $home_ 'python.exe'))
}

# PURE: rewrite the three path lines in a pyvenv.cfg's text.
function Set-VenvCfgBase {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CfgText,
        [Parameter(Mandatory = $true)][string]$PythonDir
    )
    $exe = Join-Path $PythonDir 'python.exe'
    $lines = @()
    $sawHome = $false
    foreach ($line in ($CfgText -split "`r?`n")) {
        if ($line -match '^\s*home\s*=') { $lines += "home = $PythonDir"; $sawHome = $true }
        elseif ($line -match '^\s*executable\s*=') { $lines += "executable = $exe" }
        elseif ($line -match '^\s*command\s*=') { $lines += ($line -replace '^\s*command\s*=\s*\S+', "command = $exe") }
        elseif ($line.Trim() -ne '') { $lines += $line }
    }
    if (-not $sawHome) { $lines = @("home = $PythonDir") + $lines }
    return (($lines -join "`r`n") + "`r`n")
}

# Point the venv at $PythonDir (or at whatever 3.12 we can find). Returns $true
# if the venv now points somewhere real.
function Repair-VenvBase {
    param(
        [Parameter(Mandatory = $true)][string]$VenvPath,
        [string]$PythonDir
    )
    $cfg = Join-Path $VenvPath 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    if (-not $PythonDir) { $PythonDir = Find-PythonBase }
    if (-not $PythonDir) { return $false }
    try {
        $text = [System.IO.File]::ReadAllText($cfg)
        [System.IO.File]::WriteAllText($cfg, (Set-VenvCfgBase $text $PythonDir),
                                       (New-Object System.Text.UTF8Encoding($false)))
    } catch { return $false }
    return (Test-VenvBaseValid $VenvPath)
}

# Only touches anything when the pointer is actually dangling, so it is safe to
# call on every run.
function Confirm-AlignerReady {
    param([Parameter(Mandatory = $true)][string]$VenvPath)
    if (-not (Test-Path -LiteralPath (Join-Path $VenvPath 'Scripts\python.exe'))) { return $false }
    if (Test-VenvBaseValid $VenvPath) { return $true }
    return (Repair-VenvBase $VenvPath)
}

# The real proof: does it actually import torch? Costs a second, so the
# installer runs it once rather than every caption job.
function Test-AlignerWorks {
    param([Parameter(Mandatory = $true)][string]$VenvPath)
    $exe = Join-Path $VenvPath 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    try {
        $out = & $exe -c "import torch; print('ok')" 2>$null | Select-Object -First 1
        return (([string]$out).Trim() -eq 'ok')
    } catch { return $false }
}

# Install Python 3.12 if the machine hasn't got one. Per-user on purpose: it
# needs no administrator rights and no UAC prompt, which matters when someone
# else is running the installer.
function Install-Python312 {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $null }
    foreach ($extra in @(@('--scope', 'user'), @())) {
        try {
            $wingetArgs = @('install', '--id', "Python.Python.$($script:PythonMinor)", '-e',
                            '--accept-package-agreements', '--accept-source-agreements', '--silent') + $extra
            & winget @wingetArgs 2>&1 | Out-Null
        } catch {}
        $found = Find-PythonBase
        if ($found) { return $found }
    }
    return $null
}
