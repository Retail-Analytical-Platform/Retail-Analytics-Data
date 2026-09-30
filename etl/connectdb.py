import os
from pathlib import Path
from sqlalchemy import create_engine

def get_database_url() -> str:
    docker_secret = Path("/run/secrets/database_url")
    if docker_secret.exists():
        return docker_secret.read_text().strip()

    # Local notebooks can be launched from etl/, the project root, or a parent.
    for folder in [Path.cwd(), *Path.cwd().parents]:
        candidate = folder / "secrets" / "database_url.txt"
        if candidate.exists():
            return candidate.read_text().strip()

    database_url = os.environ.get("DATABASE_URL")
    if database_url:
        return database_url

    raise RuntimeError(
        "Database URL not found. Add secrets/database_url.txt, set DATABASE_URL, "
        "or run inside the Docker ETL container."
    )

def get_engine():
    return create_engine(get_database_url())
