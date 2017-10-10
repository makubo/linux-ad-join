#!/bin/bash

# You can use this script on your own risk

VERFILE=/etc/debian_version
DEPENDENCIES="sudo samba krb5-user winbind libnss-winbind libpam-winbind ntp bash-completion"
PACKAGES="" # list of not installed packages

# Configs backup directory
BACKUPDIR=~/.ADCONNECT/

# Configuration files location
SMBCNF=/etc/samba/smb.conf
KRBCNF=/etc/krb5.conf
NSSWITCHCNF=/etc/nsswitch.conf
PAMAUTHCNF=/etc/pam.d/common-auth
PAMSESSCNF=/etc/pam.d/common-session
SUDOCNF=/etc/pam.d/sudo
SUDOERS=/etc/sudoers

CONFIGS="$SMBCNF $KRBCNF $NSSWITCHCNF $PAMAUTHCNF $PAMSESSCNF $SUDOCNF $SUDOERS"
UNFCONF="" # list of unfounded configs

if [[ $USER != "root" ]]; then
	echo -e "[\033[31mWARN\033[m] Script needs root privileges!"
	exit
fi

if [ -f $VERFILE ]; then
	VERSION=$(sed 's/\..*//' $VERFILE)
fi

case $VERSION in
	7)
		OSNAME="Debian Wheezy"
		OSVER="Debian $(cat $VERFILE), Linux kernel $(uname -r)"
		echo -e "\033[1;37mNow we try to connect your \033[33mWheezy \033[1;37mto AD\033[m"
	;;
	8)
		OSNAME="Debian Jessie"
		OSVER="Debian $(cat $VERFILE), Linux kernel $(uname -r)"
		echo -e "\033[1;37mNow we try to connect your \033[33mJessie\033[1;37m to AD\033[m"
	;;
	*)
		echo -e "\033[1;37mThis is \033[31munsupported\033[1;37m version of Linux\033[m"
		echo Stoping script...
		exit
	;;
esac

echo -e "\nCheck packages installation:"

# Check installed packages
for i in $DEPENDENCIES
do
	CHECK=$(dpkg-query -f '\${binary:Package}\n' -W | grep ${i} -c)
	if [[ $CHECK != 0 ]]; then
		echo -e "[ \033[32mOK\033[m ] \033[33m$i\033[m is installed"
	else
		echo -e "[\033[31mWARN\033[m] \033[33m$i\033[m is not installed"
		PACKAGES="$PACKAGES $i"
	fi
done

#PACKAGES=" "

if [[ $PACKAGES != "" ]]; then
	echo ""
	echo -e "Packages for instalation: \033[33m$PACKAGES\033[m"

	TRY=0
	while true ; do
		read -erp "Do You want to install it? [Yes/No]: "
		case $REPLY  in
			[Yy]|[Yy][Ee]|[Yy][Ee][Ss] )
				apt-get update
				DEBIAN_FRONTEND=noninteractive apt-get -y install $PACKAGES
				break
			;;
			[Nn]|[Nn][Oo] )
				echo Stoping script...
				exit
			;;
			* )
				echo "Please answer \"Yes\" or \"No\"".
			;;
		esac
	done
fi

echo -e "\nCheck config files:"

for i in $CONFIGS
do
	if [ -e $i ]; then
		echo -e "[ \033[32mOK\033[m ] \033[33m$i\033[m is exist"
	else
		echo -e "[\033[31mWARN\033[m] \033[33m$i\033[m is not exist"
		UNFCONF="$UNFCONF $i"
	fi
done

if [[ $UNFCONF != "" ]]; then
	echo Please recover configuration files:
	for i in $UNFCONF
	do
		echo -e "\t$UNFCONF"
	done
	echo Stoping script...
	exit
fi

# Setting bash_completion for root

COMPLETITION=$(grep -c ". /etc/bash_completion" /root/.bashrc)

if [ $COMPLETITION == 0 ]; then
	echo -e "if [ -f /etc/bash_completion ]; then\n\t. /etc/bash_completion\nfi" >> /root/.bashrc
fi

# Backup config files

test -d $BACKUPDIR || mkdir -p $BACKUPDIR

echo ""
echo "Check of existing config's backups:"

EXBACKUP=0 # number of exist backups

