#!/bin/bash

## Starts a kube master using locally-compiled bins
## Leveragges kubeadm, and uses flannel as CNI
## See https://medium.com/@rouge.j/development-setup-for-kubernetes-on-windows-388ca05b89e

set -e

_DEFAULT_JOIN_TOKEN='102952.1a7dd4cc8d1f4cc5'
_DEFAULT_POD_NETWORK_CIDR='10.244.0.0/16'
_DEFAULT_SERVICE_CIDR='10.96.0.0/12'

usage() {
  echo "$0 --ip-address IP_ADDRESS (--kube-src-dir KUBE_SRC_DIR) (--join-token JOIN_TOKEN) (--pod-network-cidr POD_NETWORK_CIDR) (--service-cidr SERVICE_CIDR)"
  echo " KUBE_SRC_DIR defaults to the current working directory"
  echo " JOIN_TOKEN defaults to $_DEFAULT_JOIN_TOKEN"
  echo " POD_NETWORK_CIDR defaults to $_DEFAULT_POD_NETWORK_CIDR"
  echo " SERVICE_CIDR defaults to $_DEFAULT_SERVICE_CIDR"
  exit 1
}

# TODO: automatically detect the k8s version and apply the right flannel manifest...
_FLANNEL_VERSION='ecb6db314e40094a43144b57f29b3ec2164d44c9'
_FLANNEL_MANIFEST_DOWNLOAD_URL="https://raw.githubusercontent.com/coreos/flannel/$_FLANNEL_VERSION/Documentation/kube-flannel.yml"
# to regen:
# curl $_FLANNEL_MANIFEST_DOWNLOAD_URL | sha256sum
_FLANNEL_MANIFEST_CHECKSUM='801ddcce40f67e37bf50d8e5de4eaafb609561502791dc683808f57958257b26'

_MS_SDN_VERSION='7254feb355992bad5ef5981d7c381f2488fd72e8'
_MS_SDN_SELECTOR_PATCH_URL="https://raw.githubusercontent.com/Microsoft/SDN/$_MS_SDN_VERSION/Kubernetes/flannel/l2bridge/manifests/node-selector-patch.yml"
# to regen:
# curl $_MS_SDN_SELECTOR_PATCH_URL | sha256sum
_MS_SDN_SELECTOR_PATCH_CHECKSUM='6109fc8e06e7699a120cf0d46ff7fc2816bd0bc2a7ab1b88eb59b8e6dc695c63'

