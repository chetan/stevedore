#!/bin/bash
#
# # Usage
#
# ```
# $ stow [--repo <repo>] [--push] <PKG_IDENT>
# ```
#
# # Synopsis
#
# Create a Docker container from a set of Habitat packages.
#
# # License and Copyright
#
# ```
# Copyright: Copyright (c) 2016 Chef Software, Inc.
# License: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ```

# Fail if there are any unset variables and whenever a command returns a
# non-zero exit code.
set -eu

# If the variable `$DEBUG` is set, then print the shell commands as we execute.
if [ -n "${DEBUG:-}" ]; then
  set -x
  export DEBUG
fi

# parse the CLI flags and options
parse_options() {

  if [[ -z "$@" ]]; then
    # no args given, bail out
    print_help
    exit_with "You must specify one or more Habitat packages to Dockerize." 1
  fi

  while test $# -gt 0; do
    case "$1" in
      -h|--help)
        print_help
        exit
        ;;
      --push)
        DOCKER_PUSH="1"
        shift
        ;;
      --repo*)
        DOCKER_REGISTRY_URL="${1#*=}"
        if [[ "$DOCKER_REGISTRY_URL" == "--repo" ]]; then
          shift
          DOCKER_REGISTRY_URL="$1"
        fi
        shift
        ;;
      --slim)
        DOCKER_SLIM="1"
        shift
        ;;
      *)
        PKG="$1"
        break
        ;;
    esac
  done

  if [ "$PKG" == "unknown" ]; then
    print_help
    exit_with "You must specify one or more Habitat packages to Dockerize." 1
  fi
}

# ## Help

# **Internal** Prints help
print_help() {
  printf -- "$program $version

$author

Habitat Package Dockerize - Create a Docker container from a set of Habitat packages

USAGE:
  $program [--repo <repo>] [--push] <PKG_IDENT>

FLAGS:
    --help           Prints help information

OPTIONS:
    --repo=URL       If given, prefix the tag with the URL
    --push           Push the built images to the configured repository

ARGS:
    <PKG_IDENT>      Habitat package identifier (ex: acme/redis)

EXAMPLE:
    $program --repo docker.private.com:443 --push core/nginx

    Would create and push the following images/tags:

    REPOSITORY                                      TAG                      IMAGE ID            CREATED             SIZE
    docker.private.com:443/core/nginx               1.11.10-20170215235242   13bd9e6efbe1        20 seconds ago      177 MB
    docker.private.com:443/core/nginx               latest                   13bd9e6efbe1        20 seconds ago      177 MB
    docker.private.com:443/core/habitat_deps_base   a8f6b4a21c68f76b         e3c0f2acd8bd        27 seconds ago      174 MB
    docker.private.com:443/core/nginx_base          a8f6b4a21c68f76b         e3c0f2acd8bd        27 seconds ago      174 MB
    core/habitat_base                               0.19.0                   3310f705d8cf        6 minutes ago       161 MB
"
}

# **Internal** Exit the program with an error message and a status code.
#
# ```sh
# exit_with "Something bad went down" 55
# ```
exit_with() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "\033[1;31mERROR: \033[1;37m$1\033[0m\n"
      ;;
    *)
      printf -- "ERROR: $1\n"
      ;;
  esac
  exit $2
}

