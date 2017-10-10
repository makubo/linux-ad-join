#!/bin/bash
#
# Joins Debian machine to the Active Directory by using sssd and realmd.
#
# This script configures the environment and joins the machine to the Active Directory domain. 
# To join the domain, used sssd (System Security Services Daemon) and realmd.
# 
# realmd discovers information about the domain or realm automatically and 
# does not require complicated configuration in order to join a domain or realm. 
# realmd configures the basic settings of the sssd to do the actual network authentication and
# user account lookups.
# 
# The script configures several subsystems during execution.
# 
# - Configures the local DNS cache using dnsmasq. Available DNS servers are automatically detected.
# - Configures the local DNS resolver and checks that DNS settings are correct.
# - Configures the NTP client and forces synchronization of the system time. 
#   Available NTP servers are automatically detected.
# - Configures Kerberos. Available KDC servers are automatically detected.
# - Configures realmd and joins the machine to the domain using the first available LDAP server.
#   The available LDAP servers are detected automatically.
# - Configures sssd, fine tuning after realmd.
# - Configures PAM, enables mkhomedir module.
# - Configures access to the server (login) using domain groups.
# - Configures administrator rights on the server (sudo) using the domain groups.
#
# Bonus:
#
# - Configures SSH and enables GSSAPI for passwordless login.
# - Configures autocomplete in bash, enables autocomplete for a interactive root sessions.
#
# Copyright (C) 2017 Stepan Kokhanovskiy
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


# Script configuration section

readonly PROGNAME="$(basename "${0}")"
readonly LOCK_ENABLED=1
readonly LOCK_FILE="/tmp/${PROGNAME}.lock"
readonly LOCK_FD=931
readonly LOG_NAME="${PROGNAME%.*}"
readonly LOG_ENABLED=0
readonly LOG_FILE="/var/log/${LOG_NAME}/${LOG_NAME}.log"
readonly SYSLOG_ENABLED=0
readonly SYSLOG_PRIORITY="user.notice"


# Global constants

readonly APTGET_ASSUME_YES=1
readonly BACKUP_DIR="${HOME}/.${PROGNAME}"
readonly OS_RELEASE_FILE="/etc/os-release"

readonly PACKAGE_INSTALLED_STRING="ok installed"

readonly DNS_LDAP_SRV_FORMAT="_ldap._tcp.%s"

readonly DIG_TRIES=1
readonly DIG_TIMEOUT=3

readonly DNSMASQ_CONFIG_FILE="/etc/dnsmasq.d/dnscache.conf"
readonly DNSMASQ_RESOLV_FILE="/etc/resolv.dnsmasq"
readonly DNSMASQ_SYSTEM_RESOLV_FILE="/etc/resolv.conf"
readonly DNSMASQ_HOSTS_FILE="/etc/hosts"
readonly DNSMASQ_SERVICE_NAME="dnsmasq"

readonly NTP_CONFIG_FILE="/etc/ntp.conf"
readonly NTP_CONFIG_BACKUP="${BACKUP_DIR}/$(basename "${NTP_CONFIG_FILE}")"
readonly NTP_SERVICE_NAME="ntp"
readonly NTP_TEMP_LOG="/tmp/ntpd.log"

readonly PORT_CONNECT_TIMEOUT=5
readonly PORT_TEST_COMMAND="cat </dev/null >/dev/tcp/%s/%s"

readonly LDAP_PORT=389

readonly KERBEROS_PORT=88
readonly KERBEROS_CONFIG_FILE="/etc/krb5.conf"
readonly KERBEROS_TICKET_LIFETIME="10h"
readonly KERBEROS_RENEW_LIFETIME="7d"
readonly KERBEROS_CLOCKSKEW=300

readonly USER_NAME_PROMPT="Enter the domain user name or leave empty to exit.
Username: "
readonly LOGIN_GROUP_PROMPT="Enter the name of the domain group that will be permitted to login or leave empty to continue.
Group to login: "
readonly SUDO_GROUP_PROMPT="Enter the name of the domain group that will be permitted to sudo or leave empty to continue.
Group to sudo: "

readonly REALMD_CONFIG_FILE="/etc/realmd.conf"
readonly REALMD_PRINCIPAL="host/%s@%s"

readonly SSSD_CONFIG_FILE="/etc/sssd/sssd.conf"
readonly SSSD_DB_DIR="/var/lib/sss/db"
readonly SSSD_CACHE_DIR="/var/lib/sss/mc"
readonly SSSD_SERVICE_NAME="sssd"
readonly SSSD_DISCOVERY_SERVER="_srv_"
readonly SSSD_DEBUG_LEVEL=0
readonly SSSD_AD_SERVER_DISCOVERY=1
readonly SSSD_CACHE_CREDENTIALS=1
readonly SSSD_KRB5_AUTH_TIMEOUT=60
readonly SSSD_LDAP_OPT_TIMEOUT=${SSSD_KRB5_AUTH_TIMEOUT}
readonly SSSD_PAM_ID_TIMEOUT=${SSSD_KRB5_AUTH_TIMEOUT}
readonly SSSD_IGNORE_GROUP_MEMBERS=0
readonly SSSD_USE_FQDN_NAMES=0

readonly PAM_SESSIONS_CONFIG_FILE="/etc/pam.d/common-session"
readonly PAM_MKHOMEDIR_CONFIG_FILE="/usr/share/pam-configs/mkhomedir"

readonly SUDO_CONFIG_DIR="/etc/sudoers.d"
readonly SUDO_SERVICE_NAME="sudo"

readonly SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
readonly SSHD_TMP_CONFIG_FILE="/tmp/sshd_config"
readonly SSHD_SERVICE_NAME="ssh"

readonly BASH_SYSTEM_STARTUP_FILE="/etc/bash.bashrc"
readonly BASH_TMP_SYSTEM_STARTUP_FILE="/tmp/bash.bashrc"
readonly BASH_COMPLETION_FROM_PATTERN="# enable bash completion in interactive shells\r#if ! shopt -oq posix; then\r#  if \[ -f \/usr\/share\/bash-completion\/bash_completion \]; then\r#    \. \/usr\/share\/bash-completion\/bash_completion\r#  elif \[ -f \/etc\/bash_completion \]; then\r#    \. \/etc\/bash_completion\r#  fi\r#fi\r"
readonly BASH_COMPLETION_TO_PATTERN="# enable bash completion in interactive shells\rif ! shopt -oq posix; then\r  if \[ -f \/usr\/share\/bash-completion\/bash_completion \]; then\r    \. \/usr\/share\/bash-completion\/bash_completion\r  elif \[ -f \/etc\/bash_completion \]; then\r    \. \/etc\/bash_completion\r  fi\rfi\r"


# Paths to binaries

readonly LOGGER_PATH="/usr/bin/logger"
readonly APTGET_PATH="/usr/bin/apt-get"
readonly SERVICE_PATH="/usr/sbin/service"
readonly DIRNAME_PATH="/usr/bin/dirname"
readonly GETENT_PATH="/usr/bin/getent"
readonly DIG_PATH="/usr/bin/dig"
readonly NTPDATE_PATH="/usr/sbin/ntpdate"
readonly NTPD_PATH="/usr/sbin/ntpd"
readonly REALM_PATH="/usr/sbin/realm"
readonly TIMEOUT_PATH="/usr/bin/timeout"
readonly TR_PATH="/usr/bin/tr"
readonly KINIT_PATH="/usr/bin/kinit"
readonly KLIST_PATH="/usr/bin/klist"
readonly KDESTROY_PATH="/usr/bin/kdestroy"
readonly DNSMASQ_PATH="/usr/sbin/dnsmasq"
readonly PAM_AUTH_UPDATE_PATH="/usr/sbin/pam-auth-update"
readonly HEAD_PATH="/usr/bin/head"
readonly WC_PATH="/usr/bin/wc"
readonly AWK_PATH="/usr/bin/awk"


# Error messages

