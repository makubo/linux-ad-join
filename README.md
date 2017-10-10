# Join Debian to Active Directory

Bash scripts for interactive joining Debain machines to the Active Directory.

## join-ad-sssd.sh

Joins Debian machine to the Active Directory by using sssd and realmd.

This script configures the environment and joins the machine to the Active Directory domain. To join the domain, used sssd (System Security Services Daemon) and realmd.

realmd discovers information about the domain or realm automatically and does not require complicated configuration in order to join a domain or realm. realmd configures the basic settings of the sssd to do the actual network authentication and user account lookups.

The script configures several subsystems during execution.

- Configures the local DNS cache using dnsmasq. Available DNS servers are automatically detected.
- Configures the local DNS resolver and checks that DNS settings are correct.
- Configures the NTP client and forces synchronization of the system time. Available NTP servers are automatically detected.
- Configures Kerberos. Available KDC servers are automatically detected.
- Configures realmd and joins the machine to the domain using the first available LDAP server. The available LDAP servers are detected automatically.
- Configures sssd, fine tuning after realmd.
- Configures PAM, enables mkhomedir module.
- Configures access to the server (login) using domain groups.
- Configures administrator rights on the server (sudo) using the domain groups.

Bonus:

- Configures SSH and enables GSSAPI for passwordless login.
- Configures autocomplete in bash, enables autocomplete for a interactive root sessions.

#### Command line options

```
Usage:
  join-ad-sssd.sh [-hq] [-s hostname] [-d domainname] [-u username]
 
Options:
  -h            Show this message.
  -q            Suppress debug messages.
  -s hostname   Specifies available domain controller. Can be specified multiple times.
  -d domainname Specifies domain name.
  -u username   Specifies domain user name that will be used for joining to the domain.
```

#### Supported and tested Linux

Debian 8 (jessie)
Debian 9 (stretch)

---

## join-ad-winbind.sh (obsolete)

Joins machine to the domain using Samba and Winbind.

#### Supported Linux

Debian Wheezy and Debian Jessie

#### Tested

Samba 3.6.6 and 4.1.17 (not work with Samba 4.2.10)
