# DNS Teleport

DNS Teleport is a selfhosted setup that combines an SNI proxy with AdGuard Home. It provides ad blocking and a simple “teleport” style routing system that directs certain domains through specific upstreams. Everything is automated through a single setup script.

## Run this installer on a fresh install of Ubuntu.

What the Installer Sets Up

The script handles the full environment:
	•	Installs required packages such as nginx, dnsmasq, certbot, fail2ban and Docker.
	•	Requests or reuses Let’s Encrypt certificates for your domain.
	•	Configures nginx stream mode for SNI routing.
	•	Your chosen domain goes to AdGuard Home on port 8443.
	•	Other SNI traffic is forwarded based on the requested hostname.
	•	Prepares Dnsmasq to forward DNS lookups through the server’s IP.
	•	Automates AdGuard Home installation
	•	Creates a Docker Compose configuration and starts AdGuard Home.
	•	Opens the necessary firewall ports and enables fail2ban.

Quick Install

Run the installer with one command:

```
curl -fsSL https://raw.githubusercontent.com/copreus/selfhosted-sni-proxy/refs/heads/main/setup.sh | bash
```
Requirements
	•	Ubuntu 24.04 server
	•	Root access
	•	A domain pointing to your server’s IPv4 address
	•	Ports 80 and 443 available for certificate generation

During Installation

The script will ask for:
	•	Your domain
	•	Optional email for certificate notices
	•	Server IP (you can auto-detect it)
	•	AdGuard Home username and password
	•	A device name and client ID for access control

