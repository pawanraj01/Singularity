#!/bin/bash
# ============================================================
#   SINGULARITY MAIL + LDAP SERVER SETUP  (v3 - LDAP fully fixed)
#   Project  : SIH26117 - Team Aristarchus
#   Domain   : singularity.local
#   Services : OpenLDAP + Postfix + Dovecot + OpenDKIM + Roundcube
#   Auth     : OpenLDAP -> Dovecot passdb/userdb + Postfix
# ============================================================

# ---------- COLORS ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------- HELPERS ----------
info()    { echo -e "${CYAN}  [i] $*${NC}"; }
success() { echo -e "${GREEN}  [OK] $*${NC}"; }
warn()    { echo -e "${YELLOW}  [!] $*${NC}"; }
error()   { echo -e "${RED}  [X] $*${NC}"; }
step()    { echo -e "\n${BOLD}${BLUE}[$1] $2${NC}"; }
divider() { echo -e "${DIM}  ----------------------------------------------------------${NC}"; }
blank()   { echo ""; }

spin() {
  local pid=$1 msg=$2
  local chars='|/-\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % 4 ))
    printf "\r${CYAN}  [%s] %s${NC}" "${chars:$i:1}" "$msg"
    sleep 0.15
  done
  printf "\r"
}

die() {
  error "$1"
  blank
  error "Setup FAILED. See errors above."
  blank
  exit 1
}

# ---------- CONFIG ----------
DOMAIN="singularity.local"
NETWORK_NAME="singularity-mail-net"
LDAP_BASE_DN="dc=singularity,dc=local"
LDAP_ADMIN_DN="cn=admin,dc=singularity,dc=local"
LDAP_ADMIN_PW="LdapAdmin@1234"
LDAP_ORG="Singularity"
USER_PASSWORD='activ8*o'

DMS_IMAGE="mailserver/docker-mailserver:latest"

LDAP_DIR="$HOME/docker/ldap"
MAIL_DIR="$HOME/docker/mailserver"
ROUNDCUBE_DIR="$HOME/docker/roundcube"
TMP_DIR="$(mktemp -d)"

ACCOUNTS=(
  "admin@singularity.local|admin|Admin|User|10001"
  "manager@singularity.local|manager|Manager|User|10002"
  "pranav.vasankar@singularity.local|pranav.vasankar|Pranav|Vasankar|10003"
  "pawanraj-gavande@singularity.local|pawanraj-gavande|Pawanraj|Gavande|10004"
)

cleanup_tmp() { rm -rf "$TMP_DIR"; }
trap cleanup_tmp EXIT

# ---------- PREFLIGHT ----------
if docker info >/dev/null 2>&1; then
  DC="docker"
elif sudo docker info >/dev/null 2>&1; then
  DC="sudo docker"
else
  die "Docker not reachable. Is Docker installed and running?"
fi

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$HOST_IP" ] && HOST_IP="127.0.0.1"

# ============================================================
# BANNER
# ============================================================
clear
echo -e "${BOLD}${BLUE}"
echo "  +==========================================================+"
echo "  |                                                          |"
echo "  |        SINGULARITY  -  MAIL + LDAP SERVER SETUP          |"
echo "  |              SIH26117 . Team Aristarchus                 |"
echo "  |                                                          |"
echo "  +==========================================================+"
echo -e "${NC}"

echo -e "${BOLD}  Project   :${NC} Sovereign On-Premise Agentic AI Workbench"
echo -e "${BOLD}  Domain    :${NC} $DOMAIN"
echo -e "${BOLD}  Services  :${NC} OpenLDAP . Postfix . Dovecot . OpenDKIM . Roundcube"
echo -e "${BOLD}  Host IP   :${NC} $HOST_IP"
echo -e "${BOLD}  User home :${NC} $HOME/docker/"
blank
divider

