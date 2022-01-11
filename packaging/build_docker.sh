#! /bin/bash


BASEDIR="$(cd "$(dirname "${0}")/../" || exit; pwd)"
source "${BASEDIR}/packaging/build_func.sh"

[[ -f "${SRCTGZ}" ]] || make dist || errexit "Aborted"

[[ -d "src-build" ]] && rm -rf "src-build"
tar xfz "${PRGNAME}-${VER}.tar.gz"
mv "${PRGNAME}-${VER}" src-build
CNFFILE="${BASEDIR}/src-build/configure-parameters.txt"

docker_pack()
{
	[[ -z $1 ]] && errexit "Parameters missing."
	local OSARCH
	OSARCH=$1
	local dockerfile
	dockerfile="${1}/Dockerfile"
	exists "$OSARCH" "ptyspy_bin" && return
	[[ -f "${dockerfile}" ]] || errexit "Not found: packaging/docker/${dockerfile}"
	echo "$2" >"${CNFFILE}"

	local dockername
	dockername="${PRGNAME}-${1}"

	# Create local docker container if it does not yet exist
	docker run --rm -it "${dockername}" true || docker build -t "${dockername}" -f "${dockerfile}" . || errexit "FAILED docker build"
	
	docker run --rm -e OSARCH="${OSARCH}" -v "${SRCDIR}:/src" -it "${dockername}" /src/packaging/docker/build.sh || errexit "FAILED docker run"
	rm -f "${CNFFILE:-/dev/null}"

	[[ -f "${SRCDIR}/src-build/src/ptyspy_bin.${OSARCH}" ]] || errexit "FAILED in $OSARCH"
	# Copy to packaging destination
	cp "${SRCDIR}/src-build/src/ptyspy_bin.${OSARCH}" "${PKG_DIR}/" && \
	chmod 755 "${PKG_DIR}/ptyspy_bin.${OSARCH}" && \
	ok "DONE ${OSARCH}" || errexit "Aborted"
}

cd "${BASEDIR}/packaging/docker" && \
docker_pack x86_64-alpine "--enable-static" && \
docker_pack i386-alpine "--enable-static" && \
docker_pack mips64-alpine "--enable-static --host mips64" && \
docker_pack mips32-alpine "--enable-static --host mips32" && \
ok "DONE Docker"

rm -rf "${BASEDIR}/src-build"