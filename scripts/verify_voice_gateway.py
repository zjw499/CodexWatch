"""Unauthenticated public TLS and route-isolation check; never contacts OpenAI."""
import argparse
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gateway", default="https://zwyattpc.tail488e93.ts.net:8443")
    args = parser.parse_args()
    base = args.gateway.rstrip("/")
    url = urlsplit(base)
    if (url.scheme != "https" or not (url.hostname or "").endswith(".ts.net")
            or url.port != 8443 or url.path or url.query or url.fragment or url.username or url.password):
        parser.error("Use the HTTPS Tailscale Funnel origin on port 8443.")
    opener = build_opener(NoRedirects())
    for path, method, expected in [("/voice/v1/health", "GET", 200), ("/voice/v1/config", "GET", 401),
                                    ("/voice/v1/diagnostics", "POST", 401), ("/api/recordings", "GET", 404),
                                    ("/api/voice/diagnostics", "GET", 404), ("/api/admin/voice/policy", "GET", 404)]:
        try:
            with opener.open(Request(base + path, method=method, headers={"Accept": "application/json"}), timeout=15) as response:
                status = response.status
                if path.endswith("/health"):
                    health = json.loads(response.read(4096))
                    if health.get("ok") is not True or health.get("version") != 1:
                        print("Voice health version check failed.", file=sys.stderr)
                        return 1
        except HTTPError as error:
            status = error.code
            error.close()
        except (URLError, TimeoutError, ValueError):
            print(f"Public TLS connection failed for {path}.", file=sys.stderr)
            return 1
        print(f"{path}: {status} (expected {expected})")
        if status != expected:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
