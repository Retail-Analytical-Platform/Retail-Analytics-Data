import os
from pathlib import Path
from sqlalchemy import create_engine

def get_database_url() -> str:
    docker_secret = Path("/run/secrets/database_url")
    if docker_secret.exists():
        return docker_secret.read_text().strip()

    # # 2) Local notebook: walk up folders until secrets/database_url.txt is found
    # for folder in [Path.cwd(), *Path.cwd().parents]:
    #     candidate = folder / "secrets" / "database_url.txt"
    #     if candidate.exists():
    #         return candidate.read_text().strip()

    # # 3) Fallback: environment variable
    # if os.environ.get("DATABASE_URL"):
    #     return os.environ["DATABASE_URL"]

    raise RuntimeError("Database URL not found.")

def get_engine():
    return create_engine(get_database_url())