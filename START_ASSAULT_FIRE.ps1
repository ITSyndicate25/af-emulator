#requires -Version 5.1
<#
Assault Fire PH v1.0.0.24 - one-click setup + launcher.

Recommended layout:

    AssaultFirePH\
    |-- Binaries\Win32\TGame.exe
    |-- TCLS\client.exe
    |-- TCLS\Tenio\TCLS.dll
    |-- TGame\...
    |-- af-emulator\
        |-- START_ASSAULT_FIRE.ps1

The repository contents may also be copied directly into the game root.

This script does NOT download or redistribute Assault Fire game files.
When PvE support is prepared, TGame_AFDEV.exe is made as a local private copy
of the user's exact validated TGame.exe.
#>

[CmdletBinding()]
param(
    [switch]$SetupOnly,
    [switch]$SkipPythonInstall,
    [switch]$KeepServer
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$LAUNCHER_REVISION = "2026-09-27-oneclick-v18"
$EXPECTED_TGAME_SHA256 = "B4273F2658CA94EEBC559A997FDFCD02D51E77CE75B892250C1DB7FB80C70B51"
$TCLS_ORIGINAL_SHA256 = "13EAD403452E0F25CF00658369BF4BF5FF34ED1B16027F7833FB27D398386CD1"
$TCLS_PATCHED_SHA256  = "3FF351E0ADB594D7544E28DB2E966A6D6EB548E9DF70DAAF4DAF58F2EE438D56"

function Write-Title([string]$Text) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "[AF-ONECLICK] $Text" -ForegroundColor Yellow
}

function Stop-WithMessage([string]$Message) {
    Write-Host ""
    Write-Host "[AF-ONECLICK] ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    Write-Host "Nothing else will be launched. Fix the message above, then run this script again."
    Read-Host "Press Enter to close"
    exit 1
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-PS([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Backup-IfExists([string]$Path, [string]$Reason) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backup = "$Path.$Reason.$stamp.bak"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Host "[BACKUP] $Path"
    Write-Host "      -> $backup"
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments, [string]$Description) {
    Write-Host "[RUN] $Description"

    # IMPORTANT: native command stdout must NOT escape onto PowerShell's
    # success-output pipeline. Callers assign function return values, so leaked
    # pip/python output would be captured together with paths such as
    # .venv\Scripts\python.exe and later treated as one giant command name.
    # Windows PowerShell 5.1 turns redirected native stderr into ErrorRecords.
    # Warnings are not failures: wait for the process and check its exit code.
    $savedErrorActionPreference = $ErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    # Native processes update the global automatic variable; do not shadow it.
    $global:LASTEXITCODE = 1
    try {
        $ErrorActionPreference = "Continue"
        & $Exe @Arguments 2>&1 | ForEach-Object {
            Write-Host ([string]$_)
        }
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode"
    }
}

function Find-GameRoot([string]$RepoRoot) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($RepoRoot)

    $parent = Split-Path -Parent $RepoRoot
    if ($parent) { $candidates.Add($parent) }

    $grand = if ($parent) { Split-Path -Parent $parent } else { $null }
    if ($grand) { $candidates.Add($grand) }

    foreach ($candidate in $candidates) {
        $client = Join-Path $candidate "TCLS\client.exe"
        $tcls = Join-Path $candidate "TCLS\Tenio\TCLS.dll"
        $tgame = Join-Path $candidate "Binaries\Win32\TGame.exe"
        if (
            (Test-Path -LiteralPath $client -PathType Leaf) -and
            (Test-Path -LiteralPath $tcls -PathType Leaf) -and
            (Test-Path -LiteralPath $tgame -PathType Leaf)
        ) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Test-SupportedPythonPath([string]$Candidate) {
    if (-not $Candidate) {
        return $null
    }

    try {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            $exe = (Resolve-Path -LiteralPath $Candidate).Path
        } else {
            $command = Get-Command $Candidate -ErrorAction SilentlyContinue
            $exe = if ($command) { $command.Source } else { $null }
        }

        if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            return $null
        }

        # Let Python itself decide whether the interpreter is new enough.
        # This avoids PowerShell version-parsing edge cases and works with
        # nonstandard executable names such as python312.exe.
        # Collect output only after Python exits. Piping the native process into
        # Select-Object -First 1 can stop it early and produce exit code -1.
        $probeLines = @(& $exe -c "import sys; print(('OK|' if sys.version_info >= (3,10) and sys.version_info < (4,0) else 'NO|') + sys.executable)" 2>$null)
        $probeExitCode = $LASTEXITCODE
        $probe = $probeLines | Select-Object -First 1

        if ($probeExitCode -ne 0 -or -not $probe) {
            return $null
        }

        $parts = ([string]$probe).Trim() -split "\|", 2
        if ($parts.Count -ne 2 -or $parts[0] -ne "OK") {
            return $null
        }

        $resolved = $parts[1].Trim()
        if ($resolved -and (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $resolved).Path
        }

        return (Resolve-Path -LiteralPath $exe).Path
    } catch {
        return $null
    }
}

function Find-VenvPython([string]$VenvDir) {
    if (-not $VenvDir -or -not (Test-Path -LiteralPath $VenvDir -PathType Container)) {
        return $null
    }

    $scripts = Join-Path $VenvDir "Scripts"
    if (-not (Test-Path -LiteralPath $scripts -PathType Container)) {
        return $null
    }

    # Normal CPython venvs use python.exe, but some valid Windows installs keep
    # the base executable name (for example python312.exe). Probe executables
    # instead of assuming one filename.
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($name in @("python.exe", "python3.exe")) {
        $path = Join-Path $scripts $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $candidates.Add($path)
        }
    }

    Get-ChildItem -LiteralPath $scripts -Filter "python*.exe" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "(?i)^pythonw" } |
        Sort-Object Name |
        ForEach-Object { $candidates.Add($_.FullName) }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        $found = Test-SupportedPythonPath $candidate
        if ($found) {
            return $found
        }
    }

    return $null
}