readonly E_ANOTHER_INSTANCE_IS_RUNNING="Possibly an another instance of the ${PROGNAME} script is currently running."
readonly E_CAN_NOT_CREATE_LOCK_FILE="Can not create lock file: '${LOCK_FILE}'. ${E_ANOTHER_INSTANCE_IS_RUNNING}"
readonly E_CAN_NOT_LOCK_FILE="Can not lock file: '${LOCK_FILE}'. ${E_ANOTHER_INSTANCE_IS_RUNNING}"
readonly E_CAN_NOT_CREATE_LOG_FILE="Can not create log file: ${LOG_NAME}."
readonly E_CAN_NOT_WRITE_LOG_FILE="Can not write to log file: ${LOG_NAME}."
readonly E_LOG_FILE_IS_NOT_SPECIFIED="Log enabled (LOG_ENABLED = ${LOG_ENABLED}) but a file name for log (LOG_FILE) is not specified. Check the script configuration section."
readonly E_LOGGER_FAILED="Can not write message to the syslog."
readonly E_ARGS_INVALID="Try '${PROGNAME} -h' for help."
readonly E_APTGET_UPDATE="apt-get update failed."
readonly E_APTGET_INSTALL="apt-get install failed."
readonly E_ROOT_REQUIRED="This script must be run as root."
readonly E_DOMAIN_NAME_NOT_FOUND="The DNS domain name not found. Try to specify the domain name using -d parameter or see 'man dnsdomainname' for details."
readonly E_DOMAIN_NAME_NOT_RESOLVED="Check the DNS settings specified at the /etc/resolv.conf."
readonly E_LDAP_SRV_NOT_RESOLVED="Can not resolve the LDAP SRV record '%s'. Check that the DNS servers are configured properly."
readonly E_DOMAIN_CONTROLLER_NOT_FOUND="Can not found domain controllers for the DNS domain name '%s'."
readonly E_NTP_SERVER_UNAVAILABLE="NTP server '%s' is unavailable."
readonly E_NTP_SERVER_NO_AVAILABLE="There are no NTP servers available."
readonly E_NTP_SYNC_FAILED="Time synchronization failed."
readonly E_PORT_UNAVAILABLE="Port '%s:%s' is unavailable."
readonly E_LDAP_SERVER_NO_AVAILABLE="There are no LDAP servers available."
readonly E_DIG_EMPTY_RESPONSE="Can not resolve the DNS record '%s', type %s. Empty response from DNS server."
readonly E_REALM_ALREADY_JOINED="Already joined to the domain '%s'."
readonly E_DNS_SERVER_UNAVAILABLE="DNS server %s is unavailable."
readonly E_GROUP_NOT_FOUND="Can not found group '%s'."
readonly E_HOST_ADDRESS_NOT_FOUND="Can not determine the IP address of the host."
readonly E_USER_NAME_NOT_SPECIFIED="Domain user name is not specified."
readonly E_KERBEROS_SERVER_NO_AVAILABLE="There are no kerberos servers available."


# Global flags

IS_APTGET_UPDATE_COMPLETED=0
DEBUG_ENABLED=1


# Creates empty file
# Arguments:
#   1: Path to file to create
# Returns:
#   0: success
#   1: failure

create_file()
{
    local path="${1}"

    [[ -z "${path}" ]] && return 0

    install -D "/dev/null" "${path}" || return 1

    return 0
}


# Checks that flag value is true: not empty or zero.
# Arguments:
#   1: value to check
# Returns:
#   0: value is true
#   1: value is false

is_true()
{
    local value="${1}"

    if [[ -n "${value}" ]] && [[ "${value}" != "0" ]] ; then
        return 0
    else
        return 1
    fi
}


# Prints message to the error output and to the log file
# Arguments:
#   1: message to write
# Returns:
#   0: success
#   1: failure

log()
{
    local msg="${@}"
    local timestamp="$(date --rfc-3339=seconds)"

    echo "${msg}" 1>&2

    if is_true "${LOG_ENABLED}" ; then

        # Exit if log file is not specified

        if [[ -z "${LOG_FILE}" ]] ; then
            echo "${E_LOG_FILE_IS_NOT_SPECIFIED}" 1>&2
            return 1
        fi

        # Create log file if it is not exists

        if ! [[ -f "${LOG_FILE}" ]] ; then
            if ! create_file "${LOG_FILE}" ; then
                echo "${E_CAN_NOT_CREATE_LOG_FILE}" 1>&2
                return 1
            fi
        fi

        if ! echo "[${timestamp}]: ${msg}" >> "${LOG_FILE}" ; then
            echo "${E_CAN_NOT_WRITE_LOG_FILE}" 1>&2
            return 1
        fi
    fi

    if is_true "${SYSLOG_ENABLED}" && test_app "${LOGGER_PATH}" ; then
        if ! "${LOGGER_PATH}" -t "${LOG_NAME}" -p "${SYSLOG_PRIORITY}" "${msg}" ; then
            echo "${E_LOGGER_FAILED}" 1>&2
        fi
    fi

    return 0
}


# Prints debug log message
# Arguments:
#   1: message to write
# Returns:
#   0: success
#   1: failure

debug() {

    local msg="${@}"

    if is_true "${DEBUG_ENABLED}" ; then
        log "DEBUG: ${msg}" || return 1
    fi

    return 0
}


# Locks file to prevent multiple instances of the script from running at the same time
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

lock()
{
    if is_true "${LOCK_ENABLED}" ; then

        # Create lock file

        if ! eval "exec ${LOCK_FD}>${LOCK_FILE}" ; then
            log "${E_CAN_NOT_CREATE_LOCK_FILE}"
            return 1
        fi

        # Acquier the lock

        if ! flock -n "${LOCK_FD}" ; then
            log "${E_CAN_NOT_LOCK_FILE}"
            return 1
        fi

    fi

    return 0
}


# Stop script execution with error message
# Arguments:
#   1: error message
# Returns:
#   None

eexit()
{
    local msg="${@}"

    log "${msg}"

    exit 1
}


# Print text with the specified new line at the end
# Arguments:
#   1: text to print
#   2: new line to print
# Returns:
#   0: success
#   1: failure

add_line()
{
    local text="${1}"
    local new_line="${2}"

    [[ -z "${text}" ]] || echo "${text}"
    [[ -z "${new_line}" ]] || echo "${new_line}"

    return 0
}


# Print joined lines by using the specified delimiter
# Arguments:
#   1: lines of the text
#   2: delimiter, empty by default
# Returns:
#   0: success
#   1: failure

join_lines()
{
    local text="${1}"
    local delimiter="${2}"

    local line=""
    local first_line_flag=1

    [[ -z "${text}" ]] && return 0

    while read line ; do

        if is_true "${first_line_flag}" ; then
            first_line_flag=0
        else
            printf "%s" "${delimiter}"
        fi

        printf "%s" "${line}"

    done <<< "${text}"

    return 0
}


# Prints only the first line from text
# Arguments:
#   1: lines of the text
# Returns:
#   0: success
#   1: failure

first_line()
{
    local text="${1}"

    [[ -z "${text}" ]] && return 0

    "${HEAD_PATH}" --lines=1 <<< "${text}" || return 1

    return 0
}


# Prints number of lines in the text
# Arguments:
#   1: lines of the text
# Returns:
#   0: success
#   1: failure

print_lines_count()
{
    local text="${1}"

    "${WC_PATH}" --lines <<< "${text}" || return 1

    return 0
}


# Prints text with replaced char
# Arguments:
#   1: source text
#   2: char to replace
#   3: replacing char
# Returns:
#   0: success
#   1: failure

replace_chars()
{
    local text="${1}"
    local from_char="${2}"
    local to_char="${3}"

    [[ -z "${text}" ]] && return 0

    echo "${text}" | "${TR_PATH}" "${from_char}" "${to_char}" || return 1

    return 0
}


# Prints text with replaced substring
# Arguments:
#   1: source text
#   2: substring to replace
#   3: replacing substring
# Returns:
#   0: success
#   1: failure

replace_string()
{
    local text="${1}"
    local from_string="${2}"
    local to_string="${3}"

    [[ -z "${text}" ]] && return 0

    echo "${text}" | sed "s/${from_string}/${to_string}/g" || return 1

    return 0
}


# Prints text uppercase
# Arguments:
#   1: text to uppercase
# Returns:
#   0: success
#   1: failure

print_uppercase()
{
    local text="${1}"

    replace_chars "${text}" '[:lower:]' '[:upper:]' || return 1

    return 0
}


