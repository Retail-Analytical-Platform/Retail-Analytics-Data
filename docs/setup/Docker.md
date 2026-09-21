# Setting up PostgreSQL with Docker

This tutorial runs PostgreSQL locally via Docker so every team member can
practice queries against the same dataset (see [`data/`](/data/README.md)),
without installing PostgreSQL directly on their own OS.

## Table of Contents

1. [Install & enable Docker](#1-install--enable-docker)
2. [Run PostgreSQL in a container](#2-run-postgresql-in-a-container)
3. [Alternative: docker-compose](#3-alternative-docker-compose)
4. [Connect from VS Code (PostgreSQL extension)](#4-connect-from-vs-code-postgresql-extension)
5. [Everyday Docker commands](#5-everyday-docker-commands)

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

```bash
docker run --name retailspg \
  -e POSTGRES_PASSWORD=passgw \
  -p 5432:5432 \
  -v retailspg-data:/var/lib/postgresql/data \
  -d postgres:16
```

### Command breakdown

| Part | Purpose |
|---|---|
| `docker run` | runs a new container |
| `--name retailspg` | names the container `retailspg` (retail store postgres) |
| `-e POSTGRES_PASSWORD=...` | environment variable password required by the `postgres` image |
| `-p 5432:5432` | maps `host:container` ports — 5432 is PostgreSQL's default port |
| `-v retailspg-data:/var/lib/postgresql/data` | local volume for storing data. `/var/lib/postgresql/data` is where PostgreSQL physically stores its tables, so if the container is removed, the data still lives in the `retailspg-data` volume and can be reused once a new container is created |
| `-d` | runs in the background (detached), so it stays alive even if the terminal is closed |
| `postgres:16` | the image used — PostgreSQL version 16 |


## 3. Alternative: docker-compose

For a more permanent project, `docker-compose.yml` is more convenient because
the configuration is stored in the repo (repeatable & versionable), so you
don't need to retype the `docker run` command every time:

```yaml
services:
  postgres:
    image: postgres:16
    container_name: pg-dev
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: mysecret
      POSTGRES_DB: myapp
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data
```

```bash
docker compose up -d      # run in the background
docker compose ps         # check status
docker compose logs -f    # view logs live
docker compose down       # stop (add -v to also remove the volume/data)
```

## 4. Connect from VS Code (PostgreSQL extension)

1. Install the **PostgreSQL** extension in VS Code.
2. Click the PostgreSQL icon (elephant icon) in the Activity Bar, or
   `Ctrl+Shift+P` → **PostgreSQL: New Connection**.
3. Fill in the connection form as below — match **Password** to the one you
   set in step 2:


   | Field | Value |
   |---|---|
   | Host | `127.0.0.1` |
   | Port | `5432` |
   | Username | `postgres` |
   | Password | the password from `POSTGRES_PASSWORD` in step 2 |
   | Database | `postgres` |

4. Click **Save**/**Connect**. The sidebar will show the database → schema →
   table tree.

## 5. Everyday Docker commands

```bash
docker ps                                            # view running containers
docker exec -it retailspg psql -U postgres            # enter psql inside the container
docker stop retailspg                                 # stop the container
docker start retailspg                                # start it again (data persists via the volume)
docker rm -f retailspg                                # remove the container (retailspg-data volume persists)
```
