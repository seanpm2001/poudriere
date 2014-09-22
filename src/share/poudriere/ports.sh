#!/bin/sh
# 
# Copyright (c) 2011-2013 Baptiste Daroussin <bapt@FreeBSD.org>
# Copyright (c) 2012-2013 Bryan Drewery <bdrewery@FreeBSD.org>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

SCRIPTPATH=`realpath $0`
SCRIPTPREFIX=`dirname ${SCRIPTPATH}`
. ${SCRIPTPREFIX}/common.sh

# test if there is any args
usage() {
	cat << EOF
poudriere ports [parameters] [options]

Parameters:
    -c            -- Create a portstree
    -d            -- Delete a portstree
    -u            -- Update a portstree
    -l            -- List all available portstrees
    -v            -- Be verbose; show more information.

Options:
    -k            -- when used with -d, only unregister the directory from
                     the ports tree list, but keep the files.
    -p name       -- specifies the name of the portstree to work on . If not
                     specified, work on a portstree called "default".
    -M mountpoint -- mountpoint
    -m method     -- when used with -c, specify the method used to create the
		     tree. By default is git, possible usage are "git",
                     "rsync"
    -q            -- Quiet (Remove the header in the list view)
EOF
	exit 1
}

CREATE=0
FAKE=0
UPDATE=0
DELETE=0
LIST=0
QUIET=0
VERBOSE=0
KEEP=0
QOP="-q"
while getopts "cudklp:M:m:vq" FLAG; do
	case "${FLAG}" in
		B)
			# Masked on DragonFly
			BRANCH="${OPTARG}"
			;;
		c)
			CREATE=1
			;;
		F)
			# Masked on DragonFly
			FAKE=1
			;;
		u)
			UPDATE=1
			;;
		p)
			PTNAME=${OPTARG}
			;;
		d)
			DELETE=1
			;;
		k)
			KEEP=1
			;;
		l)
			LIST=1
			;;
		q)
			QUIET=1
			;;
		f)
			# option masked on DragonFly
			PTFS=${OPTARG}
			;;
		M)
			PTMNT=${OPTARG}
			;;
		m)
			METHOD=${OPTARG}
			;;
		v)
			VERBOSE=$((${VERBOSE} + 1))
			QOP=
			;;
		*)
			usage
		;;
	esac
done

[ $(( CREATE + UPDATE + DELETE + LIST )) -lt 1 ] && usage

saved_argv="$@"
shift $((OPTIND-1))

METHOD=${METHOD:-git}
PTNAME=${PTNAME:-default}

case ${METHOD} in
rsync);;
git);;
*) usage;;
esac

if [ ${LIST} -eq 1 ]; then
	format='%%-20s %%-17s %%-7s %%s\n'
	display_setup "${format}" 4 "-d"
	display_add "PORTSTREE" "LAST-UPDATED" "METHOD" "PATH"
	while read ptname ptmethod pthack ptpath; do
		display_add ${ptname} ${pthack} ${ptmethod} ${ptpath}
	done <<- EOF
	$(porttree_list)
	EOF
	[ ${QUIET} -eq 1 ] && quiet="-q"
	display_output ${quiet}
else
	[ -z "${PTNAME}" ] && usage
fi

cleanup_new_ports() {
	msg "Error while creating ports tree, cleaning up." >&2
	destroyfs ${PTMNT} ports
	rm -rf ${POUDRIERED}/ports/${PTNAME} || :
}

generate_makefiles() {
	msg "Generating ports top level and category makefiles."
	local CATEGORIES ALLPORTS CAT LVL2
	
	CATEGORIES=$(cd ${PTMNT} && find -s * -type d -depth 0 -maxdepth 0 \
		-not -name \[A-Z\]\*)
	rm -f ${PTMNT}/Makefile
	for CAT in ${CATEGORIES}; do
		echo "SUBDIR += ${CAT}" >> ${PTMNT}/Makefile
		rm -f ${PTMNT}/${CAT}/Makefile
		ALLPORTS=$(cd ${PTMNT}/${CAT} && find -s * -type d -depth 0 \
			-maxdepth 0)
		for LVL2 in ${ALLPORTS}; do
			echo "SUBDIR += ${LVL2}" >> ${PTMNT}/${CAT}/Makefile
		done
	done
}

