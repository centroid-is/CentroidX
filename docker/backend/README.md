# Backend Docker Setup

## Image tags

| tag | built from | what it is |
|---|---|---|
| `latest`, `<sha>` | every push to main | AOT, `dart build cli`, the station default |
| `stable`, `<sha>` | every release tag | the same, pinned |
| `pr-N` | every pull request | the same, for trying a branch |
| `latest-profile`, `<sha>-profile` | every push to main | **JIT**, `dart run` with the Dart VM Service on, for attaching a profiler |

The `-profile` variant is the Dockerfile's `profile` stage. It is not the
default target and none of the other tags are built from it. The Dockerfile
explains why the SDK leaves no AOT option and what a JIT heap does and does
not tell you; `../profiler/README.md` says how to attach to it and how to
read what comes back.

## Quick Start

```bash
# Copy example config
cp config/stateman.example.json config/stateman.json

# Start services
docker compose up -d
```

## Certificate Generation

### PostgreSQL/TimescaleDB SSL Certificates

These are generated automatically by the `pg-certs` service on first startup. The certs are stored in `./certs/` and reused on subsequent runs.

To regenerate:
```bash
rm -rf certs/
docker compose up pg-certs
```

### OPC-UA Client Certificates

The `generate_certs` tool creates certificates for OPC-UA client authentication.

```bash
# Run from container
docker compose run --rm centroidx-backend generate_certs --help

# Generate certs (JSON format with base64-encoded values)
docker compose run --rm centroidx-backend generate_certs

# Generate certs (PEM format)
docker compose run --rm centroidx-backend generate_certs --pem

# Custom options
docker compose run --rm centroidx-backend generate_certs \
  --cn "My-Client" \
  --org "MyOrg" \
  --country "US" \
  --days 365
```

Options:
- `--cn, -c` - Common Name (default: OPC-UA-Client)
- `--org, -o` - Organization (default: Centroid)
- `--country` - Country code (default: IS)
- `--state` - State/Province (default: Hofudborgarsvaedid)
- `--locality, -l` - City/Locality (default: Hafnarfjordur)
- `--days, -d` - Validity in days (default: 3650)
- `--pem` - Output PEM format instead of JSON