# Prints text lowercase
# Arguments:
#   1: text to lowercase
# Returns:
#   0: success
#   1: failure

print_lowercase()
{
    local text="${1}"

    replace_chars "${text}" '[:upper:]' '[:lower:]' || return 1

    return 0
}


# Checks that scipt running as root
# Arguments:
#   None
# Returns:
#   0: running as root
#   1: running as non-root user

test_root()
{
    if [[ "${EUID}" != "0" ]] ; then

        log "${E_ROOT_REQUIRED}"
        return 1

    fi

    return 0
}


# Checks that application binaries is exists
# Arguments:
#   @: paths or names of the application binaries
# Returns:
#   0: all application exists
#   1: one or more applications does not exists

test_app()
{
    local app_list="${@}"
    local app=""

    [[ -z "${app_list}" ]] && return 0

    for app in ${app_list} ; do

        debug "Check application: '${app}'."

        if ! command -v "${app}" &>/dev/null ; then

            log "Application '${app}' does not exists."
            return 1

        fi
    done

    return 0
}


# Checks that specified packages are installed
# Arguments:
#   @: names of the packages to check
# Returns:
#   0: all packages are installed
#   1: one or more packages are not installed

test_package()
{
    local package_list="${@}"

    local package=""
    local status_string=""

    [[ -z "${package_list}" ]] && return 0

    for package in ${package_list} ; do

        debug "Check package installed: '${package}'."

        status_string="$(dpkg-query --show --showformat='${status}\n' "${package}")" 2>/dev/null || return 1

        if ! echo "${status_string}" | grep "${PACKAGE_INSTALLED_STRING}" &>/dev/null ; then

            debug "Package '${package}' does not installed."
            return 1

        fi
    done

    return 0
}


# Starts 'apt-get update' once
# Arguments:
#   None
# Returns:
#   0: apt-get update (already) finished successfully
#   1: apt-get update failed

start_aptget_update()
{
    if ! is_true "${IS_APTGET_UPDATE_COMPLETED}" ; then

        debug "Start 'apt-get update' once."

        if ! "${APTGET_PATH}" "update" ; then
            log "${E_APTGET_UPDATE}"
            return 1
        fi

        IS_APTGET_UPDATE_COMPLETED=1

        debug "'apt-get update' finished successfully."
    fi

    return 0
}


# Starts 'apt-get install' with specified package list
# Arguments:
#   @: names of the packages to install
# Returns:
#   0: success
#   1: failure

start_aptget_install()
{
    local package_list="${@}"
    local is_error=0

    [[ -z "${package_list}" ]] && return 0

    if [[ -z "${APTGET_ASSUME_YES}" ]] || [[ "${APTGET_ASSUME_YES}" == "0" ]] ; then

        debug "Start 'apt-get install ${package_list}'."

        "${APTGET_PATH}" "install" ${package_list} || is_error=1
    else

        debug "Start 'apt-get -y install ${package_list}'."

        "${APTGET_PATH}" --assume-yes "install" ${package_list} || is_error=1
    fi

    if [[ "${is_error}" != 0 ]] ; then
        log "${E_APTGET_INSTALL}"
        return 1
    fi

    debug "Installed successfully: ${package_list}."

    return 0
}


# Installs packages
# Arguments:
#   @: names of the packages to install
# Returns:
#   0: success
#   1: failure

install_package()
{
    local pkg="${@}"

    [[ -z "${pkg}" ]] && return 0

    debug "Install package: ${pkg}."

    start_aptget_update || return 1
    start_aptget_install "${pkg}" || return 1

    return 0
}


# Check that the service is running
# Arguments:
#   1: service name
# Returns:
#   0: service is running
#   1: service not running

test_service()
{
    local service_name="${1}"

    [[ -z "${service_name}" ]] && return 0

    debug "Test state of service '${service_name}'."

    if ! "${SERVICE_PATH}" "${service_name}" status &>/dev/null ; then

        debug "Service is stopped."
        return 1

    fi

    debug "Service is running."

    return 0
}


# Stops the service
# Arguments:
#   1: service name
# Returns:
#   0: stopped successfully
#   1: failure

stop_service()
{
    local service_name="${1}"

    [[ -z "${service_name}" ]] && return 0

    if test_service "${service_name}" ; then

        debug "Stop service '${service_name}'."

        "${SERVICE_PATH}" "${service_name}" stop || return 1

        debug "Stopped successfully."

    fi

    return 0
}


# Starts the service
# Arguments:
#   1: service name
# Returns:
#   0: started successfully
#   1: failure

start_service()
{
    local service_name="${1}"

    [[ -z "${service_name}" ]] && return 0

    debug "Start service '${service_name}'."

    "${SERVICE_PATH}" "${service_name}" restart || return 1

    debug "Started successfully."

    return 0
}


# Creates directories from file path
# Arguments:
#   1: path to file
# Returns:
#   0: success
#   1: failure

make_path_for_file()
{
    local file_path="${1}"
    local dir_path=""

    [[ -z "${file_path}" ]] && return 0

    dir_path="$("${DIRNAME_PATH}" "${file_path}")" || return 1

    if [[ ! -d "${dir_path}" ]] ; then

        debug "Create directory '${dir_path}'."

        mkdir -p "${dir_path}" || return 1
    fi

    return 0
}


# Copies file to the backup directory
# Arguments:
#   1: path to file
# Returns:
#   0: success
#   1: failure

backup_file()
{
    local src_file="${1}"

    local dst_file="${BACKUP_DIR}/$(basename "${src_file}")"

    [[ -z "${src_file}" ]] && return 0
    [[ -f "${src_file}" ]] || return 0

    debug "Backup file '${src_file}' to '${dst_file}'."

    make_path_for_file "${dst_file}" || return 1
    cp --backup=numbered "${src_file}" "${dst_file}" || return 1

    return 0
}


# Writes a text data to the file and makes backup of file before that
# Arguments:
#   1: text to write
#   2: path to file
# Returns:
#   0: success
#   1: failure

write_to_file()
{
    local text="${1}"
    local dst_file="${2}"

    [[ -z "${text}" ]] && return 0
    [[ -z "${dst_file}" ]] && return 0

    local lines_count="$(print_lines_count "${text}")"

    backup_file "${dst_file}" || return 1
    make_path_for_file "${dst_file}" || return 1

    debug "Write data to the file '${dst_file}'."

    echo "${text}" > "${dst_file}"

    debug "Wrote ${lines_count} lines successfully."

    return 0
}


# Prints name of the domain
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

print_domain_name()
{
    local domain_name=""

    domain_name="$(dnsdomainname)" || return 1

    if [[ -z "${domain_name}" ]] ; then
        log "${E_DOMAIN_NAME_NOT_FOUND}"
        return 1
    fi

    debug "Found domain '${domain_name}'."
    echo "${domain_name}"

    return 0
}


# Prints name of the current host as FQDN
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

print_host_fqdn()
{
    local domain_name="${1}"

    local host_name=""

    [[ -z "${domain_name}" ]] && return 0

    host_name="$(hostname --fqdn)" || return 1

    if [[ ! "${host_name}" == *.${domain_name} ]] ; then
        host_name="${host_name}.${domain_name}"
    fi

    debug "Found host FQDN '${host_name}'."
    echo "${host_name}"

    return 0
}


# Installs dnsutils package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_dnsutils()
{
    test_package "dnsutils" || install_package "dnsutils" || return 1
    test_app "${DIG_PATH}" || return 1

    return 0
}


# Resolves DNS name to ip address
# Arguments:
#   1: name to resolve
#   2: DNS record type, A by default
#   3: DNS server that will be used for resolve, empty by default.
#      system nameservers from /etc/resolv.conf will be used if empty.
# Returns:
#   0: success
#   1: failure

