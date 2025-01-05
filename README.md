# docker-compose-blue-green

Example implementation for Blue-Green deployments with Docker Compose and Traefik.

While testing similar implementations at https://github.com/straypaper/blue-green and https://frustrated.blog/2021/03/16/traefik_blue_green.html, I encountered problems with [Traefik File Provider](https://doc.traefik.io/traefik/providers/file/) and docker bind mounts - even though *directory* configuration and *providersThrottleDuration* were set, there still were 404s for up to 60s during dynamic configuration changes.

Workaround:
- These issues did not arise with the [HTTP Provider](https://doc.traefik.io/traefik/providers/http/). This is why an Nginx container serves the dynamic configuration as yaml template via HTTP, using https://nginx.org/en/docs/http/ngx_http_sub_module.html for dynamic contents.
- During Nginx container restarts (updates...), Traefik will keep the dynamic configuration in memory until the HTTP endpoint is reachable again.

## Prerequisites

- Add domains in */etc/hosts*: `127.0.0.1 localhost main.lan blue.lan green.lan`
- Create external docker network for backend communication: `docker network create traefik_proxy`
- Generate self-signed SSL certificate `openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ./traefik/certs/cert.key -out ./traefik/certs/cert.crt`
- For Green and Blue service, the **container_name** in docker-compose.yml must be explicitely set to either *green* or *blue* (see *project.docker-compose.yml*).
- The docker host needs yq `apt install -y yq`

## Usage

Bring up Traefik and Backend:
```bash
docker compose -f traefik.docker-compose.yml up -d
docker compose -f project.docker-compose.yml up -d
```

*.env*:
```bash
# old images
DOCKER_IMAGE_BLUE=php:8.2.27-apache@sha256:56d8b242c3430aa5eb27fc112194d2b22c5c72fe7c3b3db0940639f735154c55
DOCKER_IMAGE_GREEN=php:8.2.27-apache@sha256:56d8b242c3430aa5eb27fc112194d2b22c5c72fe7c3b3db0940639f735154c55
```

Run continuous HTTP check:
```bash
while true; do
    curl -k https://main.lan
done
```

Deploy new container version #1: `bash deploy.sh -i "php:8.3-apache@sha256:fce243539486d99cfefba35724ec485fd6078f1d4928feba5728d3ca587f8820" -f "project.docker-compose.yml"`
```bash
# containers are updated in .env
DOCKER_IMAGE_BLUE=php:8.3-apache@sha256:fce243539486d99cfefba35724ec485fd6078f1d4928feba5728d3ca587f8820
DOCKER_IMAGE_GREEN=php:8.3-apache@sha256:fce243539486d99cfefba35724ec485fd6078f1d4928feba5728d3ca587f8820

# blue is running with updated image
:~$ docker ps
CONTAINER ID   IMAGE                     COMMAND                  CREATED          STATUS          PORTS                                      NAMES
c514e4d21936   php:8.3-apache            "docker-php-entrypoi…"   44 seconds ago   Up 42 seconds   80/tcp                                     blue
```

Deploy new container version #2: `bash deploy.sh -i "php:8.4.2-apache@sha256:2c9ae64a55950a3b44c5121cae9b1dc82601e9ff2a0ed0279d02c047019ca53d" -f "project.docker-compose.yml"`
```bash
# containers are updated in .env
DOCKER_IMAGE_BLUE=php:8.4.2-apache@sha256:2c9ae64a55950a3b44c5121cae9b1dc82601e9ff2a0ed0279d02c047019ca53d
DOCKER_IMAGE_GREEN=php:8.4.2-apache@sha256:2c9ae64a55950a3b44c5121cae9b1dc82601e9ff2a0ed0279d02c047019ca53d

# green is running with updated image
:~$ docker ps
CONTAINER ID   IMAGE                     COMMAND                  CREATED              STATUS              PORTS                                      NAMES
7f2a89711237   php:8.4.2-apache          "docker-php-entrypoi…"   18 seconds ago       Up 16 seconds       80/tcp                                     green
```

## Caveats

- Only tested on Debian 12.
- The deployment script only accepts images with sha256 hashes for security reasons, read https://candrews.integralblue.com/2023/09/always-use-docker-image-digests/.

## Todos

- deploy.sh:
    - Add automatic rollbacks - currently the script only leaves the lock enabled to avoid re-runs until it is removed manually.
    - Handling of additional commented tasks (database backups and migrations,...)
    - Use `shellcheck deploy.sh -x` for new commits
- Traefik:
    - Let's Encrypt
    - ACLs
