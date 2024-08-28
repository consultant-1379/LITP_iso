#!/bin/bash -a
# ********************************************************************
# Ericsson LMI                                    SCRIPT
# ********************************************************************
#
# (c) Ericsson AB 2013 - All rights reserved.
#
# The copyright to the computer program(s) herein is the property
# of Ericsson AB. The programs may be used and/or copied only with
# the written permission from Ericsson AB or in accordance with the
# terms and conditions stipulated in the agreement/contract under
# which the program(s) have been# supplied.
#
# ********************************************************************
# Name    : installer.sh
# Date    : 20/11/2013
# Revision:
# Purpose : Cache Litp/3PP packages from LITP iso image and install LITP RPM's via yum group install
# Author  : Kevin Griffin
#
# ********************************************************************

# VARIABLES
BASE_PATH=$(dirname "$(readlink -f "$0")")
DVDMNT=$(dirname $BASE_PATH)
REPODIR=/var/www/html
LITP_PATH=/opt/ericsson/nms/litp/
INSTALL_DATE_FILE=${LITP_PATH}.upgrade.history
LITP_VERSION_FILE=.version
LITP_RELEASE_FILE=/etc/litp-release
LITP_GROUP="LITP2"
LITP_ADMIN=litp-admin
PASSWD='$1$XxjmaPai$N9eWwy6OJCe/xJT0ZFSrC/'
PASSWD_FILE=/etc/passwd
SYSLOG=/var/log/messages
SYSLOG_CONF=/etc/rsyslog.conf


_CP=/bin/cp
_CUT=/bin/cut
_CAT=/bin/cat
_CREATEREPO=/usr/bin/createrepo
_DATE=/bin/date
_FIND=/bin/find
_GREP=/bin/grep
_MKDIR=/bin/mkdir
_RM=/bin/rm
_RPM=/bin/rpm
_TOUCH=/bin/touch
_YUM=/usr/bin/yum
_EGREP=/bin/egrep
_SETFACL=/usr/bin/setfacl
_CHAGE=/usr/bin/chage
_USERADD=/usr/sbin/useradd
_SYSTEMCTL=/usr/bin/systemctl
_TAR=/bin/tar
_LN=/bin/ln
_MCO=/usr/bin/mco
_PUPPET=/usr/bin/puppet


# FUNCTIONS

log() {
    logger "LITP Installer: $*"
}

error() {
    echo "LITP Installation failure: $*"
    logger "LITP Installation failure: $*"
    echo "Error. Please consult the logs at /var/log/messages for further troubleshooting."
    exit 1
}

#
# Check the local RPM DB for the existence of an RPM. This function
# just prints the result so be sure to check for a non-empty string
# when calling
#
check_rpm_installed() {
    RPM=$1
    $_RPM -qa | $_GREP ${RPM}
}

#
# Install an RPM if not already installed.
#
install_rpm() {
    REPO=$1
    RPM=$2
    if [ -z "$(check_rpm_installed ${RPM})" ] ; then
        log "installing ${RPM}"
        RPMFILES=$($_FIND ${REPO} -type f | $_GREP ${RPM})
        [ -z "${RPMFILES}" ] && error "Could not find any RPMs called ${RPM} in ${REPO}"
        for rpmfile in ${RPMFILES} ; do
            $_RPM -i ${rpmfile}
            [ $? -ne 0 ] && error "Could not install ${RPM}"
        done
    fi
}

create_repo() {
    THIS_REPO=$1
    log "creating Yum repository in ${THIS_REPO}"
    $_CREATEREPO ${THIS_REPO} || error "Could not create a repository in ${THIS_REPO}"
}