lookup_hostname()
{
    local name="${1}"
    local type="${2:-A}"
    local server="${3}"

    local output=""

    [[ -z "${name}" ]] && return 0

    if [[ -z "${server}" ]] ; then

        if [[ "${type}" == "A" ]] ; then

            if test_app "${DIG_PATH}" &>/dev/null ; then

                debug "Lookup DNS record '${name}'."
                output="$("${DIG_PATH}" "${name}" "${type}" +short +search +tries=${DIG_TRIES} +time=${DIG_TIMEOUT})" || return 1

            else

                debug "Lookup DNS record '${name}'."
                output="$("${GETENT_PATH}" hosts "${name}" | "${AWK_PATH}" '{ print $1 }')"

            fi

        else

            debug "Lookup DNS record '${name}', type ${type}."
            output="$("${DIG_PATH}" "${name}" "${type}" +short +search +tries=${DIG_TRIES} +time=${DIG_TIMEOUT})" || return 1

        fi

    else

        debug "Lookup DNS record '${name}', type ${type} by the server '$server'."
        output="$("${DIG_PATH}" "@${server}" "${name}" "${type}" +short +search +tries=${DIG_TRIES} +time=${DIG_TIMEOUT})" || return 1

    fi

    if [[ -z "${output}" ]] ; then
        log "$(printf "${E_DIG_EMPTY_RESPONSE}" "${name}" "${type}")"
        return 1
    fi

    debug "Resolved successfully."
    echo "${output}"

    return 0
}


# Resolves ip address to DNS name
# Arguments:
#   1: ip address to resolve
# Returns:
#   0: success
#   1: failure

lookup_address()
{
    local address="${1}"

    local dig_output=""

    [[ -z "${address}" ]] && return 0

    debug "Reverse lookup DNS record for address '${address}'."
    dig_output="$("${DIG_PATH}" -x "${address}" +short +tries=${DIG_TRIES} +time=${DIG_TIMEOUT})" || return 1

    if [[ -z "${dig_output}" ]] ; then
        log "$(printf "${E_DIG_EMPTY_RESPONSE}" "${address}" "PTR")"
        return 1
    fi

    dig_output="$(replace_string "${dig_output}" "\.$" "")" || return 1

    debug "Resolved successfully."
    echo "${dig_output}"

    return 0
}


# Prints hostnames for the specified ip addresses
# Prints the ip address if it can not be resolved
# Arguments:
#   1: list of the ip addresses
# Returns:
#   0: success
#   1: failure

print_hostname_or_address()
{
    local address_list="${1}"

    local address=""
    local hostname=""

    [[ -z "${address_list}" ]] && return 0

    while read address ; do

        hostname="$(lookup_address "${address}")"
        if [[ -z "${hostname}" ]] ; then
            echo "${address}"
        else
            echo "${hostname}"
        fi

    done <<< "${address_list}"

    return 0
}


# Checks that TCP port is open and available
# Arguments:
#   1: server to connect
#   2: TCP port to connect
#   3: connection timeout, ${PORT_CONNECT_TIMEOUT} by default
# Returns:
#   0: TCP port is available
#   1: TCP port is not available

test_port()
{
    local server="${1}"
    local port="${2}"
    local timeout="${3:-${PORT_CONNECT_TIMEOUT}}"

    [[ -z "${server}" ]] && return 0
    [[ -z "${port}" ]] && return 0

    local test_command="$(printf "${PORT_TEST_COMMAND}" "${server}" "${port}")"

    debug "Test port: '${server}:${port}'."

    if ! "${TIMEOUT_PATH}" "${timeout}" "bash" -c "${test_command}" ; then
        log "$(printf "${E_PORT_UNAVAILABLE}" "${server}" "${port}")"
        return 1
    fi

    debug "Port is available."

    return 0
}


# Checks that DNS client on the current host is configured properly
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

test_dns_settings()
{
    local domain_name="${1}"
    local dns_ldap_srv="$(printf "${DNS_LDAP_SRV_FORMAT}" "${domain_name}")"

    [[ -z "${domain_name}" ]] && return 0

    if ! lookup_hostname "${domain_name}" 1>/dev/null ; then
        log "${E_DOMAIN_NAME_NOT_RESOLVED}"
        return 1
    fi

    if ! lookup_hostname "${dns_ldap_srv}" "SRV" 1>/dev/null ; then
        log "$(printf "${E_LDAP_SRV_NOT_RESOLVED}" "${domain_name}")"
        return 1
    fi

    return 0
}


# Print ip addresses of AD domain controllers
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

print_domain_controllers()
{
    local domain_name="${1}"

    local server_list=""
    local server=""

    [[ -z "${domain_name}" ]] && return 0

    server_list="$(lookup_hostname "${domain_name}")" || return 1

    if [[ -z "${server_list}" ]] ; then

        log "$(printf "${E_DOMAIN_CONTROLLER_NOT_FOUND}" "${domain_name}")"
        return 1

    fi

    while read server ; do
        debug "Found domain controller: '${server}'."
    done <<< "${server_list}"

    echo "${server_list}"

    return 0
}


# Installs dnsmasq package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_dnsmasq()
{
    test_package "dnsmasq" || install_package "dnsmasq" || return 1
    test_app "${DNSMASQ_PATH}" || return 1

    return 0
}


# Prints contents of the dnsmasq configuration file
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

print_dnsmasq_config()
{
    echo "listen-address=127.0.0.1"
    echo "bind-interfaces"
    echo "no-poll"
    echo "no-negcache"
    echo "cache-size=1000"
    echo "dns-forward-max=150"
    echo "domain-needed"
    echo "resolv-file=${DNSMASQ_RESOLV_FILE}"
    echo "all-servers"

    return 0
}


# Prints contents of the dnsmasq resolv.conf file
# Arguments:
#   1: list of the DNS servers
# Returns:
#   0: success
#   1: failure

print_dnsmasq_resolv_config()
{
    local server_list="${1}"

    [[ -z "${server_list}" ]] && return 0

    while read server ; do
        debug "Add DNS server: '${server}'."
        echo "nameserver ${server}"
    done <<< "${server_list}"

    return 0
}


# Prints contents of the system resolv.conf file that points to the dnsmasq
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

print_dnsmasq_system_resolv_config()
{
    local domain_name="${1}"

    if [[ ! -z "${domain_name}" ]] ; then
        echo "search ${domain_name}"
        echo "domain ${domain_name}"
    fi

    echo "nameserver 127.0.0.1"

    return 0
}


# Checks that specified DNS server is available
# Arguments:
#   1: DNS server
#   2: hostname to lookup
# Returns:
#   0: DNS server is available
#   1: DNS server is not available

test_dns_server()
{
    local server="${1}"
    local lookup_name="${2}"

    [[ -z "${server}" ]] && return 0
    [[ -z "${lookup_name}" ]] && return 0

    debug "Test DNS server: '${server}'."

    if ! lookup_hostname "${lookup_name}" "A" "${server}" 1>/dev/null ; then
        log "$(printf "${E_DNS_SERVER_UNAVAILABLE}" "${server}")"
        return 1
    fi

    debug "DNS server available."

    return 0
}


# Prints only available DNS servers from specified list
# Arguments:
#   1: list of the DNS servers
#   2: hostname to lookup
# Returns:
#   0: success
#   1: there are no available DNS servers

print_dns_server()
{
    local server_list="${1}"
    local lookup_name="${2}"

    local error_flag=1

    [[ -z "${server_list}" ]] && return 0
    [[ -z "${lookup_name}" ]] && return 0

    while read server ; do
        if test_dns_server "${server}" "${lookup_name}" ; then
            echo "${server}"
            error_flag=0
        fi
    done <<< "${server_list}"

    if is_true "${error_flag}" ; then
        log "${E_DNS_SERVER_NO_AVAILABLE}"
        return 1
    fi

    return 0
}


# Prints ip address of the current host
# Arguments:
#   1: hostname of the current host
#   2: list of the DNS servers
# Returns:
#   0: success
#   1: failure

print_host_address()
{
    local host_name="${1}"
    local server_list="${2}"

    local host_address=""

    [[ -z "${host_name}" ]] && return 0
    [[ -z "${server_list}" ]] && return 0

    debug "Determine the IP address of the host."

    host_address="$(hostname --all-ip-addresses)"

    if [[ -z "${host_address}" ]] ; then

        debug "Lookup the IP address of the host by DNS."

        while read server ; do
            host_address="$(lookup_hostname "${host_name}" "A" "${server}")" && break
        done <<< "${server_list}"

    fi

    if [[ -z "${host_address}" ]] ; then
        log "${E_HOST_ADDRESS_NOT_FOUND}"
        return 1
    fi

    host_address="$(first_line "${host_address}")"

    debug "Found host IP address '${host_address}'."
    echo "${host_address}"

    return 0
}


