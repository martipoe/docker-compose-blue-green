# docker-compose-blue-green

Example implementation for Blue-Green deployments with Docker Compose and Traefik with routing based on HTTP headers.

While testing subdomain-based implementations at https://github.com/straypaper/blue-green and https://frustrated.blog/2021/03/16/traefik_blue_green.html, I encountered problems with [Traefik File Provider](https://doc.traefik.io/traefik/providers/file/) and docker bind mounts - even though *directory* configuration and *providersThrottleDuration* were set, there still were 404s for up to 60s during dynamic configuration changes.

Workaround:
- These issues did not arise with the [HTTP Provider](https://doc.traefik.io/traefik/providers/http/). This is why an Nginx container serves the dynamic configuration as yaml template via HTTP, using https://nginx.org/en/docs/http/ngx_http_sub_module.html for dynamic contents.
- During Nginx container restarts (updates...), Traefik will keep the dynamic configuration in memory until the HTTP endpoint is reachable again.

Another issue with subdomain-based routing is configuration overhead in terms of DNS and application (especially if designed for single domain usage).
    - An alternative to host names are custom headers: https://doc.traefik.io/traefik/routing/routers/#header-and-headerregexp

# Features

- Blue-Green deployments - nodes are replaced interchangeably with each new container version.
- Zero-Downtime.
- Same hostname, routing via custom HTTP headers.
- Healthchecks:
    - Docker HEALTHCHECK if supported by image
    - HTTP status code must be 200
    - HTTP custom header must match node name
- Rollbacks: If deployments fail, the container version is rolled back automatically.
- Staging node is stopped after deployment.

# Schema

![schema](docs/blue-green.drawio.png)

## Prerequisites

- Add domain in */etc/hosts*: `127.0.0.1 localhost main.lan`
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
DOCKER_IMAGE_BLUE=serversideup/php:8.2-fpm-apache@sha256:0d08c8277aefcbf2780e94774d8a3464cbcf0d701c0a78795a6c2c0432beef0d
DOCKER_IMAGE_GREEN=serversideup/php:8.2-fpm-apache@sha256:0d08c8277aefcbf2780e94774d8a3464cbcf0d701c0a78795a6c2c0432beef0d
```

Run continuous HTTP check on live node:
```bash
while true; do
    curl -k https://main.lan
done
```

Run continuous HTTP check on staging node:
```bash
while true; do
    curl -k --header 'X-Deployment-Status: staging' https://main.lan
done
```

Deploy new container version #1: `bash deploy.sh -i "serversideup/php:8.3-fpm-apache@sha256:379a43f6285f665ee1e0a37875fe6222b712d2b23a3c20b342d57893af9a7ff0" -f "project.docker-compose.yml"`
```bash
# containers are updated in .env
DOCKER_IMAGE_BLUE=serversideup/php:8.3-fpm-apache@sha256:379a43f6285f665ee1e0a37875fe6222b712d2b23a3c20b342d57893af9a7ff0
DOCKER_IMAGE_GREEN=serversideup/php:8.3-fpm-apache@sha256:379a43f6285f665ee1e0a37875fe6222b712d2b23a3c20b342d57893af9a7ff0

# blue is running with updated image
:~$ docker ps
CONTAINER ID   IMAGE                             COMMAND                  CREATED          STATUS                    PORTS                                      NAMES
b964420275d7   serversideup/php:8.3-fpm-apache   "docker-php-serversi…"   44 seconds ago   Up 33 seconds (healthy)   8080/tcp, 8443/tcp, 9000/tcp               blue
```

Deploy new container version #2: `bash deploy.sh -i "serversideup/php:8.4-fpm-apache@sha256:7584df1eab8e93dc9e1077b6ac7d752f3e2b12e32009ef5bb0b08e824c5720c6" -f "project.docker-compose.yml"`
```bash
# containers are updated in .env
DOCKER_IMAGE_BLUE=serversideup/php:8.4-fpm-apache@sha256:7584df1eab8e93dc9e1077b6ac7d752f3e2b12e32009ef5bb0b08e824c5720c6
DOCKER_IMAGE_GREEN=serversideup/php:8.4-fpm-apache@sha256:7584df1eab8e93dc9e1077b6ac7d752f3e2b12e32009ef5bb0b08e824c5720c6

# green is running with updated image
:~$ docker ps
CONTAINER ID   IMAGE                             COMMAND                  CREATED          STATUS                    PORTS                                      NAMES
79e359d3b1e3   serversideup/php:8.4-fpm-apache   "docker-php-serversi…"   40 seconds ago   Up 39 seconds (healthy)   8080/tcp, 8443/tcp, 9000/tcp               green
```

## Caveats

- Only tested on Debian 12.
- The deployment script only accepts images with sha256 hashes for security reasons, read https://candrews.integralblue.com/2023/09/always-use-docker-image-digests/.

## Todos

- deploy.sh:
    - A true deployment usually needs additional tasks, like database backups and migrations (commented where applicable).
        - These actions must also be considered during rollbacks. Until then, the script only leaves the lock enabled to avoid re-runs until issues have been fixed manually.
    - Test behaviour with more slowly responding applications, might require changes to waits and timeouts.
    - Always use `shellcheck deploy.sh -x` for new commits.
    - Rewrite in a more suitable language like Python or Go?
- Traefik:
    - Let's Encrypt
    - ACLs