function Find-PythonInstallManager {
    foreach ($name in @("pymanager.exe", "pymanager")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $command.Source).Path
        }
    }

    if ($env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\pymanager.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Find-ManagedPython {
    $manager = Find-PythonInstallManager
    if (-not $manager) {
        return $null
    }

    try {
        # The manager reports the executable for the best installed Python 3 runtime.
        $rows = @(& $manager list --format=exe --one 3 2>$null)
        if ($LASTEXITCODE -eq 0) {
            foreach ($row in $rows) {
                $candidate = ([string]$row).Trim().Trim('"')
                if (-not $candidate) {
                    continue
                }

                $found = Test-SupportedPythonPath $candidate
                if ($found) {
                    return $found
                }
            }
        }
    } catch {}

    return $null
}

function Add-PythonManagerAliasesToPath {
    if (-not $env:LOCALAPPDATA) {
        return
    }

    $windowsApps = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if (-not (Test-Path -LiteralPath $windowsApps -PathType Container)) {
        return
    }

    $pathEntries = @()
    if ($env:Path) {
        $pathEntries = @($env:Path -split [regex]::Escape([System.IO.Path]::PathSeparator))
    }

    foreach ($entry in $pathEntries) {
        if ([string]$entry -and ([string]$entry).TrimEnd('\') -ieq $windowsApps.TrimEnd('\')) {
            return
        }
    }

    if ($env:Path) {
        $env:Path = $windowsApps + [System.IO.Path]::PathSeparator + $env:Path
    } else {
        $env:Path = $windowsApps
    }
}

function Resolve-SupportedPython([string]$RepoRoot = "", [string]$GameRoot = "") {
    # Reuse the persistent runtime first. "venv" is the new generic location;
    # "venv-py312" is kept for backward compatibility with one-click v11.
    if ($GameRoot) {
        $runtimeRoot = Join-Path $GameRoot ".af-emulator-runtime"
        foreach ($name in @("venv", "venv-py312")) {
            $found = Find-VenvPython (Join-Path $runtimeRoot $name)
            if ($found) {
                return $found
            }
        }
    }

    if ($RepoRoot) {
        $found = Find-VenvPython (Join-Path $RepoRoot ".venv")
        if ($found) {
            return $found
        }
    }

    # Prefer whatever supported Python the user already has.
    foreach ($name in @(
        "python.exe",
        "python",
        "python3.exe",
        "python3",
        "python314.exe",
        "python314",
        "python3.14.exe",
        "python3.14",
        "python313.exe",
        "python313",
        "python3.13.exe",
        "python3.13",
        "python312.exe",
        "python312",
        "python3.12.exe",
        "python3.12",
        "python311.exe",
        "python311",
        "python3.11.exe",
        "python3.11",
        "python310.exe",
        "python310",
        "python3.10.exe",
        "python3.10"
    )) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            $found = Test-SupportedPythonPath $command.Source
            if ($found) {
                return $found
            }
        }
    }

    # Python Launcher can resolve an installed interpreter even when its
    # python*.exe name is not on PATH.
    $pyLauncher = $null
    foreach ($pyName in @("py.exe", "py")) {
        $candidateCommand = Get-Command $pyName -ErrorAction SilentlyContinue
        if ($candidateCommand) {
            $pyLauncher = $candidateCommand
            break
        }
    }

    if ($pyLauncher) {
        $found = Test-SupportedPythonPath $pyLauncher.Source
        if ($found) {
            Write-Host "[PY-DETECT] Python Launcher default is supported: $found"
            return $found
        }

        foreach ($minor in @(14, 13, 12, 11, 10)) {
            foreach ($selector in @("-3.$minor", "-V:3.$minor")) {
                try {
                    $resolvedLines = @(& $pyLauncher.Source $selector -c "import sys; print(sys.executable)" 2>$null)
                    $resolveExitCode = $LASTEXITCODE
                    $resolved = $resolvedLines | Select-Object -First 1
                    if ($resolveExitCode -eq 0 -and $resolved) {
                        $found = Test-SupportedPythonPath $resolved.Trim()
                        if ($found) {
                            return $found
                        }
                    }
                } catch {}
            }
        }

        foreach ($listArgs in @(@("-0p"), @("--list-paths"))) {
            try {
                $rows = @(& $pyLauncher.Source @listArgs 2>$null)
                foreach ($row in $rows) {
                    $text = [string]$row
                    $match = [regex]::Match(
                        $text,
                        '([A-Za-z]:\\[^\r\n]*?python(?:3(?:\.\d+)?)?\.exe)',
                        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                    )
                    if ($match.Success) {
                        $found = Test-SupportedPythonPath $match.Groups[1].Value.Trim()
                        if ($found) {
                            return $found
                        }
                    }
                }
            } catch {}
        }
    }

    # Python Install Manager keeps runtimes outside the traditional install folders.
    # Ask it for its installed Python 3 executable so PATH aliases are not required.
    $managedPython = Find-ManagedPython
    if ($managedPython) {
        return $managedPython
    }

    # Scan common per-user and machine-wide CPython install folders. This also
    # catches installs whose only console executable is python312.exe, etc.
    $roots = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) {
        $roots.Add((Join-Path $env:LOCALAPPDATA "Programs\Python"))
    }
    if ($env:ProgramFiles) {
        $roots.Add($env:ProgramFiles)
    }
    $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
    if ($programFilesX86) {
        $roots.Add($programFilesX86)
    }

    # Also support simple root-level installs such as C:\Python313\python.exe.
    # These are common on developer/test machines and may not be on PATH.
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    foreach ($dir in @(Get-ChildItem -LiteralPath ($systemDrive + "\") -Directory -Filter "Python*" -ErrorAction SilentlyContinue)) {
        foreach ($pythonFile in @(
            Get-ChildItem -LiteralPath $dir.FullName -Filter "python*.exe" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch "(?i)^pythonw" }
        )) {
            $found = Test-SupportedPythonPath $pythonFile.FullName
            if ($found) {
                return $found
            }
        }
    }

    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        $dirs = @()
        if ((Split-Path -Leaf $root) -eq "Python") {
            $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)
        } else {
            $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Filter "Python*" -ErrorAction SilentlyContinue)
        }

        foreach ($dir in $dirs) {
            $pythonFiles = @(
                Get-ChildItem -LiteralPath $dir.FullName -Filter "python*.exe" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch "(?i)^pythonw" }
            )
            foreach ($pythonFile in $pythonFiles) {
                $found = Test-SupportedPythonPath $pythonFile.FullName
                if ($found) {
                    return $found
                }
            }
        }
    }

    return $null
}

