import os
from pathlib import Path
from sqlalchemy import create_engine

def get_secret(name: str) -> str:
    path = Path(f"/run/secrets/{name}")
    if path.exists():
        return path.read_text().strip()          # strip removes trailing newline

    value = os.environ.get(name.upper())         # fallback when running outside Docker
    if value:
        return value

    # Local development secret files mirror the Docker secret names.
    for folder in [Path.cwd(), *Path.cwd().parents]:
        local_secret = folder / "secrets" / f"{name}.txt"
        if local_secret.exists():
            return local_secret.read_text().strip()

    raise RuntimeError(
        f"Secret '{name}' not found in /run/secrets, the environment, or secrets/{name}.txt"
    )


def get_engine():
    return create_engine(get_secret("database_url"))