echo -e "\n${BOLD}  Services that will be deployed:${NC}"
echo -e "  ${CYAN}*${NC} OpenLDAP       - central user directory   (port 389)"
echo -e "  ${CYAN}*${NC} phpLDAPadmin   - LDAP web UI              (port 8081)"
echo -e "  ${CYAN}*${NC} Postfix        - SMTP mail transfer       (25, 587, 465)"
echo -e "  ${CYAN}*${NC} Dovecot        - IMAP mailbox server      (143, 993)"
echo -e "  ${CYAN}*${NC} OpenDKIM       - email signing            (internal)"
echo -e "  ${CYAN}*${NC} Roundcube      - browser webmail UI       (port 8080)"
blank
divider

echo -e "\n${BOLD}  Email accounts to be created:${NC}"
echo -e "  ${DIM}(all with password: $USER_PASSWORD)${NC}"
for ACC in "${ACCOUNTS[@]}"; do
  echo -e "  ${GREEN}->${NC} ${ACC%%|*}"
done
blank
divider

echo -e "\n${YELLOW}  WARNING: This will DELETE and recreate:${NC}"
echo -e "  ${RED}x${NC} $LDAP_DIR"
echo -e "  ${RED}x${NC} $MAIL_DIR"
echo -e "  ${RED}x${NC} $ROUNDCUBE_DIR"
blank
read -r -p "  Continue with setup? [y/N]: " ANS
[[ "$ANS" =~ ^[Yy]$ ]] || { warn "Aborted by user."; exit 0; }

# ============================================================
step "1/9" "Cleaning previous state"
# ============================================================
divider
info "Stopping and removing old containers..."
for CNAME in openldap phpldapadmin mailserver roundcube; do
  if $DC ps -a --format '{{.Names}}' | grep -q "^${CNAME}$"; then
    $DC rm -f "$CNAME" >/dev/null 2>&1
    success "Removed container: $CNAME"
  else
    info "Container not found (skip): $CNAME"
  fi
done

info "Removing old network..."
if $DC network rm "$NETWORK_NAME" >/dev/null 2>&1; then
  success "Network removed: $NETWORK_NAME"
else
  info "Network not found (skip)"
fi

info "Deleting old data directories..."
sudo rm -rf "$LDAP_DIR" "$MAIL_DIR" "$ROUNDCUBE_DIR" 2>/dev/null
success "Data directories cleared."
success "Step 1 complete."

# ============================================================
step "2/9" "Creating Docker network and directory structure"
# ============================================================
divider
info "Creating Docker bridge network: $NETWORK_NAME"
$DC network create "$NETWORK_NAME" >/dev/null \
  && success "Network created." \
  || die "Failed to create Docker network."

info "Creating directory structure..."
mkdir -p \
  "$LDAP_DIR/ldap" "$LDAP_DIR/slapd.d" \
  "$MAIL_DIR/data" "$MAIL_DIR/state" "$MAIL_DIR/logs" \
  "$MAIL_DIR/config/ssl/demoCA" \
  "$MAIL_DIR/config/opendkim/keys/$DOMAIN" \
  "$ROUNDCUBE_DIR"

sudo chown "$USER":"$USER" "$HOME/docker" -R 2>/dev/null || true
success "Directories created:"
echo -e "  ${DIM}$LDAP_DIR/{ldap,slapd.d}${NC}"
echo -e "  ${DIM}$MAIL_DIR/{data,state,logs,config}${NC}"
echo -e "  ${DIM}$ROUNDCUBE_DIR${NC}"
success "Step 2 complete."

# ============================================================
step "3/9" "Starting OpenLDAP + phpLDAPadmin"
# ============================================================
divider
info "Pulling OpenLDAP image (osixia/openldap:1.5.0)..."
$DC pull osixia/openldap:1.5.0 >/dev/null 2>&1 &
spin $! "Downloading osixia/openldap:1.5.0..."
success "Image ready."

info "Starting OpenLDAP container..."
$DC run -d \
  --name=openldap \
  --hostname="ldap.$DOMAIN" \
  --network="$NETWORK_NAME" \
  --network-alias="ldap" \
  -p 389:389 -p 636:636 \
  -e LDAP_ORGANISATION="$LDAP_ORG" \
  -e LDAP_DOMAIN="$DOMAIN" \
  -e LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_PW" \
  -e LDAP_CONFIG_PASSWORD="config123" \
  -e LDAP_TLS_VERIFY_CLIENT="never" \
  -v "$LDAP_DIR/ldap":/var/lib/ldap \
  -v "$LDAP_DIR/slapd.d":/etc/ldap/slapd.d \
  --restart=unless-stopped \
  osixia/openldap:1.5.0 >/dev/null \
  || die "Failed to start OpenLDAP container."

