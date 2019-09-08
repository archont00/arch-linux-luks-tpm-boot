#!/bin/bash

if [ $(whoami) != "root" ]; then
  echo "$0 must be run as root!"
  exit -1
fi

. /etc/tpm-secret/secret.conf

if [[ $(stat -c %a "$KEYFILE") -ne "400" ]]; then
  echo "File permissions of $KEYFILE wrong, setting to 0400"
  chmod 0400 "$KEYFILE"
fi

if [[ $(stat -c %u "$KEYFILE") -ne "0" ]]; then
  echo "File owner of $KEYFILE wrong, changing to 0"
  chown 0 "$KEYFILE"
fi

if [ "$1" = "--no-seal" ]; then
  unset PCRS
else
  echo "Sealing to PCRs... "
fi

read -s -r -p "TPM owner password: " OWNERPSWD && echo

# Check if the NVRAM index already exists and release it if so
tpm_nvinfo | grep \($INDEX\) > /dev/null && tpm_nvrelease -i $INDEX -o"$OWNERPSWD"

# Define a new NVRAM area
tpm_nvdefine -i $INDEX -s $(stat -c '%s' $KEYFILE) -p "$PERMISSIONS" -o "$OWNERPSWD" -z $PCRS || \
  { echo "NVRAM index $INDEX could not be created"; exit -1; }

# Write the KEYFILE to NVRAM
tpm_nvwrite -i $INDEX -f $KEYFILE -z --password="$OWNERPSWD" || \
  { echo "NVRAM index $INDEX could not be written"; exit -1; }