cleanup_and_exit() {
  code=$1
  set +e
  if [[ -n "$DOCKER_CONTEXT" && -d $DOCKER_CONTEXT ]]; then
    if [[ -n "$(ls $DOCKER_CONTEXT/*.hart 2>/dev/null)" ]]; then
      mv $DOCKER_CONTEXT/*.hart /hab/cache/artifacts/
    fi
    popd >/dev/null
    rm -rf "$DOCKER_CONTEXT"
  fi
  exit $code
}

find_system_commands() {
  if mktemp --version 2>&1 | grep -q 'GNU coreutils'; then
    _mktemp_cmd=$(command -v mktemp)
  else
    if /bin/mktemp --version 2>&1 | grep -q 'GNU coreutils'; then
      _mktemp_cmd=/bin/mktemp
    else
      exit_with "We require GNU mktemp to build docker images; aborting" 1
    fi
  fi
}

# Add a trailing slash to the first argument ($1)
add_trailing_slash() {
  STR="$1"
  length=${#STR}
  last_char=${STR:length-1:1}
  [[ $last_char != "/" ]] && STR="$STR/"; :
  echo $STR
}

# Wraps `dockerfile` to ensure that a Docker image build is being executed in a
# clean directory with native filesystem permissions which is outside the
# source code tree.
build_docker_image() {
  local ident_file="$(hab pkg path $PKG)/IDENT"
  if [[ ! -f "$ident_file" ]]; then
    hab pkg install $PKG # try to install it
    ident_file="$(hab pkg path $PKG)/IDENT"
  fi

  if [[ -n "$DOCKER_REGISTRY_URL" ]]; then
    DOCKER_REGISTRY_URL=$(add_trailing_slash "$DOCKER_REGISTRY_URL")
  fi

  # get pkg info
  pkg_name=$(package_name_for $PKG)
  pkg_origin=$(package_origin_for $ident_file)
  pkg_ident=$(package_ident_for $ident_file)
  pkg_version=$(version_num_for $ident_file)
  BASE_PKGS=$(base_pkgs $PKG)

  # slim setup
  if [[ "$DOCKER_SLIM" == "1" ]]; then
    SLIM_TAG="-slim"
    SLIM_DOCKERFILE=$(cat <<'EOF'
    ls /hab/pkgs/core > /tmp/.slim_shady_deps \
    && hab pkg install chetan/slimshady \
    && hab pkg exec chetan/slimshady slimshady \
    && hab pkg exec chetan/slimshady slimshady --uninstall \
    && rm -rf /hab/pkgs/chetan/slimshady /tmp/.slim_shady_deps
EOF
)
  else
    SLIM_TAG=""
    SLIM_DOCKERFILE="true"
  fi

  # set tags
  HAB_VERSION=$(hab --version | awk '{print $2}' | cut -d/ -f1)
  DOCKER_HAB_TAG="${DOCKER_REGISTRY_URL}core/habitat_base:${HAB_VERSION}${SLIM_TAG}"
  DOCKER_BASE_HASH="$(base_pkg_hash $HAB_VERSION $BASE_PKGS)"
  DOCKER_BASE_TAG="${DOCKER_REGISTRY_URL}${pkg_ident}_base:${DOCKER_BASE_HASH}${SLIM_TAG}"
  DOCKER_BASE_TAG_ALT="${DOCKER_REGISTRY_URL}${pkg_origin}/habitat_deps_base:${DOCKER_BASE_HASH}${SLIM_TAG}"
  DOCKER_RUN_TAG="${DOCKER_REGISTRY_URL}${pkg_ident}"


  # create hab base layer image
  DOCKER_CONTEXT="$($_mktemp_cmd -t -d "${program}-XXXX")"
  pushd $DOCKER_CONTEXT > /dev/null
  docker_hab_image $PKG
  popd > /dev/null
  rm -rf "$DOCKER_CONTEXT"

  # create app base layer image
  DOCKER_CONTEXT="$($_mktemp_cmd -t -d "${program}-XXXX")"
  pushd $DOCKER_CONTEXT > /dev/null
  docker_base_image $PKG
  popd > /dev/null
  rm -rf "$DOCKER_CONTEXT"

  # build runtime image
  DOCKER_CONTEXT="$($_mktemp_cmd -t -d "${program}-XXXX")"
  pushd $DOCKER_CONTEXT > /dev/null
  docker_image $PKG
  popd > /dev/null
  rm -rf "$DOCKER_CONTEXT"
}

package_origin_for() {
  local ident_file="$1"
  cat $ident_file | awk 'BEGIN { FS = "/" }; { print $1 }'
}

package_ident_for() {
  local ident_file="$1"
  cat $ident_file | awk 'BEGIN { FS = "/" }; { print $1 "/" $2 }'
}

package_name_for() {
  local pkg="$1"
  echo $(echo $pkg | cut -d "/" -f 2)
}

package_exposes() {
  local pkg="$1"
  local expose_file="$(hab pkg path $pkg)/EXPOSES"
  if [ -f "$expose_file" ]; then
    cat $expose_file
  fi
}

version_num_for() {
  local ident_file="$1"
  cat $ident_file | awk 'BEGIN { FS = "/" }; { print $3 "-" $4 }'
}

# Collect all dependencies for the requested package
base_pkgs() {
  local BUILD_PKGS="$@"
  touch /tmp/_all_deps
  for p in $BUILD_PKGS; do
    hab pkg install $p >/dev/null
    if [[ -f $(hab pkg path $p)/DEPS ]]; then
      # DEPS file will be missing if the pkg has no deps
      cat $(hab pkg path $p)/DEPS >> /tmp/_all_deps
    fi
  done
  (cat /tmp/_all_deps | sort | uniq) && rm -f /tmp/_all_deps
}

base_pkg_hash() {
  echo "$@" | sha256sum | cut -b1-16
}

# Test if the given tag already exists
docker_image_exists() {
  if [[ -n "$(docker images -q $1 2> /dev/null)" ]]; then
    return 0
  fi
  return 1
}
docker_hab_image() {
  local _l=">> hab base image (hab only)"
  if docker_image_exists $DOCKER_HAB_TAG; then
    echo "$_l: $DOCKER_HAB_TAG already built; skipping rebuild"
    return 0
  fi

  echo "$_l: building..."

  env PKGS="" NO_MOUNT=1 hab-studio -r $DOCKER_CONTEXT/rootfs -t baseimage new

  # create base image Dockerfile
  cat <<EOT > $DOCKER_CONTEXT/Dockerfile
FROM scratch
ENV $(cat $DOCKER_CONTEXT/rootfs/init.sh | grep PATH= | cut -d' ' -f2-)
WORKDIR /
ADD rootfs /
RUN $SLIM_DOCKERFILE \
    && rm -f /hab/cache/artifacts/*
EOT

  if [ -n "${DEBUG:-}" ]; then
    cat $DOCKER_CONTEXT/Dockerfile
  fi

  docker build --force-rm --no-cache --squash -t $DOCKER_HAB_TAG .

  echo "$_l: built $DOCKER_HAB_TAG"
}

docker_base_image() {
  local _l=">> app deps image"
  if docker_image_exists $DOCKER_BASE_TAG; then
    echo "$_l: $DOCKER_BASE_TAG already built; skipping rebuild"
    return 0
  fi

  if docker_image_exists $DOCKER_BASE_TAG_ALT; then
    echo "$_l: $DOCKER_BASE_TAG_ALT already built; skipping rebuild"
    # create a tag alias for our package
    docker tag $DOCKER_BASE_TAG_ALT $DOCKER_BASE_TAG
    DOCKER_BASE_TAG="$DOCKER_BASE_TAG_ALT"
    return 0
  fi

  if [[ "$(echo $BASE_PKGS | tr ' ' \"\n\" | wc -l)" == "0" ]]; then
    # There are no BASE_PKGS so simply retag the hab_base
    echo "$_l: no deps, skipping build (just tagging)"
    docker tag $DOCKER_HAB_TAG $DOCKER_BASE_TAG
    docker tag $DOCKER_BASE_TAG $DOCKER_BASE_TAG_ALT
    return 0
  fi

  echo "$_l: building..."

  cp /hab/cache/artifacts/* $DOCKER_CONTEXT/
  mkdir -p $DOCKER_CONTEXT/keys && cp -a /hab/cache/keys/* $DOCKER_CONTEXT/keys/
  local _base_pkgs=$(echo -n $BASE_PKGS | tr '\n' ' ')

  # create base image Dockerfile
  cat <<EOT > $DOCKER_CONTEXT/Dockerfile
FROM ${DOCKER_HAB_TAG}

COPY *.hart /hab/cache/artifacts/
COPY keys/* /hab/cache/keys/

RUN hab pkg install $_base_pkgs \
    && $SLIM_DOCKERFILE \
    && rm -f /hab/cache/artifacts/* \
    && rm -f /hab/cache/keys/*.key
EOT

  if [ -n "${DEBUG:-}" ]; then
    cat $DOCKER_CONTEXT/Dockerfile
  fi

  docker build --force-rm --no-cache --squash -t $DOCKER_BASE_TAG .
  docker tag $DOCKER_BASE_TAG $DOCKER_BASE_TAG_ALT

  echo "$_l: built $DOCKER_BASE_TAG and $DOCKER_BASE_TAG_ALT"
}

docker_image() {
  echo ">> app image: building..."

  local pkg_file=$(ls /hab/cache/artifacts/$(cat $(hab pkg path $pkg_ident)/IDENT | tr '/' '-')-*)
  cp $pkg_file $DOCKER_CONTEXT/
  # make sure all local keys are available during docker build
  mkdir -p $DOCKER_CONTEXT/keys && cp -a /hab/cache/keys/* $DOCKER_CONTEXT/keys/
  pkg_file=$(basename $pkg_file)

  cat <<EOT > $DOCKER_CONTEXT/Dockerfile
FROM ${DOCKER_BASE_TAG}

COPY ${pkg_file} /tmp/
COPY keys/* /hab/cache/keys/

RUN hab pkg install /tmp/${pkg_file} \
    && rm -f /tmp/${pkg_file} \
    && $SLIM_DOCKERFILE \
    && rm -f /hab/cache/artifacts/* \
    && echo "$pkg_ident" > /.hab_pkg \
    && mkdir -p $HAB_ROOT_PATH/svc/${pkg_name}/data \
                $HAB_ROOT_PATH/svc/${pkg_name}/config \
    && chown -R 42:42 $HAB_ROOT_PATH/svc/${pkg_name} \
    && rm -f /hab/cache/keys/*.key

VOLUME $HAB_ROOT_PATH/svc/${pkg_name}/data $HAB_ROOT_PATH/svc/${pkg_name}/config
EXPOSE 9631 $(package_exposes $1)
ENTRYPOINT ["/init.sh"]
CMD ["start", "$1"]
EOT

  if [ -n "${DEBUG:-}" ]; then
    cat $DOCKER_CONTEXT/Dockerfile
  fi

  docker build --force-rm --no-cache --squash -t "${DOCKER_RUN_TAG}:${pkg_version}" .
  docker tag "${DOCKER_RUN_TAG}:${pkg_version}" "${DOCKER_RUN_TAG}:latest"

  echo ">> app image: built ${DOCKER_RUN_TAG}:${pkg_version} and ${DOCKER_RUN_TAG}:latest"
}

# Push the built docker images to the configured registry
push_docker_image() {
  if [[ "$DOCKER_PUSH" != "1" ]]; then
    return 0;
  fi

  local repo="$DOCKER_REGISTRY_URL"
  if [[ -z "$repo" ]]; then
    repo="public (docker.io)"
  fi
  echo ">> pushing to registry: $repo"

  # push images/tags we created to registry
  docker push $DOCKER_BASE_TAG
  docker push $DOCKER_BASE_TAG_ALT
  docker push "${DOCKER_RUN_TAG}:${pkg_version}"
  docker push "${DOCKER_RUN_TAG}:latest"
}

# The root of the filesystem. If the program is running on a seperate
# filesystem or chroot environment, this environment variable may need to be
# set.
: ${FS_ROOT:=}
# The root path of the Habitat file system. If the `$HAB_ROOT_PATH` environment
# variable is set, this value is overridden, otherwise it is set to its default
: ${HAB_ROOT_PATH:=$FS_ROOT/hab}

# Set a default docker registry url (empty)
# If set, images will be tagged with this prefix
: ${DOCKER_REGISTRY_URL:=""}

# Controls whether or not we push to the configured registry
: ${DOCKER_PUSH:="0"}

# Controls whether or not to slim the image(s)
: ${DOCKER_SLIM:="0"}

# The package to dockerize
: ${PKG:="unknown"}

# The current version of Habitat Studio
version='@version@'
# The author of this program
author='@author@'
# The short version of the program name which is used in logging output
program=$(basename $0)

find_system_commands

parse_options $@
trap 'cleanup_and_exit $?' INT TERM HUP EXIT
build_docker_image
push_docker_image