for i in $CONFIGS
do
	BACKUPFILE="$BACKUPDIR$(echo $i | sed 's/.*\///').BACK"
	if [ -e $BACKUPFILE ] ; then
		echo -e "[ \033[33mEX\033[m ] \033[33m$BACKUPFILE\033[m is exist"
		let EXBACKUP+=1
	else
		echo -e "[ \033[32mOK\033[m ] \033[33m$BACKUPFILE\033[m is not exist"
	fi
done

if [ $EXBACKUP -gt 0 ] ; then
	while true ; do
	read -erp "Some backup files was found. Do you want to rewrite it? [Yes/No]: "
	case $REPLY in
		[Yy]|[Yy][Ee]|[Yy][Ee][Ss] )
			# OK exit loop and resume script
			break
		;;
		[Nn]|[Nn][Oo] )
			# Stop script
			echo Stoping script...
			exit
		;;
		* )
			echo "Please answer \"Yes\" or \"No\"".
		;;
		esac
	done
fi

echo "Backuping configs..."
for i in $CONFIGS
do
	cp $i "$BACKUPDIR$(echo $i | sed 's/.*\///').BACK"
done

cp /etc/resolv.conf "${BACKUPDIR}resolv.conf.BACK"

# Set domain
while true ; do
read -erp "Please enter your domain name: "
	# regex get from http://myregexp.com/examples.html
	if [[ $REPLY =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}$ ]]; then
		DOMAIN=${REPLY^^}
		WORKGROUP=$(echo  $DOMAIN | sed 's/\..*//')
		SERVER=${DOMAIN,,}
		break
	else
		echo "Wrong domain format ($REPLY), please try again!"
		#exit
	fi
done

# Check resolving domain
while true ; do
	host ${DOMAIN,,} >/dev/null 2>&1
	if [[ $? != "0" ]]; then
		echo "Can't resolve ${DOMAIN,,}"
	#	http://www.regextester.com/22
	#	^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$
		read -erp "Please enter your domain DNS IP address: "
		if [[ $REPLY =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]; then
			echo nameserver $REPLY > /etc/resolv.conf
			host ${DOMAIN,,} >/dev/null 2>&1
			if [[ $? == "0" ]]; then
				DNSS=$(host ${DOMAIN,,} | grep "has address" | sed 's/.*\shas\saddress\s//')
				echo domain $DOMAIN > /etc/resolv.conf
				echo search ${DOMAIN,,} >> /etc/resolv.conf
				for i in $DNSS ; do
					nslookup ${DOMAIN,,} $i > /dev/null 2>&1
					if [[ $? == "0" ]]; then
						echo $i
						echo "nameserver ${i}" >> /etc/resolv.conf
					fi
				done

				while true ; do
					read -erp "This is a your real DNS servers? [Yes/No]: "
					case $REPLY  in
					[Yy]|[Yy][Ee]|[Yy][Ee][Ss] )
						echo OK thanks.
						break
					;;
					[Nn]|[Nn][Oo] )
						while true ; do
							read -erp "Please write your DNS servers's IP separeted by space or coma(,): "
							# check list of IP adresses
							if [[ $REPLY =~ ^((((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])),?[ ]{0,}){1,}((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])))|((([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5]))$ ]]; then
								echo domain ${DOMAIN,,} > /etc/resolv.conf
								echo search ${DOMAIN,,} >> /etc/resolv.conf
								DNSS=$(echo $REPLY | sed 's/,\s*\|\s/ /g')
								for i in $DNSS ; do
									nslookup $DOMAIN $i > /dev/null 2>&1
									if [[ $? == "0" ]]; then
										echo $i
										echo "nameserver ${i}" >> /etc/resolv.conf
									fi
								done
								host ${DOMAIN,,} >/dev/null 2>&1
								if [[ $? != "0" ]]; then
									echo -e "[\033[31mWARN\033[m] Cant resolve ${DOMAIN,,}. Please check your network connection"
								else
									break
								fi
							else
								echo Wrong format. Try again.
							fi
						done
					;;
					* )
						echo "Please answer \"Yes\" or \"No\"".
					;;
					esac
				done
			fi
		else
			echo You write not valid IP address!
		fi
	else
		break
	fi
done

# Edit /etc/hosts

