#!/usr/bin/env python3
"""Dependency-free structural checks for the shared chaos dashboard."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SHARED_DASHBOARD = ROOT / "grafana" / "dashboards" / "chaos" / "chaos-tests.json"
DEMO_DASHBOARD = (
    ROOT / "grafana" / "dashboards" / "chaos" / "deep-tech-search-demo.json"
)
DEPLOY_SCRIPT = ROOT / "grafana" / "deploy-dashboard.sh"
SCRAPE_CONFIG = ROOT / "grafana" / "scrape.yml"
VICTORIA_INSTALLER = ROOT / "grafana" / "01-victoria.sh"


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def main() -> None:
    dashboard = json.loads(SHARED_DASHBOARD.read_text(encoding="utf-8"))
    deploy_script = DEPLOY_SCRIPT.read_text(encoding="utf-8")
    scrape_config = SCRAPE_CONFIG.read_text(encoding="utf-8")
    victoria_installer = VICTORIA_INSTALLER.read_text(encoding="utf-8")
    assert 'dashboards/chaos/chaos-tests.json' in deploy_script
    assert "GRAFANA_DASH_FILE" in deploy_script
    assert "job_name: ydb-partition-observer" in scrape_config
    assert "/etc/prometheus/ydb-partition-observer.yml" in scrape_config
    assert "build_observer_yml" in victoria_installer
    assert 'ydb-partition-observer.yml"' in victoria_installer
    panels = dashboard["panels"]
    ids = [panel["id"] for panel in panels]
    assert len(ids) == len(set(ids)), "dashboard contains duplicate panel IDs"
    assert dashboard.get("timepicker", {}).get("nowDelay") == "2s"

    titles = {panel.get("title") for panel in panels}
    for title in {
        "Search index partitions",
        "Partitions by table/index",
        "Data size by table/index",
        "CPU by table/index",
        "Retries / Dropped",
        "User pool utilization by node",
        "IC pool utilization by node",
    }:
        assert title in titles, f"missing dashboard panel: {title}"

    expressions = {
        target["expr"]
        for node in walk(dashboard)
        for target in node.get("targets", [])
        if isinstance(target, dict) and "expr" in target
    }
    for metric in {
        "ydb_partition_count",
        "ydb_partition_size_bytes",
        "ydb_partition_cpu_cores",
        "ydb_workload_target_rps",
        "ydb_workload_dropped",
        "utils_ElapsedMicrosec",
        "utils_CurrentThreadCount",
    }:
        assert any(metric in expression for expression in expressions), metric

    for node in walk(dashboard):
        if "spanNulls" in node:
            assert node["spanNulls"] is not True, "stale values must not be connected"

    demo = json.loads(DEMO_DASHBOARD.read_text(encoding="utf-8"))
    demo_panels = demo["panels"]
    demo_ids = [panel["id"] for panel in demo_panels]
    assert len(demo_ids) == len(set(demo_ids)), "demo dashboard has duplicate panel IDs"
    assert demo.get("timepicker", {}).get("nowDelay") == "2s"

    annotation_tags = {
        item.get("name"): set(item.get("tags", []))
        for item in demo.get("annotations", {}).get("list", [])
        if item.get("type") == "tags"
    }
    assert "Хаосы" not in annotation_tags
    assert annotation_tags.get("Отказы") == {"chaos", "event:failure"}
    assert annotation_tags.get("Профили нагрузки") == {"chaos", "event:workload"}
    assert annotation_tags.get("Управляющие действия") == {
        "chaos",
        "event:control",
    }

    demo_titles = {panel.get("title") for panel in demo_panels}
    for title in {
        "Поисковые запросы и DML, RPS",
        "Задержка p95, мс",
        "Ошибки и ретраи, RPS",
        "User pool CPU по dynamic-узлам, %",
        "Самая загруженная таблетка, %",
        "Партиции",
    }:
        assert title in demo_titles, f"missing demo dashboard panel: {title}"

    assert len(demo_panels) == 6, "demo dashboard must fit into two rows"
    assert all(
        variable.get("hide") == 2
        for variable in demo.get("templating", {}).get("list", [])
    ), "fixed dashboard variables must be hidden"

    demo_expressions = {
        target["expr"]
        for node in walk(demo)
        for target in node.get("targets", [])
        if isinstance(target, dict) and "expr" in target
    }
    for metric in {
        "ydb_workload_target_rps",
        "ydb_workload_error_rps",
        "ydb_workload_retry_rps",
        "ydb_partition_count",
        "ydb_tablet_cpu_cores",
    }:
        assert any(metric in expression for expression in demo_expressions), metric

    assert not any(
        "ydb_workload_dropped" in expression for expression in demo_expressions
    ), "generator backpressure is diagnostic, not a YDB error"

    assert any(
        'scenario="dml_check"' in expression for expression in demo_expressions
    ), "demo must show the complete DML verification cycle"
    assert not any(
        'scenario="write"' in expression or 'scenario="read_after_write"' in expression
        for expression in demo_expressions
    ), "demo must hide internal DML steps"

    for node in walk(demo):
        if "spanNulls" in node:
            assert node["spanNulls"] is not True, "demo must not connect stale values"

    partition_panel = next(panel for panel in demo_panels if panel.get("title") == "Партиции")
    assert partition_panel["type"] == "timeseries"
    partition_expressions = [target["expr"] for target in partition_panel["targets"]]
    assert any("indexImplDocsTable" in expression for expression in partition_expressions)
    assert any("indexImplPostingTable" in expression for expression in partition_expressions)
    for title in {
        "Внутренние чтения и записи, строк/с",
        "Доступные узлы и серверы",
        "Данные и индексы",
        "Метрики качества поиска",
    }:
        assert title not in demo_titles, f"static panel must stay out of demo: {title}"

    print("dashboard smoke: OK")


if __name__ == "__main__":
    main()
