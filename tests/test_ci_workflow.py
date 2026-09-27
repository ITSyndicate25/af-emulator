from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"


def test_ci_workflow_exists():
    assert WORKFLOW.is_file()


def test_ci_uses_windows_python_matrix_and_pytest():
    source = WORKFLOW.read_text(encoding="utf-8", errors="replace")
    assert "runs-on: windows-latest" in source
    assert 'python: ["3.12", "3.14"]' in source
    assert "python-version: ${{ matrix.python }}" in source
    assert 'python -m pip install "pytest>=8,<9"' in source
    assert "python -m pytest -v tests" in source


def test_powershell_parser_uses_real_ref_variables():
    source = WORKFLOW.read_text(encoding="utf-8", errors="replace")
    assert "$tokens = $null" in source
    assert "$parseErrors = $null" in source
    assert "[ref]$tokens" in source
    assert "[ref]$parseErrors" in source
    assert "[ref]$null" not in source
