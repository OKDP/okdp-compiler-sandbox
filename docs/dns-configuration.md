# DNS Configuration Guide

This guide provides detailed instructions for configuring local DNS resolution for the OKDP sandbox environment.

**Note**: The sandbox uses different DNS ports depending on your operating system:
- **Linux/macOS (Shell)**: Port 30053
- **Windows (PowerShell)**: Port 53 (standard DNS port)

## Option 1: Local DNS Server Configuration (Recommended)

### Linux/macOS Configuration (Shell)

The sandbox deploys a DNS server exposed on port 30053. Configure your local resolver to point to `localhost:30053` for the `okdp.sandbox` domain.

#### macOS Configuration

```bash
sudo mkdir -p /etc/resolver
echo "nameserver 127.0.0.1" | sudo tee /etc/resolver/okdp.sandbox
echo "port 30053" | sudo tee -a /etc/resolver/okdp.sandbox
```

#### Linux with systemd-resolved

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
cat > /tmp/okdp-sandbox.conf <<EOF
[Resolve]
DNS=127.0.0.1:30053
Domains=~okdp.sandbox
EOF
sudo mv /tmp/okdp-sandbox.conf /etc/systemd/resolved.conf.d/
sudo systemctl restart systemd-resolved
```

#### Linux with NetworkManager

Route only `okdp.sandbox` to the sandbox: the sandbox's DNS server
forwards every other name to the resolvers of the kind node, hence of
this host, so making it the host's only resolver loops (CoreDNS's loop
plugin then stops it). When NetworkManager hands DNS to
systemd-resolved (the common case), use the systemd-resolved drop-in
above. With NetworkManager's dnsmasq plugin (`dns=dnsmasq`):

```bash
echo "server=/okdp.sandbox/127.0.0.1#30053" | sudo tee /etc/NetworkManager/dnsmasq.d/okdp-sandbox.conf
sudo systemctl restart NetworkManager
```

#### Linux with dnsmasq

```bash
echo "server=/okdp.sandbox/127.0.0.1#30053" | sudo tee -a /etc/dnsmasq.conf
sudo systemctl restart dnsmasq
```

### Windows Configuration (PowerShell)

The sandbox deploys a DNS server exposed on port 53 (standard DNS port). Configure your local resolver to point to `localhost:53` for the `okdp.sandbox` domain.

Route only `okdp.sandbox` to it, with a Name Resolution Policy Table
rule: making it the adapter's only DNS server loops, since the sandbox's
DNS server forwards every other name to the host's resolvers.

1. Open PowerShell as Administrator
2. Run:
```powershell
Add-DnsClientNrptRule -Namespace ".okdp.sandbox" -NameServers "127.0.0.1"
```

## Verification

### Linux/macOS Verification

To verify that DNS resolution is working correctly:

```bash
# Test with dig
dig @127.0.0.1 -p 30053 okdp-ui.okdp.sandbox

# Test DNS resolution
nslookup -port=30053 okdp-ui.okdp.sandbox 127.0.0.1
# Should resolve to 127.0.0.1
```

### Windows Verification

To verify that DNS resolution is working correctly:

```powershell
# Test with nslookup
nslookup okdp-ui.okdp.sandbox

# Test with PowerShell
Resolve-DnsName okdp-ui.okdp.sandbox
# Should resolve to 127.0.0.1
```

## Option 2: Manual /etc/hosts Configuration

Add the following entries to your `/etc/hosts` file for each service that will be deployed:
```
127.0.0.1 keycloak.okdp.sandbox kad.okdp.sandbox okdp-server.okdp.sandbox okdp-ui.okdp.sandbox 
```

A project's services have two labels below the suffix (`<label>.<namespace>.okdp.sandbox`, e.g. `trino.demo.okdp.sandbox`): the resolvers above answer them all, `/etc/hosts` needs each one written out.

**Important**: Always use a single line for all hostnames pointing to 127.0.0.1. Having multiple lines with the same IP address (127.0.0.1) can cause DNS resolution problems.

**Note**: You will need to manually add DNS entries for each additional service deployed through the frontend.


## Troubleshooting

### DNS Server Not Responding

#### Linux/macOS
- Ensure the Kind cluster is running: `kind get clusters`
- Check that port 30053 is properly mapped: `docker ps | grep okdp-sandbox`
- Verify the DNS service is running in the cluster: `kubectl get svc -A | grep dns`

#### Windows
- Ensure the Kind cluster is running: `kind get clusters`
- Check that port 53 is properly mapped: `docker ps | findstr okdp-sandbox`
- Verify the DNS service is running in the cluster: `kubectl get svc -A | findstr dns`

### DNS Resolution Still Not Working
- Clear DNS cache:
  - **macOS**: `sudo dscacheutil -flushcache`
  - **Linux**: `sudo systemctl restart systemd-resolved` or `sudo service nscd restart`
  - **Windows**: `ipconfig /flushdns`

### Reverting Changes
- **macOS**: `sudo rm /etc/resolver/okdp.sandbox`
- **Linux (systemd-resolved)**: `sudo rm /etc/systemd/resolved.conf.d/okdp-sandbox.conf && sudo systemctl restart systemd-resolved`
- **Linux (NetworkManager with dnsmasq)**: `sudo rm /etc/NetworkManager/dnsmasq.d/okdp-sandbox.conf && sudo systemctl restart NetworkManager`
- **Windows**: `Get-DnsClientNrptRule | Where-Object Namespace -eq ".okdp.sandbox" | Remove-DnsClientNrptRule -Force`