#!/bin/bash -eu

function log_progress () {
  if declare -F setup_progress > /dev/null
  then
    setup_progress "verify-and-configure-archive: $*"
    return
  fi
  echo "verify-and-configure-archive: $1"
}

function check_archive_server_reachable () {
  log_progress "Verifying that the archive server $ARCHIVE_SERVER is reachable..."
  local serverunreachable=false
  local default_interface
  default_interface=$(route | grep "^default" | awk '{print $NF}')
  hping3 -c 1 -S -p "$" "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    hping3 -c 1 -S -p "$ARCHIVE_SERVER_PORT" -I "$default_interface" "$ARCHIVE_SERVER" 1>/dev/null 2>&1 ||
    serverunreachable=true

  if [ "$serverunreachable" = true ]
  then
    log_progress "STOP: The archive server $ARCHIVE_SERVER is unreachable. Try specifying its IP address instead."
    exit 1
  fi

  log_progress "The archive server is reachable."
}

function write_archive_configs_to {
  (
    echo "$CEPH_SECRET"
  ) > "$1"
}

function check_archive_mountable () {
  local test_mount_location="/tmp/archivetestmount"

  log_progress "Verifying that the archive share is mountable..."

  if [ ! -e "$test_mount_location" ]
  then
    mkdir "$test_mount_location"
  fi

  local tmp_credentials_file_path="/tmp/teslaCamArchiveCredentials"
  write_archive_configs_to "$tmp_credentials_file_path"

  local mounted=false

  # fix this commandline mount
  local commandline="mount -t ceph '$1:$2:$3' '$test_mount_location' -o 'name=$4,secretfile=${tmp_credentials_file_path}'"
  log_progress "Trying mount command-line:"
  log_progress "$commandline"
  if eval "$commandline"
  then
    mounted=true
    break 2
  fi

  if [ "$mounted" = false ]
  then
    log_progress "STOP: no working combination mount options worked"
    exit 1
  else
    log_progress "The archive share is mountable using: $commandline"
  fi

  umount "$test_mount_location"
}

function install_required_packages () {
  log_progress "Installing/updating required packages if needed"
  apt-get -y --force-yes install hping3 ceph-common
  if ! command -v nc > /dev/null
  then
    apt-get -y --force-yes install netcat || apt-get -y --force-yes install netcat-openbsd
  fi
  log_progress "Done"
}

install_required_packages

check_archive_server_reachable

check_archive_mountable "$ARCHIVE_SERVER" "$ARCHIVE_SERVER_PORT" "$FS_PATH" "$CEPH_CLIENT"
if [ -n "${MUSIC_SHARE_NAME:+x}" ]
then
  if [ "$MUSIC_SIZE" = "0" ]
  then
    log_progress "STOP: MUSIC_SHARE_NAME specified but no music drive size specified"
    exit 1
  fi
  check_archive_mountable "$ARCHIVE_SERVER" "$ARCHIVE_SERVER_PORT" "$MUSIC_SHARE_NAME" "$CEPH_CLIENT"
fi

function configure_archive () {
  log_progress "Configuring the archive..."

  local archive_path="/mnt/archive"
  local music_archive_path="/mnt/musicarchive"

  if [ ! -e "$archive_path" ]
  then
    mkdir "$archive_path"
  fi

  local credentials_file_path="/root/.teslaCamArchiveCredentials"
  write_archive_configs_to "$credentials_file_path"

  sed -i "/^.*\.teslaCamArchiveCredentials.*$/ d" /etc/fstab
  local sharenameforstab="${FS_PATH// /\\040}"
  echo "$ARCHIVE_SERVER:$ARCHIVE_SERVER_PORT:$sharenameforstab $archive_path ceph name=$CEPH_CLIENT,secretfile=${credentials_file_path},noauto 0" >> /etc/fstab

  if [ -n "${MUSIC_SHARE_NAME:+x}" ]
  then
    if [ ! -e "$music_archive_path" ]
    then
      mkdir "$music_archive_path"
    fi
    local musicsharenameforstab="${MUSIC_SHARE_NAME// /\\040}"
    # fix this mount
    echo "$ARCHIVE_SERVER:$ARCHIVE_SERVER_PORT:$musicsharenameforstab $music_archive_path ceph name=$CEPH_CLIENT,secretfile=${credentials_file_path},noauto 0" >> /etc/fstab
    echo "$ARCHIVE_SERVER:$ARCHIVE_SERVER_PORT:$sharenameforstab $archive_path ceph name=$CEPH_CLIENT,secretfile=${credentials_file_path},noauto 0" >> /etc/fstab
  fi
  log_progress "Configured the archive."
}

configure_archive
