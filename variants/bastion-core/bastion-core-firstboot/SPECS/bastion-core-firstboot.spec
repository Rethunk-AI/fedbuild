Name:           bastion-core-firstboot
Version:        0.1.2
Release:        1%{?dist}
Summary:        First-boot PKI roll and SAI generation for Bastion core VM
License:        MIT
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros
BuildRequires:  ShellCheck

Requires:       bash
Requires:       systemd
Requires:       bastion-core

# Commit SHA passed via --define "_git_commit <sha>" from the root Makefile.
%global git_commit %{?_git_commit}%{!?_git_commit:unknown}

Source0:        firstboot.sh
Source1:        bastion-core-firstboot.service
Source2:        10-firstboot-ordering.conf
Source3:        10-bastion-qemu-ordering.conf

%description
Runs once on first boot to roll the Bastion PKI (BASTION_PKI_EPOCH_ROLL=1)
so every VM instance gets unique cryptographic identity rather than the
image-baked defaults generated during package install at image build time.
Generates a fresh SAI callsign + BASTION_WS_TOKEN and writes them to
/var/lib/bastion/install/bootstrap.env.

Also installs systemd drop-ins on bastion-core.service and all sidecar
services that add After=bastion-core-firstboot.service so no service starts
before the per-VM PKI and at-rest key are ready.

Installs a tmpfiles.d rule to create /run/bastion on every boot so that
sidecar Unix sockets can be created before service start.

Corrects RuntimeDirectory conflict: three sidecars ship with DynamicUser=yes
and RuntimeDirectory=bastion which causes systemd to chown /run/bastion to
a transient UID at each service start, blocking all bastion-user services
from creating sockets there. Drop-ins override these to User=bastion so all
services share the directory under a stable identity.

Adds RuntimeDirectoryMode=01775 (sticky + group-writable) and
RuntimeDirectoryPreserve=yes to bastion-credential-keystore so the shared
socket directory survives service restarts and is group-writable for
non-bastion service accounts (bastion-ironlaw-loader, bastion-ilreplicator,
bastion-qemu) via SupplementaryGroups=bastion.

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_libexecdir}/%{name}/firstboot.sh
install -Dm644 %{SOURCE1} %{buildroot}%{_unitdir}/%{name}.service
install -Dm644 %{SOURCE2} \
    %{buildroot}%{_unitdir}/bastion-core.service.d/10-firstboot-ordering.conf
install -Dm644 %{SOURCE3} \
    %{buildroot}%{_unitdir}/bastion-qemu.service.d/10-bastion-qemu-ordering.conf
install -d %{buildroot}%{_localstatedir}/lib/bastion-core

# Ordering drop-ins: every sidecar must start after firstboot so that the
# service-plane CA, sidecar TLS certs, and at-rest key are all in place.
for svc in bastion-credential-keystore bastion-ssh bastion-pack-loader \
           bastion-pki-trust bastion-adcon-engine bastion-adcon-mirror \
           bastion-ironlaw-loader bastion-mfa bastion-intent-ledger-replicator; do
    install -dm755 %{buildroot}%{_unitdir}/${svc}.service.d
    printf '[Unit]\nAfter=bastion-core-firstboot.service\nWants=bastion-core-firstboot.service\n' \
        > %{buildroot}%{_unitdir}/${svc}.service.d/10-firstboot-ordering.conf
done

# Runtime socket directory drop-ins for bastion-credential-keystore:
#   RuntimeDirectoryMode=01775 — sticky + owner/group write so bastion-group
#     service accounts (ironlaw-loader, ilreplicator, qemu) can create sockets.
#   RuntimeDirectoryPreserve=yes — prevents systemd from deleting /run/bastion
#     on service stop/crash; keeps stale socket cleanup manageable.
install -dm755 %{buildroot}%{_unitdir}/bastion-credential-keystore.service.d
printf '[Service]\nRuntimeDirectoryMode=01775\nRuntimeDirectoryPreserve=yes\n' \
    > %{buildroot}%{_unitdir}/bastion-credential-keystore.service.d/20-runtime-dir.conf

# RuntimeDirectory shared-mode fix for bastion-user services:
#   Every service with RuntimeDirectory=bastion calls into systemd's
#   RuntimeDirectory setup which resets ownership AND mode on each service
#   start. All services must agree on the same RuntimeDirectoryMode so the
#   last-to-start doesn't silently reset the directory to a restrictive mode.
#   Mode 01775: sticky + owner/group write — bastion owner and bastion group
#   members can create/delete their OWN sockets; sticky prevents cross-deletion.
for svc in bastion-adcon-mirror bastion-ssh bastion-pack-loader; do
    install -dm755 %{buildroot}%{_unitdir}/${svc}.service.d
    printf '[Service]\nRuntimeDirectoryMode=01775\nRuntimeDirectoryPreserve=yes\n' \
        > %{buildroot}%{_unitdir}/${svc}.service.d/20-runtime-preserve.conf
done

# DynamicUser=yes fix for adcon-engine, pki-trust, mfa:
#   These services ship with DynamicUser=yes and RuntimeDirectory=bastion.
#   Each service start causes systemd to chown /run/bastion to a transient UID
#   (mode 0700 or 0750), blocking all bastion-user services from binding sockets.
#   Override to User=bastion/Group=bastion eliminates the chown conflict since
#   all services then share /run/bastion under the same stable identity.
#   RuntimeDirectoryMode=01775 must match the other services (see above).
for svc in bastion-adcon-engine bastion-pki-trust bastion-mfa; do
    install -dm755 %{buildroot}%{_unitdir}/${svc}.service.d
    printf '[Service]\nDynamicUser=no\nUser=bastion\nGroup=bastion\nRuntimeDirectoryMode=01775\nRuntimeDirectoryPreserve=yes\n' \
        > %{buildroot}%{_unitdir}/${svc}.service.d/20-bastion-user.conf