if [ ${CREATE} -eq 1 ]; then
	# test if it already exists
	porttree_exists ${PTNAME} && err 2 "The ports tree, ${PTNAME}, already exists"
	maybe_run_queued "${saved_argv}"
	: ${PTMNT="${BASEFS:=/usr/local${ZROOTFS}}/ports/${PTNAME}"}
	: ${PTFS="${ZPOOL}${ZROOTFS}/ports/${PTNAME}"}

	# Wrap the ports creation in a special cleanup hook that will remove it
	# if any error is encountered
	CLEANUP_HOOK=cleanup_new_ports

	createfs ${PTNAME} ${PTMNT} ${PTFS}
	pset ${PTNAME} mnt ${PTMNT}
	if [ $FAKE -eq 0 ]; then
		case ${METHOD} in
		rsync)
			msg "Cloning the ports tree via rsync"
			cpdup -VV -i0 ${QOP} ${DPORTS_RSYNC_LOC}/ ${PTMNT}/ || \
			    err 1 " fail"
			;;
		git)
			msg "Cloning the ports tree via git"
			git clone --depth 1 ${QOP} ${DPORTS_URL} ${PTMNT} || \
			    err 1 " fail"
			;;
		esac
		pset ${PTNAME} method ${METHOD}
		pset ${PTNAME} timestamp $(date "+%Y-%m-%d/%H:%M")
	else
		pset ${PTNAME} method "-"
	fi

	generate_makefiles
	unset CLEANUP_HOOK
fi

if [ ${DELETE} -eq 1 ]; then
	porttree_exists ${PTNAME} || err 2 "No such ports tree ${PTNAME}"
	PTMNT=$(pget ${PTNAME} mnt)
	[ -d "${PTMNT}/ports" ] && PORTSMNT="${PTMNT}/ports"
	/sbin/mount | /usr/bin/grep -q "${PORTSMNT:-${PTMNT}} on" \
		&& err 1 "Ports tree \"${PTNAME}\" is currently mounted and being used."
	maybe_run_queued "${saved_argv}"
	msg_n "Deleting portstree \"${PTNAME}\""
	[ ${KEEP} -eq 0 ] && destroyfs ${PTMNT} ports
	rm -rf ${POUDRIERED}/ports/${PTNAME} || :
	echo " done"
fi

if [ ${UPDATE} -eq 1 ]; then
	porttree_exists ${PTNAME} || err 2 "No such ports tree ${PTNAME}"
	METHOD=$(pget ${PTNAME} method)
	PTMNT=$(pget ${PTNAME} mnt)
	[ -d "${PTMNT}/ports" ] && PORTSMNT="${PTMNT}/ports"
	/sbin/mount | /usr/bin/grep -q "${PORTSMNT:-${PTMNT}} on" \
		&& err 1 "Ports tree \"${PTNAME}\" is currently mounted and being used."
	maybe_run_queued "${saved_argv}"
	msg "Updating portstree \"${PTNAME}\""
	if [ -z "${METHOD}" -o ${METHOD} = "-" ]; then
		METHOD=git
		pset ${PTNAME} method ${METHOD}
	fi
	case ${METHOD} in
	rsync)
		msg "Updating the ports tree via rsync"
		rsync -a ${QOP} --delete ${DPORTS_RSYNC_LOC}/ ${PTMNT}/
		;;
	git)
		msg "Pulling from ${DPORTS_URL}"
		cd ${PORTSMNT:-${PTMNT}} && git pull ${QOP}
		;;
	*)
		err 1 "Undefined upgrade method"
		;;
	esac

	generate_makefiles
	pset ${PTNAME} timestamp $(date "+%Y-%m-%d/%H:%M")
fi
