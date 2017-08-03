#!/bin/bash
#######################################################
#              DO NOT EDIT THIS FILE
#######################################################

# Include the config file.
. "${WORKSPACE}/jenkins-config.sh"

# We consider here that the web site sources are sibling of this script
local_dir="${WORKSPACE}"

showHelp() {
cat << EOF
Usage: ${0##*/} -u <USERNAME> -p <PASSWORD> -h <IP> -d <REMOTEDIRECTORY> [--sftp] [-p <PORT>]
Syncs a remote directory with recent changes to the current directory
the script is ran within.

	-u [--username]     The username for the FTP host.
	-p [--password]     The password for the FTP host.
	-h [--host]         The IP address for the remote FTP host.
	-d [--directory]    Where you will be pushing the files to.
	-s [--sftp]         Set to enable SFTP
	--port              The port to use for FTP.

EOF
}

while [[ $# -gt 1 ]]; do
	key="$1"
	case $key in
	    -u|--username)
	    ftp_user="$2"
	    shift # past argument
	    ;;
	    -p|--password)
	    ftp_password="$2"
	    shift # past argument
	    ;;
	    -h|--host)
	    ftp_host="$2"
	    shift # past argument
	    ;;
	    -d|--directory)
	    remote_dir="$2"
	    shift # past argument
	    ;;
	    --port)
	    # Must use --port, since -p is already taken above.
	    PORT="$2"
	    shift # past argument
	    ;;
	    -s|--sftp)
	    # TODO: There is a better way of handling args, right now we must set -s "true"
	    PREFIX="sftp"
	    shift # past argument
	    ;;
	    *)
	      # Skip this option, nothing special
	    ;;
	esac
	shift # past argument or value
done

if [ -z ${ftp_user+x} ]; then
	echo "ERROR: FTP Username not found."
	echo ""
	showHelp
	exit 1
fi

if [ -z ${ftp_password+x} ]; then
	echo "ERROR: FTP Password not found."
	echo ""
	showHelp
	exit 1
fi

if [ -z ${ftp_host+x} ]; then
	echo "ERROR: FTP Host/IP not found."
	echo ""
	showHelp
	exit 1
fi

if [ -z ${remote_dir+x} ]; then
	echo "ERROR: Remote directory not specified."
	echo ""
	showHelp
	exit 1
fi

# Set port default 21 if not specified in the flags.
if [ -z ${PORT+x} ]; then
	PORT="21"
fi

# Set Prefix FTP if not specified in the flags.
if [ -z ${PREFIX+x} ]; then
	PREFIX="ftp"
fi

RED='\033[00;31m'
GREEN='\033[00;32m'
BLUE='\033[00;34m'
PURPLE='\033[00;35m'
CYAN='\033[00;36m'
CLEAR='\033[00;0m'

echo -e "${GREEN}============================================="
echo "Sending data to $ftp_user on $ftp_host via $PREFIX to $remote_dir"
echo "Base Directory: $WORKSPACE"
echo "============================================="

# use lftp to synchronize the source with the FTP server for only modified files.
FTP_CONNECT="
#debug;
set sftp:auto-confirm yes;
open -p ${PORT} ${PREFIX}://${ftp_user}:${ftp_password}@${ftp_host};
lcd ${local_dir};
cd ${remote_dir};
"

FTP_MIRROR=" mirror --ignore-time \
    --only-newer \
	--reverse \
	--parallel=5 \
	--verbose \
	--exclude .git/ \
	--exclude .gitignore \
	--exclude wds-sync-script \
	--exclude-glob composer.* \
	--exclude-glob node_modules/ \
	--exclude-glob *.sh;"

##
# Remove a file from the FTP server
remove_file() {
	echo " rm -r -f ${1};"
}

##
# Add a file to the FTP server, by passing a filename
add_file() {
	local directory=$(dirname $1)
	local out=""
	if [ "." == "$directory" ]; then
		out+=" put ${1};"
	else
		# Make the directory(s) between FTP root and the file.
		# -f ignores if they're already created or not.
		out+=" mkdir -p -f ${directory};"
		out+=" put -O ${directory} ${1};"
	fi

	echo $out
}

SUBCOMMANDS=""
REPORT=""

if [ -z ${GIT_PREVIOUS_SUCCESSFUL_COMMIT+x} ]; then
	echo -e "${RED}No previous commit to check against, running initial sync.${CLEAR}"
else
	echo -e "${CYAN}Comparing against ${GIT_PREVIOUS_SUCCESSFUL_COMMIT}${CLEAR}"
	# Loop over all changed files
	REPORT+="${BLUE}=================================="
	REPORT+="|         Transfer Report"
	REPORT+="=================================="
	while read -r line; do
		
		# Exclude a few basic scripts.
		if [[ $line != *".sh"* ]] || [[ $line != *"wds-sync-script"* ]]; then
		
			filename="$( echo $line | awk '{ print $2; }')"
			status="$( echo $line | awk '{ print $1; }')"

			if [[ $status == "D" ]]; then
				# Delete this file
				command=$(remove_file $filename)

				## Add this to the report
				REPORT+="${RED}[-]: ${filename} \n"
			else
				# Put this file
				command=$(add_file $filename)

				## Add this to the report
				REPORT+="${GREEN}[+]: ${filename} \n"
			fi

			SUBCOMMANDS+=" ${command}"
		fi
	done < <(git diff --name-status $GIT_PREVIOUS_SUCCESSFUL_COMMIT HEAD)
fi

# Walk over any 'guarnateed' uploads.
if [[ -n "${FORCE_UPLOADS+set}" ]]; then
	REPORT+="${PURPLE}==================================\n"
	REPORT+="|         Forced Uploads \n"
	REPORT+="==================================\n"

	# Loop over all upload files and add to the command list
	for i in "${FORCE_UPLOADS[@]}"; do :
		# Build the app directories
		command=$(add_file $i)
		REPORT+="${GREEN}[+] ${i}\n"
		SUBCOMMANDS+=" ${command}"
	done
fi

# Use a scripting file, so we can do as many commands as we need.
echo "${FTP_CONNECT} ${SUBCOMMANDS} ${FTP_MIRROR}" > "${WORKSPACE}/wds-sync-script"

# Connect and run the created commands file ( as outlined in the above line )
echo -e "${CYAN}"
lftp -f "${WORKSPACE}/wds-sync-script"
echo -e "${CLEAR}"

# All done, print the transfer report.
echo -e "${REPORT} ${CLEAR}"

# Remove the commands file used for FTP
rm "${WORKSPACE}/wds-sync-script"