#
# copy the LITP RPMs into the local repository
#
cache_litp_rpms() {
    log "caching LITP RPMs"
    $_MKDIR -p $REPODIR >/dev/null 2>&1 || error "Could not create repository base directory ${REPODIR}"
    $_MKDIR -p $REPODIR/litp >/dev/null 2>&1 || error "Could not create repository directory ${REPODIR}/litp"
    semanage fcontext -a -t httpd_sys_content_t $REPODIR/litp
    restorecon -v $REPODIR/litp
    $_CP -ra $DVDMNT/litp/plugins/* $REPODIR/litp || error "Could not copy LITP RPMs to ${REPODIR}"
    create_repo ${REPODIR}/litp
    $_MKDIR -p $REPODIR/litp_plugins >/dev/null 2>&1 || error "Could not create repository directory ${REPODIR}/litp_plugins"
    create_repo ${REPODIR}/litp_plugins
    RHEL_MAJOR_VER=$(sed 's/.*release //' /etc/redhat-release | awk '{split($1,ver,"."); print ver[1]}')
    REPODIR_3PP="${REPODIR}/3pp_rhel${RHEL_MAJOR_VER}"
    if [ -d ${DVDMNT}/litp/3pp ] ; then
        # cache the 3PPs as well
        $_MKDIR -p ${REPODIR_3PP} >/dev/null 2>&1 || error "Could not create repository directory ${REPODIR}/3pp"
        semanage fcontext -a -t httpd_sys_content_t ${REPODIR_3PP}
        restorecon -v ${REPODIR_3PP}
        $_CP -ra ${DVDMNT}/litp/3pp/* ${REPODIR_3PP} || error "Could not copy 3PP RPMs to ${REPODIR_3PP}"
        create_repo ${REPODIR_3PP}
    else
        [ ! -d ${REPODIR_3PP} ] && error "There are no 3PPs on the ISO, and none on your system. You must make sure you have the required 3PP packages available prior to install"
    fi

    create_comps_xml ${REPODIR_3PP}
    $_CREATEREPO -g comps.xml $REPODIR/litp || error "Could not create LITP2 groups"
}

#
# Install LITP
#
install_litp() {
    log "Installing LITP"
    $_YUM -y groupinstall ${LITP_GROUP} --disableplugin=post-transaction-actions || error "Could not install LITP group ${LITP_GROUP}"
}

#
# Restart LITP
#
restart_litp() {
    log "Restarting LITP"
    $_SYSTEMCTL restart litpd.service || error "Could not restart LITP service"
}


# Add litp-admin
add_litp_user() {
    $_EGREP ${LITP_ADMIN} ${PASSWD_FILE} >/dev/null
    if [ $? -eq 0 ]; then
        logger "Litp-admin already exists "
        return 1
    else
        log "Adding litp-admin user"
        $_USERADD -m -p ${PASSWD} ${LITP_ADMIN}
        $_CHAGE -d 0 ${LITP_ADMIN}
        $_SETFACL -m u:${LITP_ADMIN}:r ${SYSLOG}
    fi
}

# Is the package to be installed on MS
is_pkg_for_ms_install() {

    pkg=$1

    exclude_pkgs_from_install=(
        "ERIClitpdocs_CXP9030557" \
        "ERIClitpmnlibvirt_CXP9031529" \
        "EXTRlitprsyslogelasticsearch_CXP9032173" \
        "EXTRlitprsysloggnutls_CXP9032174" \
        "EXTRlitprsyslogmmanon_CXP9032175" \
        "EXTRlitprsyslogmmfields_CXP9032176" \
        "EXTRlitprsyslogmmjsonparse_CXP9032177" \
        "EXTRlitprsyslogmmutf8fix_CXP9032178" \
        "EXTRlitprsyslogmysql_CXP9032179" \
        "EXTRlitprsyslogommail_CXP9032180" \
        "EXTRlitprsyslogpgsql_CXP9032181" \
        "EXTRlitprsyslogpmciscoios_CXP9032182" \
        "EXTRlitprsyslogrelp_CXP9032183" \
        "EXTRlitprsyslogsnmp_CXP9032184" \
        "EXTRlitprsyslogudpspoof_CXP9032185" \
        "EXTRlitprsyslog_CXP9032140" \
        "EXTRlitpliblogging_CXP9032141" \
        "EXTRlitpcelery_CXP9032834" \
        "EXTRlitppuppetinifile_CXP9032828" \
        "EXTRlitppuppetpostgresql_CXP9032827" \
        "EXTRlitppuppetpuppetdb_CXP9032830" \
        "EXTRlitppythonalembic_CXP9032831" \
        "EXTRlitppythonamqp_CXP9032835" \
        "EXTRlitppythonanyjson_CXP9032836" \
        "EXTRlitppythonbilliard_CXP9032837" \
        "EXTRlitppythoneditor_CXP9032833" \
        "EXTRlitppythonimportlib_CXP9032838" \
        "EXTRlitppythonkombu_CXP9032839" \
        "EXTRlitppythonmako_CXP9032832" \
        "EXTRlitppythonsqlalchemy_CXP9032518" \
        "EXTRlitppuppetdb_CXP9032594" \
        "EXTRlitppuppetdbterminus_CXP9032595" \
        "EXTRlitppythonpsycopg2_CXP9032522" \
        "EXTRlitplibfastjson_CXP9037929")

    for litp_pkg in ${exclude_pkgs_from_install[*]}
    do
        if [ "${pkg}" == "${litp_pkg}" ];
        then
            log "Not installing ${pkg}"
            return 1
        fi
    done

    log "Installing ${pkg}"
    echo ${pkg}
    return 0
}

# create comps.xml in /var/www/html/litp
create_comps_xml() {
    REPODIR_3PP=$1
    log "creating comps file from cached litp packages"
    cd $REPODIR/litp
    HEADER='<?xml version='\''1.0'\'' encoding='\''UTF-8'\''?>
<!DOCTYPE comps PUBLIC "-//Ericsson, Ltd.//DTD Comps info//EN" "comps.dtd">
<comps>
  <group>
    <id>litp-rpms</id>
    <name>LITP2</name>
    <description>LITP provided packages</description>
    <default>false</default>
    <uservisible>true</uservisible>
    <packagelist>'

$_CAT > $REPODIR/litp/comps.xml << EOF
$HEADER
EOF

for PKG in ERIClitp*; do
        PKG_CUT=$(echo $PKG | $_CUT -f1 -d-)
        PKG_INSTALL=$(is_pkg_for_ms_install $PKG_CUT)
        if [ -n "$PKG_INSTALL" ]; then
             $_CAT >> $REPODIR/litp/comps.xml << EOF
        <packagereq type='mandatory'>$PKG_CUT</packagereq>
EOF
         fi
    done

cd ${REPODIR_3PP}
for PKG in EXTRlitp*; do
        PKG_CUT=$(echo $PKG | $_CUT -f1 -d-)
        PKG_INSTALL=$(is_pkg_for_ms_install $PKG_CUT)
        if [ -n "$PKG_INSTALL" ]; then
            $_CAT >> $REPODIR/litp/comps.xml << EOF
        <packagereq type='mandatory'>$PKG_CUT</packagereq>
EOF
        fi
    done

     FOOTER='</packagelist>
  </group>
</comps>'

    $_CAT >> $REPODIR/litp/comps.xml << EOF
    $FOOTER
EOF

}

# Remove rate-limit form syslog
remove_rate_limit() {

    log "removing rate-limit from syslog"
    if [[ -z $($_GREP SystemLogRateLimitInterval $SYSLOG_CONF) ]] ; then
        echo -e "\$SystemLogRateLimitInterval 0" >> $SYSLOG_CONF
    fi
    if [[ -z $($_GREP SystemLogRateLimitBurst $SYSLOG_CONF) ]] ; then
        echo -e "\$SystemLogRateLimitBurst 0\n" >> $SYSLOG_CONF
    fi
}


wait_for_mcollective() {
    log "Ensuring mcollective has restarted"
    echo "Ensuring mcollective has restarted"
    let maxLoops=180 timeToSleep=1
    for (( try=0; try < $maxLoops; ++try )); do
        $_MCO ping | grep -i " replies max" >/dev/null 2>&1
        (( $? == 0 )) && break
        sleep $timeToSleep
    done
    $_SYSTEMCTL status mcollective.service >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log "mcollective failed to restart"
        echo "mcollective failed to restart"
        return 1
    fi
    log 'mcollective has restarted'
    echo "mcollective has restarted"
    return 0
}

check_service_status() {
    APP=$1
    log "Ensuring $APP has restarted"
    echo "Ensuring $APP has restarted"
    $_SYSTEMCTL status ${APP}.service >/dev/null 2>&1
    STATUS=$?
    if [ $STATUS -ne 0 ]; then
        log "$APP failed to restart"
        echo "$APP failed to restart"
        return 1
    else
        log "$APP has restarted"
        echo "$APP has restarted"
        return 0
    fi
}

#
# Create release info based on ${LITP_VERSION_FILE} file from the ISO root directory
#
create_release_info() {
    $_CP -f "${DVDMNT}/${LITP_VERSION_FILE}" "${LITP_RELEASE_FILE}"
}

start_puppet_and_check_rabbitmq() {
# avoid clashes with the daemon. This way the foreground run will be the only
# running puppet instance

# TORF-379065: puppetdb might have not started, retry
$_SYSTEMCTL status puppetdb.service >/dev/null 2>&1
if [ $? -ne 0 ]; then
    log "Found puppetdb startup problem. Restarting puppetdb to fix it"
    $_SYSTEMCTL restart puppetdb.service
fi

$_SYSTEMCTL stop puppet.service
# Run puppet once to setup rabbitmq and mcollective.
for i in {1..3};
do
    $_PUPPET agent --server $(hostname) --onetime --ignorecache --no-daemonize --no-usecacheonfailure --no-splay
    ret=$?
    if [ $ret -eq 0 ]; then
        log "Foreground Puppet run succeeded"
        break
    fi
    log "Attempt $i/3 to run Puppet on the foreground failed"
    if [ $i -eq 3 ]; then
        error "Cannot run Puppet. Please retry running the installer"
    fi
    sleep 10
done

# LITPCDS-12343: rabbitmq might have not started, retry
$_SYSTEMCTL status rabbitmq-server.service >/dev/null 2>&1
if [ $? -ne 0 ]; then
    log "Found RabbitMQ startup problem. Restarting RabbitMQ to fix it"
    $_SYSTEMCTL restart rabbitmq-server.service
fi

$_SYSTEMCTL start puppet.service
}

# BODY

#Commencement
log "Starting the Linux IT Platform (LITP) installation."
echo "Starting the Linux IT Platform (LITP) installation."

#Prerequisites
log "LITP Installation: Step 1/5 - Installation Prerequisites"
echo "LITP Installation: Step 1/5 - Installation Prerequisites."
install_rpm ${DVDMNT}/litp/3pp yum-plugin-post-transaction-actions
install_rpm ${DVDMNT}/litp/plugins ERIClitpcfg_CXP9030421

#Preparation
log "LITP Installation: Step 2/5 - Preparing Files."
echo "LITP Installation: Step 2/5 - Preparing Files."
create_release_info
cache_litp_rpms

#Permissions
log "LITP Installation: Step 3/5 - Setting Permissions."
echo "LITP Installation: Step 3/5 - Setting Permissions."

add_litp_user
remove_rate_limit

#Installing
log "LITP Installation: Step 4/5 - Installing."
echo "LITP Installation: Step 4/5 - Installing."
install_litp

$_SYSTEMCTL stop puppet.service

log "Installing Firefox, xauth, dejavu-sans-fonts, mesa-libGL"
$_YUM install -y mesa-libGL xorg-x11-xauth firefox dejavu-sans-fonts

#Check services
log "LITP Installation: Step 5/5 - Check services."
echo "LITP Installation: Step 5/5 - Check services."

start_puppet_and_check_rabbitmq
check_service_status httpd
httpd_status=$?
check_service_status puppet
puppet_status=$?
wait_for_mcollective
mcollective_status=$?
restart_litp

if [ $httpd_status -ne 0 ] || [ $puppet_status -ne 0 ] || [ $mcollective_status -ne 0 ] ; then
    log "LITP installation has failed as it found the following service(s) not running: "
    echo "LITP installation has failed as it found the following service(s) not running: "
    if [ $httpd_status -ne 0 ] ; then
         log " * Httpd "
         echo " * Httpd "
    fi
    if [ $puppet_status -ne 0 ] ; then
         log " * Puppet"
         echo " * Puppet "
    fi
    if [ $mcollective_status -ne 0 ] ; then
         log " * Mcollective "
         echo " * Mcollective "
    fi
    log " Error. Please consult the logs at var/log/messages for further troubleshooting. "
    echo " Error. Please consult the logs at var/log/messages for further troubleshooting. "
    exit 1
fi

log "LITP has been successfully installed."
log "Please consult the official LITP documentation or run the \"litp -h\" command for help with the LITP cli."
echo "LITP has been successfully installed."
echo "Please consult the official LITP documentation or run the \"litp -h\" command for help with the LITP cli."


exit 0