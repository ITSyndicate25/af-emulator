"""Startup option and path helpers for the Assault Fire emulator."""

import os
from pathlib import Path
from typing import Mapping, Sequence

_TRUE = frozenset(("1", "true", "yes", "on"))


def server_only_requested(
    argv: Sequence[str] = (),
    env: Mapping[str, str] | None = None,
) -> bool:
    env = os.environ if env is None else env
    if "--server-only" in argv:
        return True
    return (env.get("AF_SERVER_ONLY") or "").strip().lower() in _TRUE


def _private_key_arg(argv: Sequence[str]) -> str | None:
    for index, value in enumerate(argv):
        if value == "--private-key":
            if index + 1 >= len(argv):
                raise ValueError("--private-key requires a path")
            return argv[index + 1]
        if value.startswith("--private-key="):
            path = value.split("=", 1)[1].strip()
            if not path:
                raise ValueError("--private-key requires a path")
            return path
    return None


def private_key_candidates(
    *,
    script_path: Path,
    cwd: Path,
) -> tuple[Path, ...]:
    script_dir = Path(script_path).expanduser().resolve().parent
    work_dir = Path(cwd).expanduser().resolve()
    raw = (
        script_dir / "PRIVATE.PEM",
        script_dir.parent / "server" / "PRIVATE.PEM",
        work_dir / "PRIVATE.PEM",
        work_dir / "server" / "PRIVATE.PEM",
        work_dir.parent / "server" / "PRIVATE.PEM",
    )
    result = []
    seen = set()
    for candidate in raw:
        resolved = candidate.resolve()
        key = str(resolved).lower()
        if key not in seen:
            seen.add(key)
            result.append(resolved)
    return tuple(result)


def resolve_private_key_path(
    *,
    script_path: Path,
    argv: Sequence[str] = (),
    env: Mapping[str, str] | None = None,
    cwd: Path | None = None,
) -> Path:
    env = os.environ if env is None else env
    cwd = Path.cwd() if cwd is None else Path(cwd)

    explicit = (
        _private_key_arg(argv)
        or (env.get("AF_PRIVATE_KEY") or "").strip()
        or (env.get("AF_PRIVATE_KEY_PATH") or "").strip()
    )
    if explicit:
        return Path(explicit).expanduser().resolve()

    candidates = private_key_candidates(script_path=script_path, cwd=cwd)
    for candidate in candidates:
        if candidate.is_file():
            return candidate

    # Preserve the historical beside-the-script path in the error message when
    # no key can be discovered.
    return candidates[0]
