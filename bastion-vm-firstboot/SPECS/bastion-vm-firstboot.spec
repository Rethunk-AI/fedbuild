Name:           bastion-vm-firstboot
Version:        0.3.0
Release:        1%{?dist}
Summary:        First-boot setup for coding-agent VM
License:        MIT
BuildArch:      noarch
BuildRequires:  systemd-rpm-macros

Requires:       bash
Requires:       curl
Requires:       systemd

Source0:        firstboot.sh
Source1:        bastion-vm-firstboot.service
Source2:        devbox-profile.sh
Source3:        user-sudoers
Source4:        agent-claude.md
Source5:        agent-settings.json
Source6:        Brewfile

%description
Runs once on first boot (as the 'user' account) to install Homebrew
and the development tools listed in the shipped Brewfile (formulae
that are bleeding-edge or have no signed RPM repo with an
always-update URL).

  (cloudflared is installed from its RPM repo and is NOT handled here.
  kubectl/kubernetes-cli uses brew because pkgs.k8s.io requires a
  pinned minor version in its URL, breaking the always-update policy.)

Also installs:
  /etc/profile.d/devbox.sh   — Go / Homebrew / editor environment
  /etc/sudoers.d/user        — passwordless sudo for coding-agent use

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_libexecdir}/%{name}/firstboot.sh
install -Dm644 %{SOURCE1} %{buildroot}%{_unitdir}/%{name}.service
install -Dm644 %{SOURCE2} %{buildroot}%{_sysconfdir}/profile.d/devbox.sh
install -Dm440 %{SOURCE3} %{buildroot}%{_sysconfdir}/sudoers.d/user
install -d %{buildroot}%{_localstatedir}/lib/%{name}
install -Dm644 %{SOURCE4} %{buildroot}%{_datadir}/%{name}/agent-claude.md
install -Dm644 %{SOURCE5} %{buildroot}%{_datadir}/%{name}/agent-settings.json
install -Dm644 %{SOURCE6} %{buildroot}%{_datadir}/%{name}/Brewfile

%post
%systemd_post %{name}.service

%preun
%systemd_preun %{name}.service

%postun
%systemd_postun_with_restart %{name}.service

%files
%dir %{_libexecdir}/%{name}
%{_libexecdir}/%{name}/firstboot.sh
%dir %attr(0755, user, user) %{_localstatedir}/lib/%{name}
%{_unitdir}/%{name}.service
%{_sysconfdir}/profile.d/devbox.sh
%{_sysconfdir}/sudoers.d/user
%dir %{_datadir}/%{name}
%{_datadir}/%{name}/agent-claude.md
%{_datadir}/%{name}/agent-settings.json
%{_datadir}/%{name}/Brewfile

%changelog
* Wed Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.3.0-1
- Add jq, yq, sqlite, buildah, skopeo to blueprint

* Wed Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.2.0-1
- Sync version to blueprint 0.2.0
- Add BuildRequires: systemd-rpm-macros

* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.1.0-1
- Bake Claude Code agent configuration into ~/.claude/ via firstboot
- Add CHANGELOG.md; reset versions to 0.1.0
- Initial package: firstboot service, devbox-profile, sudoers, done sentinel
