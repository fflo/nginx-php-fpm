## Custom Nginx Config files
Sometimes you need a custom config file for nginx to do rewrites or password protection, etc. For this reason we've included the ability to have custom nginx configs pulled directly from your git source. Please have a read of the [repo layout guidelines](repo_layout.md) for more information. Its pretty simple to enable this, all you need to do is include a folder in the root of your repository called ```conf/nginx/``` within this folder you need to include a file called ```nginx-site.conf``` which will contain your default nginx site config. If you wish to have a custom file for SSL you simply include a file called ```nginx-site-ssl.conf``` in the same directory. These files will then be swapped in after you code is cloned.

## REAL IP / X-Forwarded-For Headers
If you run the container behind a reverse proxy or load balancer (nginx, Traefik, Caddy, an AWS ELB, Cloudflare Tunnel, ...) nginx and PHP would otherwise only see the proxy's IP and plain HTTP. Two flags fix that:
```
-e "REAL_IP_HEADER=1"
-e "REAL_IP_FROM=10.1.0.0/16"
```
With `REAL_IP_HEADER=1` the container trusts the `X-Forwarded-For` and `X-Forwarded-Proto` headers **from the proxies listed in `REAL_IP_FROM`** (space or comma separated CIDRs; default `172.16.0.0/12`, which covers Docker's default bridge networks):

- `$remote_addr` / `$_SERVER['REMOTE_ADDR']` and the access log show the real client IP (`real_ip_recursive on`, so chains of proxies work).
- `$_SERVER['HTTPS']` is `on` when the proxy sent `X-Forwarded-Proto: https`, so frameworks generate `https://` URLs and secure cookies correctly even though the container itself speaks plain HTTP.

`User-Agent`, `Host`, `Referer` and the other request headers are forwarded by every reverse proxy unchanged; nothing needs enabling for those.

Only set `REAL_IP_HEADER=1` when a proxy really is in front of the container: with it enabled, a client that can reach port 80 directly could spoof both headers.

Example:
```
docker run -d -e "REAL_IP_HEADER=1" -e "REAL_IP_FROM=10.1.0.0/16,192.168.100.0/24" richarvey/nginx-php-fpm:latest
```
