from pathlib import Path
import pytest
from sentry_poller.config import load_config

def test_load_config_parses_projects(tmp_path: Path):
    cfg_file = tmp_path / "config.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects:\n"
        "  - devlake_project: tallone-sistema-de-gestion\n"
        "    sentry_project: tallone-prod\n"
        "    incidents_connection_id: 4\n"
    )
    cfg = load_config(str(cfg_file))
    assert cfg.sentry_org == "greencode"
    assert cfg.poll_interval_minutes == 30
    assert cfg.devlake_webhook_base == "http://devlake:8080/plugins/webhook"
    assert len(cfg.projects) == 1
    assert cfg.projects[0].sentry_project == "tallone-prod"
    assert cfg.projects[0].incidents_connection_id == 4

def test_load_config_multiple_sentry_projects_same_devlake_project(tmp_path: Path):
    # pinvest: backend + frontend son 2 Sentry projects que atribuyen al mismo
    # project DevLake via la misma incidents connection.
    cfg_file = tmp_path / "config.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects:\n"
        "  - devlake_project: pinvest-platform\n"
        "    sentry_project: pinvest-backend\n"
        "    incidents_connection_id: 6\n"
        "  - devlake_project: pinvest-platform\n"
        "    sentry_project: pinvest-frontend\n"
        "    incidents_connection_id: 6\n"
    )
    cfg = load_config(str(cfg_file))
    assert len(cfg.projects) == 2
    assert {p.sentry_project for p in cfg.projects} == {"pinvest-backend", "pinvest-frontend"}
    assert all(p.devlake_project == "pinvest-platform" for p in cfg.projects)
    assert all(p.incidents_connection_id == 6 for p in cfg.projects)


def test_repo_config_yml_is_valid():
    # el config.yml versionado (el que viaja en la imagen) debe parsear siempre.
    repo_cfg = Path(__file__).resolve().parents[1] / "config.yml"
    cfg = load_config(str(repo_cfg))
    assert len(cfg.projects) >= 1
    # pinvest debe estar con sus 2 Sentry projects apuntando a la conn 6.
    pinvest = [p for p in cfg.projects if p.devlake_project == "pinvest-platform"]
    assert {p.sentry_project for p in pinvest} == {"pinvest-backend", "pinvest-frontend"}
    assert all(p.incidents_connection_id == 6 for p in pinvest)


def test_load_config_rejects_missing_field(tmp_path: Path):
    cfg_file = tmp_path / "bad.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects:\n"
        "  - devlake_project: x\n"
        "    sentry_project: y\n"  # falta incidents_connection_id
    )
    import pytest
    with pytest.raises(ValueError, match="incidents_connection_id"):
        load_config(str(cfg_file))

def test_load_config_rejects_malformed_yaml(tmp_path: Path):
    cfg_file = tmp_path / "bad.yml"
    cfg_file.write_text("sentry_org: [unclosed\n")
    with pytest.raises(ValueError):
        load_config(str(cfg_file))

def test_load_config_rejects_non_list_projects(tmp_path: Path):
    cfg_file = tmp_path / "bad.yml"
    cfg_file.write_text(
        "sentry_org: greencode\n"
        "poll_interval_minutes: 30\n"
        "devlake_webhook_base: http://devlake:8080/plugins/webhook\n"
        "projects: not-a-list\n"
    )
    with pytest.raises(ValueError, match="projects"):
        load_config(str(cfg_file))
