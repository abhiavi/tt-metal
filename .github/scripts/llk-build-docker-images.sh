#!/usr/bin/env bash
# SPDX-FileCopyrightText: (c) 2025 Tenstorrent AI ULC
#
# SPDX-License-Identifier: Apache-2.0

# MIGRATION NOTE: These images are staging for LLK-in-Metal; not consumed by CI yet.
# tt_llk/.github/Dockerfile.ci still FROM ghcr.io/tenstorrent/tt-llk/... while this
# script pushes to ghcr.io/$GITHUB_REPOSITORY/... — reconcile when CI starts using
# these images or when LLK moves in-tree, then remove this note.

set -euo pipefail

# LLK Docker images are built from the submodule content
LLK_PATH="tt_metal/third_party/tt_llk"
if [[ ! -d "$LLK_PATH" || ! -f "$LLK_PATH/.github/scripts/get-docker-tag.sh" ]]; then
  echo "::error::tt_llk submodule is missing or not checked out (expected $LLK_PATH with .github/scripts/get-docker-tag.sh)." >&2
  exit 1
fi

REPO="${GITHUB_REPOSITORY:-tenstorrent/tt-metal}"
BASE_IMAGE_NAME=ghcr.io/$REPO/tt-llk-base-ubuntu-22-04
CI_IMAGE_NAME=ghcr.io/$REPO/tt-llk-ci-ubuntu-22-04

# Compute the hash of the Dockerfile (run from LLK path since script uses relative paths)
DOCKER_TAG=$(cd "$LLK_PATH" && ./.github/scripts/get-docker-tag.sh)
echo "Docker tag: $DOCKER_TAG"

# Are we on main branch - use GITHUB_REF_NAME if available (GitHub Actions), otherwise fall back to git
if [ -n "${GITHUB_REF_NAME-}" ]; then
    ON_MAIN=$([ "${GITHUB_REF_NAME}" = "main" ] && echo "true" || echo "false")
else
    ON_MAIN=$(git branch --show-current 2>/dev/null | grep -q main && echo "true" || echo "false")
fi

export DOCKER_BUILDKIT=1

# Ensure a buildx builder exists and is active
docker buildx create --use --name tt-builder >/dev/null 2>&1 || docker buildx use tt-builder
docker buildx inspect --bootstrap >/dev/null

build_and_push() {
    local image_name=$1
    local dockerfile=$2
    local on_main=$3
    local from_image=$4

    if docker manifest inspect $image_name:$DOCKER_TAG > /dev/null 2>&1; then
        echo "Image $image_name:$DOCKER_TAG already exists"

        # If we're on main, update the latest tag even if the image exists
        if [ "$on_main" = "true" ]; then
            # Check if latest already points to this tag (compare manifest digests)
            latest_digest=$(docker buildx imagetools inspect "$image_name:latest" 2>/dev/null | awk '/^Digest: / {print $2; exit}' || echo "")
            current_digest=$(docker buildx imagetools inspect "$image_name:$DOCKER_TAG" 2>/dev/null | awk '/^Digest: / {print $2; exit}')

            if [ "$latest_digest" != "$current_digest" ]; then
                echo "Updating latest tag for $image_name"
                docker buildx imagetools create -t $image_name:latest $image_name:$DOCKER_TAG
            else
                echo "Latest tag already points to $DOCKER_TAG"
            fi
        fi
        return
    fi

    echo "Building and pushing image $image_name:$DOCKER_TAG"

    if [ "$on_main" = "true" ]; then
        tags="-t $image_name:$DOCKER_TAG -t $image_name:latest"
    else
        tags="-t $image_name:$DOCKER_TAG"
    fi

    docker buildx build \
        --push \
        --output type=image,compression=zstd,oci-mediatypes=true \
        --build-arg FROM_TAG=$DOCKER_TAG \
        ${from_image:+--build-arg FROM_IMAGE=$from_image} \
        $tags \
        -f $dockerfile \
        $LLK_PATH
}

# Build base image from LLK submodule
build_and_push $BASE_IMAGE_NAME $LLK_PATH/.github/Dockerfile.base $ON_MAIN ""

# Build CI image from LLK submodule
build_and_push $CI_IMAGE_NAME $LLK_PATH/.github/Dockerfile.ci $ON_MAIN $BASE_IMAGE_NAME:$DOCKER_TAG

echo "All LLK images built and pushed successfully"
echo "CI_IMAGE_NAME:"
echo "$CI_IMAGE_NAME:$DOCKER_TAG"

# Output for GitHub Actions (if running in GHA)
if [ -n "${GITHUB_OUTPUT-}" ]; then
    echo "docker-image=$CI_IMAGE_NAME:$DOCKER_TAG" >> "$GITHUB_OUTPUT"
fi
