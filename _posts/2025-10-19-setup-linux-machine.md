---
title: Setup Linux environment
category: operation
tags: [linux, system adaministration]
---

Setup Linux environment

# Setup VPN in headless environment

## Use network management to setup vpn

### basic steps

```
  To import and use your OpenVPN config:

  # Import the OpenVPN config file
  sudo nmcli connection import type openvpn file /path/to/your-config.ovpn

  # Connect to the VPN
  sudo nmcli connection up <connection-name>

  # Check status
  nmcli connection show --active

  # Disconnect
  sudo nmcli connection down <connection-name>

  If NetworkManager isn't installed on your server:

  # RHEL/Fedora
  sudo dnf install NetworkManager NetworkManager-openvpn

  # Ubuntu/Debian
  sudo apt install network-manager network-manager-openvpn

```

### Save user name and keep to ask password


```
  # Set username in vpn.data (not as a separate field)
  sudo nmcli connection modify rh_ovpn vpn.data "username=your-username"

  # Set password flags
  sudo nmcli connection modify rh_ovpn vpn.secrets "password-flags=2"
```

### troubleshooting

```
Check `journalctl -r` log
```

# Fedora

## dnf config
  
- Make sure /etc/dnf/dnf.conf is updated for trying fast mirror

```
[main]
gpgcheck=True
installonly_limit=3
clean_requirements_on_remove=True
best=False
skip_if_unavailable=True
max_parallel_downloads=10
fastestmirror=true
deltarpm=true
```

