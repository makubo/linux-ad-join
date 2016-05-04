#!/bin/bash

DOMAIN=
ADMIN=
LOGIN_GROUP=
SUDO_GROUP=

SSSD_DEBUG=0
SSSD_USE_FQDN=0
SSSD_MANUAL_SEARCH_DC=1
BACKUP_PATH=~/.join-ad/backup

test_app()
{
	local APPLIST=$@
	
	for APP in $APPLIST; do
		command -v $APP >/dev/null 2>&1
		if [ $? -ne 0 ] ; then
			return 1
		fi
	done
	
	return 0
}

install_app()
{
	local CAPTION=$1
	shift
	local PACKAGE=$@
	
	echo "Install $CAPTION: $PACKAGE."
	
	if [ $APTGET_UPDATE -eq 0 ] ; then
		apt-get update
		if [ $? -ne 0 ] ; then
			echo "apt-get update failed."
			return 1
		fi
		APTGET_UPDATE=1
	fi
	
	apt-get -y install $PACKAGE
	if [ $? -ne 0 ] ; then
		echo "Installation failed."
		return 1
	fi
	
	echo "Installed successful."
	return 0
}

stop_service()
{
	local SERVICE_NAME=$1
	
	echo "Stop service '$SERVICE_NAME'."
	
	service $SERVICE_NAME status >/dev/null 2>&1 && (
		service $SERVICE_NAME stop
		if [ $? -ne 0 ] ; then
			echo "Can not stop the service '$SERVICE_NAME'."
			return 1
		fi
	)
	return 0
}

start_service()
{
	local SERVICE_NAME=$1
	
	echo "Start service '$SERVICE_NAME'."
	
	service $SERVICE_NAME start
	if [ $? -ne 0 ] ; then
		echo "Can not start the service '$SERVICE_NAME'."
		return 1
	fi
	return 0
}

make_path_for_file()
{
	local FILE=$1
	local DIR=$(dirname $FILE)
	
	if [ ! -d "$DIR" ] ; then
		mkdir -p $DIR
	fi
	
	return 0
}

check_root()
{
	if [ $EUID -ne 0 ] ; then
		echo "This script must be run as root."
		return 1
	fi
	return 0
}

prepare_backup_dir()
{
	mkdir -p $BACKUP_PATH
	echo "All modified configuration files will be backuped to the '$BACKUP_PATH'."
	
	return 0
}

setup_domain()
{
	if [ -z "$DOMAIN" ] ; then
		DOMAIN=$(hostname --domain)
		if [ -z "$DOMAIN" ] ; then
			echo "Can not determine a domain name. Check your resolv.conf settings."
			return 1
		fi
	fi
	
	echo "Found domain '$DOMAIN'."
	
	return 0
}

install_dnsutils()
{
	test_app dig nslookup nsupdate || install_app "BIND DNS utils" dnsutils
	return $?
}

check_dns_settings()
{
	local DNS_LDAP_SRV="_ldap._tcp.$DOMAIN"

	echo "Try to resolve domain $DOMAIN."
	getent hosts $DOMAIN
	if [ $? -ne 0 ] ; then
		echo "Domain resolve failed. Check your domain name and DNS settings."
		return 1
	fi
	echo "Resolved successful."
	
	echo "Try to resolve LDAP SRV record '$DNS_LDAP_SRV'."
	
	
	local DIG=$(dig -t SRV "$DNS_LDAP_SRV")
	echo "$DIG" | grep -i 'answer section' >/dev/null 2>&1
	if [ $? -ne 0 ] ; then
		echo "Can not resolve LDAP SRV record. Check that your Active Directory DNS configured properly."
		return 1
	fi
	
	echo "Resolved successful."
	return 0
}
 
install_ntp()
{
	test_app ntpd ntpdate || install_app "NTP client" ntp ntpdate
	return $?
}

write_ntp_config()
{
	local SERVERLIST=$@
	
	echo driftfile /var/lib/ntp/ntp.drift
	echo statistics loopstats peerstats clockstats
	echo filegen loopstats file loopstats type day enable
	echo filegen peerstats file peerstats type day enable
	echo filegen clockstats file clockstats type day enable
	
	for SERVER in $SERVERLIST; do
		echo server $SERVER
	done
	
	echo restrict -4 default kod notrap nomodify nopeer noquery
	echo restrict -6 default kod notrap nomodify nopeer noquery
	echo restrict 127.0.0.1
	echo restrict ::1
	
	return 0
}