# Prints contents of the system hosts file
# Gets contents of the system hosts file and remove line with hostname
# Arguments:
#   1: path to the hosts file
#   2: short hostname of the current host
#   3: FQDN of the current host
#   4: ip address of the current host
# Returns:
#   0: success
#   1: failure

print_hosts_config()
{
    local hosts_file="${1}"
    local host_name="${2}"

    local custom_lines=""

    [[ -z "${hosts_file}" ]] && return 0
    [[ -z "${host_name}" ]] && return 0

    grep --invert-match --ignore-case "${host_name}" "${hosts_file}"

    return 0
}


# Configures dnsmasq as the local DNS cache
# Arguments:
#   1: domain name
#   2: list of the DNS servers
# Returns:
#   0: success
#   1: failure

configure_dnsmasq()
{
    local domain_name="${1}"
    local server_list="${2}"

    local host_name=""
    local host_fqdn=""
    local host_address=""

    [[ -z "${server_list}" ]] && return 0
    [[ -z "${domain_name}" ]] && return 0

    debug "Configure local DNS cache."

    server_list="$(print_dns_server "${server_list}" "${domain_name}")" || return 1

    write_to_file "$(print_dnsmasq_resolv_config "${server_list}")" "${DNSMASQ_RESOLV_FILE}" || return 1
    write_to_file "$(print_dnsmasq_config)" "${DNSMASQ_CONFIG_FILE}" || return 1
    write_to_file "$(print_dnsmasq_system_resolv_config "${domain_name}")" "${DNSMASQ_SYSTEM_RESOLV_FILE}" || return 1

    host_name="$(hostname)" || return 1

    write_to_file \
        "$(print_hosts_config "${DNSMASQ_HOSTS_FILE}" "${host_name}")" "${DNSMASQ_HOSTS_FILE}" || return 1

    stop_service "${DNSMASQ_SERVICE_NAME}" && start_service "${DNSMASQ_SERVICE_NAME}" || return 1

    debug "Local DNS cache configured successfully."

    return 0
}


# Installs ntp and ntpdate packages
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_ntp()
{
    test_package "ntpdate" "ntp" || install_package "ntpdate" "ntp" || return 1
    test_app "${NTPDATE_PATH}" || return 1
    test_app "${NTPD_PATH}" || return 1

    return 0
}


# Prints contents of the ntpd configuration file
# Arguments:
#   1: list of the NTP servers
# Returns:
#   0: success
#   1: failure

print_ntp_config()
{
    local server_list="${1}"

    echo "driftfile /var/lib/ntp/ntp.drift"
    echo "statistics loopstats peerstats clockstats"
    echo "filegen loopstats file loopstats type day enable"
    echo "filegen peerstats file peerstats type day enable"
    echo "filegen clockstats file clockstats type day enable"

    if [[ ! -z "${server_list}" ]] ; then
        while read server ; do

            server="$(print_hostname_or_address "${server}")"

            debug "Add NTP server: ${server}."

            echo "server ${server}"

        done <<< "${server_list}"
    fi

    echo "restrict -4 default notrap nomodify nopeer noquery"
    echo "restrict -6 default notrap nomodify nopeer noquery"
    echo "restrict 127.0.0.1"
    echo "restrict ::1"
#   echo "restrict source notrap nomodify noquery"

    return 0
}


# Checks that NTP server is available
# Arguments:
#   1: NTP server
# Returns:
#   0: NTP server is available
#   1: NTP server is not available

test_ntp_server()
{
    local server="${1}"

    [[ -z "${server}" ]] && return 0

    debug "Test NTP server: '${server}'."

    if ! "${NTPDATE_PATH}" -p1 -q "${server}" 1>/dev/null ; then
        log "$(printf "${E_NTP_SERVER_UNAVAILABLE}" "${server}")"
        return 1
    fi

    debug "NTP server available."

    return 0

}


# Prints only available NTP servers from specified list
# Arguments:
#   1: list of the NTP servers
# Returns:
#   0: success
#   1: there are no available NTP servers

print_ntp_server()
{
    local server_list="${1}"

    local error_flag=1

    [[ -z "${server_list}" ]] && return 0

    while read server ; do
        if test_ntp_server "${server}" ; then
            echo "${server}"
            error_flag=0
        fi
    done <<< "${server_list}"

    if is_true "${error_flag}" ; then
        log "${E_NTP_SERVER_NO_AVAILABLE}"
        return 1
    fi

    return 0
}


# Forces time sync with NTP servers
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

sync_ntp_time()
{
    debug "Synchronize time. This can take a while."

    if ! "${NTPD_PATH}" -g -l "${NTP_TEMP_LOG}" -q ; then
        log "${E_NTP_SYNC_FAILED}"
        return 1
    fi

    debug "Time synchronized successfully."

    return 0
}


# Configures ntpd and sync time
# Arguments:
#   1: list of the NTP servers
# Returns:
#   0: success
#   1: failure

configure_ntp()
{
    local server_list="${1}"

    [[ -z "${server_list}" ]] && return 0

    debug "Configure NTP client."

    stop_service "${NTP_SERVICE_NAME}" || return 1

    server_list="$(print_ntp_server "${server_list}")" || return 1
    write_to_file "$(print_ntp_config "${server_list}")" "${NTP_CONFIG_FILE}" || return 1

    sync_ntp_time || return 1

    start_service "${NTP_SERVICE_NAME}" || return 1

    debug "NTP client configured successfully."

    return 0
}


# Installs kerberos package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_kerberos()
{
    test_package "krb5-user" || install_package "krb5-user" || return 1
    test_app "${KINIT_PATH}" "${KLIST_PATH}" "${KDESTROY_PATH}" || return 1

    return 0
}


# Prints kerberos realm name from the domain name
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

print_realm_name()
{
    local domain_name="${1}"

    local realm_name=""

    realm_name="$(print_uppercase "${domain_name}")" || return 1

    debug "Found realm name: '${realm_name}'."

    echo "${realm_name}"

    return 0
}


# Prints only available by TCP kerberos servers from specified list
# Arguments:
#   1: list of the KDC servers
# Returns:
#   0: success
#   1: there are no available KDC servers

print_kerberos_server()
{
    local server_list="${1}"

    local is_empty=1

    [[ -z "${server_list}" ]] && return 0

    while read server ; do
        if test_port "${server}" "${KERBEROS_PORT}" ; then
            echo "${server}"
            is_empty=0
        fi
    done <<< "${server_list}"

    if is_true "${is_empty}" ; then
        log "${E_KERBEROS_SERVER_NO_AVAILABLE}"
        return 1
    fi

    return 0
}


# Prints contents of the krb5 configuration file
# Arguments:
#   1: domain name
#   2: realm name
#   3: list of the KDC servers
# Returns:
#   0: success
#   1: failure

print_kerberos_config()
{
    local domain_name="${1}"
    local realm_name="${2}"
    local server_list="${3}"

    [[ -z "${domain_name}" ]] && return 0
    [[ -z "${realm_name}" ]] && return 0
    [[ -z "${server_list}" ]] && return 0

    local server=""
    local is_first=1
    local tab="    "

    echo "[libdefaults]"
    echo "default_realm = ${realm_name}"
    echo "dns_lookup_realm = true"
    echo "dns_lookup_kdc = true"
    echo "forwardable = true"
    echo "ticket_lifetime = ${KERBEROS_TICKET_LIFETIME}"
    echo "renew_lifetime = ${KERBEROS_RENEW_LIFETIME}"
    echo "clockskew = ${KERBEROS_CLOCKSKEW}"
    echo ""
    echo "[realms]"
    echo "${realm_name} = {"

    while read server ; do

        server="$(print_hostname_or_address "${server}")"

        if is_true "${is_first}" ; then

            debug "Add master kerberos server: '${server}'."
            echo "${tab}admin_server = ${server}"
            is_first=0

        fi

        debug "Add KDC server: '${server}'."
        echo "${tab}kdc = ${server}"

    done <<< "${server_list}"

    echo "}"
    echo ""
    echo "[domain_realm]"
    echo ".${domain_name} = ${realm_name}"
    echo "${domain_name} = ${realm_name}"

    return 0
}


