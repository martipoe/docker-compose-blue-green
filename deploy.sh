#!/bin/bash

set -euxo pipefail

DOCKER_IMAGE_NEW="$1"

DOCKER_COMPOSE_CONFIG="project.docker-compose.yml"
# set to true if container provides integrated healthcheck
DOCKER_HEALTHCHECK=false

# Create lockfile to avoid race conditions due to multiple deploys
LOCKFILE=./deploy.lock
if [ -f "${LOCKFILE}" ]; then
    echo "Failure: Lock file exists, exiting."
    exit 1
fi
touch "${LOCKFILE}"


# Validation checks
if ! [ -f ".env" ]; then
    echo "Failure: .env is missing."
    rm "${LOCKFILE}"
    exit 1
else
    # requires URL_MAIN, URL_BLUE, URL_GREEN
    source .env
fi

if ! [[ $(dpkg -l yq) ]]; then
    echo "Failure: Dependency yq is not installed (apt install yq)."
    rm "${LOCKFILE}"
    exit 1
fi

echo "Validating image name..."
if ! [[ "${DOCKER_IMAGE_NEW}" =~ ^.*:.*@sha256:[a-z0-9]{64}$ ]]; then
    echo "Failure: Image name ${DOCKER_IMAGE_NEW} did not pass validation checks. Ensure the sha256-hash is also provided."
    rm "${LOCKFILE}"
    exit 1
fi


# Pull docker image
echo "Pulling docker image ${DOCKER_IMAGE_NEW}..."
if ! [[ $(docker pull "${DOCKER_IMAGE_NEW}") ]]; then
    echo "Failure: ${DOCKER_IMAGE_NEW} does not exist."
    rm "${LOCKFILE}"
    exit 1
fi

# Detect running container from Traefik dynamic configuration
echo "Detecting active container and image version..."
SERVICE_ACTIVE=$(yq -r .http.routers.main.service nginx/dynamic/http.routers.main.yml)
CONTAINER_OLD="${SERVICE_ACTIVE%%@*}"
if ! [[ "${CONTAINER_OLD}" =~ ^(blue|green)$ ]]; then
    echo "Failure: No container is active."
    rm "${LOCKFILE}"
    exit 1
else
    DOCKER_IMAGE_OLD=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_OLD}")
    echo "${CONTAINER_OLD} currently runs image ${DOCKER_IMAGE_OLD}"
fi

# Update image version in .env
echo "Updating docker image version for ${CONTAINER_OLD} to ${DOCKER_IMAGE_NEW} in .env"
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="green"
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="blue"
fi

# Todo: Implement backups for rollbacks here
# Todo: Implement database locking here if required

# Launch new container
echo "Starting ${CONTAINER_NEW} with docker image ${DOCKER_IMAGE_NEW} and wait 5s for container to start..."
docker compose -f "${DOCKER_COMPOSE_CONFIG}" up -d "${CONTAINER_NEW}"
sleep 5

echo "Ensure container ${CONTAINER_NEW} uses the new image ${DOCKER_IMAGE_NEW}..."
if ! [[ "$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NEW}")" == "${DOCKER_IMAGE_NEW}" ]]; then
    echo "Failure: Container ${CONTAINER_NEW} still uses the old image."
    rm "${LOCKFILE}"
    exit 1
fi

# Optional: Docker Healthcheck
if [[ "${DOCKER_HEALTHCHECK}" == "true" ]]; then
    echo "Checking Docker Healthcheck status..."
    if [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}")" == 'healthy' ]]; then
        echo "Container ${CONTAINER_NEW} is healthy"
    else
        echo "Failure: Healthcheck for container ${CONTAINER_NEW} failed, but container ${CONTAINER_OLD} is still active."
        # Todo: Implement rollback here
        exit 1
    fi
fi

# Todo: Implement migrations for new image here

# HTTP health check on dedicated container url
echo "Ensure the container ${CONTAINER_NEW} can be accessed with HTTP status code 200"
if [[ "${CONTAINER_NEW}" == "blue" ]]; then
    HTTP_STATUS=$(curl -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL_BLUE}")
    if [[ "${HTTP_STATUS}" != '200' ]]; then
        echo "Failure: HTTP check for https://${URL_BLUE} failed with code ${HTTP_STATUS}"
        # Todo: Implement rollback here
        exit 1
    fi
elif [[ "${CONTAINER_NEW}" == "green" ]]; then
    HTTP_STATUS=$(curl -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL_GREEN}")
    if [[ "${HTTP_STATUS}" != '200' ]]; then
        echo "Failure: HTTP check for https://${URL_GREEN} failed with code ${HTTP_STATUS}"
        # Todo: Implement rollback here
        exit 1
    fi
fi

# Promote new container to serve requests on primary url
echo "Switching traffic to ${CONTAINER_NEW}..."
yq -yi --arg c "${CONTAINER_NEW}" '.http.routers.main.service = $c + "@docker"' nginx/dynamic/http.routers.main.yml
sleep 3

# HTTP health check on primary url
echo "Ensure the container ${CONTAINER_NEW} can be accessed at http://${URL_MAIN} with HTTP status code 200"
HTTP_STATUS=$(curl -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL_MAIN}")
if [[ "${HTTP_STATUS}" != '200' ]]; then
    echo "Failure: HTTP check for https://${URL_MAIN} failed with code ${HTTP_STATUS}"
    # Todo: Implement rollback here
    exit 1
fi

# Todo: Implement database unlocking here if required

# Cleanup
echo "Decomissioning outdated container ${CONTAINER_OLD}..."
docker compose -f "${DOCKER_COMPOSE_CONFIG}" down "${CONTAINER_OLD}"


# Remove lockfile
rm "${LOCKFILE}"
