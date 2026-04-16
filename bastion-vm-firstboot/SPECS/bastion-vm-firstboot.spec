Name:           bastion-vm-firstboot
Version:        0.1.0
Release:        1%{?dist}
Summary:        First-boot setup for coding-agent VM
License:        MIT
BuildArch:      noarch

Requires:       bash
Requires:       curl
Requires:       systemd

Source0:        firstboot.sh
Source1:        bastion-vm-firstboot.service
Source2:        devbox-profile.sh
Source3:        user-sudoers

%description
Runs once on first boot (as the 'user' account) to install Homebrew
and the development tools that are either bleeding-edge or have no
signed RPM repo with an always-update URL:

  actionlint, buf, kubernetes-cli, semgrep,
  stripe-cli, supabase, uv, watchexec

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

%changelog
* Thu Apr 16 2026 Damon Blais <damon.blais@gmail.com> - 0.1.0-1
- Bake Claude Code agent configuration into ~/.claude/ via firstboot
- Add CHANGELOG.md; reset versions to 0.1.0
- Initial package: firstboot service, devbox-profile, sudoers, done sentinel
