# Setting up PostgreSQL with Docker

This tutorial runs PostgreSQL locally via Docker so every team member can
practice queries against the same dataset (see [`data/`](/data/README.md)),
without installing PostgreSQL directly on their own OS.

## Table of Contents

1. [Install & enable Docker](#1-install--enable-docker)
2. [Run PostgreSQL in a container](#2-run-postgresql-in-a-container)
3. [Connect from VS Code (PostgreSQL extension)](#3-connect-from-vs-code-postgresql-extension)
4. [Everyday Docker commands](#4-everyday-docker-commands)

Next, load the `data/` dataset into the database → [Data-Integration-Docker.md](Data-Integration-Docker.md)

---

## 1. Install & enable Docker

```bash
# start Docker now, and automatically on boot
sudo systemctl enable --now docker

# so the user can run docker without sudo
sudo usermod -aG docker "$USER"
```

After that, **log out and log back in** (or run `newgrp docker` in the current
terminal) for the group change to take effect. Check the installation:

```bash
docker run hello-world
```

## 2. Run PostgreSQL in a container

The `postgres` service is already defined in this repo's [`compose.yaml`](/compose.yaml),
so there's no `docker run` command to type — just start it:

```bash
docker compose up -d postgres
```

The password isn't a plain environment variable — it's a **Docker secret**,
read from a local file instead of being stored in the compose file or visible
in `docker inspect`. Create it once, before the first start:

```bash
mkdir -p secrets
openssl rand -base64 24 | tr -d '/+=' | head -c 24 > secrets/postgres_password.txt
```

This file is gitignored (`secrets/*` in `.gitignore`) — it stays local and is
never committed.

### `compose.yaml` breakdown

```yaml
services:
  postgres:
    image: postgres:16
    container_name: retailspg
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD_FILE: /run/secrets/postgres_password
    ports:
      - "5432:5432"
    volumes:
      - retailspg-data:/var/lib/postgresql/data
    secrets:
      - postgres_password

secrets:
  postgres_password:
    file: ./secrets/postgres_password.txt

volumes:
  retailspg-data:
```

| Part | Purpose |
|---|---|
| `container_name: retailspg` | names the container `retailspg` (retail store postgres) — referenced throughout these docs |
| `POSTGRES_PASSWORD_FILE` | tells the `postgres` image to read its password from a file instead of an env var, so the plaintext value never appears in `docker inspect` or `docker compose config` |
| `secrets: postgres_password` | mounts the secret read-only at `/run/secrets/postgres_password` inside the container |
| `-p 5432:5432` (`ports`) | maps `host:container` ports — 5432 is PostgreSQL's default port |
| `retailspg-data:/var/lib/postgresql/data` (`volumes`) | local volume for storing data. `/var/lib/postgresql/data` is where PostgreSQL physically stores its tables, so if the container is removed, the data still lives in the `retailspg-data` volume and can be reused once a new container is created |
| `restart: unless-stopped` | stays alive across reboots/crashes, similar in spirit to `docker run -d` |
| `postgres:16` | the image used — PostgreSQL version 16 |

```bash
docker compose up -d postgres  # run in the background
docker compose ps              # check status
docker compose logs -f postgres # view logs live
docker compose down            # stop (add -v to also remove the volume/data)
```

## 3. Connect from VS Code (PostgreSQL extension)

1. Install the **PostgreSQL** extension in VS Code.
2. Click the PostgreSQL icon (elephant icon) in the Activity Bar, or
   `Ctrl+Shift+P` → **PostgreSQL: New Connection**.
3. Fill in the connection form as below — match **Password** to the value in
   `secrets/postgres_password.txt`:


   | Field | Value |
   |---|---|
   | Host | `127.0.0.1` |
   | Port | `5432` |
   | Username | `postgres` |
   | Password | the value in `secrets/postgres_password.txt` |
   | Database | `postgres` |

4. Click **Save**/**Connect**. The sidebar will show the database → schema →
   table tree.

## 4. Everyday Docker commands

```bash
docker ps                                            # view running containers
docker exec -it retailspg psql -U postgres            # enter psql inside the container
docker stop retailspg                                 # stop the container
docker start retailspg                                # start it again (data persists via the volume)
docker rm -f retailspg                                # remove the container (retailspg-data volume persists)
```
