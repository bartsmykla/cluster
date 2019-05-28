#!/usr/bin/env bash

function parse_args {
  # positional args
  args=()

  # named args
  while [ "$1" != "" ]; do
      case "$1" in
          -p | --json-file-path )       json_file_path="$2";     shift;;
          -u | --api-url )              api_url="$2";            shift;;
          * )                           args+=("$1")             # if no match, add it to the positional args
      esac
      shift # move to next kv pair
  done

  # restore positional args
  set -- "${args[@]}"

  # set defaults
  if [[ -z "${json_file_path}" ]]; then
      json_file_path="/tmp/droplets_qwerty9876.json";
  fi

  if [[ -z "${api_url}" ]]; then
      api_url="https://api.digitalocean.com/v2/droplets";
  fi

  if [[ -z "${TF_VAR_do_token:?}" ]]; then
      echo "env var TF_VAR_do_token is not set"
      exit 1
  fi
}

parse_args "$@"

curl -X GET -s \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TF_VAR_do_token:?}" \
    -o "${json_file_path}" \
    "${api_url}"