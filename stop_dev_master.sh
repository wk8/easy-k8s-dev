#!/bin/bash

## Stops the kube master started by `start_dev_master.sh'

set -e

usage() {
  echo "$0 (--kube-src-dir KUBE_SRC_DIR)"
  echo " KUBE_SRC_DIR defaults to the current working directory"
  exit 1
}

main() {
  local KUBE_SRC_DIR="$(pwd)"

  # parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --kube-src-dir)
        KUBE_SRC_DIR="$2" ;;
      *)
        usage ;;
    esac
    shift 2
  done

  cd "$KUBE_SRC_DIR"

  local KUBEADM_BIN='_output/bin/kubeadm'
  if [ ! -x "$KUBEADM_BIN" ] && ! KUBEADM_BIN="$(which 'kubeadm' 2> /dev/null)"; then
    echo 'Unable to locate kubeadm'
    exit 1
  fi

  sudo "$KUBEADM_BIN" reset -f
  sudo service kubelet stop
}

main "$@"
