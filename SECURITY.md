# Security Policy

## Supported Versions

This project has no versioned releases. Only the latest code on the `main` branch is supported and receives security fixes.

## Reporting a Vulnerability

Please do not report security issues in public issues, pull requests or discussions.

Report privately using GitHub's private vulnerability reporting:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Describe the issue, how to reproduce it, and its potential impact.

If private reporting is unavailable, contact the maintainers at `josephdeornay@gmail.com`.

Please include:
- The affected file, table, endpoint or workflow
- Steps to reproduce
- What an attacker could read, change or delete
- Any suggested fix

We aim to acknowledge reports within 3 business days and to share a status update within 7 days. We will credit reporters in the fix unless they prefer to stay anonymous.

## Scope

In scope:
- The ETL scripts in `etl/` and the Docker setup in `docker/` and `compose.yaml`
- Database schema and migration files in `data/` and `docs/`
- Our Supabase/PostgreSQL configuration, including Row-Level Security (RLS) and exposed API access
- Secrets or credentials accidentally committed to the repository or its history

Out of scope:
- Vulnerabilities in third-party services (Supabase, GitHub, Docker, Tableau). Please report those to the vendor.
- Social engineering or physical attacks
- Denial-of-service testing against the hosted Supabase project

Please do not access, modify or delete data in our hosted database while testing. Use a local Docker instance (`docker compose up -d`) to reproduce issues.

## Security Practices for Contributors

- **Never commit secrets.** Database passwords, connection strings, and Supabase anon/service keys belong in `.env`, which must stay in `.gitignore`. Provide a `.env.example` with empty values.
- **Enable RLS on every table in the `public` schema.** Tables created through `data/schema.sql` must include `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;`. Grant API access only through explicit, minimal policies.
- **Use the right connection.** ETL and BI tools connect with the database connection string. Never put the service role key in client-side code or dashboards.
- **Rotate on exposure.** If a key or password is committed, treat it as compromised: rotate it immediately in Supabase (Project Settings), then remove it from the code. Removing it from history alone is not enough.
- **Review before merging.** Changes go through pull requests, and any change touching schema, permissions or credentials needs a second reviewer.

## Disclosure

We follow coordinated disclosure. Once a fix is available, we will note the issue in the repository's security advisories and describe what was affected and how to update.