if [ $(grep -c -e "^[^#]*${HOSTNAME}" /etc/hosts) -gt 0 ]; then
	#echo 1 #DEBUG
	if [ $(grep -c -e "^[^#]*${HOSTNAME}.${DOMAIN,,}" /etc/hosts) == 0 ]; then
		HOSTTEXT=$(grep -e "^[^#]*${HOSTNAME}" /etc/hosts)
		#echo 1.1 #DEBUG
		sed -i "s/^[^#]*${HOSTNAME}/${HOSTTEXT} $HOSTNAME.${DOMAIN,,}/" /etc/hosts
	fi
else
	HOSTSTR=$(grep -n -e '^\s*127.0.1.1' /etc/hosts | sed 's/:.*//')
	HOSTTEXT=$(grep -e '^\s*127.0.1.1' /etc/hosts)
	#echo 2 #DEBUG
	if [[ $HOSTSTR != 0 ]] && [[ $HOSTTEXT != "" ]]; then
		sed -i '/^\s*127.0.1.1/d' /etc/hosts
		sed -i "${HOSTSTR}i${HOSTTEXT} $HOSTNAME $HOSTNAME.${DOMAIN,,}" /etc/hosts
		#echo 2.1 #DEBUG
	else
		#echo 2.2 #DEBUG
		if [[ $(grep -c -e '^\s*127.0.0.1' /etc/hosts) != 0 ]]; then
			#echo 2.2.1 #DEBUG
			HOSTSTR=$(grep -n -e '^\s*127.0.0.1' /etc/hosts | sed 's/:.*//')
			let HOSTSTR+=1
			sed -i "${HOSTSTR}i127.0.1.1\t$HOSTNAME $HOSTNAME.${DOMAIN,,}" /etc/hosts
		else
			#echo 2.2.2 #DEBUG
			sed -i "1i127.0.0.1\tlocalhost\n127.0.1.1\t$HOSTNAME $HOSTNAME.${DOMAIN,,}" /etc/hosts
#			echo 127.0.0.1 string not found in /etc/hosts file.
		fi
	fi
fi

if [[ $(grep -c -e '^\s*127.0.0.1' /etc/hosts) == 0 ]]; then
	#echo 3 #DEBUG
	sed -i "1i127.0.0.1\tlocalhost" /etc/hosts
fi

# Edit smb config

STARTSTR=$(grep -n '#======================= Global Settings =======================' $SMBCNF | sed 's/:.*//')
ENDSTR=$(grep -n '#======================= Share Definitions =======================' $SMBCNF | sed 's/:.*//')

#echo $STARTSTR
#echo $ENDSTR

if [[ $STARTSTR != "" ]] && [[ $ENDSTR != "" ]]; then
	sed -i '/#======================= Global Settings =======================/,/#======================= Share Definitions =======================/d' $SMBCNF
	ABRACADABRA="#======================= Global Settings =======================\n\n[global]\n\tsecurity = ads\n\tname resolve order = wins bcast host\n\trealm = ${DOMAIN}\n\tpassword server = ${SERVER}\n\tworkgroup = ${WORKGROUP}\n\n\twinbind refresh tickets = yes\n\twinbind enum users = yes\n\twinbind enum groups = yes\n\twinbind use default domain = yes\n\twinbind nss info = template\n\twinbind cache time = 10800\n\twinbind offline logon = true\n\n\tidmap config * : backend = tdb\n\tidmap config * : range = 2000-9999\n\n\tidmap config ${WORKGROUP}:backend = rid\n\tidmap config ${WORKGROUP}:range = 10000-99999\n\n\ttemplate homedir = /home/%U\n\ttemplate shell = /bin/bash\n\n\tclient use spnego = yes\n\tclient ntlmv2 auth = yes\n\tclient ldap sasl wrapping = seal\n\n\tencrypt passwords = yes\n\n\trestrict anonymous = 2\n\n\tdomain master = no\n\tlocal master = no\n\tpreferred master = no\n\tos level = 0\n\n\tload printers = no\n\tprinting = bsd\n\tprintcap name = /dev/null\n\n#======================= Share Definitions ======================="
	sed -i "${STARTSTR}i${ABRACADABRA}" $SMBCNF
else
	echo Key string not found. Process was stopped on samba configuration.
	echo Stoping script...
	exit
fi

# Edit krb config

sed -i "/^\sdefault_realm/ s/default_realm.*$/default_realm = ${DOMAIN}/" $KRBCNF