# Configures kerberos
# Arguments:
#   1: domain name
#   2: list of the KDC servers
# Returns:
#   0: success
#   1: failure

configure_kerberos()
{
    local domain_name="${1}"
    local server_list="${2}"

    local realm_name=""

    debug "Configure kerberos."

    realm_name="$(print_realm_name "${domain_name}")" || return 1
    server_list="$(print_kerberos_server "${server_list}")" || return 1

    write_to_file "$(print_kerberos_config "${domain_name}" "${realm_name}" "${server_list}")" \
        "${KERBEROS_CONFIG_FILE}" || return 1

    debug "Kerberos configured successfully."

    return 0
}


# Removes all cached kerberos tickets
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

clear_kerberos_ticket()
{
    debug "Clear Kerberos tickets."

    "${KDESTROY_PATH}" -Aq || return 1

    debug "Cleared successfully."
}


# Gets the kerberos ticket for specified user and realm
# Arguments:
#   1: realm name
#   2: user name
# Returns:
#   0: success
#   1: failure

init_kerberos_ticket()
{
    local realm_name="${1}"
    local user_name="${2}"

    [[ -z "${realm_name}" ]] && return 0
    [[ -z "${user_name}" ]] && return 0

    local principal="${user_name}@${realm_name}"

    debug "Get Kerberos ticket for the principal '${principal}'."

    "${KINIT_PATH}" -V "${principal}" 1>&2 || return 1
    "${KLIST_PATH}" || return 1

    debug "Ticket received successfully."

    return 0
}


# Prints user name
# Asks user for input if user name is empty
# Arguments:
#   1: user name
# Returns:
#   0: success
#   1: failure

print_user_name()
{
    local user_name="${1}"

    if [[ -z "${user_name}" ]] ; then

        read -p "${USER_NAME_PROMPT}" user_name || return 1

        if [[ -z "${user_name}" ]] ; then
            log "${E_USER_NAME_NOT_SPECIFIED}"
            return 1
        fi

    fi

    echo "${user_name}"

    return 0
}


# Gets the kerberos ticket for specified user
# Asks user for input if user name is empty
# Arguments:
#   1: domain name
#   2: user name
# Returns:
#   0: success
#   1: failure

init_user_name()
{
    local domain_name="${1}"
    local user_name="${2}"

    local realm_name=""

    [[ -z "${domain_name}" ]] && return 0

    realm_name="$(print_realm_name "${domain_name}")" || return 1

    while : ; do

        user_name="$(print_user_name "${user_name}")" || return 1

        if init_kerberos_ticket "${realm_name}" "${user_name}" ; then
            break
        else
            clear_kerberos_ticket
            user_name=""
        fi
    done

    echo "${user_name}"

    return 0
}


# Installs realmd package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_realm()
{
    test_package "realmd" "policykit-1" "packagekit" || \
        install_package "realmd" "policykit-1" "packagekit" || return 1

    test_app "${REALM_PATH}" || return 1

    return 0
}


# Installs sssd package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_sssd()
{
    test_package "sssd-tools" "sssd" "libnss-sss" "libpam-sss" "adcli" "samba-common-bin" || \
        install_package "sssd-tools" "sssd" "libnss-sss" "libpam-sss" "adcli" "samba-common-bin" || \
        return 1

    return 0
}


# Gets domain information for the specified realm server
# Arguments:
#   1: hostname or ip address of the server
# Returns:
#   0: success
#   1: failure

discover_realm()
{
    local realm_name="${1}"

    [[ -z "${realm_name}" ]] && return 0

    debug "Discover realm: '${realm_name}'."

    if ! "${REALM_PATH}" discover "${realm_name}" --verbose 1>&2 ; then
        log "$(printf "${E_REALM_UNAVAILABLE}" "${realm_name}")"
        return 1
    fi

    debug "Realm is available."

    return 0
}


# Prints only available LDAP servers from specified list
# Arguments:
#   1: list of the LDAP servers
# Returns:
#   0: success
#   1: there are no available LDAP servers

print_ldap_server()
{
    local server_list="${1}"

    local is_empty=1

    [[ -z "${server_list}" ]] && return 0

    while read server ; do
        if test_port "${server}" "${LDAP_PORT}" && discover_realm "${server}" ; then
            echo "${server}"
            is_empty=0
        fi
    done <<< "${server_list}"

    if is_true "${is_empty}" ; then
        log "${E_LDAP_SERVER_NO_AVAILABLE}"
        return 1
    fi

    return 0
}


# Prints information about operation system
# Arguments:
#   1: parameter name, see contents of the ${OS_RELEASE_FILE} file
# Returns:
#   0: success
#   1: failure

print_os_info()
{
    local info_name="${1}"

    local info_value=""

    [[ -z "${info_name}" ]] && return 1
    info_name="$(print_uppercase "${info_name}")" || return 1

    [[ -f "${OS_RELEASE_FILE}" ]] || return 1
    info_value="$(bash -c ". \"${OS_RELEASE_FILE}\" && echo \"\${${info_name}}\"")" || return 1
    [[ -z "${info_value}" ]] && return 1

    echo "${info_value}"

    return 0
}


# Prints contents of the realmd configuration file
# Arguments:
#   1: os name
#   2: os version
# Returns:
#   0: success
#   1: failure

print_realmd_config()
{
    local os_name="${1}"
    local os_version="${2}"

    [[ -z "${os_name}" ]] && [[ -z "${os_version}" ]] && return 0

    echo "[active-directory]"

    [[ -z "${os_name}" ]] || echo "os-name = ${os_name}"
    [[ -z "${os_version}" ]] || echo "os-version = ${os_version}"

    return 0
}


# Joins host to the domain
# Arguments:
#   1: domain name
#   2: list of the domain controllers
# Returns:
#   0: success
#   1: failure

join_realm()
{
    local domain_name="${1}"
    local server_list="${2}"

    [[ -z "${domain_name}" ]] && return 0
    [[ -z "${server_list}" ]] && return 0

    local server=""
    local os_name=""
    local os_version=""
    local current_domain_name=""
    local host_name_short=""
    local host_name_fqdn=""
    local is_joined=0

    current_domain_name="$("${REALM_PATH}" list --name-only)"

    if [[ ! -z "${current_domain_name}" ]] ; then
        log "$(printf "${E_REALM_ALREADY_JOINED}" "${current_domain_name}")"
        if [[ "${domain_name}" == "${current_domain_name}" ]] ; then
            return 0
        else
            return 1
        fi
    fi

    os_name="$(print_os_info "name")" || return 1
    os_version="$(print_os_info "version_id")" || return 1
    write_to_file "$(print_realmd_config "${os_name}" "${os_version}")" "${REALMD_CONFIG_FILE}" || return 1

    host_name_short="$(hostname)" || return 1
    host_name_fqdn="$(print_host_fqdn "${domain_name}")" || return 1

    if [[ "${host_name_short}" != "${host_name_fqdn}" ]] ; then

        # < adcli bug description >
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=858981
        # https://bugs.freedesktop.org/show_bug.cgi?id=86107

        debug "Change hostname to FQDN: '${host_name_fqdn}'."
        hostname "${host_name_fqdn}" || return 1
    fi

    while read server ; do

        debug "Join to the domain '${domain_name}' by the server '${server}'..."

        "${REALM_PATH}" join \
            --verbose \
            --client-software="sssd" \
            --server-software="active-directory" \
            --membership-software="adcli" \
            "${server}" || continue

        is_joined=1
        debug "Joined successfully."
        break

    done <<< "${server_list}"

    if [[ "${host_name_short}" != "${host_name_fqdn}" ]] ; then
        debug "Change hostname back: '${host_name_short}'."
        hostname "${host_name_short}" || return 1
    fi

    if ! is_true "${is_joined}" ; then
        return 1
    fi

    return 0
}


# Prints 'True' or 'False' for sssd configuration file
# Arguments:
#   1: flag value
# Returns:
#   0: success
#   1: failure