main() {
  local IP_ADDRESS KUBE_SRC_DIR="$(pwd)"
  local JOIN_TOKEN="$_DEFAULT_JOIN_TOKEN"
  local POD_NETWORK_CIDR="$_DEFAULT_POD_NETWORK_CIDR"
  local SERVICE_CIDR="$_DEFAULT_SERVICE_CIDR"

  # parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --kube-src-dir)
        KUBE_SRC_DIR="$2" ;;
      --ip-address)
        IP_ADDRESS="$2" ;;
      --join-token)
        JOIN_TOKEN="$2" ;;
      --pod-network-cidr)
        POD_NETWORK_CIDR="$2" ;;
      --service-cidr)
        SERVICE_CIDR="$2" ;;
      *)
        usage ;;
    esac
    shift 2
  done

  local SPLIT_TOKEN
  if [[ "$JOIN_TOKEN" =~ ^([a-z0-9]+)\.[a-z0-9]+$ ]]; then
    SPLIT_TOKEN="${BASH_REMATCH[1]}"
  else
    echo "Unexpected join token: '$JOIN_TOKEN'"
    echo "Should be two alphanumeric strings joined with a dot"
    exit 1
  fi

  # cd to $KUBE_SRC_DIR, simplifies a few things below
  cd "$KUBE_SRC_DIR"

  local KUBEADM_BIN="$(_k8s_bin_path 'kubeadm')"
  local KUBECTL_BIN="$(_k8s_bin_path 'kubectl')"

  # patch images as needed
  _patch_kubeadm_images "$KUBEADM_BIN"

  local INIT_CMD="sudo $KUBEADM_BIN init --apiserver-advertise-address='$IP_ADDRESS' --pod-network-cidr='$POD_NETWORK_CIDR' --service-cidr='$SERVICE_CIDR' --token='$JOIN_TOKEN' --token-ttl=0 --ignore-preflight-errors=KubeletVersion"

  echo "$INIT_CMD" && eval "$INIT_CMD"

  # copy the kube config
  local KUBECONFIG_DIR="$HOME/.kube"
  local LOCAL_KUBECONFIG="$KUBECONFIG_DIR/config"
  mkdir -p "$KUBECONFIG_DIR"
  sudo cp /etc/kubernetes/admin.conf "$LOCAL_KUBECONFIG"
  sudo chown $(id -u):$(id -g) "$LOCAL_KUBECONFIG"

  # allow to schedule pods on the master
  KUBECONFIG="$LOCAL_KUBECONFIG" "$KUBECTL_BIN" taint nodes --all node-role.kubernetes.io/master-

  # grant access to joining nodes
  KUBECONFIG="$LOCAL_KUBECONFIG" "$KUBECTL_BIN" create clusterrolebinding cluster-system-$SPLIT_TOKEN --clusterrole=cluster-admin --user=system:bootstrap:$SPLIT_TOKEN

  # now install flannel
  local FLANNEL_MANIFEST="$(_ensure_file_present "$_FLANNEL_MANIFEST_DOWNLOAD_URL" "$_FLANNEL_MANIFEST_CHECKSUM")"
  # we want flannel in host gateway node, for Windows workers
  sed 's/"vxlan"/"host-gw"/g' "$FLANNEL_MANIFEST" | KUBECONFIG="$LOCAL_KUBECONFIG" "$KUBECTL_BIN" apply -f -

  # make sure that no system component will be scheduled on Windows nodes
  local SELECTOR_PATCH="$(_ensure_file_present "$_MS_SDN_SELECTOR_PATCH_URL" "$_MS_SDN_SELECTOR_PATCH_CHECKSUM")"
  local SYSTEM_DAEMONSETS DAEMONSET
  SYSTEM_DAEMONSETS=$(KUBECONFIG="$LOCAL_KUBECONFIG" "$KUBECTL_BIN" -n kube-system get daemonset -o template --template='{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}') 
  for DAEMONSET in $SYSTEM_DAEMONSETS; do
    KUBECONFIG="$LOCAL_KUBECONFIG" "$KUBECTL_BIN" -n kube-system patch daemonset "$DAEMONSET" --patch "$(cat "$SELECTOR_PATCH")" || return $?
  done

  echo 'Done starting the master. Edit the manifests in /etc/kubernetes/manifests to eg change the admission controllers used by the API - the changes will be applied as soon as the manifests are modified.'
}

# patches the images kubeadm uses
# $1 is the path to kubeadm
_patch_kubeadm_images() {
  local KUBEADM_BIN="$1"

  local IMAGE_NAME BIN_NAME BIN_PATH
  for IMAGE_NAME in $("$KUBEADM_BIN" config images list); do
    if [[ "$IMAGE_NAME" =~ ^[a-z0-9.]+\/(kube-[a-z]+): ]]; then
      BIN_NAME="${BASH_REMATCH[1]}"

      _patch_kubeadm_image "$KUBEADM_BIN" "$IMAGE_NAME" "$(_k8s_local_bin_path "$BIN_NAME")"
    fi
  done
}

_PATCH_IMG_TEMP_DIR_PATTERN='/tmp/easy_k8s_dev_patch_img'

