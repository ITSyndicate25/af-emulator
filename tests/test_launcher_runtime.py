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
                AF_TEST_ROOT=tmp,
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

    def test_ensure_venv_installs_dependencies_and_reuses_runtime(self):
        for shell in self.shells():
            with self.subTest(shell=shell):
                self.run_launcher(shell, r"""
$first = Ensure-Venv $env:AF_TEST_REPO $env:AF_TEST_ROOT $env:AF_TEST_PYTHON
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