configure_ntp()
{
	local NTP_CONFIG_FILE=/etc/ntp.conf
	local NTP_CONFIG_BACKUP=$BACKUP_PATH/ntp.conf
	local NTP_SERVICE_NAME=ntp
	
	echo "Configure NTP client."
	
	DCLIST=$(getent hosts $DOMAIN | awk '{ print $1 }')
	if [ $? -ne 0 ] || [ -z "$DCLIST" ] ; then
		echo "Failed to retrive IP addresses of domain controllers."
		return 1
	fi
	
	NTPLIST=
	while read -r DC ; do
		printf "Check NTP server $DC: "
		ntpdate -p1 -q $DC >/dev/null 2>&1
		if [ $? -eq 0 ] ; then
			if [ -z "$NTPLIST" ] ; then
				NTPLIST="$DC"
			else
				NTPLIST="${NTPLIST}"$'\n'"${DC}"
			fi
			echo 'OK.'
		else
			echo 'failed.'
		fi
	done <<< "$DCLIST"
	if [ -z "$NTPLIST" ] ; then
		echo "There are no NTP servers available."
		return 1
	fi
	
	mv $NTP_CONFIG_FILE $NTP_CONFIG_BACKUP
	if [ $? -ne 0 ] ; then
		echo "Can not move file '$NTP_CONFIG_FILE' to '$NTP_CONFIG_BACKUP'."
		return 1
	fi
	
	write_ntp_config $NTPLIST >$NTP_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not write to file '$NTP_CONFIG_FILE'."
		return 1
	fi
	chown --reference=$NTP_CONFIG_BACKUP $NTP_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not copy file owner from '$NTP_CONFIG_BACKUP' to '$NTP_CONFIG_FILE'."
		return 1
	fi
	chmod --reference=$NTP_CONFIG_BACKUP $NTP_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not copy file permissions from '$NTP_CONFIG_BACKUP' to '$NTP_CONFIG_FILE'."
		return 1
	fi
	
	stop_service $NTP_SERVICE_NAME || return 1
	echo "Sync time."
	ntpd -gq
	if [ $? -ne 0 ] ; then
		echo "Sync time failed."
		return 1
	fi
	echo "Time synchronized successful."
	start_service $NTP_SERVICE_NAME || return 1

	echo "NTP client configured successful."
	return 0
}

install_realm()
{
	test_app realm || install_app "realm" realmd
	return $?
}

install_kerberos()
{
	test_app kinit klist kdestroy || install_app "kerberos utils" krb5-user
}

check_domain()
{
	local DISCOVERY_TRY_COUNT=5
	
	echo "Discovery domain '$DOMAIN'."
	
	local TRY=1
	local DISCOVERY=1
	
	while [ $TRY -le $DISCOVERY_TRY_COUNT ] && [ $DISCOVERY -ne 0 ] ; do
		
		if [ $TRY -gt 1 ] ; then
			echo "Try again. Attempt $TRY from $DISCOVERY_TRY_COUNT."
		fi
		
		realm discover $DOMAIN --verbose
		DISCOVERY=$?
		if [ $DISCOVERY -ne 0 ] ; then
			echo "Discovery failed."
		fi
		
		TRY=$((TRY + 1))
	done
	
	if [ $DISCOVERY -ne 0 ] ; then
		return 1
	fi
	
	echo "Discovery finished successful."
	return 0
}

install_sssd()
{
	test_app sssd adcli || install_app "SSSD" sssd sssd-tools adcli
	return $?
}

setup_admin()
{
	while [ -z "$ADMIN" ] ; do
                printf "Please enter a domain admin login to use: "
                read ADMIN
        done
	
	return 0
}

