#!/bin/bash

# Timestamp function for better logging
timestamp() {
    date +"%Y-%m-%d %T"
}

# Print a message with a timestamp
log_message() {
    local level="$1"
    local message="$2"
    echo "$(timestamp) ${level}: ${message}"
}

# Print usage and exit
usage() {
    log_message "ERROR" "Usage: $0 [-i image:tag@sha256:*] (required) [-f project.docker-compose.yml] (required)"
    exit 1
}

# Parse and validate command line options
while getopts "i:f:" opt; do
    case $opt in
        i)
            DOCKER_IMAGE_NEW=$OPTARG
            if ! [[ "${DOCKER_IMAGE_NEW}" =~ ^.*:.*@sha256:[a-z0-9]{64}$ ]]; then
                log_message "ERROR" "Invalid Docker image format: ${DOCKER_IMAGE_NEW}. Ensure sha256 hash is included."
                usage
            fi
            ;;
        f)
            DOCKER_COMPOSE_FILE=$OPTARG
            if ! [ -f "${DOCKER_COMPOSE_FILE}" ]; then
                log_message "ERROR" "Docker compose file ${DOCKER_COMPOSE_FILE} does not exist."
                usage
            fi
            ;;
        :)
            log_message "ERROR" "Missing argument for option -$OPTARG"
            usage
            ;;
        *)
            log_message "ERROR" "Invalid option -$OPTARG"
            usage
            ;;
    esac
done

# Ensure required options are set
if [[ -z "${DOCKER_IMAGE_NEW}" || -z "${DOCKER_COMPOSE_FILE}" ]]; then
    log_message "ERROR" "Missing required options."
    usage
fi

# Set bash options for error handling
set -euo pipefail

# Perform HTTP health check (live or staging)
http_health_check() {
    local URL="$1"
    local NODE_EXPECTED="$2"
    local TARGET="$3"

    local HEADER=""
    case "${TARGET}" in
        live) HEADER='' ;;
        staging) HEADER='X-Deployment-Status: staging' ;;
        *)
            log_message "WARNING" "Unknown Target ${TARGET}"
            return 1
            ;;
    esac

    log_message "INFO" "Checking health for ${NODE_EXPECTED} at ${URL}..."
    sleep 5

    for i in {1..5}; do
        HTTP_STATUS=$(curl --header "${HEADER}" -k --silent --output /dev/null --write-out "%{http_code}" "https://${URL}")
        CUSTOM_HEADER=$(curl --header "${HEADER}" -I -k --silent --output /dev/null --write-out '%header{x-deployment-node}' "https://${URL}")

        if [[ "${HTTP_STATUS}" == '200' ]] && [[ "${CUSTOM_HEADER}" == "${NODE_EXPECTED}" ]]; then
            log_message "INFO" "Node ${NODE_EXPECTED} is healthy, status: ${HTTP_STATUS}"
            return 0
        else
            log_message "WARNING" "${NODE_EXPECTED} returned ${HTTP_STATUS} with header ${CUSTOM_HEADER}. Retrying [${i}/5]..."
            sleep 3
        fi
    done

    return 1
}

# Check Docker container health
dockerhealth_status() {
    local CONTAINER="$1"

    if [[ "$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER}" 2>&1)" =~ 'map has no entry for key' ]]; then
        log_message "INFO" "No integrated HEALTHCHECK for container ${CONTAINER}, skipping."
        return 0
    else
        sleep 10
        for i in {1..6}; do
            HEALTHCHECK_STATUS="$(docker container inspect --format='{{.State.Health.Status}}' "${CONTAINER}")"
            case "${HEALTHCHECK_STATUS}" in
                starting)
                    log_message "INFO" "Docker HEALTHCHECK is starting for ${CONTAINER}, retrying [${i}/6]."
                    sleep 10
                    ;;
                healthy)
                    log_message "INFO" "Container ${CONTAINER} is healthy."
                    return 0
                    ;;
                unhealthy)
                    log_message "ERROR" "Container ${CONTAINER} is unhealthy."
                    return 1
                    ;;
                *)
                    log_message "ERROR" "Unknown HEALTHCHECK status for ${CONTAINER}: ${HEALTHCHECK_STATUS}"
                    return 1
                    ;;
            esac
        done
    fi
}

# Rollback container to the previous state
rollback_container() {
    log_message "INFO" "Rolling back container ${CONTAINER_NEW} to previous state."

    # Bring down the new container
    docker compose -f "${DOCKER_COMPOSE_FILE}" down "${CONTAINER_NEW}"

    # Reset image version in .env
    if [[ "${CONTAINER_NEW}" == "blue" ]]; then
        sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_OLD}|g" .env
    elif [[ "${CONTAINER_NEW}" == "green" ]]; then
        sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_OLD}|g" .env
    fi

    # Reset Traefik dynamic configuration
    log_message "INFO" "Resetting Traefik dynamic configuration."
    yq -yi --arg c "${CONTAINER_OLD}" '.http.routers[$c].rule = "Host(`__fqdn_main__`) && ! Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
    yq -yi --arg c "${CONTAINER_NEW}" '.http.routers[$c].rule = "Host(`__fqdn_main__`) && Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml

    # Health check for live node
    http_health_check "${FQDN_MAIN}" "${CONTAINER_OLD}" "live"
    if [ $? -eq 1 ]; then
        log_message "ERROR" "${FQDN_MAIN} is still served by ${CONTAINER_NEW}, rollback failed."
        exit 1
    fi
}

# Lockfile check to prevent race conditions
LOCKFILE=./deploy.lock
if [ -f "${LOCKFILE}" ]; then
    log_message "ERROR" "Lock file exists. Previous deployment either failed or is still running."
    exit 1