# Edit nsswitch config

sed -i 's/^\s*passwd:.*/passwd:	 compat winbind/' $NSSWITCHCNF
sed -i 's/^\s*group:.*/group:	  compat winbind/' $NSSWITCHCNF
sed -i 's/^\s*shadow:.*/shadow:	 compat winbind/' $NSSWITCHCNF

case $VERSION in
	7)
		service winbind stop
		service samba restart
		service winbind start
	;;
	8)
		service winbind stop
		service smbd restart
		service winbind start
	;;
	*)
		echo -e "This is \033[31munsupported\033[m version of Linux"
		echo Stoping script...
		exit
	;;
esac

sleep 0.5

while true ; do
read -erp "Please enter your domain administrator login: "
	if [[ $REPLY =~ ^[a-zA-Z0-9\.\-]{0,}$ ]]; then
		net ads join -U ${REPLY}@${DOMAIN} osname="${OSNAME}" osver="${OSVER}"
		break
	else
		echo Wrong username
	fi
done

case $VERSION in
	7)
		service winbind stop
		service samba restart
		service winbind start
	;;
	8)
		service winbind stop
		service smbd restart
		service winbind start
	;;
	*)
		echo -e "This is \033[31munsupported\033[m version of Linux"
		echo Stoping script...
		exit
	;;
esac

sleep 0.5

# Configure pam and sudoers

if [ $(getent group | grep "domain users" -c) -gt 0 ]; then
	echo -e "[ \033[32mOK\033[m ] Computer was connected to domain."
	while true ; do
		read -erp "Do you whant to specify group or user for domain authorization? [Yes/No]: "
		case $REPLY  in
		[Yy]|[Yy][Ee]|[Yy][Ee][Ss] )
			while true ; do
				read -erp "Please type AD group or user name: "
				GROUP=${REPLY,,}
				WBINFO=$(wbinfo -n "$REPLY")
				if [[ $? == 0 ]] ; then
					SID=$(echo $WBINFO | awk '{ print $1 }')

					AUTH="# ${SID} - \"$GROUP\"\nauth    [success=1 default=ignore]      pam_winbind.so krb5_auth krb5_ccache_type=FILE cached_login try_first_pass require_membership_of=$SID"
					echo -e $AUTH
					sed -i "s/^\s*auth\s*\[success=1 default=ignore\]\s*pam_winbind.so\skrb5_auth\skrb5_ccache_type=FILE.*$/${AUTH}/" $PAMAUTHCNF

					break
				else
					echo "Please try again"
				fi
			done
			break
		;;
		[Nn]|[Nn][Oo] )
			break
		;;
		* )
			echo "Please answer \"Yes\" or \"No\"".
		;;
		esac
	done

	if [[ $(grep -e "^session\s*required\s*pam_mkhomedir.so" $PAMSESSCNF) == "" ]]; then
		sed -i "s/session\s*required\s*pam_unix.so/session\trequired\t\t\tpam_unix.so\nsession\trequired\t\t\tpam_mkhomedir.so/"  $PAMSESSCNF
	fi

	if [[ $( grep -e "#@include common-session-noninteractive" $SUDOCNF) == "" ]]; then
		sed -i "s/^\@include\scommon-session-noninteractive/\#\@include\scommon-session-noninteractive/" $SUDOCNF
	fi

	while true ; do
		read -erp "Please type user or AD group witch can use sudo: "
		case $(wbinfo -n "${REPLY}") in
		*SID_USER* )
			USER=${REPLY,,}
			SUDO="# \"$USER\" user from AD\n$(echo $USER | sed 's/\s/\\ /g') ALL=(ALL:ALL) ALL"
			echo -e $SUDO > /etc/sudoers.d/AD
			break
		;;
		*SID_DOM_GROUP* )
			GROUP=${REPLY,,}
			SUDO="# \"$GROUP\" group from AD\n%$(echo $GROUP | sed 's/\s/\\ /g') ALL=(ALL:ALL) ALL"
			echo -e $SUDO > /etc/sudoers.d/AD
			break
		;;
		* )
			echo "Please try again"
		;;
		esac
	done
else
	echo -e "[\033[31mWARN\033[m] Computer was not connected to domain. Something going wrong."
	echo Stoping script...
	exit
fi

echo Finish!

exit