function Ensure-SupportedPython([string]$RepoRoot, [string]$GameRoot) {
    $python = Resolve-SupportedPython $RepoRoot $GameRoot
    if ($python) {
        $versionText = Get-PythonVersionText $python
        Write-Host "[OK] Supported Python: $versionText  $python" -ForegroundColor Green
        return $python
    }

    if ($SkipPythonInstall) {
        throw "No supported Python was found. Install Python 3.10 or newer, then run this script again."
    }

    Write-Host "[SETUP] No supported Python 3.10+ runtime was found."
    Write-Host "[SETUP] Trying Windows Package Manager (winget) to install Python Install Manager because no usable local Python was detected."

    Add-PythonManagerAliasesToPath
    $manager = Find-PythonInstallManager
    if (-not $manager) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) {
            # This is the official Python Install Manager Store product ID.
            # It installs the manager, which then selects the latest stable CPython 3.
            $managerPackageId = "9NQ7512CXL7T"
            Write-Host "[SETUP] Installing Python Install Manager through Windows Package Manager..."
            $wingetExit = 1
            try {
                # Keep native winget output off PowerShell's success-output pipeline.
                & $winget.Source install --exact --id $managerPackageId --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 |
                    ForEach-Object { Write-Host ([string]$_) }
                $wingetExit = $LASTEXITCODE
            } catch {
                Write-Host "[WARNING] winget raised an error while installing Python Install Manager: $($_.Exception.Message)" -ForegroundColor Yellow
            }

            Add-PythonManagerAliasesToPath
            $manager = Find-PythonInstallManager
            if (-not $manager) {
                # An install can report that the manager is already present. Recheck Python
                # before telling the user to do anything manually.
                $python = Resolve-SupportedPython $RepoRoot $GameRoot
                if ($python) {
                    $versionText = Get-PythonVersionText $python
                    Write-Host "[OK] Supported Python found after winget attempt: $versionText  $python" -ForegroundColor Green
                    return $python
                }

                Write-Host "[WARNING] Python Install Manager was not available after the winget attempt (exit $wingetExit)." -ForegroundColor Yellow
            }
        } else {
            Write-Host "[WARNING] winget is not available on this Windows installation." -ForegroundColor Yellow
        }
    }

    if ($manager) {
        Write-Host "[SETUP] Installing the current stable Python 3 runtime..."
        $managerExit = 1
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            $managerUpdatedDuringInstall = $false
            $managerOutput = New-Object System.Collections.Generic.List[string]
            try {
                & $manager install default 2>&1 |
                    ForEach-Object {
                        $line = [string]$_
                        [void]$managerOutput.Add($line)
                        Write-Host $line
                    }
                $managerExit = $LASTEXITCODE
            } catch {
                $message = $_.Exception.Message
                Write-Host "[WARNING] Python Install Manager raised an error: $message" -ForegroundColor Yellow
                if ($message -match "(?i)Python install manager was successfully updated") {
                    $managerUpdatedDuringInstall = $true
                }
            }

            foreach ($line in $managerOutput) {
                if ($line -match "(?i)Python install manager was successfully updated") {
                    $managerUpdatedDuringInstall = $true
                }
            }

            Add-PythonManagerAliasesToPath
            $python = Resolve-SupportedPython $RepoRoot $GameRoot
            if ($python) {
                $versionText = Get-PythonVersionText $python
                Write-Host "[OK] Supported Python installed: $versionText  $python" -ForegroundColor Green
                return $python
            }

            if ($attempt -eq 1 -and $managerUpdatedDuringInstall) {
                Write-Host "[SETUP] Python Install Manager updated itself; retrying runtime installation..."
                Start-Sleep -Seconds 1
                Add-PythonManagerAliasesToPath
                $manager = Find-PythonInstallManager
                if ($manager) {
                    continue
                }

                Write-Host "[WARNING] Python Install Manager could not be found after its self-update." -ForegroundColor Yellow
            }
            break
        }

        Write-Host "[WARNING] Python Install Manager did not provide a usable Python 3.10+ runtime (exit $managerExit)." -ForegroundColor Yellow
    }

    throw "No usable Python 3.10+ interpreter was found. Install any 64-bit Python 3.10+ version or the Python Install Manager, then rerun this launcher."
}