print_sssd_bool()
{
    local value="${1}"

    [[ -z "${value}" ]] && return 0

    if is_true "${value}" ; then
        printf "%s" "True"
    else
        printf "%s" "False"
    fi

    return 0
}


# Prints contents of the sssd configuration file
# Arguments:
#   1: domain name
#   2: list of the active directory servers
# Returns:
#   0: success
#   1: failure

print_sssd_config()
{
    local domain_name="${1}"
    local address_list="${2}"

    [[ -z "${domain_name}" ]] && return 0

    local server_list="$(print_hostname_or_address "${address_list}")"
    local backup_server_list=""

    if [[ -z "${server_list}" ]] ; then
        server_list="${SSSD_DISCOVERY_SERVER}"
    else
        if is_true "${SSSD_AD_SERVER_DISCOVERY}" ; then
            backup_server_list="${SSSD_DISCOVERY_SERVER}"
        fi
    fi

    echo "[sssd]"
    echo "debug_level = ${SSSD_DEBUG_LEVEL}"
    echo "domains = ${domain_name}"
    echo "config_file_version = 2"
    echo "services = nss, pam, sudo"
    echo ""
    echo "[nss]"
    echo "debug_level = ${SSSD_DEBUG_LEVEL}"
    echo ""
    echo "[pam]"
    echo "debug_level = ${SSSD_DEBUG_LEVEL}"
    echo "pam_id_timeout = ${SSSD_PAM_ID_TIMEOUT}"
    echo ""
    echo "[domain/${domain_name}]"
    echo "debug_level = ${SSSD_DEBUG_LEVEL}"
    echo "ad_domain = ${domain_name}"
    echo "ad_server = $(join_lines "${server_list}" ", ")"
    echo "ad_backup_server = ${backup_server_list}"
    echo "ad_hostname = $(print_host_fqdn "${domain_name}")"
    echo "krb5_realm = $(print_realm_name "${domain_name}")"
    echo "realmd_tags = manages-system joined-with-adcli"
    echo "id_provider = ad"
    echo "krb5_store_password_if_offline = True"
    echo "default_shell = /bin/bash"
    echo "ldap_id_mapping = True"
    echo "fallback_homedir = /home/%d/%u"
    echo "sudo_provider = none"
    echo "use_fully_qualified_names = $(print_sssd_bool "${SSSD_USE_FQDN_NAMES}")"
    echo "cache_credentials = $(print_sssd_bool "${SSSD_CACHE_CREDENTIALS}")"
    echo "krb5_auth_timeout = ${SSSD_KRB5_AUTH_TIMEOUT}"
    echo "ldap_opt_timeout = ${SSSD_LDAP_OPT_TIMEOUT}"
    echo "access_provider = simple"

    return 0
}


# Removes all data from the sssd cache
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

clear_sssd_cache()
{
    debug "Clear sssd cache."

    [[ ! -z "${SSSD_DB_DIR}" ]] && rm -vf "${SSSD_DB_DIR}/*" || return 1
    [[ ! -z "${SSSD_CACHE_DIR}" ]] && rm -vf "${SSSD_CACHE_DIR}/*" || return 1

    debug "Cleared successfully."

    return 0
}


# Configures the sssd
# Arguments:
#   1: domain name
#   2: list of the active directory servers
# Returns:
#   0: success
#   1: failure

configure_sssd()
{
    local domain_name="${1}"
    local server_list="${2}"

    [[ -z "${domain_name}" ]] && return 0

    debug "Configure sssd."

    write_to_file "$(print_sssd_config "${domain_name}" "${server_list}")" \
        "${SSSD_CONFIG_FILE}" || return 1

    chown 'root:root' "${SSSD_CONFIG_FILE}" || return 1
    chmod '0600' "${SSSD_CONFIG_FILE}" || return 1

    stop_service "${SSSD_SERVICE_NAME}" || return 1
    clear_sssd_cache || return 1
    start_service "${SSSD_SERVICE_NAME}" || return 1

    debug "Sssd configured successfully."

    return 0
}


# Installs libpam-modules package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_pam_modules()
{
    test_package "libpam-modules" || install_package "libpam-modules" || return 1

    return 0
}


# Prints contents of the configuration file for the mkhomedir PAM module
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

print_pam_mkhomedir_config()
{
    echo "Name: Activate mkhomedir"
    echo "Default: yes"
    echo "Priority: 900"
    echo "Session-Type: Additional"
    echo "Session:"
    echo "  required pam_mkhomedir.so umask=0022 skel=/etc/skel"

    return 0
}


# Configures the PAM mkhomedir module
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

configure_pam()
{
    debug "Configure PAM."

    write_to_file "$(print_pam_mkhomedir_config)" "${PAM_MKHOMEDIR_CONFIG_FILE}" || return 1

    "${PAM_AUTH_UPDATE_PATH}" --force --package || return 1

    debug "PAM configured successfully."

    return 0
}


# Prints group name with domain sufffix
# Arguments:
#   1: group name
#   2: domain name
# Returns:
#   0: success
#   1: failure

print_group_fqdn()
{
    local group_name="${1}"
    local domain_name="${2}"

    [[ -z "${group_name}" ]] && return 0
    [[ -z "${domain_name}" ]] && return 0

    if [[ ! "${group_name}" == *@${domain_name} ]] ; then
        group_name="${group_name}@${domain_name}"
    fi

    echo "${group_name}"

    return 0
}


# Check that group exists
# Arguments:
#   1: group name
# Returns:
#   0: group exists
#   1: group does not exists

test_group()
{
    local group_name="${1}"

    local getent_output=""

    [[ -z "${group_name}" ]] && return 0

    debug "Check group: '${group_name}'."

    if ! getent_output="$("${GETENT_PATH}" group "${group_name}")" ; then
        log "$(printf "${E_GROUP_NOT_FOUND}" "${group_name}")"
        return 1
    fi

    debug "Group exists: ${getent_output}."

    return 0
}


# Configures login permissions for groups specified by user
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

configure_login_permissions()
{
    local domain_name="${1}"

    local group_name=""

    [[ -z "${domain_name}" ]] && return 0

    debug "Configure login permissions."

    while : ; do

        read -p "${LOGIN_GROUP_PROMPT}" group_name || break
        [[ -z "${group_name}" ]] && break

        group_name="$(print_lowercase "${group_name}")" || continue
        group_name="$(print_group_fqdn "${group_name}" "${domain_name}")" || continue
        test_group "${group_name}" || continue

        debug "Permit login for group: '${group_name}'."
        "${REALM_PATH}" permit --groups "${group_name}" || continue
        debug "Permitted successfully."

    done

    debug "Login permissions configured successfully."

    return 0
}


# Installs sudo package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_sudo()
{
    test_package "sudo" || install_package "sudo" || return 1

    return 0
}


# Configures sudo permissions for groups specified by user
# Arguments:
#   1: domain name
# Returns:
#   0: success
#   1: failure

configure_sudo_permissions()
{
    local domain_name="${1}"

    [[ -z "${domain_name}" ]] && return 0

    local sudo_config_file="${domain_name}"
    local sudoers_lines=""
    local line=""

    sudo_config_file="$(replace_chars "${sudo_config_file}" "." "_")"
    sudo_config_file="${SUDO_CONFIG_DIR}/${sudo_config_file}"

    debug "Configure sudo permissions."
    debug "Sudoers file: '${sudo_config_file}'."

    while : ; do

        read -p "${SUDO_GROUP_PROMPT}" group_name || break
        [[ -z "${group_name}" ]] && break

        group_name="$(print_lowercase "${group_name}")" || continue

        if is_true "${SSSD_USE_FQDN_NAMES}" ; then
            group_name="$(print_group_fqdn "${group_name}" "${domain_name}")" || continue
        fi

        test_group "${group_name}" || continue

        line="$(replace_string "${group_name}" ' ' '\\ ')"
        line="%${line} ALL=(ALL:ALL) ALL"

        debug "Add line to sudoers file: '${line}'."

        sudoers_lines="$(add_line "${sudoers_lines}" "${line}")"

    done

    write_to_file "${sudoers_lines}" "${sudo_config_file}" || return 1

    chown "root:root" "${sudo_config_file}" || return 1
    chmod '0440' "${sudo_config_file}" || return 1

    stop_service "${SUDO_SERVICE_NAME}" && start_service "${SUDO_SERVICE_NAME}" || return 1

    debug "Sudo permissions configured successfully."

    return 0
}


