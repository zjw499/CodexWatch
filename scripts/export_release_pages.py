"""Export the exact backend disclosure pages for the public company website.

No workspace, credentials, account data or patient content is loaded.
"""
import argparse
from pathlib import Path
from types import SimpleNamespace

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server_workspace.release_api import install_release_routes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    app = FastAPI()
    config = SimpleNamespace(public_base_url='https://www.skydataservice.com/scribe-pilot',
                             support_email='zach@skydataservice.com')
    install_release_routes(app, SimpleNamespace(config=config), lambda: None, lambda: None, lambda: None)
    args.out.mkdir(parents=True, exist_ok=True)
    with TestClient(app) as client:
        for name in ('privacy', 'support', 'account-deletion'):
            response = client.get('/' + name)
            response.raise_for_status()
            (args.out / (name + '.html')).write_text(response.text, encoding='utf-8')
    print('Exported three public pages without loading private workspace data')


if __name__ == '__main__':
    main()