function Get-PythonVersionText([string]$Exe) {
    try {
        $versionLines = @(& $Exe --version 2>&1)
        $versionExitCode = $LASTEXITCODE
        $line = $versionLines | Select-Object -First 1
        if ($versionExitCode -eq 0 -and $line) {
            return ([string]$line).Trim()
        }
    } catch {}
    return ""
}

function Test-VenvDependencies([string]$VenvPython) {
    # requirements.txt currently contains cryptography>=42,<47.
    try {
        # Collect complete output and the process status before inspecting either.
        # The marker makes validation explicit and avoids stale native exit state.
        $validationOutput = @(& $VenvPython -c @"
import sys
try:
    import cryptography
    major = int(cryptography.__version__.split(".", 1)[0])
except Exception:
    raise SystemExit(1)
if 42 <= major < 47:
    print("AF_CRYPTOGRAPHY_OK")
    raise SystemExit(0)
raise SystemExit(1)
"@ 2>$null)
        $validationExitCode = $global:LASTEXITCODE
        return ($validationExitCode -eq 0 -and $validationOutput -contains "AF_CRYPTOGRAPHY_OK")
    } catch {
        return $false
    }
}

function Preserve-BadRuntime([string]$Path, [string]$Kind) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $parent = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $backup = Join-Path $parent "$leaf.$Kind.$stamp"
    Move-Item -LiteralPath $Path -Destination $backup
    Write-Host "[REPAIR] Preserved old runtime as: $backup" -ForegroundColor Yellow
}

function Ensure-Venv([string]$RepoRoot, [string]$GameRoot, [string]$BootstrapPython) {
    $requirements = Join-Path $RepoRoot "requirements.txt"
    if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) {
        throw "requirements.txt is missing from the emulator folder."
    }

    $runtimeRoot = Join-Path $GameRoot ".af-emulator-runtime"
    $venvDir = Join-Path $runtimeRoot "venv"
    $legacyPersistentDir = Join-Path $runtimeRoot "venv-py312"

    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null

    $activeDir = $null
    $venvPython = $null

    if (Test-Path -LiteralPath $venvDir -PathType Container) {
        $venvPython = Find-VenvPython $venvDir
        if ($venvPython) {
            $activeDir = $venvDir
            Write-Host "[OK] Reusing persistent Python environment: $activeDir" -ForegroundColor Green
        } else {
            Preserve-BadRuntime $venvDir "incomplete-or-unsupported"
        }
    }

    # Backward compatibility: v11 stored the runtime in venv-py312. Reuse it
    # in place when valid instead of making users redownload dependencies.
    if (-not $venvPython -and (Test-Path -LiteralPath $legacyPersistentDir -PathType Container)) {
        $legacyPython = Find-VenvPython $legacyPersistentDir
        if ($legacyPython) {
            $activeDir = $legacyPersistentDir
            $venvPython = $legacyPython
            Write-Host "[OK] Reusing legacy persistent runtime: $activeDir" -ForegroundColor Green
        } else {
            Preserve-BadRuntime $legacyPersistentDir "incomplete-or-unsupported"
        }
    }

    if (-not $venvPython) {
        Write-Host "[SETUP] Creating persistent Python environment (FIRST TIME ONLY)..."
        Invoke-Checked -Exe $BootstrapPython -Arguments @("-m", "venv", $venvDir) -Description "create persistent venv"

        $venvPython = Find-VenvPython $venvDir
        if (-not $venvPython) {
            throw (
                "New persistent Python runtime was created, but no working Python 3.10+ " +
                "executable could be found under its Scripts folder."
            )
        }

        $activeDir = $venvDir
        Write-Host "[OK] Persistent Python environment created: $venvPython" -ForegroundColor Green
    }

    $marker = Join-Path $activeDir ".af_requirements_sha256"
    $wantedHash = Get-Sha256 $requirements
    $currentHash = ""
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $currentHash = (Get-Content -LiteralPath $marker -Raw).Trim().ToUpperInvariant()
    }

    if ($currentHash -eq $wantedHash) {
        Write-Host "[OK] Python dependencies are already installed." -ForegroundColor Green
        return $venvPython
    }

    if (Test-VenvDependencies $venvPython) {
        Set-Content -LiteralPath $marker -Value $wantedHash -Encoding ASCII
        Write-Host "[OK] Existing Python dependencies verified; no pip install needed." -ForegroundColor Green
        return $venvPython
    }

    Write-Host "[SETUP] Installing emulator Python dependency (FIRST TIME OR REQUIREMENTS CHANGED)..."
    Invoke-Checked -Exe $venvPython -Arguments @(
        "-m", "pip", "install",
        "--disable-pip-version-check",
        "-r", $requirements
    ) -Description "install requirements"
    Set-Content -LiteralPath $marker -Value $wantedHash -Encoding ASCII

    if (-not (Test-VenvDependencies $venvPython)) {
        throw "Python dependencies were installed, but the required cryptography package still failed validation."
    }

    return $venvPython
}