info "Waiting 20s for OpenLDAP to fully initialize..."
for i in $(seq 1 20); do
  sleep 1
  printf "\r${CYAN}  [.] Waiting... ${i}/20s${NC}"
done
blank
success "OpenLDAP initialized."

info "Starting phpLDAPadmin..."
$DC pull osixia/phpldapadmin:0.9.0 >/dev/null 2>&1 &
spin $! "Downloading osixia/phpldapadmin:0.9.0..."

$DC run -d \
  --name=phpldapadmin \
  --network="$NETWORK_NAME" \
  -p 8081:80 \
  -e PHPLDAPADMIN_LDAP_HOSTS=ldap \
  -e PHPLDAPADMIN_HTTPS=false \
  --restart=unless-stopped \
  osixia/phpldapadmin:0.9.0 >/dev/null \
  || die "Failed to start phpLDAPadmin."
success "phpLDAPadmin started."

info "Building LDAP user LDIF..."
cat > "$TMP_DIR/users.ldif" << EOF
dn: ou=people,$LDAP_BASE_DN
objectClass: organizationalUnit
ou: people
EOF

for ACC in "${ACCOUNTS[@]}"; do
  IFS='|' read -r EMAIL UVAL CN SN UNUM <<< "$ACC"
  cat >> "$TMP_DIR/users.ldif" << EOF

dn: uid=$UVAL,ou=people,$LDAP_BASE_DN
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: top
cn: $CN $SN
sn: $SN
givenName: $CN
displayName: $CN $SN
uid: $UVAL
uidNumber: $UNUM
gidNumber: 5000
homeDirectory: /var/mail/$DOMAIN/$UVAL
mail: $EMAIL
userPassword: $USER_PASSWORD
EOF
done

