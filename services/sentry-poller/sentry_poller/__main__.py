from __future__ import annotations
import argparse
import logging
import os
import sys
import time

from .config import Config, load_config
from .sentry import SentryClient
from .devlake import DevLakeClient
from .sync import sync_all

log = logging.getLogger("sentry_poller")


def build_clients(cfg: Config, token: str):
    sentry = SentryClient(token, cfg.sentry_org)
    devlake = DevLakeClient(cfg.devlake_webhook_base)
    return sentry, devlake


def run_once(cfg: Config, token: str, dry_run: bool):
    sentry, devlake = build_clients(cfg, token)
    results = sync_all(sentry, devlake, cfg.projects, dry_run=dry_run)
    for proj, stats in zip(cfg.projects, results):
        log.info("sync %s: %s", proj.sentry_project, stats)
    return results


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser(prog="sentry-poller")
    ap.add_argument("--config", default=os.environ.get("SENTRY_POLLER_CONFIG", "config.yml"))
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    default=os.environ.get("SENTRY_POLLER_DRY_RUN") == "1")
    args = ap.parse_args(argv)

    token = os.environ.get("SENTRY_AUTH_TOKEN")
    if not token:
        log.error("falta env SENTRY_AUTH_TOKEN")
        return 2
    try:
        cfg = load_config(args.config)
    except (OSError, ValueError) as exc:
        log.error("config inválida: %s", exc)
        return 2

    if args.once:
        run_once(cfg, token, args.dry_run)
        return 0

    log.info("poller arrancado (cada %d min, dry_run=%s)", cfg.poll_interval_minutes, args.dry_run)
    while True:
        run_once(cfg, token, args.dry_run)
        time.sleep(cfg.poll_interval_minutes * 60)


if __name__ == "__main__":
    sys.exit(main())