function Test-AFHosts {
    $hostsPath = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    if (-not (Test-Path -LiteralPath $hostsPath -PathType Leaf)) {
        return $false
    }

    $wanted = @(
        "tversion.levelupgames.ph",
        "tauthproxy.levelupgames.ph",
        "tdir.levelupgames.ph"
    )
    $seen = @{}
    foreach ($name in $wanted) { $seen[$name] = @() }

    foreach ($line in Get-Content -LiteralPath $hostsPath) {
        $content = ($line -split "#", 2)[0].Trim()
        if (-not $content) { continue }
        $parts = $content -split "\s+"
        if ($parts.Count -lt 2) { continue }
        $ip = $parts[0]
        foreach ($rawName in $parts[1..($parts.Count - 1)]) {
            $name = $rawName.ToLowerInvariant()
            if ($seen.ContainsKey($name)) {
                $seen[$name] += $ip
            }
        }
    }

    foreach ($name in $wanted) {
        $values = @($seen[$name])
        if ($values.Count -ne 1 -or $values[0] -ne "127.0.0.1") {
            return $false
        }
    }
    return $true
}

function Ensure-Hosts([string]$RepoRoot) {
    if (Test-AFHosts) {
        Write-Host "[OK] Windows hosts mappings already point to 127.0.0.1." -ForegroundColor Green
        return
    }

    $hostScript = Join-Path $RepoRoot "tools\setup\setup_assaultfire_hosts.ps1"
    if (-not (Test-Path -LiteralPath $hostScript -PathType Leaf)) {
        throw "Hosts setup helper is missing: $hostScript"
    }

    Write-Host "[SETUP] Repairing Assault Fire localhost mappings..."

    if (Test-IsAdministrator) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hostScript
        if ($LASTEXITCODE -ne 0) {
            throw "Windows hosts setup helper failed with exit code $LASTEXITCODE."
        }
    } else {
        Write-Host "[SETUP] Windows will ask for Administrator permission only for the hosts-file repair."
        try {
            $hostProc = Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -PassThru -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", ('"' + $hostScript + '"')
            )
        } catch {
            throw "Administrator permission for the hosts-file repair was cancelled or failed: $($_.Exception.Message)"
        }
        if ($hostProc.ExitCode -ne 0) {
            throw "Windows hosts setup helper failed with exit code $($hostProc.ExitCode)."
        }
    }

    ipconfig /flushdns | Out-Null
    if (-not (Test-AFHosts)) {
        throw "Windows hosts setup finished but the required 127.0.0.1 mappings did not verify."
    }
    Write-Host "[OK] Hosts mappings verified." -ForegroundColor Green
}

