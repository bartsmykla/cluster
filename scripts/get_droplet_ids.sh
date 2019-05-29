#!/usr/bin/env bash

#abort on error
set -e

function parse_args {
  # positional args
  args=()

  # named args
  while [ "$1" != "" ]; do
      case "$1" in
          -u | --api-url )              api_url="$2";            shift;;
          * )                           args+=("$1")             # if no match, add it to the positional args
      esac
      shift # move to next kv pair
  done

  # restore positional args
  set -- "${args[@]}"

  # set defaults
  if [[ -z "${api_url}" ]]; then
      api_url="https://api.digitalocean.com/v2/droplets";
  fi

  if [[ -z "${TF_VAR_do_token:?}" ]]; then
      echo "env var TF_VAR_do_token is not set";
      exit;
  fi
}

function run {
  parse_args "$@";

  droplet_ids=$(curl -X GET -s \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${TF_VAR_do_token:?}" \
      "${api_url}" | jq -c '[.droplets[] | .id]');

  jq -n --arg droplet_ids "${droplet_ids}" '{"droplet_ids": $droplet_ids}';
}

run "$@";