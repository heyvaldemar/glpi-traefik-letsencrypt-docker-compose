# GLPI with Let's Encrypt in a Docker Compose

Install the Docker Engine by following the official guide: https://docs.docker.com/engine/install/

Install the Docker Compose by following the official guide: https://docs.docker.com/compose/install/

Deploy GLPI server with a Docker Compose using the command:

`docker-compose -f glpi-traefik-letsencrypt-docker-compose.yml -p glpi up -d`
