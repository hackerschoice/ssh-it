#! /usr/bin/env bash

# Create deploy-all.sh:
# - Create a tar file containing all static binaries and deploy.sh
# - Create shell script with deploy-all_head.sh and append tar file to it.

PKG_DIR="ssh-it-deploy"
FILE_DEPLOY_SH="../../deploy/deploy.sh"
FILE_TGZ="../ssh-it-pkg.tar.gz"

# CY="\033[1;33m" # yellow
# CG="\033[1;32m" # green
CR="\033[1;31m" # red
# CC="\033[1;36m" # cyan
# CM="\033[1;35m" # magenta
CN="\033[0m"    # none

errexit()
{
	[[ -z "$1" ]] || echo -e 1>&2 "ERROR: ${CR}$*${CN}"

	exit 255
}

check_file()
{
	[[ -f "$1" ]] || errexit "Not found: $1"
}

check_file deploy-all_head.sh
check_file "${FILE_DEPLOY_SH}"
check_file "${FILE_TGZ}"

rm -rf ./"$PKG_DIR"
mkdir "$PKG_DIR" 2>/dev/null

ln -s ../"${FILE_DEPLOY_SH}" "${PKG_DIR}/deploy.sh"
ln -s ../"${FILE_TGZ}" "${PKG_DIR}/ssh-it-pkg.tar.gz"

(cat deploy-all_head.sh; gtar cfhz - --owner=0 --group=0 ${PKG_DIR}) >ssh-it-deploy.sh
chmod 755 ssh-it-deploy.sh

ls -al ssh-it-deploy.sh
exit
[[ -d "$PKG_DIR" ]] && rm -rf "${PKG_DIR}"