# Installs openssh-server package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_ssh_server()
{
    test_package "openssh-server" || install_package "openssh-server" || return 1

    return 0
}


# Change value of the parameter in the ssh configuration file
# Arguments:
#   1: path to configuration file
#   2: name of the parameter
#   3: value of the parameter
# Returns:
#   0: success
#   1: failure

set_sshd_config_parameter()
{
    local file_name="${1}"
    local param_name="${2}"
    local param_value="${3}"

    [[ -z "${file_name}" ]] && return 0
    [[ -z "${param_name}" ]] && return 0
    [[ -z "${param_value}" ]] && return 0

    if [[ -f "${file_name}" ]] ; then

        if grep "${param_name} " "${file_name}" | grep -v "^#" &>/dev/null ; then
            debug "Change the value of the existing parameter '${param_name}' to '${param_value}', file: '${file_name}'."
            sed --in-place "/${param_name} .*/ {/^#/! s/${param_name} .*/${param_name} ${param_value}/}" "${file_name}" || return 1
            return 0
        fi

        if grep "${param_name} " "${file_name}" | grep "^#" &>/dev/null; then
            debug "Uncomment and change the value of the parameter '${param_name}' to '${param_value}', file: '${file_name}'."
            sed --in-place --regexp-extended "0,/^# *${param_name} / s/^# *${param_name} .*/${param_name} ${param_value}/" "${file_name}" || return 1
            return 0
        fi

    fi

    debug "Add new parameter '${param_name}' with value '${param_value}', file: '${file_name}'."
    echo -en "\n${param_name} ${param_value}" >>"${file_name}" || return 1

    return 0
}


# Configures GSSAPI for sshd
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

configure_ssh_gssapi()
{
    local os_name="$(print_os_info "name")"
    local os_version="$(print_os_info "version_id")"

    [[ -f "${SSHD_CONFIG_FILE}" ]] || return 0

    debug "Configure SSH GSSAPI."

    debug "Copy file '${SSHD_CONFIG_FILE}' to '${SSHD_TMP_CONFIG_FILE}'."
    cp "${SSHD_CONFIG_FILE}" "${SSHD_TMP_CONFIG_FILE}" || return 1

    set_sshd_config_parameter "${SSHD_TMP_CONFIG_FILE}" "GSSAPIAuthentication" "yes" || return 1
    set_sshd_config_parameter "${SSHD_TMP_CONFIG_FILE}" "GSSAPICleanupCredentials" "yes" || return 1

    if [[ "${os_name}" == "Debian GNU/Linux" ]] && [[ "${os_version}" == 8* ]] ; then

        # < adcli bug description >
        # https://bugs.freedesktop.org/show_bug.cgi?id=84749
        # https://bugzilla.redhat.com/show_bug.cgi?id=1267319
        set_sshd_config_parameter "${SSHD_TMP_CONFIG_FILE}" "GSSAPIStrictAcceptorCheck" "no" || return 1

    else

        # Reset to the default value
        set_sshd_config_parameter "${SSHD_TMP_CONFIG_FILE}" "GSSAPIStrictAcceptorCheck" "yes" || return 1

    fi

    write_to_file "$(cat "${SSHD_TMP_CONFIG_FILE}")" "${SSHD_CONFIG_FILE}" || return 1
    rm "${SSHD_TMP_CONFIG_FILE}"

    stop_service "${SSHD_SERVICE_NAME}" && start_service "${SSHD_SERVICE_NAME}" || return 1

    debug "SSH GSSAPI configured successfully."

    return 0
}


# Installs bash-completion package
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

install_bash_completion()
{
    test_package "bash-completion" || install_package "bash-completion" || return 1

    return 0
}


# Configures auto completion for bash
# Enables auto completion for root's interactive shell
# Arguments:
#   None
# Returns:
#   0: success
#   1: failure

configure_bash_completion()
{
    [[ -f "${BASH_SYSTEM_STARTUP_FILE}" ]] || return 0

    debug "Configure bash completion."

    debug "Copy file '${BASH_SYSTEM_STARTUP_FILE}' to '${BASH_TMP_SYSTEM_STARTUP_FILE}'."
    
    # tr '\n' '\r' join multiple lines at one.
    # sed patterns use '\r' instead of '\n'.
    # tr '\r' '\n' split lines as it was.
    
    cat "${BASH_SYSTEM_STARTUP_FILE}" | tr '\n' '\r' | \
        sed "s/${BASH_COMPLETION_FROM_PATTERN}/${BASH_COMPLETION_TO_PATTERN}/" | \
        tr '\r' '\n' > "${BASH_TMP_SYSTEM_STARTUP_FILE}" || return 1

    write_to_file "$(cat "${BASH_TMP_SYSTEM_STARTUP_FILE}")" "${BASH_SYSTEM_STARTUP_FILE}" || return 1
    rm "${BASH_TMP_SYSTEM_STARTUP_FILE}"

    debug "Bash completion configured successfully."

    return 0
}


# Prints help information to the stdout.
# Arguments:
#   None
# Returns:
#   0: success

print_help()
{
    echo "Usage:"
    echo "  ${PROGNAME} [-hq] [-s hostname] [-d domainname] [-u username]"
    echo ""   
    echo "Configures the environment and joins the machine to the Active Directory domain."
    echo ""
    echo "Options:"
    echo "  -h            Show this message."
    echo "  -q            Suppress debug messages."
    echo "  -s hostname   Specifies available domain controller. Can be specified multiple times."
    echo "  -d domainname Specifies domain name."
    echo "  -u username   Specifies domain user name that will be used for joining to the domain."

    return 0
}


# Main function

main() {

    local domain_name="${DEFAULT_DOMAIN_NAME}"
    local server_list="${DEFAULT_SERVER_LIST}"
    local user_name="${DEFAULT_USER_NAME}"

    local server=""
    local ldap_server_list=""

    while getopts "hqs:d:u:" arg; do
        case "${arg}" in
            h)
                print_help
                exit 0
                ;;
            q)
                DEBUG_ENABLED=0
                ;;
            d)
                domain_name="${OPTARG}"
                ;;
            u)
                user_name="${OPTARG}"
                ;;
            s)
                server="$(lookup_hostname "${OPTARG}")" || exit 1
                server_list="$(add_line "${server_list}" "${server}")"
                ;;
            *)
                eexit "${E_ARGS_INVALID}"
                ;;
        esac
    done
    
    test_root || exit 1
    lock || exit 1
    debug "The ${PROGNAME} script started." || exit 1

    if [[ -z "${domain_name}" ]] ; then
        domain_name="$(print_domain_name)" || exit 1
    fi

    install_dnsutils || exit 1
    test_dns_settings "${domain_name}" || exit 1

    if [[ -z "${server_list}" ]] ; then
        server_list="$(print_domain_controllers "${domain_name}")" || exit 1
    fi

    install_dnsmasq && configure_dnsmasq "${domain_name}" "${server_list}" || exit 1
    test_dns_settings "${domain_name}" || exit 1

    install_ntp || exit 1
    configure_ntp "${server_list}" || exit 1

    install_kerberos && configure_kerberos "${domain_name}" "${server_list}" || exit 1

    user_name="$(init_user_name "${domain_name}" "${user_name}")" || exit 1

    install_realm && install_sssd || exit 1
    ldap_server_list="$(print_ldap_server "${server_list}")" || exit 1
    join_realm "${domain_name}" "${ldap_server_list}" || exit 1

    configure_sssd "${domain_name}" "${ldap_server_list}" || exit 1

    install_pam_modules && configure_pam || exit 1

    configure_login_permissions "${domain_name}" || exit 1
    install_sudo && configure_sudo_permissions "${domain_name}" || exit 1

    install_ssh_server && configure_ssh_gssapi || exit 1
    install_bash_completion && configure_bash_completion || exit 1

    debug "All configuration changes by ${PROGNAME} was finished successfully."

    exit 0
}

main "${@}"