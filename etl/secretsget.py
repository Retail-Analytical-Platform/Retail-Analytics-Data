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
    raise RuntimeError(f"Secret '{name}' not found in /run/secrets or environment")

engine = create_engine(get_secret("database_url"))