# $1 is the path to kubeadm
# $2 is the name of the image to patch - must include the version tag
# $3 is the path of the executable to patch into the image at /usr/local/bin/
_patch_kubeadm_image() {
  local KUBEADM_BIN="$1"
  local IMAGE_NAME="$2"
  local BIN_PATH="$3"

  if [ ! -x "$BIN_PATH" ]; then
    echo "Executable $BIN_PATH not found, aborting" && return 1
  fi

  echo "Patching image $IMAGE_NAME with $BIN_PATH...."

  # let's ensure the image exists locally
  if _docker_image_exists "$IMAGE_NAME"; then
    echo "$IMAGE_NAME exists locally"
  else
    echo "$IMAGE_NAME does not exist locally, pulling..."
    "$KUBEADM_BIN" config images pull

    if ! _docker_image_exists "$IMAGE_NAME"; then
      echo "$IMAGE_NAME still does not exist after pulling, aborting" && return 1
    fi
  fi

  # now let's generate a Dockerfile and patch the image
  local TMP_DIR
  TMP_DIR="$(mktemp -d "$_PATCH_IMG_TEMP_DIR_PATTERN.XXXXXXXX")"
  cp -v "$BIN_PATH" "$TMP_DIR"

  local BIN_NAME="$(basename "$BIN_PATH")"
  cat <<EOF > "$TMP_DIR/Dockerfile"
FROM $IMAGE_NAME
# can't hurt to double check that we're patching the right thing
RUN [ "\$(readlink -f "\$(which $BIN_NAME)")" = '/usr/local/bin/$BIN_NAME' ]
COPY $BIN_NAME /usr/local/bin/
EOF
  docker build "$TMP_DIR" --tag "$IMAGE_NAME"

  # cleanup
  rm -rf "$_PATCH_IMG_TEMP_DIR_PATTERN"*
}

# $1 is the name of the image, with the version tag
_docker_image_exists() {
  docker image inspect "$1" > /dev/null 2>&1
}

# $1 is the name of the built executable
_k8s_local_bin_path() {
  local BIN_PATH="_output/bin/$1"

  if [ -x "$BIN_PATH" ]; then
    echo "$BIN_PATH"
  else
    1>&2 echo "Unable to find the built binary at $(readlink -f "$BIN_PATH"), is $(readlink -f "$(pwd)") a k8s source directory, and have you run make?"
    return 1
  fi
}

# $1 is the name of the bin we're looking for
_k8s_bin_path() {
  local NAME="$1"
  local BIN_PATH

  if ! BIN_PATH="$(_k8s_local_bin_path "$NAME" 2> /dev/null)"; then
    # see if we can find it somewhere else
    if BIN_PATH="$(which "$NAME" 2> /dev/null)"; then
      1>&2 echo "Unable to find a locally built $NAME, using system-wide $BIN_PATH"
    else
      echo "Unable to find $NAME either locally built or system-wide"
      return 1
    fi
  fi

  echo "$BIN_PATH"
}

_HOME_DIR="$HOME/.easy-k8s-dev/cache"

# $1 is the URL to download from if not present
# $2 is the checksum it should have
_ensure_file_present() {
  local DOWNLOAD_URL="$1"
  local CHECKSUM="$2"

  local FILE_PATH="$_HOME_DIR/$(basename "$DOWNLOAD_URL")-$CHECKSUM"
  if ! [ -r "$FILE_PATH" ]; then
    1>&2 echo "Downloading from $DOWNLOAD_URL"
    mkdir -p "$(dirname "$FILE_PATH")"
    curl -L "$DOWNLOAD_URL" > "$FILE_PATH"
  fi

  # either way, should be the right checksum
  local ACTUAL_CHECKSUM="$(sha256sum "$FILE_PATH" | cut -f 1 -d ' ')"
  if [[ "$ACTUAL_CHECKSUM" != "$CHECKSUM" ]]; then
    1>&2 echo "Expected checksum $CHECKSUM from donwload URL $DOWNLOAD_URL"
    return 1
  fi

  echo "$FILE_PATH"
}

if [[ "$(whoami)" == 'root' ]]; then
  echo 'Cowardly refusing to run as root'
  exit 2
fi

main "$@"
