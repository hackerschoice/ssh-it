#! /usr/bin/env bash

BINDIR="$(cd "$(dirname "${0}")" || exit; pwd)"
source "${BINDIR}/funcs" || exit 254

[[ -z $THC_PWD_FILE ]] && ERREXIT 123 "THC_PWD_FILE= not set"

MYDIR="$(cd "$(dirname "${0}")" || exit; pwd)"

[[ ! -f "${THC_PWD_FILE}" ]] && ERREXIT 124 "Not found: ${THC_PWD_FILE}"
source "${THC_PWD_FILE}" 2>/dev/null || ERREXIT 125 "bad content in ${THC_PWD_FILE}"

# Check if password was used:
if [[ -n $LOG_PASSWORD ]]; then
	export SSH_ASKPASS="${MYDIR}/askpass.sh"
	export SSH_ASKPASS_REQUIRE="force"
	export SSH_PASSWORD="$LOG_PASSWORD"
fi

# xargs to remove leading and trailing whitespaces
SSH_ARG="$(tail -n1 "${THC_PWD_FILE}" | cut -f2 -d\# | xargs)"

[[ -z $SSH_ARG ]] && ERREXIT 126 "auto-login not supported" # when SSH_ASKPASS was used originally

SSH_BIN="$(command -v ssh 2>/dev/null)"
[[ -z $SSH_BIN ]] && ERREXIT 126 "ssh not found"

# DEBUGF "SSH_ARG             = '$SSH_ARG'"
# DEBUGF "SSH_ARG_EXTRA       = $SSH_ARG_EXTRA"
# DEBUGF "SSH_PASSWORD        = ${SSH_PASSWORD}"
# DEBUGF "SSH_ASKPASS         = ${SSH_ASKPASS}"
# DEBUGF "SSH_ASKPASS_REQUIRE = ${SSH_ASKPASS_REQUIRE}"
# DEBUGF "SSH_PASSWORD        = ${SSH_PASSWORD}"

# FIXME: some SSH-versions do not support SSH_ASKPASS_REQUIRED=force.
# In this case we must undo the tty using setsid (if available).
# FIXME: setsid is not always available. Implement a cheap setsid()
# in ptyspy.
# If this is still a TTY then use 'setsid' to make it non-tty:
tty &>/dev/null && command -v setsid >/dev/null && { DISPLAY= exec setsid -w "$SSH_BIN" $SSH_ARG_EXTRA $SSH_ARG "$1" || ERREXIT 126 "Cant execute '$SSH_ARG $1'"; }

DISPLAY= exec "$SSH_BIN" $SSH_ARG_EXTRA $SSH_ARG "$1" || ERREXIT 126 "Cant execute '$SSH_ARG $1'"