info "Copying LDIF into container and adding users..."
$DC cp "$TMP_DIR/users.ldif" openldap:/tmp/users.ldif >/dev/null
ADD_OUT=$($DC exec openldap ldapadd -x \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" \
  -f /tmp/users.ldif 2>&1)

if echo "$ADD_OUT" | grep -q "adding new entry"; then
  success "LDAP users seeded successfully."
elif echo "$ADD_OUT" | grep -qi "already exists"; then
  warn "Some entries already existed - continuing."
else
  error "LDAP add output:"
  echo "$ADD_OUT"
  die "Failed to seed LDAP users."
fi

blank
info "Verifying LDAP directory contents:"
$DC exec openldap ldapsearch -x -LLL \
  -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PW" \
  -b "ou=people,$LDAP_BASE_DN" uid mail 2>/dev/null \
  | grep -E "^(dn|uid|mail):" \
  | sed 's/^/    /'
blank
success "Step 3 complete - LDAP running on port 389."

# ============================================================
step "4/9" "Generating SSL Certificates (self-signed, 10 years)"
# ============================================================
divider
info "Generating RSA 2048 private key + self-signed certificate..."
openssl req -newkey rsa:2048 -x509 -nodes -days 3650 \
  -keyout "$MAIL_DIR/config/ssl/mail.$DOMAIN-key.pem" \
  -out    "$MAIL_DIR/config/ssl/mail.$DOMAIN-cert.pem" \
  -subj "/C=IN/ST=Maharashtra/L=Pune/O=Singularity/CN=mail.$DOMAIN" 2>/dev/null \
  || die "SSL cert generation failed."

cp "$MAIL_DIR/config/ssl/mail.$DOMAIN-cert.pem" \
   "$MAIL_DIR/config/ssl/demoCA/cacert.pem"

success "SSL certificate:   $MAIL_DIR/config/ssl/mail.$DOMAIN-cert.pem"
success "SSL private key:   $MAIL_DIR/config/ssl/mail.$DOMAIN-key.pem"
success "CA certificate:    $MAIL_DIR/config/ssl/demoCA/cacert.pem"
success "Step 4 complete."

# ============================================================
step "5/9" "Generating OpenDKIM Keys"
# ============================================================
divider
info "Generating DKIM RSA 2048 key pair for domain: $DOMAIN"
openssl genrsa \
  -out "$MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.private" 2048 2>/dev/null \
  || die "DKIM key generation failed."
openssl rsa \
  -in  "$MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.private" \
  -pubout \
  -out "$MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.public" 2>/dev/null

info "Writing DKIM configuration files..."
echo "mail._domainkey.$DOMAIN $DOMAIN:mail:/etc/opendkim/keys/$DOMAIN/mail.private" \
  > "$MAIL_DIR/config/opendkim/KeyTable"
echo "*@$DOMAIN mail._domainkey.$DOMAIN" \
  > "$MAIL_DIR/config/opendkim/SigningTable"

cat > "$MAIL_DIR/config/opendkim/TrustedHosts" << EOF
127.0.0.1
localhost
$DOMAIN
mail.$DOMAIN
172.16.0.0/12
192.168.0.0/16
10.0.0.0/8
EOF

chmod 600 "$MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.private" 2>/dev/null
chmod 644 "$MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.public"  2>/dev/null
chmod 644 "$MAIL_DIR/config/opendkim/KeyTable"                  2>/dev/null
chmod 644 "$MAIL_DIR/config/opendkim/SigningTable"              2>/dev/null
chmod 644 "$MAIL_DIR/config/opendkim/TrustedHosts"              2>/dev/null
sudo chown -R 101:101 "$MAIL_DIR/config/opendkim/" 2>/dev/null || true

success "DKIM private key:  $MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.private"
success "DKIM public key:   $MAIL_DIR/config/opendkim/keys/$DOMAIN/mail.public"
success "Step 5 complete."

# ============================================================
step "6/9" "Writing Roundcube SSL override (self-signed trust)"
# ============================================================
divider
info "Writing Roundcube SSL override config..."
cat > "$ROUNDCUBE_DIR/zz-self-signed.inc.php" << 'EOF'
<?php
$config['imap_conn_options'] = [
  'ssl' => [
    'verify_peer'       => false,
    'verify_peer_name'  => false,
    'allow_self_signed' => true,
  ],
];
$config['smtp_conn_options'] = [
  'ssl' => [
    'verify_peer'       => false,
    'verify_peer_name'  => false,
    'allow_self_signed' => true,
  ],
];
EOF
success "Roundcube SSL override written: $ROUNDCUBE_DIR/zz-self-signed.inc.php"
success "Step 6 complete."

# ============================================================
step "7/9" "Writing mailserver.env (LDAP provisioner - COMPLETE FIX)"
# ============================================================
divider
info "Writing $MAIL_DIR/mailserver.env ..."

# FIXES APPLIED:
# 1. LDAP_SERVER_HOST now includes ldap:// scheme + port (Dovecot 2.4 requirement)
# 2. Added DOVECOT_USER_FILTER / DOVECOT_PASS_FILTER (Dovecot needs these separately
#    from Postfix's LDAP_QUERY_FILTER_USER - that is why "No passdb_ldap_filter given")
# 3. Added DOVECOT_USER_ATTRS / DOVECOT_PASS_ATTRS to map our posixAccount schema
#    (homeDirectory, uidNumber, gidNumber) instead of the assumed postfix-book schema

cat > "$MAIL_DIR/mailserver.env" << EOF
OVERRIDE_HOSTNAME=mail.$DOMAIN

# ---------- Account provisioner: LDAP ----------
ACCOUNT_PROVISIONER=LDAP

# LDAP connection (scheme REQUIRED in Dovecot 2.4)
LDAP_SERVER_HOST=ldap://ldap:389
LDAP_SEARCH_BASE=ou=people,$LDAP_BASE_DN
LDAP_BIND_DN=$LDAP_ADMIN_DN
LDAP_BIND_PW=$LDAP_ADMIN_PW
LDAP_START_TLS=no

# ---------- Postfix LDAP filters (uses %s placeholder) ----------
LDAP_QUERY_FILTER_USER=(&(objectClass=inetOrgPerson)(mail=%s))
LDAP_QUERY_FILTER_ALIAS=(&(objectClass=inetOrgPerson)(mail=%s))
LDAP_QUERY_FILTER_GROUP=(&(objectClass=inetOrgPerson)(mail=%s))
LDAP_QUERY_FILTER_DOMAIN=(&(objectClass=inetOrgPerson)(mail=%s))

# ---------- Dovecot LDAP filters (uses %u placeholder) ----------
# Without these, Dovecot logs: "No passdb_ldap_filter given"
DOVECOT_USER_FILTER=(&(objectClass=inetOrgPerson)(mail=%u))
DOVECOT_PASS_FILTER=(&(objectClass=inetOrgPerson)(mail=%u))

# ---------- Dovecot attribute mapping (posixAccount schema) ----------
# Default DMS expects postfix-book schema; we override for our LDIF
DOVECOT_USER_ATTRS=homeDirectory=home,uidNumber=uid,gidNumber=gid,mail=mail
DOVECOT_PASS_ATTRS=mail=user,userPassword=password

# ---------- Postfix / Dovecot runtime ----------
POSTFIX_INET_PROTOCOLS=ipv4
POSTFIX_MAILBOX_SIZE_LIMIT=0
POSTFIX_MESSAGE_SIZE_LIMIT=52428800
DOVECOT_INET_PROTOCOLS=ipv4
DOVECOT_DISABLE_PLAINTEXT_AUTH=no

# ---------- General ----------
ONE_DIR=1
SSL_TYPE=self-signed
ENABLE_SASLAUTHD=0
ENABLE_SPAMASSASSIN=0
SPAMASSASSIN_SPAM_TO_INBOX=0
ENABLE_CLAMAV=0
ENABLE_POSTGREY=0
ENABLE_RSPAMD=0
ENABLE_FAIL2BAN=0
ENABLE_OPENDKIM=1
ENABLE_OPENDMARC=0
ENABLE_QUOTAS=0
SPOOF_PROTECTION=0

LOG_LEVEL=info
SUPERVISOR_LOGLEVEL=warn
PERMIT_DOCKER=network
EOF

success "mailserver.env written with DOVECOT_* filters and attribute mappings."
success "Step 7 complete."

# ============================================================
step "8/9" "Starting Mailserver (Postfix + Dovecot + OpenDKIM)"
# ============================================================
divider
info "Pulling mailserver image ($DMS_IMAGE)..."
$DC pull "$DMS_IMAGE" >/dev/null 2>&1 &
spin $! "Downloading docker-mailserver image..."
success "Image ready."

info "Starting mailserver container..."
$DC run -d \
  --name=mailserver \
  --hostname="mail.$DOMAIN" \
  --network="$NETWORK_NAME" \
  --network-alias="mailserver" \
  --network-alias="mail.$DOMAIN" \
  -p 25:25 \
  -p 143:143 \
  -p 465:465 \
  -p 587:587 \
  -p 993:993 \
  --env-file="$MAIL_DIR/mailserver.env" \
  -v "$MAIL_DIR/data/":/var/mail/ \
  -v "$MAIL_DIR/state/":/var/mail-state/ \
  -v "$MAIL_DIR/logs/":/var/log/mail/ \
  -v "$MAIL_DIR/config/":/tmp/docker-mailserver/ \
  -v /etc/localtime:/etc/localtime:ro \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_PTRACE \
  --security-opt no-new-privileges:false \
  --restart=unless-stopped \
  "$DMS_IMAGE" >/dev/null \
  || die "Failed to start mailserver container."

success "Mailserver container started."

info "Waiting for healthcheck (up to 3 minutes)..."
HEALTHY=0
for i in $(seq 1 60); do
  STATUS=$($DC inspect --format='{{.State.Health.Status}}' mailserver 2>/dev/null || echo "unknown")
  printf "\r${CYAN}  [.] Status: %-12s [%ds / 180s]${NC}" "$STATUS" "$((i*3))"
  if [ "$STATUS" = "healthy" ]; then
    HEALTHY=1
    blank
    success "Container healthy after $((i*3)) seconds."
    break
  fi
  sleep 3
done
blank

if [ "$HEALTHY" -eq 0 ]; then
  warn "Container did not reach 'healthy' in 3 minutes."
  warn "Current status: $($DC inspect --format='{{.State.Health.Status}}' mailserver 2>/dev/null)"
  warn "Continuing anyway - container may still be starting up."
  info "Last 10 log lines:"
  $DC logs --tail 10 mailserver 2>&1 | sed 's/^/    /'
  blank
fi

# ---------- Verify LDAP auth is actually working ----------
info "Testing LDAP authentication (admin@$DOMAIN)..."
sleep 8
AUTH_TEST=$($DC exec mailserver doveadm auth test "admin@$DOMAIN" "$USER_PASSWORD" 2>&1)
if echo "$AUTH_TEST" | grep -qi "auth succeeded"; then
  success "LDAP auth: WORKING"
else
  warn "LDAP auth test did not succeed yet."
  warn "Output: $AUTH_TEST"
  info "Checking Dovecot LDAP config inside container..."
  $DC exec mailserver grep -E 'passdb_ldap_filter|userdb_ldap_filter|uris' \
    /etc/dovecot/dovecot-ldap.conf.ext 2>/dev/null \
    | sed 's/^/    /' || true
  info "Recent auth/ldap log lines:"
  $DC exec mailserver tail -n 20 /var/log/mail/mail.log 2>/dev/null \
    | grep -i 'auth\|ldap' | sed 's/^/    /' || true
fi
blank

success "Step 8 complete - Postfix + Dovecot + OpenDKIM running."

# ============================================================
step "9/9" "Starting Roundcube webmail"
# ============================================================
divider
info "Pulling Roundcube image..."
$DC pull roundcube/roundcubemail:latest >/dev/null 2>&1 &
spin $! "Downloading roundcube/roundcubemail:latest..."
success "Image ready."

info "Starting Roundcube webmail container..."
$DC run -d \
  --name=roundcube \
  --network="$NETWORK_NAME" \
  -p 8080:80 \
  -e ROUNDCUBEMAIL_DEFAULT_HOST=ssl://mailserver \
  -e ROUNDCUBEMAIL_DEFAULT_PORT=993 \
  -e ROUNDCUBEMAIL_SMTP_SERVER=tls://mailserver \
  -e ROUNDCUBEMAIL_SMTP_PORT=587 \
  -e ROUNDCUBEMAIL_SMTP_USER=%u \
  -e ROUNDCUBEMAIL_SMTP_PASS=%p \
  -e ROUNDCUBEMAIL_SKIN=elastic \
  -e ROUNDCUBEMAIL_PLUGINS=archive,zipdownload \
  -e ROUNDCUBEMAIL_DB_TYPE=sqlite \
  -v "$ROUNDCUBE_DIR/zz-self-signed.inc.php":/var/roundcube/config/zz-self-signed.inc.php:ro \
  --restart=unless-stopped \
  roundcube/roundcubemail:latest >/dev/null \
  || die "Failed to start Roundcube container."

info "Waiting 15s for Roundcube to initialize..."
for i in $(seq 1 15); do
  sleep 1
  printf "\r${CYAN}  [.] Waiting... ${i}/15s${NC}"
done
blank
success "Roundcube started."
success "Step 9 complete."

# ============================================================
# FINAL VERIFICATION
# ============================================================
blank
echo -e "${BOLD}${BLUE}"
echo "  +==========================================================+"
echo "  |                    SETUP  COMPLETE  [OK]                 |"
echo "  +==========================================================+"
echo -e "${NC}"

echo -e "${BOLD}  Container Status:${NC}"
divider
$DC ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
  | grep -E "NAMES|openldap|phpldapadmin|mailserver|roundcube" \
  | sed 's/^/    /'
blank

echo -e "${BOLD}  Port Status:${NC}"
divider
for PORT in 25 143 389 465 587 993 8080 8081; do
  if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
    exec 3<&- 2>/dev/null
    echo -e "  ${GREEN}[OK]${NC} Port ${BOLD}$PORT${NC} - LISTENING"
  else
    echo -e "  ${RED}[--]${NC} Port ${BOLD}$PORT${NC} - not listening"
  fi
done
blank

echo -e "${BOLD}  Service URLs (localhost):${NC}"
divider
echo -e "  ${CYAN}*${NC}  Roundcube Webmail   : ${BOLD}http://localhost:8080${NC}"
echo -e "  ${CYAN}*${NC}  phpLDAPadmin        : ${BOLD}http://localhost:8081${NC}"
blank
echo -e "${BOLD}  Service URLs (LAN):${NC}"
divider
echo -e "  ${CYAN}*${NC}  Roundcube Webmail   : ${BOLD}http://$HOST_IP:8080${NC}"
echo -e "  ${CYAN}*${NC}  phpLDAPadmin        : ${BOLD}http://$HOST_IP:8081${NC}"
blank

echo -e "${BOLD}  phpLDAPadmin Login:${NC}"
divider
echo -e "  ${CYAN}DN       :${NC} $LDAP_ADMIN_DN"
echo -e "  ${CYAN}Password :${NC} $LDAP_ADMIN_PW"
blank

echo -e "${BOLD}  Email Accounts - Login Credentials for Roundcube:${NC}"
divider
printf "  ${BOLD}%-42s %-18s %-10s${NC}\n" "Email Address" "Password" "Role"
printf "  ${DIM}%-42s %-18s %-10s${NC}\n" "-------------" "--------" "----"
for ACC in "${ACCOUNTS[@]}"; do
  IFS='|' read -r EMAIL UVAL CN SN UNUM <<< "$ACC"
  ROLE="User"
  [[ "$UVAL" == "admin"   ]] && ROLE="Admin"
  [[ "$UVAL" == "manager" ]] && ROLE="Manager"
  printf "  ${GREEN}%-42s${NC} ${YELLOW}%-18s${NC} ${CYAN}%-10s${NC}\n" \
    "$EMAIL" "$USER_PASSWORD" "$ROLE"
done
blank

echo -e "${BOLD}  SMTP / IMAP Settings (for other mail clients):${NC}"
divider
echo -e "  ${CYAN}IMAP Host    :${NC} $HOST_IP   ${DIM}(or localhost)${NC}"
echo -e "  ${CYAN}IMAP Port    :${NC} 993 (SSL) / 143 (STARTTLS)"
echo -e "  ${CYAN}SMTP Host    :${NC} $HOST_IP"
echo -e "  ${CYAN}SMTP Port    :${NC} 587 (STARTTLS) / 465 (SSL)"
echo -e "  ${CYAN}Auth         :${NC} Normal password (email address as username)"
blank

echo -e "${BOLD}  Quick Commands:${NC}"
divider
echo -e "  ${DIM}# Test LDAP auth${NC}"
echo -e "  docker exec -it mailserver doveadm auth test admin@$DOMAIN '$USER_PASSWORD'"
blank
echo -e "  ${DIM}# Check Dovecot LDAP filters${NC}"
echo -e "  docker exec -it mailserver grep -E 'passdb_ldap_filter|userdb_ldap_filter' /etc/dovecot/dovecot-ldap.conf.ext"
blank
echo -e "  ${DIM}# Check Dovecot auth log${NC}"
echo -e "  docker exec -it mailserver tail -f /var/log/mail/mail.log | grep -i auth"
blank
echo -e "  ${DIM}# Send test email${NC}"
echo -e "  docker exec -it mailserver bash -c \"echo Test | sendmail -f admin@$DOMAIN manager@$DOMAIN\""
blank
echo -e "  ${DIM}# Stop / Start all services${NC}"
echo -e "  docker stop  mailserver roundcube openldap phpldapadmin"
echo -e "  docker start openldap mailserver roundcube phpldapadmin"
blank

divider
echo -e "${BOLD}${GREEN}  Open your browser and go to: http://localhost:8080${NC}"
echo -e "${DIM}  Login with any email above using password: $USER_PASSWORD${NC}"
divider
blank
read -r -p "  Press Enter to exit..."