function Stop-RunningGameProcesses {
    $running = @(
        Get-Process -Name "client", "TGame", "TGame_AFDEV" -ErrorAction SilentlyContinue
    )
    if ($running.Count -gt 0) {
        Write-Host ""
        Write-Host "Assault Fire is already running. Setup/patching needs it closed."
        foreach ($p in $running) {
            Write-Host ("  {0} PID={1}" -f $p.ProcessName, $p.Id)
        }
        $answer = Read-Host "Close these Assault Fire processes automatically? [Y/n]"
        if ($answer -and $answer -notmatch "^(?i)y(es)?$") {
            throw "Close client.exe/TGame.exe/TGame_AFDEV.exe, then run this script again."
        }

        foreach ($p in $running) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 800
    }

    $debugger = Get-Process -Name "x32dbg" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($debugger) {
        Write-Host ""
        Write-Host "x32dbg is running, but the clean one-click launch helper requires it detached/closed."
        $answer = Read-Host "Close x32dbg automatically? [Y/n]"
        if ($answer -and $answer -notmatch "^(?i)y(es)?$") {
            throw "Close or detach x32dbg, then run this script again."
        }
        Stop-Process -Id $debugger.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

function Stop-ExistingEmulatorServer([string]$RepoRoot) {
    $matches = @()
    try {
        $matches = @(
            Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                $_.CommandLine -match "assaultfire_server_v143b\.py" -and
                $_.CommandLine.IndexOf(
                    $RepoRoot,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -ge 0
            }
        )
    } catch {}

    if ($matches.Count -eq 0) {
        return
    }

    Write-Host ""
    foreach ($p in $matches) {
        Write-Host "[FOUND] Existing emulator server PID=$($p.ProcessId)"
    }
    $answer = Read-Host "Stop the existing emulator server and start a clean one? [Y/n]"
    if ($answer -and $answer -notmatch "^(?i)y(es)?$") {
        throw "An emulator server is already running."
    }

    foreach ($p in $matches) {
        Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 800
}

function Ensure-PermanentTCLS([string]$RepoRoot, [string]$GameRoot, [string]$VenvPython) {
    $tcls = Join-Path $GameRoot "TCLS\Tenio\TCLS.dll"
    $hash = Get-Sha256 $tcls

    if ($hash -eq $TCLS_PATCHED_SHA256) {
        Write-Host "[OK] TCLS.dll permanent compatibility patch is already installed." -ForegroundColor Green
        return
    }

    if ($hash -ne $TCLS_ORIGINAL_SHA256) {
        throw (
            "Unsupported TCLS.dll build. Expected the verified original or patched PH v1.0.0.24 DLL, " +
            "but found SHA256 $hash. Nothing was modified."
        )
    }

    Write-Host ""
    Write-Host "Your TCLS.dll is the verified ORIGINAL PH build."
    Write-Host "The emulator can install the verified permanent raw-PEM compatibility patch once."
    Write-Host "It creates TCLS.dll.bak and verifies the final SHA256."
    Write-Host ""
    $answer = Read-Host "Patch TCLS.dll permanently so you do not have to do this setup again? [Y/n]"
    if ($answer -and $answer -notmatch "^(?i)y(es)?$") {
        throw (
            "The current emulator preflight requires the verified patched TCLS build. " +
            "No patch was applied because you selected No."
        )
    }

    $patcher = Join-Path $RepoRoot "tools\patches\patch_tcls_apclient_raw_pem.py"
    Invoke-Checked -Exe $VenvPython -Arguments @($patcher, $tcls, "--apply") -Description "apply verified permanent TCLS compatibility patch"

    $after = Get-Sha256 $tcls
    if ($after -ne $TCLS_PATCHED_SHA256) {
        throw "TCLS.dll patch finished but final SHA256 is unexpected: $after"
    }
    Write-Host "[OK] TCLS.dll permanently patched and verified." -ForegroundColor Green
}

function Ensure-Keys([string]$RepoRoot, [string]$GameRoot, [string]$VenvPython) {
    $privateKey = Join-Path $RepoRoot "server\PRIVATE.PEM"
    $publicKey = Join-Path $RepoRoot "generated\APClient.dat"
    $clientConfig = Join-Path $GameRoot "TCLS\config"
    $clientAP = Join-Path $clientConfig "APClient.dat"
    $generator = Join-Path $RepoRoot "tools\setup\generate_local_rsa_keypair.py"
    $diagnose = Join-Path $RepoRoot "tools\patches\diagnose_tcls_apclient.py"

    if (-not (Test-Path -LiteralPath $clientConfig -PathType Container)) {
        throw "Missing client config folder: $clientConfig"
    }

    $needGenerate = (
        -not (Test-Path -LiteralPath $privateKey -PathType Leaf) -or
        -not (Test-Path -LiteralPath $publicKey -PathType Leaf)
    )

    if ($needGenerate) {
        Write-Host "[SETUP] Local RSA/APClient pair is incomplete; generating a fresh matching pair..."
        Backup-IfExists $privateKey "oneclick_old"
        Backup-IfExists $publicKey "oneclick_old"
        Invoke-Checked -Exe $VenvPython -Arguments @(
            $generator,
            "--client-config-dir", $clientConfig,
            "--force"
        ) -Description "generate and install local RSA/APClient pair"
    } else {
        $copyNeeded = $true
        if (Test-Path -LiteralPath $clientAP -PathType Leaf) {
            try {
                $copyNeeded = ((Get-Sha256 $clientAP) -ne (Get-Sha256 $publicKey))
            } catch {
                $copyNeeded = $true
            }
        }

        if ($copyNeeded) {
            Write-Host "[SETUP] Installing this emulator's matching APClient.dat..."
            Backup-IfExists $clientAP "oneclick_old"
            Copy-Item -LiteralPath $publicKey -Destination $clientAP -Force
        } else {
            Write-Host "[OK] APClient.dat already matches the emulator public key." -ForegroundColor Green
        }
    }

    Write-Host "[CHECK] Verifying TCLS + APClient + PRIVATE.PEM..."
    & $VenvPython $diagnose --client-root $GameRoot
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] TCLS/RSA/APClient verification passed." -ForegroundColor Green
        return
    }

    Write-Host "[REPAIR] Existing RSA files are inconsistent. Rebuilding the local pair..."
    Backup-IfExists $privateKey "oneclick_mismatch"
    Backup-IfExists $publicKey "oneclick_mismatch"
    Backup-IfExists $clientAP "oneclick_mismatch"

    Invoke-Checked -Exe $VenvPython -Arguments @(
        $generator,
        "--client-config-dir", $clientConfig,
        "--force"
    ) -Description "regenerate matching local RSA/APClient pair"

    & $VenvPython $diagnose --client-root $GameRoot
    if ($LASTEXITCODE -ne 0) {
        throw "TCLS/RSA/APClient verification still fails after automatic repair."
    }
    Write-Host "[OK] TCLS/RSA/APClient repaired and verified." -ForegroundColor Green
}

function Ensure-AFDev([string]$GameRoot) {
    $win32 = Join-Path $GameRoot "Binaries\Win32"
    $tgame = Join-Path $win32 "TGame.exe"
    $afdev = Join-Path $win32 "TGame_AFDEV.exe"

    $tgameHash = Get-Sha256 $tgame
    if ($tgameHash -ne $EXPECTED_TGAME_SHA256) {
        throw (
            "Unsupported TGame.exe. This project currently supports Assault Fire PH v1.0.0.24 only. " +
            "Expected SHA256 $EXPECTED_TGAME_SHA256 but found $tgameHash. Nothing was patched."
        )
    }
    Write-Host "[OK] TGame.exe is the validated PH v1.0.0.24 build." -ForegroundColor Green

    $replace = $false
    if (-not (Test-Path -LiteralPath $afdev -PathType Leaf)) {
        $replace = $true
        Write-Host "[SETUP] TGame_AFDEV.exe is missing."
    } else {
        $afdevHash = Get-Sha256 $afdev
        if ($afdevHash -ne $EXPECTED_TGAME_SHA256) {
            Write-Host "[REPAIR] Existing TGame_AFDEV.exe is not the validated build."
            Backup-IfExists $afdev "oneclick_wrong_build"
            $replace = $true
        }
    }

    if ($replace) {
        Write-Host "[SETUP] Creating TGame_AFDEV.exe from YOUR OWN validated TGame.exe..."
        Copy-Item -LiteralPath $tgame -Destination $afdev -Force
    }

    $finalHash = Get-Sha256 $afdev
    if ($finalHash -ne $EXPECTED_TGAME_SHA256) {
        throw "TGame_AFDEV.exe verification failed after local copy."
    }

    Write-Host "[OK] PvE AFDEV runtime is present and verified." -ForegroundColor Green
    Write-Host "     (Local private copy only; the emulator repository does not redistribute this game binary.)"
}

function Wait-ForLaunchGate([string]$StatusPath, [int]$TimeoutSeconds = 45) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
            try {
                $last = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
                if ($last.launch_ready -eq $true) {
                    return $last
                }

                if ($last.passed -eq $false -and $last.errors -and @($last.errors).Count -gt 0) {
                    $joined = (@($last.errors) -join "; ")
                    throw "Server preflight failed: $joined"
                }
            } catch {
                if ($_.Exception.Message -like "Server preflight failed:*") {
                    throw
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }

    if ($last) {
        $errors = if ($last.errors) { @($last.errors) -join "; " } else { "no detailed error was recorded" }
        throw "Timed out waiting for game launch gate UNLOCKED. Last preflight: $errors"
    }
    throw "Timed out waiting for server preflight_status.json."
}

Write-Title "Assault Fire PH - ONE CLICK SETUP + PLAY"
Write-Host "[AF-ONECLICK] Launcher revision: $LAUNCHER_REVISION"

$self = $MyInvocation.MyCommand.Path
if (-not $self) {
    Stop-WithMessage "Could not determine the launcher script path."
}
$self = (Resolve-Path -LiteralPath $self).Path

# Use $PSScriptRoot for helpers so StrictMode never observes $self before it is
# initialized.  $PSScriptRoot is available in Windows PowerShell 5.1.
$consoleHelper = Join-Path $PSScriptRoot "tools\setup\af_console_nonblocking.ps1"
if (Test-Path -LiteralPath $consoleHelper -PathType Leaf) {
    . $consoleHelper
    Disable-AFConsoleBlockingSelection
    Write-Host "[AF-ONECLICK] Console mouse selection: NON-BLOCKING"
} else {
    Write-Host "[AF-ONECLICK] WARNING: console non-blocking helper is missing." -ForegroundColor Yellow
}

# Stay in the user's normal PowerShell environment so Python launchers, aliases,
# PATH entries, and per-user installations remain visible.  Administrator
# elevation is requested later only if the Windows hosts file actually needs
# to be changed.

try {
    $repoRoot = Split-Path -Parent $self
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot "server\assaultfire_server_v143b.py") -PathType Leaf)) {
        throw "START_ASSAULT_FIRE.ps1 must stay in the root of the af-emulator folder."
    }

    $gameRoot = Find-GameRoot $repoRoot
    if (-not $gameRoot) {
        throw (
            "Could not find the Assault Fire PH game root. Put the ENTIRE af-emulator folder inside your " +
            "Assault Fire game folder, or copy the emulator contents directly into the game root. " +
            "The game root must contain TCLS\client.exe, TCLS\Tenio\TCLS.dll, and Binaries\Win32\TGame.exe."
        )
    }

    $win32 = Join-Path $gameRoot "Binaries\Win32"
    $clientExe = Join-Path $gameRoot "TCLS\client.exe"

    Write-Host "[OK] Emulator : $repoRoot" -ForegroundColor Green
    Write-Host "[OK] Game root: $gameRoot" -ForegroundColor Green

    Write-Step "Closing old Assault Fire processes"
    Stop-RunningGameProcesses
    Stop-ExistingEmulatorServer $repoRoot

    Write-Step "Checking Python and emulator dependencies"
    $bootstrapPython = Ensure-SupportedPython $repoRoot $gameRoot
    $venvPython = Ensure-Venv $repoRoot $gameRoot $bootstrapPython

    Write-Step "Checking the exact supported game build"
    Ensure-AFDev $gameRoot

    Write-Step "Checking TCLS.dll"
    Ensure-PermanentTCLS $repoRoot $gameRoot $venvPython

    Write-Step "Preparing the local RSA/APClient pair"
    Ensure-Keys $repoRoot $gameRoot $venvPython

    Write-Step "Checking Windows hosts mappings"
    Ensure-Hosts $repoRoot

    $env:AF_CLIENT_ROOT = $gameRoot
    $env:AF_GAME_DIR = $win32
    $env:AF_DS_SPAWNER_ENABLED = "1"

    Write-Host ""
    Write-Host "[READY] First-time setup checks are complete." -ForegroundColor Green
    Write-Host "[READY] PvE DS spawning is enabled."
    Write-Host "[READY] Runtime components that use OpenProcess will be elevated automatically."
    Write-Host "[READY] You no longer need to set AF_CLIENT_ROOT / AF_GAME_DIR manually."

    if ($SetupOnly) {
        Write-Host ""
        Write-Host "-SetupOnly was selected, so the server/client will not be launched."
        Read-Host "Press Enter to close"
        exit 0
    }

    Write-Step "Starting the emulator server"
    $statusPath = Join-Path $repoRoot "runtime\preflight_status.json"
    Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue

    $serverScript = Join-Path $repoRoot "server\assaultfire_server_v143b.py"
    $serverCommand = (
        ". " + (Quote-PS $consoleHelper) + "; " +
        "Disable-AFConsoleBlockingSelection; " +
        '$env:AF_CLIENT_ROOT=' + (Quote-PS $gameRoot) + "; " +
        '$env:AF_GAME_DIR=' + (Quote-PS $win32) + "; " +
        '$env:AF_DS_SPAWNER_ENABLED=' + (Quote-PS "1") + "; " +
        '$env:AF_DS_PYTHON=' + (Quote-PS $venvPython) + "; " +
        "Set-Location -LiteralPath " + (Quote-PS $repoRoot) + "; " +
        "Write-Host '[AF-ADMIN] Emulator server running elevated.' -ForegroundColor Green; " +
        "& " + (Quote-PS $venvPython) + " " + (Quote-PS $serverScript)
    )

    Write-Host "[UAC] Administrator permission is required for the server runtime because the AFDEV/OpenProcess path needs elevated process access." -ForegroundColor Yellow
    try {
        $serverWindow = Start-Process -FilePath "powershell.exe" -Verb RunAs -WorkingDirectory $repoRoot -PassThru -ArgumentList @(
            "-NoProfile",
            "-NoExit",
            "-ExecutionPolicy", "Bypass",
            "-Command",
            $serverCommand
        )
    } catch {
        throw "Administrator permission for the emulator server was cancelled or failed: $($_.Exception.Message)"
    }

    Write-Host "[WAIT] Waiting for server preflight and listener gate..."
    $status = Wait-ForLaunchGate $statusPath 45
    Write-Host "[OK] Server launch gate is UNLOCKED. Server PID=$($status.server_pid)" -ForegroundColor Green

    Write-Step "Starting the automatic TGame launch helper"
    $helper = Join-Path $repoRoot "tools\patches\patch_tcls_suspended_launch.py"
    $helperCommand = (
        ". " + (Quote-PS $consoleHelper) + "; " +
        "Disable-AFConsoleBlockingSelection; " +
        '$env:AF_CLIENT_ROOT=' + (Quote-PS $gameRoot) + "; " +
        "Set-Location -LiteralPath " + (Quote-PS $repoRoot) + "; " +
        "Write-Host '[AF-ADMIN] TGame launch/OpenProcess helper running elevated.' -ForegroundColor Green; " +
        "& " + (Quote-PS $venvPython) + " " + (Quote-PS $helper) + " --timeout 900"
    )

    Write-Host "[UAC] Administrator permission is required for the TGame launch helper (OpenProcess/WriteProcessMemory)." -ForegroundColor Yellow
    try {
        $helperWindow = Start-Process -FilePath "powershell.exe" -Verb RunAs -WorkingDirectory $repoRoot -PassThru -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command",
            $helperCommand
        )
    } catch {
        throw "Administrator permission for the TGame launch helper was cancelled or failed: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds 700

    Write-Step "Launching Assault Fire client.exe for you"
    Start-Process -FilePath $clientExe -WorkingDirectory (Split-Path -Parent $clientExe) | Out-Null

    Write-Title "YOU ARE DONE WITH SETUP"
    Write-Host "The emulator server is running."
    Write-Host "The launch helper is running automatically."
    Write-Host "The Assault Fire launcher was opened automatically."
    Write-Host ""
    Write-Host "What you do now:" -ForegroundColor Green
    Write-Host "  1. Log in normally in the Assault Fire launcher."
    Write-Host "  2. When the START button appears, click START."
    Write-Host ""
    Write-Host "You do NOT need to run the server, patcher, hosts helper, or client.exe manually anymore."
    Write-Host "The temporary suspended-launch patch and TGame datetime patch are applied automatically every launch."
    Write-Host ""
    Write-Host "[WAIT] Waiting for TGame.exe to appear (up to 15 minutes)..."

    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        $game = Get-Process -Name "TGame" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($game) {
            Write-Host ""
            Write-Host "[WAIT] TGame.exe appeared as PID=$($game.Id). Waiting for the automatic launch helper to finish..."

            $helperDeadline = (Get-Date).AddSeconds(30)
            while (-not $helperWindow.HasExited -and (Get-Date) -lt $helperDeadline) {
                Start-Sleep -Milliseconds 250
            }
            if ($helperWindow.HasExited -and $helperWindow.ExitCode -ne 0) {
                throw "The automatic launch helper failed with exit code $($helperWindow.ExitCode). TGame was not accepted as a successful launch."
            }
            if (-not $helperWindow.HasExited) {
                Write-Host "[WARNING] TGame exists but the launch helper is still running after 30 seconds. Check the helper window before assuming the launch succeeded." -ForegroundColor Yellow
            } else {
                Write-Host "[SUCCESS] TGame launch helper completed successfully." -ForegroundColor Green
            }
            Write-Host "[SUCCESS] TGame.exe launched. PID=$($game.Id)" -ForegroundColor Green

            if ($KeepServer) {
                Write-Host "[SUCCESS] -KeepServer was selected; the emulator server will remain running."
                Start-Sleep -Seconds 2
                exit 0
            }

            Write-Host "[SESSION] This one-click window will stay open while you play."
            Write-Host "[SESSION] When TGame.exe closes, it will stop the emulator server automatically."

            try {
                Wait-Process -Id $game.Id
            } catch {}

            Write-Host ""
            Write-Host "[CLEANUP] TGame.exe closed. Stopping the emulator server..."
            try {
                if ($status.server_pid) {
                    Stop-Process -Id ([int]$status.server_pid) -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            try {
                if ($serverWindow -and -not $serverWindow.HasExited) {
                    Stop-Process -Id $serverWindow.Id -Force -ErrorAction SilentlyContinue
                }
            } catch {}

            Write-Host "[CLEANUP] Done." -ForegroundColor Green
            Read-Host "Press Enter to close"
            exit 0
        }

        if ($helperWindow.HasExited -and $helperWindow.ExitCode -ne 0) {
            throw "The automatic launch helper exited with code $($helperWindow.ExitCode). Check its window/log output."
        }
        Start-Sleep -Seconds 1
    }

    throw "Timed out waiting for TGame.exe. The server is still running; check the launcher/helper window for the exact error."
}
catch {
    Stop-WithMessage $_.Exception.Message
}