join_domain()
{
	local TICKET_TRY_COUNT=5
	local JOIN_TRY_COUNT=5
	local DOMAIN_UPPER=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
	
	echo "Try to receive kerberos ticket."
	
	local TRY=1
	local TICKET=1
	
	while [ $TRY -le $TICKET_TRY_COUNT ] && [ $TICKET -ne 0 ] ; do
	
		if [ $TRY -gt 1 ] ; then
			echo "Try again. Attempt $TRY from $JOIN_TRY_COUNT."
		fi
	
		kdestroy -A
		if [ $? -ne 0 ] ; then
			echo "Clear local kerberos tickets cache failed."
			return 1
		fi
	
		kinit -V $ADMIN@$DOMAIN_UPPER && klist
		TICKET=$?
		if [ $TICKET -ne 0 ] ; then
			echo "Failed to receive kerberos ticket."
		fi
		
		TRY=$((TRY + 1))
	done
	
	if [ $TICKET -ne 0 ] ; then
		return 1
	fi
	
	echo "Kerberos ticket received successful."
	
	echo "Join '$HOSTNAME' to domain '$DOMAIN'."
	
	local TRY=1
	local JOIN=1
	
	while [ $TRY -le $JOIN_TRY_COUNT ] && [ $JOIN -ne 0 ] ; do
		
		if [ $TRY -gt 1 ] ; then
			echo "Try again. Attempt $TRY from $JOIN_TRY_COUNT."
		fi
		
		realm join --verbose $DOMAIN
		JOIN=$?
		if [ $JOIN -ne 0 ] ; then
			echo "Join failed."
		fi
		
		TRY=$((TRY + 1))		
	done
	
	if [ $JOIN -ne 0 ] ; then
		return 1
	fi
	
	echo "Joined successful."
	return 0
}

search_domain_controller()
{
	local LOOKUP_COUNT=10
	local PORT_LDAP=389
	
	local IPLIST=
	
	lookup_dc()
	{
		local LOOKUP_COUNT=$1
		local I=1
		
		while [ $I -le $LOOKUP_COUNT ] ; do
			getent hosts $DOMAIN | head -1 | awk '{ print $1 }'
			I=$((I + 1))
		done | sort | uniq
		
		return 0
	}
	
	check_dc_port()
	{
		local PORT=$1
		local CONNECTION_TIMEOUT=5
		
		while read IP ; do
			nc -w 5 -z $IP $PORT >/dev/null 2>&1
			if [ $? -eq 0 ] ; then
				echo "$IP"
			fi
		done
	}
	
	IPLIST=$(lookup_dc $LOOKUP_COUNT | check_dc_port $PORT_LDAP)
	
	while read -r IP ; do
		if [ ! -z "$IP" ] ; then
			getent hosts $IP | awk '{ print $2 }'
		fi
	done <<< "$IPLIST"
	
	return 0
}

write_sssd_config()
{
	local SSSD_LDAP_SEARCH_TIMEOUT=15
	local SSSD_LDAP_NETWORK_TIMEOUT=3

	local DOMAIN_LOWER=$(echo $DOMAIN | tr '[:upper:]' '[:lower:]')
	local DOMAIN_UPPER=$(echo $DOMAIN | tr '[:lower:]' '[:upper:]')
	
	echo [sssd]
	echo domains = $DOMAIN_LOWER
	echo config_file_version = 2
	echo services = nss, pam
	
	if [ ! -z "$SSSD_DEBUG" ] && [ $SSSD_DEBUG -ne 0 ] ; then
		echo debug_level = 7
	fi
	
	echo
	echo [nss]
	
	if [ ! -z "$SSSD_DEBUG" ] && [ $SSSD_DEBUG -ne 0 ] ; then
		echo debug_level = 7
	fi
	
	echo
	echo [pam]
	if [ ! -z "$SSSD_DEBUG" ] && [ $SSSD_DEBUG -ne 0 ] ; then
		echo debug_level = 7
	fi
	
        echo 
	echo [domain/$DOMAIN_LOWER]
	echo ad_domain = $DOMAIN_LOWER
	
	printf "ad_server = "
	if [ ! -z "$SSSD_MANUAL_SEARCH_DC" ] && [ $SSSD_MANUAL_SEARCH_DC -ne 0 ] ; then
		local DCLIST=$(search_domain_controller)
		if [ ! -z "$DCLIST" ] ; then
			while read -r DC ; do
				printf "$DC, "
			done <<< "$DCLIST"
		fi
	fi
	echo _srv_
	
	echo ad_hostname = $(hostname --fqdn)
	echo krb5_realm = $DOMAIN_UPPER
	echo realmd_tags = manages-system joined-with-samba
	echo cache_credentials = True
	echo id_provider = ad
	echo krb5_store_password_if_offline = True
	echo default_shell = /bin/bash
	echo ldap_id_mapping = True
	
	printf "use_fully_qualified_names = "
	if [ ! -z "$SSSD_USE_FQDN" ] && [ $SSSD_USE_FQDN -eq 0 ] ; then
		echo False
	else
		echo True
	fi
	echo fallback_homedir = /home/%d/%u
	if [ ! -z "$SSSD_DEBUG" ] && [ $SSSD_DEBUG -ne 0 ] ; then
		echo debug_level = 7
	fi
	echo access_provider = ad
	
	return 0
}

