Name:           bastion-core-firstboot
Version:        0.3.0
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

Also installs systemd drop-ins on bastion-core.service and bastion-qemu.service
that add After=bastion-core-firstboot.service so neither the C2 server nor the
QEMU sidecar starts before the per-VM PKI is ready.

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_libexecdir}/%{name}/firstboot.sh
install -Dm644 %{SOURCE1} %{buildroot}%{_unitdir}/%{name}.service
install -Dm644 %{SOURCE2} \
    %{buildroot}%{_unitdir}/bastion-core.service.d/10-firstboot-ordering.conf
install -Dm644 %{SOURCE3} \
    %{buildroot}%{_unitdir}/bastion-qemu.service.d/10-bastion-qemu-ordering.conf
install -d %{buildroot}%{_localstatedir}/lib/bastion-core

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
%ghost %attr(0644,root,root) %{_sysconfdir}/bastion-core-release

%changelog
* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.3.0-1
- chown service-ca tree to root:bastion after provision so bastion user can read certs.
- Set chmod 750 on service-ca dir, 640 on certs/keys and issued/ subtree.

* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.2.0-1
- Run bastion-provision at firstboot to create service-plane CA and issue all
  sidecar TLS leaf certs; fixes bastion-qemu.service 226/NAMESPACE failure.
- Create /var/lib/bastion/qemu (ReadWritePaths dir required before exec).
- Symlink ca.pem -> ca.crt in service-ca dir (Go binary references ca.pem).
- Add bastion-qemu.service.d drop-in for After=bastion-core-firstboot.service.
- Write {"type":"module"} to /usr/lib64/bastion-core/package.json before
  invoking node; bastion-core dist compiled with module:NodeNext emits ESM
  import statements that cause SyntaxError without the ESM marker. Proper fix
  belongs in bastion-core.spec %install; this unblocks firstboot now.
- Pipe node output through tee /dev/ttyS0 so provision errors are visible on
  serial console without requiring SSH access post-failure.

* Wed Apr 22 2026 Bastion Agent <bastion-agent@rethunk.tech> - 0.1.0-1
- Initial: PKI roll (BASTION_PKI_EPOCH_ROLL=1) at first boot; SAI stamp;
  bastion-core.service drop-in for ordering.
