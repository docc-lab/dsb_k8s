#!/bin/sh

set -x

# Grab our libs
. "`dirname $0`/setup-lib.sh"

echo "Your ${EXPTTYPE} instance setup completed on $NFQDN ." \
    |  mail -s "${EXPTTYPE} Instance Setup Complete" ${SWAPPER_EMAIL} &
