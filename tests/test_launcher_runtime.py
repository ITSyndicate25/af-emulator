"""Execute launcher functions with real Windows Python, including paths with spaces."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LOAD_FUNCTIONS = r"""
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
# Some hosted PowerShell 5.1 images omit the Utility module from PSModulePath.
# Supply the same SHA-256 result shape used by the launcher when the cmdlet is absent.
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    function Get-FileHash {
        param(
            [Parameter(Mandatory=$true)][string]$LiteralPath,
            [string]$Algorithm = "SHA256"
        )
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($LiteralPath)
            try {
                $bytes = $sha.ComputeHash($stream)
            } finally {
                $stream.Dispose()
            }
        } finally {
            $sha.Dispose()
        }
        [pscustomobject]@{
            Algorithm = "SHA256"
            Hash = ([System.BitConverter]::ToString($bytes) -replace "-", "")
            Path = $LiteralPath
        }
    }
}
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $env:AF_TEST_LAUNCHER, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($fn in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
"""


@unittest.skipUnless(os.name == "nt", "Windows launcher integration")
class LauncherRuntimeTests(unittest.TestCase):
    def run_launcher(self, shell, body):
        with tempfile.TemporaryDirectory(prefix="AF runtime with spaces ") as tmp:
            env = dict(os.environ)
            env.update(
                AF_TEST_LAUNCHER=str(ROOT / "START_ASSAULT_FIRE.ps1"),
                AF_TEST_PYTHON=sys.executable,
                AF_TEST_ROOT=str(Path(tmp).resolve()),
                AF_TEST_REPO=str(ROOT),
            )
            result = subprocess.run(
                [shell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                 "-Command", LOAD_FUNCTIONS + body],
                env=env, capture_output=True, text=True, errors="replace", timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("AF_RUNTIME_TEST_PASS", result.stdout)

    def shells(self):
        shells = [shutil.which(name) for name in ("powershell.exe", "pwsh.exe")]
        self.assertTrue(all(shells), "CI must provide Windows PowerShell 5.1 and PowerShell 7")
        return shells

    def test_created_venv_is_discovered_with_stale_exit_code(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_launcher(shell, r"""
$venv = Join-Path $env:AF_TEST_ROOT "runtime with spaces"
Invoke-Checked -Exe $env:AF_TEST_PYTHON -Arguments @("-m", "venv", $venv) -Description "test venv"
$candidate = Join-Path $venv "Scripts\python.exe"
if (-not (Test-Path -LiteralPath $candidate)) { throw "venv executable missing" }
foreach ($staleCode in @(0, 1)) {
    $global:LASTEXITCODE = $staleCode
    $found = Test-SupportedPythonPath $candidate
    if (-not $found) {
        Write-Host ($Error | Out-String)
        & $candidate -c "import sys; print(sys.version); print(sys.executable)"
        throw "Real supported venv rejected with prior exit code $staleCode"
    }
    if ($found -ne $candidate) { throw "Probe returned wrong path: $found" }
    $global:LASTEXITCODE = $staleCode
    $discovered = Find-VenvPython $venv
    if ($discovered -ne $candidate) { throw "Venv discovery returned wrong path: $discovered" }
}
Write-Host "AF_RUNTIME_TEST_PASS"
""")

    def test_native_warnings_succeed_and_nonzero_exit_fails(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_launcher(shell, r"""
$PSNativeCommandUseErrorActionPreference = $true
$output = Invoke-Checked -Exe $env:AF_TEST_PYTHON -Arguments @(
    "-c", "import sys; print('ordinary warning', file=sys.stderr); print('normal output')"
) -Description "warning with success"
if ($null -ne $output) { throw "Native output leaked into function result" }
$failed = $false
try {
    Invoke-Checked -Exe $env:AF_TEST_PYTHON -Arguments @(
        "-c", "import sys; print('failure', file=sys.stderr); sys.exit(7)"
    ) -Description "expected native failure"
} catch {
    if ($_.Exception.Message -notmatch "failed with exit code 7") { throw }
    $failed = $true
}
if (-not $failed) { throw "Native failure was accepted" }
if ($ErrorActionPreference -ne "Stop") { throw "Error preference was changed" }
if (-not $PSNativeCommandUseErrorActionPreference) { throw "Native preference was changed" }
Write-Host "AF_RUNTIME_TEST_PASS"
""")

    def test_ensure_venv_installs_dependencies_and_reuses_runtime(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_launcher(shell, r"""
$first = Ensure-Venv $env:AF_TEST_REPO $env:AF_TEST_ROOT $env:AF_TEST_PYTHON
foreach ($staleCode in @(0, 1)) {
    $global:LASTEXITCODE = $staleCode
    if (-not (Test-VenvDependencies $first)) {
        throw "Installed dependency rejected with prior exit code $staleCode"
    }
}
if ($first -is [array] -or -not $first) { throw "Bootstrap returned polluted or empty path" }
if (-not (Test-VenvDependencies $first)) { throw "Fresh venv dependencies invalid" }
$stamp = (Get-Item -LiteralPath $first).LastWriteTimeUtc
$second = Ensure-Venv $env:AF_TEST_REPO $env:AF_TEST_ROOT $env:AF_TEST_PYTHON
if ($second -ne $first) { throw "Existing runtime was not reused" }
if ((Get-Item -LiteralPath $second).LastWriteTimeUtc -ne $stamp) {
    throw "Reused runtime executable was replaced"
}
Write-Host "AF_RUNTIME_TEST_PASS"
""")


if __name__ == "__main__":
    unittest.main()
