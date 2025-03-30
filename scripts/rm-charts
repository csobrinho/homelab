#!/bin/env bash
set -x
set -eu -o pipefail

REPO="/data/config/homelab"
cd $REPO

find -type d -wholename */prod/charts -exec rm -rv \{\} \+
