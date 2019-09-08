#!/bin/sh
# /bin/sh works for both ash and bash

. /etc/tpm-secret/secret.conf

# Read the content of NVRAM
# STD OUT would do hexdump, not binary
if /usr/bin/tpm_nvread -i $INDEX -f /tmp/blob &> /dev/null; then
    cat /tmp/blob
    rm  /tmp/blob

    # Read the content again with size 0,
    # to block access to reading until next boot
    /usr/bin/tpm_nvread -i $INDEX -s 0 > /dev/null
fi