configure_sssd()
{
	local SSSD_CONFIG_FILE=/etc/sssd/sssd.conf
	local SSSD_CONFIG_BACKUP=$BACKUP_PATH/sssd.conf
	local SSSD_DB_PATH=/var/lib/sss/db
	local SSSD_CACHE_PATH=/var/lib/sss/mc
	local SSSD_LOG_PATH=/var/log/sssd
	local SSSD_SERVICE_NAME=sssd
	local SSSD_SLEEP_AFTER_START=15
	local SSSD_TRY_COUNT=5

	echo "Configure SSSD."
	
	stop_service $SSSD_SERVICE_NAME || return 1
	
	if [ -f $SSSD_CONFIG_FILE ] ; then
		mv $SSSD_CONFIG_FILE $SSSD_CONFIG_BACKUP
		if [ $? -ne 0 ] ; then
			return 1
		fi
	fi
	
	make_path_for_file $SSSD_CONFIG_FILE && write_sssd_config >$SSSD_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not write to file '$SSSD_CONFIG_FILE'."
		return 1
	fi
	
	chown root:root $SSSD_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not change owner for file '$SSSD_CONFIG_FILE'."
		return 1
	fi
	
	chmod 0600 $SSSD_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not change permissions for file '$SSSD_CONFIG_FILE'."
		return 1
	fi
	
	rm -f $SSSD_LOG_PATH/* >/dev/null 2>&1
	
	if [ $SSSD_USE_FQDN -eq 0 ] ; then
		USER=$ADMIN
	else
		USER=$ADMIN@$DOMAIN
	fi
	
	echo "Check passwd for user '$USER'."
	
	local TRY=1
	local GETENT=1
	
	while [ $TRY -le $SSSD_TRY_COUNT ] && [ $GETENT -ne 0 ] ; do
	
		if [ $TRY -eq 1 ] ; then
			start_service $SSSD_SERVICE_NAME || return 1
		else
			echo "Try again. Attempt $TRY from $SSSD_TRY_COUNT."
			stop_service $SSSD_SERVICE_NAME || return 1
			sleep 1
			rm -f $SSSD_DB_PATH/* >/dev/null 2>&1
			rm -f $SSSD_CACHE_PATH/* >/dev/null 2>&1
			start_service $SSSD_SERVICE_NAME || return 1
		fi
		
		if [ $SSSD_SLEEP_AFTER_START -gt 0 ] ; then
			echo "Wait for $SSSD_SLEEP_AFTER_START seconds."
			sleep $SSSD_SLEEP_AFTER_START
		fi
		
		getent passwd $USER && id $USER
		GETENT=$?
		if [ $GETENT -ne 0 ] ; then
			echo "Passwd check failed."
		fi
		
		TRY=$((TRY + 1))
		
	done
	
	if [ $GETENT -ne 0 ] ; then
		return 1
	fi
	
	echo "Checked successful."
	
	echo "SSSD configured successful."
	return 0
}

write_pam_mkhomedir()
{
	echo Name: Activate mkhomedir
	echo Default: yes
	echo Priority: 900
	echo Session-Type: Additional
	echo Session:
	echo         required	pam_mkhomedir.so	umask=0022 skel=/etc/skel
	
	return 0
}

configure_pam()
{
	local PAM_SESSIONS_CONFIG_FILE=/etc/pam.d/common-session
	local PAM_SESSIONS_CONFIG_BACKUP=$BACKUP_PATH/pam.common-session.conf
	local PAM_MKHOMEDIR_CONFIG_FILE=/usr/share/pam-configs/mkhomedir
	
	echo "Configure PAM."
	
	cp $PAM_SESSIONS_CONFIG_FILE $PAM_SESSIONS_CONFIG_BACKUP
	if [ $? -ne 0 ] ; then
		echo "Can not copy file '$PAM_SESSIONS_CONFIG_FILE' to '$PAM_SESSIONS_CONFIG_BACKUP'."
		return 1
	fi
	
	write_pam_mkhomedir >$PAM_MKHOMEDIR_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not write to file '$PAM_MKHOMEDIR_CONFIG_FILE'."
		return 1
	fi
	
	pam-auth-update --force --package
	if [ $? -ne 0 ] ; then
		return "Configure PAM failed."
		return 1
	fi
	
	echo "PAM configured successful."
	return 0
}

configure_login_permissions()
{
	echo "Configure login permissions."
	
	while [ -z "$LOGIN_GROUP" ] ; do
		printf "Please enter a comma separated names of the domain groups that members "
		printf "will be grant the login rights or enter 'all' for all. For example: "
		printf "'domain admins,linux admins'."
		echo
		printf "Login groups: "
		read LOGIN_GROUP
	done
	
	GROUPLIST=$(echo $LOGIN_GROUP | tr '[:upper:]' '[:lower:]' | tr ',' "\n")
	
	realm deny --all
	if [ $? -ne 0 ] ; then
		echo "Can not deny login permissions."
		return 1
	fi
	
	if [ "$GROUPLIST" == 'all' ] ; then
		echo "Permit login for all users."
		realm permit --all
		if [ $? -ne 0 ] ; then
			echo "Configure login permissions failed."
			return 1
		fi
	else
		while read -r GROUP ; do
			printf "Permit login for group '$GROUP@$DOMAIN': "
			realm permit -g "$GROUP@$DOMAIN"
			if [ $? -eq 0 ] ; then
				echo 'OK.'
			else
				echo 'failed.'
				echo "Configure login permissions failed."
				return 1
			fi
		done <<< "$GROUPLIST"
	fi
	
	service sssd restart
	
	echo "Login permissions configured successful."
	return 0
}

install_sudo()
{
	test_app sudo || install_app "sudo" sudo
	return $?
}

configure_sudo_permissions()
{
	local SUDO_CONFIG_PATH=/etc/sudoers.d
	
	local SUDO_CONFIG_FILE=$SUDO_CONFIG_PATH/$(echo $DOMAIN | tr '.' '_')

	echo "Configure sudo permissions."

	while [ -z "$SUDO_GROUP" ] ; do
		printf "Please enter a comma separated names of the domain groups that members "
		printf "will be grant the sudo rights or 'none' for none. For example: "
		printf "'domain admins,linux admins'."
		echo
		printf "Sudo groups: "
		read SUDO_GROUP
	done
	
	GROUPLIST=$(echo $SUDO_GROUP | tr '[:upper:]' '[:lower:]' | tr ',' "\n")
	
	echo -n "" >$SUDO_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not write to file '$SUDO_CONFIG_FILE'."
		return 1
	fi
	
	if [ "$GROUPLIST" == 'none' ] ; then
		echo "Deny sudo permissions for all domain users."
	else
		while read -r GROUP ; do
		
			printf "Permit sudo for group '$GROUP@$DOMAIN': "
			
			GROUP=$(echo $GROUP | sed 's/ /\\ /g')
			if [ ! -z "$SSSD_USE_FQDN" ] && [ $SSSD_USE_FQDN -ne 0 ] ; then
				GROUP="$GROUP@$DOMAIN"
			fi
			
			echo "%$GROUP	ALL=(ALL:ALL) ALL" >>$SUDO_CONFIG_FILE
			if [ $? -eq 0 ] ; then
				echo 'OK.'
			else
				echo 'failed.'
				echo "Configure sudo permissions failed."
				return 1
			fi
		done <<< "$GROUPLIST"
	fi
	
	chown root:root $SUDO_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not change owner for file '$SUDO_CONFIG_FILE'."
		return 1
	fi
	
	chmod 0440 $SUDO_CONFIG_FILE
	if [ $? -ne 0 ] ; then
		echo "Can not change permissions for file '$SUDO_CONFIG_FILE'."
		return 1
	fi
	
	service sudo restart || return 1
	
	echo "Sudo permissions configured successful."
	return 0
}

main ()
{
	APTGET_UPDATE=0

	check_root \
	&& prepare_backup_dir \
	&& setup_domain \
	&& install_dnsutils \
	&& check_dns_settings \
	&& install_ntp \
	&& configure_ntp \
	&& install_realm \
	&& check_domain \
	&& install_sssd \
	&& install_kerberos \
	&& setup_admin \
	&& join_domain \
	&& configure_sssd \
	&& configure_pam \
	&& configure_login_permissions \
	&& install_sudo \
	&& configure_sudo_permissions

	if [ $? -ne 0 ] ; then
		return $?
	fi
	
	echo "All configuration changes by '$0' finished successful."
	
	return $?
}

main
exit $?
