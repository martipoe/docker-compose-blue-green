#!/bin/bash

# Functions
usage() {
    echo "Usage: $0 [-i name:tag@sha256:*](required) [-f project.docker-compose.yml](required)"
    exit 1
}

http_health_check() {
    URL="$1"
    for i in {1..3}; do
        HTTP_STATUS=$(curl -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL}")
        if [[ "${HTTP_STATUS}" == '200' ]]; then
            echo "Success: HTTP check for https://${URL} with code ${HTTP_STATUS} [${i}/3]"
        elif [[ "${HTTP_STATUS}" != '200' ]]; then
            echo "Failure: HTTP check for https://${URL} failed with code ${HTTP_STATUS}"
            return 1
        fi
        sleep 2
    done
    return 0
}

# Parse and validate command line options
while getopts "i:f:" opt; do
    case $opt in
        i)  DOCKER_IMAGE_NEW=$OPTARG
            if ! [[ "${DOCKER_IMAGE_NEW}" =~ ^.*:.*@sha256:[a-z0-9]{64}$ ]]; then
                echo "Failure: Image name ${DOCKER_IMAGE_NEW} did not pass validation checks. Ensure the sha256-hash is included."
                usage
            fi
            ;;
        f)  DOCKER_COMPOSE_FILE=$OPTARG
            # docker compose stack for which zero-downtime deploys are implemented, requires service "blue" and "green"
            if ! [ -f "${DOCKER_COMPOSE_FILE}" ]; then
                echo "Failure: ${DOCKER_COMPOSE_FILE} does not exist"
                usage
            fi
            ;;
        :)  echo 'Failure: Missing argument' >&2
            usage
            ;;
        *)  echo 'Failure: Error in command line parsing' >&2
            usage
            ;;
    esac
done
if [[ -z "${DOCKER_IMAGE_NEW}" || -z "${DOCKER_COMPOSE_FILE}" ]]; then
    echo "Failure: Not all required options were passed"
    usage
fi

set -euxo pipefail

# Create lockfile to avoid race conditions due to multiple deploys
LOCKFILE=./deploy.lock
if [ -f "${LOCKFILE}" ]; then
    echo "Failure: Lock file exists, exiting."
    exit 1
fi
touch "${LOCKFILE}"


# Dependency checks
if ! [[ $(dpkg -l yq) ]]; then
    echo "Failure: Dependency yq is not installed (apt install yq)."
    rm "${LOCKFILE}"
    exit 1
fi

if ! [ -f ".env" ]; then
    echo "Failure: .env is missing."
    rm "${LOCKFILE}"
    exit 1
else
    # requires URL_MAIN, URL_BLUE, URL_GREEN
    source .env
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
echo "Updating docker image version for inactive container to ${DOCKER_IMAGE_NEW} in .env"
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="green"
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
    CONTAINER_NEW="blue"
fi

# Todo: Implement backups for rollbacks here
# Todo: Implement database locking here if required
# ./deploy_pre.sh


# Wait for container to start up and perform health checks
echo "Starting ${CONTAINER_NEW} with docker image ${DOCKER_IMAGE_NEW}"
docker compose -f "${DOCKER_COMPOSE_FILE}" up -d "${CONTAINER_NEW}"
sleep 5

echo "Ensure container ${CONTAINER_NEW} uses the new image ${DOCKER_IMAGE_NEW}..."
if ! [[ "$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NEW}")" == "${DOCKER_IMAGE_NEW}" ]]; then
    echo "Failure: Container ${CONTAINER_NEW} still uses the old image."
    # Todo: Roll back image version in .env
    exit 1
fi

echo "Checking Docker integrated HEALTHCHECK status..."
if [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}" 2>&1)" =~ 'map has no entry for key' ]]; then
    echo "Warning: Container ${CONTAINER_NEW} has no integrated HEALTHCHECK, will skip and continue with HTTP check..."
else
    while [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}")" == 'starting' ]]; do
        echo "Docker HEALTHCHECK is pending, will retry in 1s..."
        sleep 1
    done
    if [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}")" == 'healthy' ]]; then
        echo "Container ${CONTAINER_NEW} is healthy"
    elif [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER_NEW}")" == 'unhealthy' ]]; then
        echo "Failure: Container ${CONTAINER_NEW} is unhealthy"
        # Todo: Implement container version rollback here
        exit 1
    else
        echo "Failure: Unknown healthcheck status for ${CONTAINER_NEW}"
        # Todo: Implement container version rollback here
        exit 1
    fi
fi

# Todo: Implement migrations for new image here
# ./deploy_migrate.sh

# HTTP health checks for dedicated container urls
echo "Ensure the container ${CONTAINER_NEW} is up at is dedicated URL with HTTP status code 200"
if [[ "${CONTAINER_NEW}" == "blue" ]]; then
    http_health_check "${URL_BLUE}"
    if [ $? -eq 1 ]; then
        echo "Failure: HTTP healthcheck failed for ${URL_BLUE}"
        # Todo: Implement migration and container rollback here
        exit 1
    fi
elif [[ "${CONTAINER_NEW}" == "green" ]]; then
    http_health_check "${URL_GREEN}"
    if [ $? -eq 1 ]; then
        echo "Failure: HTTP healthcheck failed for ${URL_GREEN}"
        # Todo: Implement migration and container rollback here
        exit 1
    fi
fi

# Promote new container to serve requests on primary url
echo "Switching traffic to ${CONTAINER_NEW}..."
yq -yi --arg c "${CONTAINER_NEW}" '.http.routers.main.service = $c + "@docker"' nginx/dynamic/http.routers.main.yml

# Wait 10s for Traefik to pick up configuration changes
sleep 10s

# HTTP health check on primary url
echo "Ensure the container ${CONTAINER_NEW} is up at http:s//${URL_MAIN} with HTTP status code 200"
http_health_check "${URL_MAIN}"
if [ $? -eq 1 ]; then
    echo "Failure: HTTP healthcheck failed for ${URL_MAIN}"
    # Todo: Implement migration and container rollback here
    exit 1
fi

# Todo: Implement database unlocking here if required
# ./deploy_post.sh

# Cleanup
echo "Decomissioning outdated container ${CONTAINER_OLD}..."
docker compose -f "${DOCKER_COMPOSE_FILE}" down "${CONTAINER_OLD}"

# Ensures that an old container version is never run when ${DOCKER_COMPOSE_FILE} is restarted.
echo "Updating docker image version for inactive container ${CONTAINER_OLD} to ${DOCKER_IMAGE_NEW} in .env"
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
fi

# Remove lockfile
rm "${LOCKFILE}"