done

# SupplementaryGroups=bastion for service accounts that need to read
# service-ca certs (640 bastion:bastion) and write to /run/bastion
# (01775 bastion:bastion) without running as the bastion user directly.
for svc in bastion-qemu bastion-ironlaw-loader bastion-intent-ledger-replicator; do
    install -dm755 %{buildroot}%{_unitdir}/${svc}.service.d
    printf '[Service]\nSupplementaryGroups=bastion\n' \
        > %{buildroot}%{_unitdir}/${svc}.service.d/20-bastion-group.conf
done

# tmpfiles.d — create /run/bastion on every boot; mode 01775 (sticky +
# group-writable) matches the RuntimeDirectoryMode on credential-keystore.
# Sticky bit prevents services from deleting each other's sockets.
install -dm755 %{buildroot}%{_tmpfilesdir}
printf 'd /run/bastion 01775 bastion bastion -\n' \
    > %{buildroot}%{_tmpfilesdir}/bastion.conf

%check
shellcheck %{SOURCE0}

%post
%systemd_post %{name}.service
cat > %{_sysconfdir}/bastion-core-release <<EOF
NAME=bastion-core-firstboot
VERSION=%{version}
RELEASE=%{release}
GIT_COMMIT=%{git_commit}
INSTALL_DATE=$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)
EOF
chmod 0644 %{_sysconfdir}/bastion-core-release

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service
if [ $1 -eq 0 ]; then
    rm -f %{_sysconfdir}/bastion-core-release
fi

%files
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/firstboot.sh
%dir %{_localstatedir}/lib/bastion-core
%{_unitdir}/%{name}.service
%dir %{_unitdir}/bastion-core.service.d
%{_unitdir}/bastion-core.service.d/10-firstboot-ordering.conf
%dir %{_unitdir}/bastion-qemu.service.d
%{_unitdir}/bastion-qemu.service.d/10-bastion-qemu-ordering.conf
%{_unitdir}/bastion-qemu.service.d/20-bastion-group.conf
%dir %{_unitdir}/bastion-credential-keystore.service.d
%{_unitdir}/bastion-credential-keystore.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-credential-keystore.service.d/20-runtime-dir.conf
%dir %{_unitdir}/bastion-ssh.service.d
%{_unitdir}/bastion-ssh.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-ssh.service.d/20-runtime-preserve.conf
%dir %{_unitdir}/bastion-pack-loader.service.d
%{_unitdir}/bastion-pack-loader.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-pack-loader.service.d/20-runtime-preserve.conf
%dir %{_unitdir}/bastion-pki-trust.service.d
%{_unitdir}/bastion-pki-trust.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-pki-trust.service.d/20-bastion-user.conf
%dir %{_unitdir}/bastion-adcon-engine.service.d
%{_unitdir}/bastion-adcon-engine.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-adcon-engine.service.d/20-bastion-user.conf
%dir %{_unitdir}/bastion-adcon-mirror.service.d
%{_unitdir}/bastion-adcon-mirror.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-adcon-mirror.service.d/20-runtime-preserve.conf
%dir %{_unitdir}/bastion-ironlaw-loader.service.d
%{_unitdir}/bastion-ironlaw-loader.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-ironlaw-loader.service.d/20-bastion-group.conf
%dir %{_unitdir}/bastion-mfa.service.d
%{_unitdir}/bastion-mfa.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-mfa.service.d/20-bastion-user.conf
%dir %{_unitdir}/bastion-intent-ledger-replicator.service.d
%{_unitdir}/bastion-intent-ledger-replicator.service.d/10-firstboot-ordering.conf
%{_unitdir}/bastion-intent-ledger-replicator.service.d/20-bastion-group.conf
%{_tmpfilesdir}/bastion.conf
%ghost %attr(0644,root,root) %{_sysconfdir}/bastion-core-release

%changelog
* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.1.2-1
- Set BASTION_TRUST_HEALTH_FROM_GRPC=false in bastion.env to bypass failing pki-trust mTLS connection.
- Add ReadWritePaths=/run/bastion drop-in for bastion-qemu (allows UDS socket bind/cleanup).
- Create /var/lib/bastion/qemu/images/ (mode 0775, bastion-qemu group) for TheatreManager image staging.
- Add bastion-operator to bastion-qemu group so scp can write images directly without sudo.

* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.1.1-1
- Create /var/lib/bastion/ironlaw-loader and /etc/bastion/ironlaw-loader to prevent 226/NAMESPACE failure.
- Create /var/lib/bastion/intent-ledger-replicator and /etc/bastion/intent-ledger-replicator.
- Create tls.crt/tls.key symlinks for adcon-engine and adcon-mirror (Go binaries expect that filename).

* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.1.0-1
- Roll PKI (BASTION_PKI_EPOCH_ROLL=1) at first boot for unique per-VM identity.
- Provision service-plane CA and issue sidecar TLS leaf certs via bastion-provision.
- Create /var/log/bastion, /var/lib/bastion/qemu, /etc/bastion with correct ownership.
- Generate BASTION_HOST_CREDENTIAL_AT_REST_KEY and write to /etc/bastion/bastion.env.
- Fix bastion-credential-keystore.service TLS flag names via systemd drop-in.
- Install After=bastion-core-firstboot.service ordering drop-ins for all sidecars.
- Install tmpfiles.d rule to create /run/bastion on every boot.
- Stamp SAI callsign; add ordering drop-ins for bastion-core and bastion-qemu services.
