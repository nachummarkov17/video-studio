# PythonEnv.Tests.ps1 - making the caption-timing aligner survive being copied
# to someone else's computer.
#
# The aligner is a Python venv, and a venv is NOT self-contained: pyvenv.cfg
# holds a pointer to the Python it was built from. Ours said "C:\Python312", so
# on any machine without exactly that path the aligner silently refused to
# start and captions quietly fell back to less precise timing - broken in the
# worst way, which is invisibly.
#
# Assertions compare whole LINES rather than using multiline regex: the file is
# written with CRLF, and a regex ^...$ leaves the \r behind and fails for
# reasons that have nothing to do with the code under test.
#
# Run:  powershell -ExecutionPolicy Bypass -File tests\PythonEnv.Tests.ps1

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\PythonEnv.ps1"
$fails = 0
function A($cond, $m) { if ($cond) { Write-Host "PASS: $m" } else { Write-Host "FAIL: $m"; $script:fails++ } }
function Lines($text) { return @($text -split "`r?`n" | Where-Object { $_ -ne '' }) }
function HasLine($text, $line) { return ((Lines $text) -contains $line) }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pyenv_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# The real thing, as written by `python -m venv`.
$sample = @'
home = C:\Python312
include-system-site-packages = false
version = 3.12.2
executable = C:\Python312\python.exe
command = C:\Python312\python.exe -m venv C:\Users\nachu\AudioCleaner\tools\align-venv
'@

try {
    # ---- rewriting the pointer (pure) --------------------------------------
    $out = Set-VenvCfgBase $sample 'D:\Apps\Python312'
    A (HasLine $out 'home = D:\Apps\Python312') 'home is re-pointed'
    A (HasLine $out 'executable = D:\Apps\Python312\python.exe') 'so is executable'
    A ((Lines $out) -match '^command = D:\\Apps\\Python312\\python\.exe -m venv ') 'and the command line, keeping its tail'
    A (HasLine $out 'version = 3.12.2') 'everything else is left alone'
    A (HasLine $out 'include-system-site-packages = false') 'including the site-packages setting'
    A ($out -notmatch 'C:\\Python312') 'and no trace of the old path survives'

    $twice = Set-VenvCfgBase (Set-VenvCfgBase $sample 'C:\A') 'C:\B'
    A (HasLine $twice 'home = C:\B') 're-pointing twice ends up at the last one'
    A ((@((Lines $twice) | Where-Object { $_ -like 'home*' })).Count -eq 1) 'and does not accumulate duplicate lines'

    $noHome = Set-VenvCfgBase 'version = 3.12.2' 'C:\P'
    A (HasLine $noHome 'home = C:\P') 'a cfg with no home at all gains one'
    A (HasLine $noHome 'version = 3.12.2') 'without losing what was there'

    # ---- reading and validating a real file --------------------------------
    $venv = Join-Path $tmp 'align-venv'
    New-Item -ItemType Directory -Force -Path (Join-Path $venv 'Scripts') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $venv 'Scripts\python.exe'), 'not really python')
    [System.IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), $sample)

    A ((Get-VenvBase $venv) -eq 'C:\Python312') 'the current pointer is read back'
    A ($null -eq (Get-VenvBase $tmp)) 'a folder that is not a venv has no pointer'

    # a base that does not exist is exactly the editor's situation
    [System.IO.File]::WriteAllText((Join-Path $venv 'pyvenv.cfg'), (Set-VenvCfgBase $sample 'C:\NoSuchPython312'))
    A (-not (Test-VenvBaseValid $venv)) 'a dangling pointer is detected'

    # point it at something that really is there (a folder with a python.exe in
    # it is enough - this is the plumbing, not the interpreter)
    $fakePy = Join-Path $tmp 'FakePython'
    New-Item -ItemType Directory -Force -Path $fakePy | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fakePy 'python.exe'), 'x')
    A (Repair-VenvBase $venv $fakePy) 'repairing reports success'
    A (Test-VenvBaseValid $venv) 'and the pointer now resolves'
    A ((Get-VenvBase $venv) -eq $fakePy) 'to the Python we gave it'

    # a venv with no python at all cannot be salvaged, and says so
    $empty = Join-Path $tmp 'not-a-venv'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    A (-not (Confirm-AlignerReady $empty)) 'a missing venv is reported, not repaired'
    A (-not (Repair-VenvBase $empty $fakePy)) 'and repairing it fails cleanly'
    A (-not (Test-AlignerWorks $empty)) 'and it certainly does not "work"'

    # already-good pointers are left completely alone
    $before = [System.IO.File]::ReadAllText((Join-Path $venv 'pyvenv.cfg'))
    A (Confirm-AlignerReady $venv) 'a healthy venv confirms straight away'
    A ([System.IO.File]::ReadAllText((Join-Path $venv 'pyvenv.cfg')) -eq $before) 'without rewriting anything'

    # ---- against the Python actually on this machine ------------------------
    A ((@(Get-PythonCandidates)).Count -ge 2) 'more than one place is searched for Python'
    $real = Find-PythonBase
    A ($null -ne $real) "a Python 3.12 was found on this machine ($real)"
    if ($real) {
        A (Test-PythonDir $real) 'and it really is the right version'
        A (-not (Test-PythonDir (Join-Path $tmp 'nope'))) 'a folder with no python.exe is rejected'
        A (-not (Test-PythonDir $fakePy)) 'and one whose python.exe is not really Python is too'
    }

    # ---- and the REAL aligner, end to end ----------------------------------
    $realVenv = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')) 'tools\align-venv'
    if (Test-Path -LiteralPath $realVenv) {
        A (Confirm-AlignerReady $realVenv) 'the real aligner confirms ready'
        A (Test-AlignerWorks $realVenv) 'and torch actually imports in it'
    } else {
        Write-Host 'SKIP: no tools\align-venv on this machine'
    }
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails -eq 0) { Write-Host "All PythonEnv tests passed." } else { Write-Host "$fails test(s) FAILED."; exit 1 }
