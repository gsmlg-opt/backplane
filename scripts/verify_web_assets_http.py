#!/usr/bin/env python3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class AssetParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stylesheets = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "link" and "stylesheet" in attributes.get("rel", "").split():
            if href := attributes.get("href"):
                self.stylesheets.append(href)
        elif tag == "script" and (src := attributes.get("src")):
            self.scripts.append(src)


def fetch(url, attempts=1):
    last_error = None
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                body = response.read()
                if response.status != 200 or not body:
                    raise RuntimeError(
                        f"{url} returned status {response.status} with {len(body)} bytes"
                    )
                return body, response.headers.get_content_type()
        except (OSError, urllib.error.URLError, RuntimeError) as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(1)
    raise RuntimeError(f"could not fetch {url}: {last_error}")


def verify_page(url):
    body, content_type = fetch(url, attempts=60)
    if content_type != "text/html":
        raise RuntimeError(f"{url} returned unexpected content type {content_type}")

    parser = AssetParser()
    parser.feed(body.decode("utf-8"))
    stylesheets = [path for path in parser.stylesheets if path.startswith("/assets/")]
    scripts = [path for path in parser.scripts if path.startswith("/assets/")]
    assets = [(path, "text/css") for path in stylesheets]
    assets += [(path, "javascript") for path in scripts]

    if not stylesheets or not scripts:
        raise RuntimeError(f"{url} did not render both stylesheet and script assets")

    for path, expected_type in assets:
        asset_url = urllib.parse.urljoin(url, path)
        asset_body, asset_type = fetch(asset_url)
        if expected_type == "text/css" and asset_type != "text/css":
            raise RuntimeError(f"{asset_url} returned unexpected content type {asset_type}")
        if expected_type == "javascript" and "javascript" not in asset_type:
            raise RuntimeError(f"{asset_url} returned unexpected content type {asset_type}")
        print(f"verified {asset_url} ({asset_type}, {len(asset_body)} bytes)")


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify_web_assets_http.py API_PAGE_URL ADMIN_PAGE_URL")
    for page_url in sys.argv[1:]:
        verify_page(page_url)


if __name__ == "__main__":
    main()
