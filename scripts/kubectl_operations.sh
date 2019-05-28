#!/usr/bin/env bash

#abort on error
set -e

function parse_args {
  # positional args
  args=()

  # named args
  while [ "$1" != "" ]; do
      case "$1" in
          -i | --cluster-id )           cluster_id="$2";              shift;;
          -p | --kubeconfig-path )      kubeconfig_path="$2";         shift;;
          -c | --crds-path )            crds_path="$2";               shift;;
          --create-cluster-issuers )     create_cluster_issuers="true"  ;;
          * )                           args+=("$1")                  # if no match, add it to the positional args
      esac
      shift # move to next kv pair
  done

  # restore positional args
  set -- "${args[@]}"

  # set defaults
  if [[ -z "${kubeconfig_path}" ]]; then
      kubeconfig_path="/tmp/kubeconfig_qwerty9876";
  fi

  if [[ -z "${cluster_id}" ]]; then
      echo "you need to pass --cluster-id";
      exit;
  fi

  if [[ -z "${TF_VAR_do_token:?}" ]]; then
      echo "env var TF_VAR_do_token is not set";
      exit;
  fi
}

function get_kubeconfig {
  curl -X GET -s \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TF_VAR_do_token:?}" \
    -o "${kubeconfig_path}" \
    "https://api.digitalocean.com/v2/kubernetes/clusters/${cluster_id}/kubeconfig";
}

function create_cert_manager_crds {
  kubectl --kubeconfig "${kubeconfig_path}" apply -f "${crds_path}"
}

function create_cluster_issuers {
  cat <<EOF | kubectl --kubeconfig "${kubeconfig_path}" apply -f -
---
apiVersion: certmanager.k8s.io/v1alpha1
kind: ClusterIssuer
metadata:
  name: letsencrypt-production
  namespace: cert-manager
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "bartek@smykla.com"
    privateKeySecretRef:
      name: letsencrypt-production
    http01: {}
    dns01:
      providers:
        - name: prod-digitalocean
          digitalocean:
            tokenSecretRef:
              name: do-dns-token
              key: access-token
---
apiVersion: certmanager.k8s.io/v1alpha1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
  namespace: cert-manager
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: "bartek@smykla.com"
    privateKeySecretRef:
      name: letsencrypt-staging
    http01: {}
    dns01:
      providers:
        - name: prod-digitalocean
          digitalocean:
            tokenSecretRef:
              name: do-dns-token
              key: access-token
EOF
}

function run {
  parse_args "$@";
  get_kubeconfig;

  if [[ -n "${create_cluster_issuers}" ]]; then
    create_cluster_issuers;
  elif [[ -n "${crds_path}" ]]; then
    create_cert_manager_crds;
  fi
}

run "$@";
