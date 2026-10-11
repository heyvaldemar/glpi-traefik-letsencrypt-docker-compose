#!/bin/bash
# glpi-move-data-into-volume.sh - move GLPI's data into the glpi-data volume.
#
# Run this ONCE, with the 1.x stack still up, before updating to 2.0.0:
#
#   ./glpi-move-data-into-volume.sh && ./update.sh --allow-major
#
# WHY. Releases 1.0.0 to 1.9.x mounted glpi-data at /var/www/html/glpi, a path
# the GLPI image never reads: that is where Elestio's own compose file keeps
# the HOST side of the mount, and it was taken for the container side. GLPI
# keeps everything it owns under /var/glpi (config, files, marketplace, logs),
# which the image declares as a volume, so Docker gave it an anonymous one.
# Two consequences. The data archives the backups service wrote held an empty
# directory. And a `docker compose down` followed by `up` starts GLPI on a new,
# empty anonymous volume: the installer reappears over a database that is
# still there, and glpicrypt.key, which decrypts the passwords GLPI stores, is
# gone. 2.0.0 mounts glpi-data at /var/glpi. This script carries what is in
# the anonymous volume across first, so the update finds it.
#
# It stops the glpi container for a consistent copy and leaves it stopped: the
# update that follows recreates it on glpi-data. It refuses when glpi-data
# already holds a GLPI configuration, and compares glpicrypt.key and the file
# count on both sides before saying it is done.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="glpi-traefik-letsencrypt-docker-compose.yml"
PROJECT="${COMPOSE_PROJECT_NAME:-glpi}"
TARGET="${PROJECT}_glpi-data"

die() { echo "error: $*" >&2; exit 1; }

# A DATA_PATH left in .env from the old example would put 2.0.0 back on the
# path nothing reads, so it is refused here rather than discovered later.
if [ -r .env ]; then
  dp="$(grep -E '^DATA_PATH=' .env | tail -1 | cut -d= -f2- | tr -d '"'"'" || true)"
  if [ -n "$dp" ] && [ "$dp" != "/var/glpi" ]; then
    die ".env sets DATA_PATH=$dp; GLPI reads /var/glpi. Remove that line (or set DATA_PATH=/var/glpi) and run this again"
  fi
fi

cid="$(docker compose -f "$COMPOSE_FILE" -p "$PROJECT" ps -q glpi 2>/dev/null || true)"
[ -n "$cid" ] || die "no glpi container in compose project '$PROJECT'. Start the 1.x stack first (or set COMPOSE_PROJECT_NAME)"

src="$(docker inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/var/glpi"}}{{.Name}}{{end}}{{end}}')"
[ -n "$src" ] || die "the glpi container has nothing mounted at /var/glpi; this is not the layout this script moves"
if [ "$src" = "$TARGET" ]; then
  echo "GLPI already keeps its data in $TARGET; nothing to move"
  exit 0
fi

docker volume inspect "$TARGET" >/dev/null 2>&1 || die "volume $TARGET does not exist; is '$PROJECT' the right project?"
image="$(docker inspect "$cid" --format '{{.Config.Image}}')"

# Run as root inside the GLPI image itself: no other image to pull, and cp -a
# as root keeps the www-data ownership GLPI needs.
helper() { docker run --rm --user 0 --entrypoint sh -v "$src:/from:ro" -v "$TARGET:/to" "$image" -c "$1"; }

if helper '[ -e /to/config/config_db.php ]'; then
  die "$TARGET already holds a GLPI configuration; refusing to overwrite it"
fi
if ! helper '[ -e /from/config/config_db.php ]'; then
  echo "note: the current volume has no config/config_db.php, so GLPI was never set up; moving what is there anyway"
fi

echo "stopping the glpi container for a consistent copy"
docker stop "$cid" >/dev/null

echo "copying $src -> $TARGET"
helper 'cp -a /from/. /to/'

# shellcheck disable=SC2016 # expanded by sh inside the helper container
counts="$(helper 'printf "%s %s\n" "$(find /from | wc -l)" "$(find /to | wc -l)"')"
read -r n_from n_to <<<"$counts"
[ "$n_from" = "$n_to" ] || die "copied $n_to entries of $n_from; the old volume $src is untouched, nothing else changed"
# shellcheck disable=SC2016 # expanded by sh inside the helper container
keys="$(helper 'for d in /from /to; do if [ -f "$d/config/glpicrypt.key" ]; then sha256sum "$d/config/glpicrypt.key" | cut -d" " -f1; else echo none; fi; done' | tr '\n' ' ')"
read -r k_from k_to <<<"$keys"
[ "$k_from" = "$k_to" ] || die "glpicrypt.key differs after the copy ($k_from vs $k_to); the old volume $src is untouched"

echo "moved $n_to entries; glpicrypt.key ${k_to:0:12}... is the same on both sides"
echo "the old volume $src is kept; remove it once 2.0.0 is running: docker volume rm $src"
echo "next: ./update.sh --allow-major"