fi
touch "${LOCKFILE}"

# Dependency check for 'yq'
if ! dpkg -l yq &>/dev/null; then
    log_message "ERROR" "Dependency 'yq' is missing. Install with 'apt install yq'."
    rm "${LOCKFILE}"
    exit 1
fi

# Ensure .env exists
if ! [ -f ".env" ]; then
    log_message "ERROR" ".env file missing."
    rm "${LOCKFILE}"
    exit 1
else
    # Load .env variables
    source .env
fi

# Pull Docker image
log_message "INFO" "Pulling Docker image ${DOCKER_IMAGE_NEW}..."
if ! docker pull "${DOCKER_IMAGE_NEW}" &>/dev/null; then
    log_message "ERROR" "Docker image ${DOCKER_IMAGE_NEW} not found."
    rm "${LOCKFILE}"
    exit 1
fi

# Detect current active container and image version
log_message "INFO" "Identifying active container and image version..."
CONTAINER_OLD="${CONTAINER_LIVE}"
if ! [[ "${CONTAINER_OLD}" =~ ^(blue|green)$ ]]; then
    log_message "ERROR" "Invalid CONTAINER_LIVE in .env."
    rm "${LOCKFILE}"
    exit 1
else
    DOCKER_IMAGE_OLD=$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_OLD}")
    log_message "INFO" "Current live container ${CONTAINER_OLD} uses image ${DOCKER_IMAGE_OLD}"
fi

# Update .env for inactive container with new image version
log_message "INFO" "Updating inactive container with new image ${DOCKER_IMAGE_NEW}..."
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

# Start new container with the updated image
log_message "INFO" "Deploying container ${CONTAINER_NEW}..."
if ! docker compose -f "${DOCKER_COMPOSE_FILE}" up -d "${CONTAINER_NEW}"; then
    log_message "ERROR" "Failed to deploy container ${CONTAINER_NEW}."
    rollback_container
    rm "${LOCKFILE}" && exit 1
fi

# Check if container is using the correct image
log_message "INFO" "Verifying container ${CONTAINER_NEW} image..."
if ! [[ "$(docker inspect --format '{{.Config.Image}}' "${CONTAINER_NEW}")" == "${DOCKER_IMAGE_NEW}" ]]; then
    log_message "ERROR" "Container ${CONTAINER_NEW} is not using the expected image."
    rollback_container
    rm "${LOCKFILE}" && exit 1
fi

# Run Docker health check
log_message "INFO" "Running Docker health check for ${CONTAINER_NEW}..."
dockerhealth_status "${CONTAINER_NEW}"
if [ $? -eq 1 ]; then
    log_message "ERROR" "Docker health check failed for ${CONTAINER_NEW}."
    rollback_container
    rm "${LOCKFILE}" && exit 1
fi

# Todo: Implement migrations for new image here
# ./deploy_migrate.sh

# Perform HTTP health check
log_message "INFO" "Performing HTTP health check for ${CONTAINER_NEW}..."
http_health_check "${FQDN_MAIN}" "${CONTAINER_NEW}" "staging"
if [ $? -eq 1 ]; then
    log_message "ERROR" "HTTP health check failed for ${CONTAINER_NEW}."
    rollback_container
    # Todo: Implement migration rollback as well, then lock can be removed
    # rm "${LOCKFILE}" && exit 1
fi

# Update Traefik routing
log_message "INFO" "Updating Traefik routing for ${CONTAINER_NEW}..."
yq -yi --arg c "${CONTAINER_NEW}" '.http.routers[$c].rule = "Host(`__fqdn_main__`) && ! Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
yq -yi --arg c "${CONTAINER_OLD}" '.http.routers[$c].rule = "Host(`__fqdn_main__`) && Header(`X-Deployment-Status`, `staging`)"' nginx/dynamic/dynamic.yml
# see providersThrottleDuration and pollInterval in traefik/traefik.yml
sleep 10s

# Final live traffic check
log_message "INFO" "Performing final live traffic health check..."
http_health_check "${FQDN_MAIN}" "${CONTAINER_NEW}" "live"
if [ $? -eq 1 ]; then
    log_message "ERROR" "Final live traffic check failed for ${CONTAINER_NEW}."
    rollback_container
    # Todo: Implement migration rollback as well, then lock can be removed
    # rm "${LOCKFILE}" && exit 1
fi

# Todo: Implement database unlocking here if required
# ./deploy_post.sh

# Clean up old container
log_message "INFO" "Removing outdated container ${CONTAINER_OLD}..."
docker compose -f "${DOCKER_COMPOSE_FILE}" down "${CONTAINER_OLD}"

# Update .env to reflect live container
log_message "INFO" "Updating live container in .env..."
sed -i "s|^CONTAINER_LIVE=.*$|CONTAINER_LIVE=${CONTAINER_NEW}|g" .env

# Ensure inactive container uses the new image version
log_message "INFO" "Ensuring inactive container uses new image version..."
if [[ "${CONTAINER_OLD}" == "blue" ]]; then
    sed -i "s|^DOCKER_IMAGE_BLUE=.*$|DOCKER_IMAGE_BLUE=${DOCKER_IMAGE_NEW}|g" .env
elif [[ "${CONTAINER_OLD}" == "green" ]]; then
    sed -i "s|^DOCKER_IMAGE_GREEN=.*$|DOCKER_IMAGE_GREEN=${DOCKER_IMAGE_NEW}|g" .env
fi

# Remove lockfile
log_message "INFO" "Deployment finished successfully. Removing lockfile."
rm "${LOCKFILE}"
